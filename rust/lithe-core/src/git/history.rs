//! Bounded Git reference snapshots and incrementally consumable history pages.

use super::{
    command_value, execute_git_readonly_with_environment, git_process, is_safe_pathspec,
    parse_commit, parse_reference, readonly_command, validate_root, GitCommandRequest,
    INTERNAL_REF_PREFIX,
};
use crate::protocol::{
    cancellation, CoreError, ErrorCode, GitCommitResponse, GitHistoryCursorCloseResponse,
    GitHistoryPageResponse, GitHistoryResponse, GitReferenceResponse, GitReferencesResponse,
};
use serde::Deserialize;
use std::io::{BufRead, BufReader, Read};
use std::process::{Child, ExitStatus, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender};
use std::sync::{Mutex, OnceLock};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const DEFAULT_HISTORY_LIMIT: usize = 300;
const MAX_HISTORY_COMMITS: usize = 5_000;
const MAX_FILTERED_SCAN_COMMITS: usize = 50_000;
const RECENT_BRANCH_LIMIT: usize = 5;
const RECENT_BRANCH_REFLOG_LIMIT: &str = "100";
const DEFAULT_BRANCH_FALLBACKS: [&str; 2] = ["main", "master"];
const HISTORY_CURSOR_IDLE_TTL: Duration = Duration::from_secs(120);
const HISTORY_CURSOR_REAPER_INTERVAL: Duration = Duration::from_secs(1);
const HISTORY_PAGE_DEADLINE: Duration = Duration::from_secs(30);
const HISTORY_STREAM_POLL_INTERVAL: Duration = Duration::from_millis(10);
const MAX_HISTORY_SESSIONS: usize = 8;

static HISTORY_SESSIONS: OnceLock<Mutex<HistorySessionRegistry>> = OnceLock::new();
static HISTORY_REAPER: OnceLock<()> = OnceLock::new();
static NEXT_HISTORY_CURSOR: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Backward-compatible request for references and the first bounded history page.
pub struct GitHistoryRequest {
    pub root: String,
    #[serde(default)]
    pub reference: Option<String>,
    #[serde(default = "default_history_limit")]
    pub limit: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for repository references and identity metadata.
pub struct GitReferencesRequest {
    pub root: String,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
/// Optional backend history filter evaluated across the repository log rather than one loaded page.
pub struct GitHistoryFilter {
    /// Free-text terms matched case-insensitively across subject, hash, author, and decorations.
    #[serde(default)]
    pub text_terms: Vec<String>,
    /// Author substrings matched case-insensitively (any match passes).
    #[serde(default)]
    pub authors: Vec<String>,
    /// Exact author email or name matched case-insensitively.
    #[serde(default)]
    pub exact_author: Option<String>,
    /// Inclusive lower date bound forwarded to `git log --since`.
    #[serde(default)]
    pub after: Option<String>,
    /// Exclusive upper date bound forwarded to `git log --until`.
    #[serde(default)]
    pub before: Option<String>,
    /// Workspace-relative file or substring path filters.
    #[serde(default)]
    pub paths: Vec<String>,
}

impl GitHistoryFilter {
    fn is_empty(&self) -> bool {
        self.text_terms.is_empty()
            && self.authors.is_empty()
            && self
                .exact_author
                .as_deref()
                .is_none_or(|v| v.trim().is_empty())
            && self.after.as_deref().is_none_or(|v| v.trim().is_empty())
            && self.before.as_deref().is_none_or(|v| v.trim().is_empty())
            && self.paths.is_empty()
    }

    fn normalized(self) -> Option<Self> {
        let filter = Self {
            text_terms: self
                .text_terms
                .into_iter()
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
                .collect(),
            authors: self
                .authors
                .into_iter()
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
                .collect(),
            exact_author: self
                .exact_author
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty()),
            after: self
                .after
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty()),
            before: self
                .before
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty()),
            paths: self
                .paths
                .into_iter()
                .map(|v| v.trim().replace('\\', "/"))
                .filter(|v| !v.is_empty())
                .collect(),
        };
        (!filter.is_empty()).then_some(filter)
    }

    fn validate(&self) -> Result<(), CoreError> {
        for boundary in [self.after.as_deref(), self.before.as_deref()]
            .into_iter()
            .flatten()
        {
            if boundary.starts_with('-') || boundary.contains('\0') {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid Git history date filter",
                ));
            }
        }
        for path in &self.paths {
            if path.contains('\0') || path.starts_with('-') {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid Git history path filter",
                ));
            }
        }
        Ok(())
    }

    fn matches_metadata(&self, commit: &GitCommitResponse) -> bool {
        if let Some(exact) = self.exact_author.as_deref() {
            if !commit.author_email.eq_ignore_ascii_case(exact)
                && !commit.author_name.eq_ignore_ascii_case(exact)
            {
                return false;
            }
        }
        if !self.authors.is_empty() {
            let name_lower = commit.author_name.to_lowercase();
            let email_lower = commit.author_email.to_lowercase();
            let matched = self.authors.iter().any(|author| {
                let needle = author.to_lowercase();
                name_lower.contains(&needle) || email_lower.contains(&needle)
            });
            if !matched {
                return false;
            }
        }
        if !self.text_terms.is_empty() {
            let fields = [
                commit.subject.to_lowercase(),
                commit.hash.to_lowercase(),
                commit.short_hash.to_lowercase(),
                commit.author_name.to_lowercase(),
                commit.author_email.to_lowercase(),
                commit.decorations.to_lowercase(),
            ];
            let all_match = self.text_terms.iter().all(|term| {
                let needle = term.to_lowercase();
                fields.iter().any(|field| field.contains(&needle))
            });
            if !all_match {
                return false;
            }
        }
        true
    }

    fn single_hash_prefix(&self) -> Option<&str> {
        if self.text_terms.len() != 1
            || !self.authors.is_empty()
            || self.exact_author.is_some()
            || self.after.is_some()
            || self.before.is_some()
            || !self.paths.is_empty()
        {
            return None;
        }
        let term = self.text_terms[0].as_str();
        ((4..=40).contains(&term.len()) && term.bytes().all(|byte| byte.is_ascii_hexdigit()))
            .then_some(term)
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for one bounded page of commit history from an optional reference.
pub struct GitHistoryPageRequest {
    pub root: String,
    #[serde(default)]
    pub reference: Option<String>,
    /// Traversal order is fixed for the lifetime of a cursor. Omission keeps
    /// existing clients on topology order; macOS opts into IDEA's date order.
    #[serde(default)]
    pub order: HistoryOrder,
    #[serde(default)]
    pub cursor: Option<String>,
    /// Deprecated compatibility field; new callers omit it and continue with `cursor`.
    #[serde(default)]
    pub offset: Option<usize>,
    #[serde(default = "default_history_limit")]
    pub limit: usize,
    /// Optional repository-wide filter applied before paging commits back to the caller.
    #[serde(default)]
    pub filter: Option<GitHistoryFilter>,
}

/// Git-native ordering policies that both preserve child-before-parent order.
#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum HistoryOrder {
    /// Group branch histories, preserving the original API behavior.
    #[default]
    Topo,
    /// Order by committer date whenever topology permits, as IDEA Normal does.
    Date,
}

impl HistoryOrder {
    fn argument(self) -> &'static str {
        match self {
            Self::Topo => "--topo-order",
            Self::Date => "--date-order",
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to release an incremental history cursor that will not be consumed further.
pub struct GitHistoryCursorCloseRequest {
    pub root: String,
    pub cursor: String,
}

fn default_history_limit() -> usize {
    DEFAULT_HISTORY_LIMIT
}

/// Returns the legacy combined history snapshot while newer clients migrate to pages.
pub fn history(request: GitHistoryRequest) -> Result<GitHistoryResponse, CoreError> {
    let references = references(GitReferencesRequest {
        root: request.root.clone(),
    })?;
    let page = history_page(GitHistoryPageRequest {
        root: request.root.clone(),
        reference: request.reference,
        order: HistoryOrder::default(),
        cursor: None,
        offset: None,
        limit: request.limit,
        filter: None,
    })?;
    if let Some(cursor) = page.next_cursor.as_deref() {
        let _ = close_history_cursor(GitHistoryCursorCloseRequest {
            root: request.root,
            cursor: cursor.to_string(),
        });
    }
    Ok(GitHistoryResponse {
        references: references.references,
        recent_references: references.recent_references,
        commits: page.commits,
        has_more: page.has_more,
        user_name: references.user_name,
        user_email: references.user_email,
    })
}

/// Returns references separately so paging and branch selection do not rescan them.
pub fn references(request: GitReferencesRequest) -> Result<GitReferencesResponse, CoreError> {
    let root = validate_root(&request.root)?;
    let user_name = git_config_value(&root, "user.name");
    let user_email = git_config_value(&root, "user.email");
    let reference_arguments = vec![
        "for-each-ref".to_string(),
        "--sort=refname".to_string(),
        "--format=%(refname)\t%(refname:short)\t%(HEAD)\t%(upstream:short)\t%(upstream)\t%(upstream:track,nobracket)\t%(objecttype)\t%(*objecttype)"
            .to_string(),
        "refs/heads".to_string(),
    ];
    // `upstream:track` is evaluated independently for each local branch. A fixed
    // locale keeps its machine-parsed ahead/behind labels deterministic.
    let reference_output = execute_git_readonly_with_environment(
        &root,
        &reference_arguments,
        None,
        &[("LC_ALL".to_string(), "C".to_string())],
    )?;
    if reference_output.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git references failed")
                .with_details(reference_output.output),
        );
    }

    let mut references = reference_output
        .output
        .lines()
        .filter_map(parse_reference)
        .collect::<Vec<_>>();
    let nonlocal_reference_output = readonly_command(GitCommandRequest {
        root: root.clone(),
        arguments: vec![
            "for-each-ref".to_string(),
            "--sort=refname".to_string(),
            "--format=%(refname)\t%(refname:short)\t%(HEAD)\t%(upstream:short)\t%(upstream)\t%(upstream:track,nobracket)\t%(objecttype)\t%(*objecttype)"
                .to_string(),
            "refs/remotes".to_string(),
            "refs/tags".to_string(),
        ],
        input: None,
    })?;
    if nonlocal_reference_output.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git references failed")
                .with_details(nonlocal_reference_output.output),
        );
    }
    references.extend(
        nonlocal_reference_output
            .output
            .lines()
            .filter_map(parse_reference),
    );
    let recent_references = recent_local_references(&root, &references, RECENT_BRANCH_LIMIT);
    Ok(GitReferencesResponse {
        references,
        recent_references,
        user_name,
        user_email,
    })
}

/// Returns the next page from one bounded Git log stream.
pub fn history_page(request: GitHistoryPageRequest) -> Result<GitHistoryPageResponse, CoreError> {
    if request.cursor.is_some() && request.offset.is_some() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git history page cannot combine cursor and offset",
        ));
    }
    let filter = request.filter.and_then(GitHistoryFilter::normalized);
    if let Some(ref active_filter) = filter {
        active_filter.validate()?;
    }
    if let Some(offset) = request.offset {
        if filter.is_some() {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Git history filter requires cursor pagination instead of offset",
            ));
        }
        return offset_history_page(
            request.root,
            request.reference,
            request.order,
            offset,
            request.limit,
        );
    }
    let root = validate_root(&request.root)?;
    validate_reference(request.reference.as_deref())?;
    cleanup_expired_history_sessions();

    let is_initial_filtered_request = request.cursor.is_none() && filter.is_some();
    let (mut session, lease) = if let Some(cursor) = request.cursor.as_deref() {
        take_history_session(cursor)?.ok_or_else(|| invalid_history_cursor(cursor))?
    } else {
        let lease = reserve_history_session_slot()?;
        let session = HistorySession::start(
            root.clone(),
            request.reference.clone(),
            request.order,
            filter.clone(),
        )?;
        (session, lease)
    };
    if session.root != root
        || session.reference != request.reference
        || session.order != request.order
        || session.filter != filter
    {
        let cursor = session.cursor.clone();
        lease.store(session)?;
        return Err(invalid_history_cursor(&cursor));
    }

    let limit = request.limit.clamp(
        1,
        MAX_HISTORY_COMMITS.saturating_sub(session.emitted).max(1),
    );
    let page = session.read_page(limit);
    match page {
        Ok((mut commits, has_more)) => {
            if is_initial_filtered_request && commits.is_empty() {
                if let Some(hash_prefix) = filter
                    .as_ref()
                    .and_then(GitHistoryFilter::single_hash_prefix)
                {
                    if let Some(found) =
                        lookup_commit_in_scope(&root, request.reference.as_deref(), hash_prefix)?
                    {
                        commits.push(found);
                    }
                }
            }
            let next_cursor = has_more.then(|| session.cursor.clone());
            if has_more {
                session.last_access = Instant::now();
                lease.store(session)?;
            } else {
                session.stop();
            }
            Ok(GitHistoryPageResponse {
                commits,
                next_cursor,
                next_offset: None,
                has_more,
            })
        }
        Err(error) => {
            session.stop();
            Err(error)
        }
    }
}

fn lookup_commit_in_scope(
    root: &str,
    reference: Option<&str>,
    hash_prefix: &str,
) -> Result<Option<GitCommitResponse>, CoreError> {
    let resolved = readonly_command(GitCommandRequest {
        root: root.to_string(),
        arguments: vec![
            "rev-parse".to_string(),
            "--verify".to_string(),
            "--quiet".to_string(),
            format!("{hash_prefix}^{{commit}}"),
        ],
        input: None,
    })?;
    if resolved.exit_code != 0 {
        return Ok(None);
    }
    let full_hash = resolved.stdout.trim();
    if full_hash.is_empty() {
        return Ok(None);
    }
    if let Some(reference) = reference {
        let ancestor = readonly_command(GitCommandRequest {
            root: root.to_string(),
            arguments: vec![
                "merge-base".to_string(),
                "--is-ancestor".to_string(),
                full_hash.to_string(),
                reference.to_string(),
            ],
            input: None,
        })?;
        if ancestor.exit_code != 0 {
            return Ok(None);
        }
    }
    let shown = readonly_command(GitCommandRequest {
        root: root.to_string(),
        arguments: vec![
            "show".to_string(),
            "-s".to_string(),
            "--decorate=short".to_string(),
            format!("--decorate-refs-exclude={INTERNAL_REF_PREFIX}*"),
            "--date=format-local:%Y/%m/%d %H:%M".to_string(),
            "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%D".to_string(),
            full_hash.to_string(),
        ],
        input: None,
    })?;
    if shown.exit_code != 0 {
        return Ok(None);
    }
    Ok(shown.stdout.lines().find_map(parse_commit))
}

/// Preserves the original offset contract for callers that have not migrated to cursors.
fn offset_history_page(
    root: String,
    reference: Option<String>,
    order: HistoryOrder,
    offset: usize,
    requested_limit: usize,
) -> Result<GitHistoryPageResponse, CoreError> {
    if offset >= MAX_HISTORY_COMMITS {
        return Ok(GitHistoryPageResponse {
            commits: Vec::new(),
            next_cursor: None,
            next_offset: None,
            has_more: false,
        });
    }
    validate_reference(reference.as_deref())?;
    let root = validate_root(&root)?;
    let limit = requested_limit.clamp(1, MAX_HISTORY_COMMITS - offset);
    let mut arguments = vec!["log".to_string()];
    if let Some(reference) = reference {
        arguments.push(reference);
    } else {
        arguments.extend([
            format!("--exclude={INTERNAL_REF_PREFIX}*"),
            "--all".to_string(),
        ]);
    }
    arguments.extend([
        order.argument().to_string(),
        "--decorate=short".to_string(),
        format!("--decorate-refs-exclude={INTERNAL_REF_PREFIX}*"),
        "--skip".to_string(),
        offset.to_string(),
        "-n".to_string(),
        limit.saturating_add(1).to_string(),
        "--date=format-local:%Y/%m/%d %H:%M".to_string(),
        "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%D".to_string(),
    ]);
    let output = readonly_command(GitCommandRequest {
        root,
        arguments,
        input: None,
    })?;
    if output.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git history failed")
                .with_details(output.output),
        );
    }
    let mut commits = output
        .output
        .lines()
        .filter_map(parse_commit)
        .collect::<Vec<_>>();
    let has_more = commits.len() > limit && offset.saturating_add(limit) < MAX_HISTORY_COMMITS;
    commits.truncate(limit);
    let next_offset = has_more.then_some(offset.saturating_add(commits.len()));
    Ok(GitHistoryPageResponse {
        commits,
        next_cursor: None,
        next_offset,
        has_more,
    })
}

/// Releases a cursor early so its Git child process and reader threads can terminate.
pub fn close_history_cursor(
    request: GitHistoryCursorCloseRequest,
) -> Result<GitHistoryCursorCloseResponse, CoreError> {
    let root = validate_root(&request.root)?;
    cleanup_expired_history_sessions();
    let session = {
        let mut registry = history_sessions()
            .lock()
            .map_err(history_session_lock_error)?;
        if registry
            .sessions
            .get(&request.cursor)
            .is_some_and(|session| session.root != root)
        {
            return Err(invalid_history_cursor(&request.cursor));
        }
        registry.sessions.remove(&request.cursor)
    };
    let closed = session.is_some();
    if let Some(session) = session {
        session.stop();
    }
    Ok(GitHistoryCursorCloseResponse { closed })
}

enum HistoryStreamMessage {
    Line(String),
    ReadFailed(String),
    End,
}

struct HistorySession {
    cursor: String,
    root: String,
    reference: Option<String>,
    /// Prevents a continuation from silently switching traversal policies.
    order: HistoryOrder,
    /// Optional repository-wide filter fixed for the lifetime of this cursor.
    filter: Option<GitHistoryFilter>,
    child: Option<Child>,
    receiver: Option<Receiver<HistoryStreamMessage>>,
    stdout_reader: Option<JoinHandle<()>>,
    stderr_reader: Option<JoinHandle<Vec<u8>>>,
    pending: Option<GitCommitResponse>,
    emitted: usize,
    scanned: usize,
    last_access: Instant,
    finished: bool,
}

#[derive(Default)]
struct HistorySessionRegistry {
    sessions: std::collections::HashMap<String, HistorySession>,
    /// Sessions that are starting or temporarily checked out for a page read.
    in_flight: usize,
}

/// Accounts for a live session while it is outside the registry map.
struct HistorySessionLease {
    active: bool,
}

impl HistorySessionLease {
    fn new() -> Self {
        Self { active: true }
    }

    fn store(mut self, session: HistorySession) -> Result<(), CoreError> {
        let mut registry = history_sessions()
            .lock()
            .map_err(history_session_lock_error)?;
        registry.in_flight = registry.in_flight.saturating_sub(1);
        registry.sessions.insert(session.cursor.clone(), session);
        self.active = false;
        Ok(())
    }
}

impl Drop for HistorySessionLease {
    fn drop(&mut self) {
        if !self.active {
            return;
        }
        if let Ok(mut registry) = history_sessions().lock() {
            registry.in_flight = registry.in_flight.saturating_sub(1);
        }
    }
}

impl HistorySession {
    fn start(
        root: String,
        reference: Option<String>,
        order: HistoryOrder,
        filter: Option<GitHistoryFilter>,
    ) -> Result<Self, CoreError> {
        cancellation::check()?;
        let mut arguments = vec!["log".to_string()];
        if let Some(reference) = reference.as_deref() {
            arguments.push(reference.to_string());
        } else {
            arguments.extend([
                format!("--exclude={INTERNAL_REF_PREFIX}*"),
                "--all".to_string(),
            ]);
        }
        let max_scan = if filter.is_some() {
            MAX_FILTERED_SCAN_COMMITS
        } else {
            MAX_HISTORY_COMMITS
        };
        arguments.extend([
            order.argument().to_string(),
            "--decorate=short".to_string(),
            format!("--decorate-refs-exclude={INTERNAL_REF_PREFIX}*"),
            "-n".to_string(),
            max_scan.to_string(),
            "--date=format-local:%Y/%m/%d %H:%M".to_string(),
            "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%D".to_string(),
        ]);
        if let Some(ref active_filter) = filter {
            if let Some(after) = active_filter.after.as_deref() {
                arguments.push(format!("--since={after}"));
            }
            if let Some(before) = active_filter.before.as_deref() {
                arguments.push(format!("--until={before}"));
            }
            let safe_pathspecs: Vec<String> = active_filter
                .paths
                .iter()
                .filter(|path| is_safe_pathspec(path))
                .map(|path| format!(":(icase)*{}*", escape_git_pathspec_glob(path)))
                .collect();
            if !safe_pathspecs.is_empty() {
                arguments.push("--".to_string());
                // Passing the first pathspec lets Git prune in C without changing
                // AND semantics when multiple path filters are present (additional
                // path filters are verified per candidate in Swift).
                arguments.push(safe_pathspecs[0].clone());
            }
        }
        let mut process = git_process();
        let mut child = process
            .args(&arguments)
            .current_dir(&root)
            .env("GIT_OPTIONAL_LOCKS", "0")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| {
                CoreError::new(ErrorCode::ProcessStartFailed, "Could not start Git history")
                    .with_details(error.to_string())
            })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            CoreError::new(
                ErrorCode::ProcessFailed,
                "Git history stdout was unavailable",
            )
        })?;
        let mut stderr = child.stderr.take().ok_or_else(|| {
            CoreError::new(
                ErrorCode::ProcessFailed,
                "Git history stderr was unavailable",
            )
        })?;
        // A single-slot channel propagates backpressure to Git instead of buffering the
        // entire repository history between page requests.
        let (sender, receiver) = mpsc::sync_channel(1);
        let stdout_reader = thread::spawn(move || read_history_stream(stdout, sender));
        let stderr_reader = thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = stderr.read_to_end(&mut bytes);
            bytes
        });
        let cursor = format!(
            "git-history-cursor-{}",
            NEXT_HISTORY_CURSOR.fetch_add(1, Ordering::Relaxed)
        );
        Ok(Self {
            cursor,
            root,
            reference,
            order,
            filter,
            child: Some(child),
            receiver: Some(receiver),
            stdout_reader: Some(stdout_reader),
            stderr_reader: Some(stderr_reader),
            pending: None,
            emitted: 0,
            scanned: 0,
            last_access: Instant::now(),
            finished: false,
        })
    }

    fn read_page(&mut self, limit: usize) -> Result<(Vec<GitCommitResponse>, bool), CoreError> {
        let deadline = Instant::now() + HISTORY_PAGE_DEADLINE;
        let mut commits = Vec::with_capacity(limit);
        if let Some(commit) = self.pending.take() {
            commits.push(commit);
        }
        while commits.len() < limit && self.emitted + commits.len() < MAX_HISTORY_COMMITS {
            let Some(commit) = self.next_commit(deadline)? else {
                break;
            };
            commits.push(commit);
        }
        self.emitted += commits.len();
        let has_more = if self.emitted >= MAX_HISTORY_COMMITS || self.finished {
            false
        } else {
            self.pending = self.next_commit(deadline)?;
            self.pending.is_some()
        };
        Ok((commits, has_more))
    }

    fn next_commit(&mut self, deadline: Instant) -> Result<Option<GitCommitResponse>, CoreError> {
        loop {
            cancellation::check()?;
            if self.filter.is_some() && self.scanned >= MAX_FILTERED_SCAN_COMMITS {
                self.finish_process(true)?;
                return Ok(None);
            }
            if Instant::now() >= deadline {
                return Err(CoreError::new(
                    ErrorCode::ProcessFailed,
                    "Git history page timed out",
                ));
            }
            let message = self
                .receiver
                .as_ref()
                .ok_or_else(|| {
                    CoreError::new(
                        ErrorCode::ProcessFailed,
                        "Git history stream was unavailable",
                    )
                })?
                .recv_timeout(HISTORY_STREAM_POLL_INTERVAL);
            match message {
                Ok(HistoryStreamMessage::Line(line)) => {
                    if let Some(commit) = parse_commit(&line) {
                        self.scanned += 1;
                        if self
                            .filter
                            .as_ref()
                            .is_none_or(|filter| filter.matches_metadata(&commit))
                        {
                            return Ok(Some(commit));
                        }
                    }
                }
                Ok(HistoryStreamMessage::ReadFailed(details)) => {
                    return Err(CoreError::new(
                        ErrorCode::ProcessFailed,
                        "Could not read Git history",
                    )
                    .with_details(details));
                }
                Ok(HistoryStreamMessage::End) | Err(RecvTimeoutError::Disconnected) => {
                    self.finish_process(false)?;
                    return Ok(None);
                }
                Err(RecvTimeoutError::Timeout) => {}
            }
        }
    }

    fn finish_process(&mut self, terminate: bool) -> Result<(), CoreError> {
        if self.finished {
            return Ok(());
        }
        self.finished = true;
        self.receiver.take();
        let status = if let Some(mut child) = self.child.take() {
            if terminate {
                let _ = child.kill();
            }
            child.wait().map_err(|error| {
                CoreError::new(
                    ErrorCode::ProcessFailed,
                    "Could not read Git history status",
                )
                .with_details(error.to_string())
            })?
        } else {
            return Ok(());
        };
        if let Some(reader) = self.stdout_reader.take() {
            let _ = reader.join();
        }
        let stderr = self
            .stderr_reader
            .take()
            .and_then(|reader| reader.join().ok())
            .unwrap_or_default();
        validate_history_exit(status, stderr, terminate)
    }

    fn stop(mut self) {
        let _ = self.finish_process(true);
    }
}

impl Drop for HistorySession {
    fn drop(&mut self) {
        let _ = self.finish_process(true);
    }
}

fn read_history_stream(stdout: impl Read, sender: SyncSender<HistoryStreamMessage>) {
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => {
                let _ = sender.send(HistoryStreamMessage::End);
                break;
            }
            Ok(_) => {
                let normalized = line.trim_end_matches(['\r', '\n']).to_string();
                if sender.send(HistoryStreamMessage::Line(normalized)).is_err() {
                    break;
                }
            }
            Err(error) => {
                let _ = sender.send(HistoryStreamMessage::ReadFailed(error.to_string()));
                break;
            }
        }
    }
}

fn validate_history_exit(
    status: ExitStatus,
    stderr: Vec<u8>,
    terminated: bool,
) -> Result<(), CoreError> {
    if status.success() || terminated {
        return Ok(());
    }
    Err(
        CoreError::new(ErrorCode::ProcessFailed, "Git history failed")
            .with_details(String::from_utf8_lossy(&stderr).trim().to_string()),
    )
}

fn escape_git_pathspec_glob(path: &str) -> String {
    let mut escaped = String::with_capacity(path.len());
    for character in path.chars() {
        if matches!(character, '*' | '?' | '[' | ']' | '\\') {
            escaped.push('\\');
        }
        escaped.push(character);
    }
    escaped
}

fn validate_reference(reference: Option<&str>) -> Result<(), CoreError> {
    if reference.is_some_and(|value| value.starts_with('-') || value.contains('\0')) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git reference",
        ));
    }
    Ok(())
}

fn history_sessions() -> &'static Mutex<HistorySessionRegistry> {
    let registry = HISTORY_SESSIONS.get_or_init(|| Mutex::new(HistorySessionRegistry::default()));
    HISTORY_REAPER.get_or_init(|| {
        thread::Builder::new()
            .name("lithe-git-history-reaper".to_string())
            .spawn(|| loop {
                thread::sleep(HISTORY_CURSOR_REAPER_INTERVAL);
                cleanup_expired_history_sessions();
            })
            .expect("Git history reaper should start");
    });
    registry
}

fn history_session_lock_error<T>(error: std::sync::PoisonError<T>) -> CoreError {
    CoreError::new(
        ErrorCode::ProcessFailed,
        "Git history cursor state was unavailable",
    )
    .with_details(error.to_string())
}

fn take_history_session(
    cursor: &str,
) -> Result<Option<(HistorySession, HistorySessionLease)>, CoreError> {
    let mut registry = history_sessions()
        .lock()
        .map_err(history_session_lock_error)?;
    let Some(session) = registry.sessions.remove(cursor) else {
        return Ok(None);
    };
    registry.in_flight += 1;
    Ok(Some((session, HistorySessionLease::new())))
}

fn cleanup_expired_history_sessions() {
    let expired = history_sessions().lock().ok().map(|mut registry| {
        take_expired_history_sessions(&mut registry, Instant::now(), HISTORY_CURSOR_IDLE_TTL)
    });
    for session in expired.unwrap_or_default() {
        session.stop();
    }
}

fn take_expired_history_sessions(
    registry: &mut HistorySessionRegistry,
    now: Instant,
    ttl: Duration,
) -> Vec<HistorySession> {
    let cursors = registry
        .sessions
        .iter()
        .filter(|(_, session)| now.saturating_duration_since(session.last_access) >= ttl)
        .map(|(cursor, _)| cursor.clone())
        .collect::<Vec<_>>();
    cursors
        .into_iter()
        .filter_map(|cursor| registry.sessions.remove(&cursor))
        .collect()
}

fn reserve_history_session_slot() -> Result<HistorySessionLease, CoreError> {
    let evicted = {
        let mut registry = history_sessions()
            .lock()
            .map_err(history_session_lock_error)?;
        reserve_history_session_slot_from(&mut registry)?
    };
    for session in evicted {
        session.stop();
    }
    Ok(HistorySessionLease::new())
}

fn reserve_history_session_slot_from(
    registry: &mut HistorySessionRegistry,
) -> Result<Vec<HistorySession>, CoreError> {
    let mut evicted = Vec::new();
    while registry.sessions.len() + registry.in_flight >= MAX_HISTORY_SESSIONS {
        let Some(cursor) = registry
            .sessions
            .iter()
            .min_by_key(|(_, session)| session.last_access)
            .map(|(cursor, _)| cursor.clone())
        else {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Too many Git history sessions are active",
            ));
        };
        if let Some(session) = registry.sessions.remove(&cursor) {
            evicted.push(session);
        }
    }
    registry.in_flight += 1;
    Ok(evicted)
}

fn invalid_history_cursor(cursor: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git history cursor")
        .with_details(cursor.to_string())
}

/// Builds a bounded MRU list from Git's own checkout history.
fn recent_local_references(
    root: &str,
    references: &[GitReferenceResponse],
    limit: usize,
) -> Vec<GitReferenceResponse> {
    let local_references = references
        .iter()
        .filter(|reference| reference.kind == "local")
        .collect::<Vec<_>>();
    let mut recent = Vec::with_capacity(limit.min(local_references.len()));

    if let Some(current) = local_references
        .iter()
        .find(|reference| reference.is_current)
    {
        append_recent_reference(&mut recent, &local_references, &current.short_name, limit);
    }

    if let Some(reflog) = command_value(
        root,
        &[
            "reflog",
            "show",
            "-n",
            RECENT_BRANCH_REFLOG_LIMIT,
            "--format=%gs",
            "HEAD",
        ],
    ) {
        for line in reflog.lines() {
            let Some(checkout) = line.strip_prefix("checkout: moving from ") else {
                continue;
            };
            let Some((source, destination)) = checkout.split_once(" to ") else {
                continue;
            };
            append_recent_reference(&mut recent, &local_references, destination, limit);
            append_recent_reference(&mut recent, &local_references, source, limit);
            if recent.len() >= limit {
                break;
            }
        }
    }

    if recent.len() < limit {
        if let Some(remote_head) = command_value(
            root,
            &[
                "symbolic-ref",
                "--quiet",
                "--short",
                "refs/remotes/origin/HEAD",
            ],
        ) {
            append_recent_reference(
                &mut recent,
                &local_references,
                remote_head
                    .split_once('/')
                    .map_or(remote_head.as_str(), |(_, branch)| branch),
                limit,
            );
        }
    }
    for branch in DEFAULT_BRANCH_FALLBACKS {
        append_recent_reference(&mut recent, &local_references, branch, limit);
    }

    for reference in &local_references {
        append_recent_reference(&mut recent, &local_references, &reference.short_name, limit);
        if recent.len() >= limit {
            break;
        }
    }

    recent.into_iter().cloned().collect()
}

fn append_recent_reference<'a>(
    recent: &mut Vec<&'a GitReferenceResponse>,
    references: &[&'a GitReferenceResponse],
    raw_name: &str,
    limit: usize,
) {
    if recent.len() >= limit {
        return;
    }
    let name = raw_name.trim().trim_start_matches("refs/heads/");
    let Some(reference) = references
        .iter()
        .find(|reference| reference.short_name == name)
    else {
        return;
    };
    if !recent
        .iter()
        .any(|existing| existing.full_name == reference.full_name)
    {
        recent.push(*reference);
    }
}

/// Reads one optional repository configuration value without failing the snapshot.
fn git_config_value(root: &str, key: &str) -> Option<String> {
    let response = readonly_command(GitCommandRequest {
        root: root.to_string(),
        arguments: vec!["config".to_string(), "--get".to_string(), key.to_string()],
        input: None,
    })
    .ok()?;
    if response.exit_code != 0 {
        return None;
    }
    let value = response.output.trim();
    (!value.is_empty()).then(|| value.to_string())
}

#[cfg(test)]
mod tests {
    use super::{
        reserve_history_session_slot_from, take_expired_history_sessions, HistorySession,
        HistorySessionRegistry, MAX_HISTORY_SESSIONS,
    };
    use crate::protocol::ErrorCode;
    use std::time::{Duration, Instant};

    #[test]
    fn date_order_pages_interleave_branches_and_preserve_cursor_policy() {
        use serde_json::{json, Value};

        struct Repository {
            root: String,
            cursors: Vec<String>,
        }
        impl Drop for Repository {
            fn drop(&mut self) {
                for cursor in &self.cursors {
                    let _ = super::close_history_cursor(super::GitHistoryCursorCloseRequest {
                        root: self.root.clone(),
                        cursor: cursor.clone(),
                    });
                }
                let _ = std::fs::remove_dir_all(&self.root);
            }
        }
        let path = std::env::temp_dir().join(format!(
            "lithe-history-order-{}-{}",
            std::process::id(),
            super::NEXT_HISTORY_CURSOR.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let root = path.to_string_lossy().into_owned();
        let mut repository = Repository {
            root: root.clone(),
            cursors: Vec::new(),
        };
        std::fs::create_dir_all(&root).expect("create isolated repository");
        // Plumbing commands have no hooks, signing, or child helpers. Use the
        // production cancellation watchdog with a local deadline for each one.
        let git = |arguments: &[&str], environment: &[(String, String)]| {
            let _deadline = crate::protocol::cancellation::Scope::begin(None, Some(3_000));
            let response = crate::git::execute_git_with_environment(
                &root,
                &arguments.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
                None,
                true,
                environment,
            )
            .expect("bounded Git fixture command");
            assert_eq!(response.exit_code, 0, "{}", response.output);
            response.output.trim().to_string()
        };
        git(&["init", "-q"], &[]);
        let tree = git(&["write-tree"], &[]);
        let commit = |name: &str, minute: u32, parents: &[&str]| {
            let mut arguments = vec!["commit-tree", &tree, "-m", name];
            for parent in parents {
                arguments.extend(["-p", parent]);
            }
            git(
                &arguments,
                &[
                    ("GIT_AUTHOR_NAME".into(), "Graph fixture".into()),
                    ("GIT_AUTHOR_EMAIL".into(), "fixture@example.invalid".into()),
                    ("GIT_COMMITTER_NAME".into(), "Graph fixture".into()),
                    (
                        "GIT_COMMITTER_EMAIL".into(),
                        "fixture@example.invalid".into(),
                    ),
                    // Deliberately reversed author dates must not drive traversal.
                    (
                        "GIT_AUTHOR_DATE".into(),
                        format!("{} +0000", 1_700_010_000 - minute * 60),
                    ),
                    (
                        "GIT_COMMITTER_DATE".into(),
                        format!("{} +0000", 1_700_000_000 + minute * 60),
                    ),
                ],
            )
        };
        // A clock-skewed root is newer than its descendants, but must stay last.
        let base = commit("base", 70, &[]);
        let a1 = commit("a1", 20, &[&base]);
        let b1 = commit("b1", 30, &[&base]);
        let a2 = commit("a2", 40, &[&a1]);
        let b2 = commit("b2", 50, &[&b1]);
        let merge = commit("merge", 60, &[&a2, &b2]);
        git(&["update-ref", "HEAD", &merge], &[]);

        let page = |mut payload: Value| -> Value {
            payload["root"] = json!(root);
            serde_json::from_str(&crate::execute_json(
                &json!({
                    "id": "date-order-regression", "command": "git.historyPage",
                    "timeoutMilliseconds": 3_000, "payload": payload
                })
                .to_string(),
            ))
            .expect("JSON response")
        };
        let subjects = |response: &Value| -> Vec<String> {
            assert_eq!(response["ok"], true, "{response}");
            response["data"]["commits"]
                .as_array()
                .expect("commits")
                .iter()
                .map(|commit| commit["subject"].as_str().expect("subject").to_string())
                .collect()
        };
        let request: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/git/history-page-date-request-v1.json"
        ))
        .expect("portable date-order request");
        let first = page(request.clone());
        // Register cleanup before assertions so failures cannot leak a stream.
        let cursor = first["data"]["nextCursor"]
            .as_str()
            .expect("cursor")
            .to_string();
        repository.cursors.push(cursor.clone());
        assert_eq!(subjects(&first), ["merge", "b2"]);
        let wrong_order = page(json!({"reference": "HEAD", "cursor": cursor, "limit": 2}));
        assert_eq!(wrong_order["ok"], false);
        assert_eq!(wrong_order["error"]["code"], "invalid_request");
        let second =
            page(json!({"reference": "HEAD", "order": "date", "cursor": cursor, "limit": 2}));
        assert_eq!(subjects(&second), ["a2", "b1"]);
        let third =
            page(json!({"reference": "HEAD", "order": "date", "cursor": cursor, "limit": 2}));
        assert_eq!(subjects(&third), ["a1", "base"]);
        assert_eq!(third["data"]["hasMore"], false);
        assert_eq!(third["data"]["nextCursor"], Value::Null);

        let offset = page(json!({"reference": "HEAD", "order": "date", "offset": 2, "limit": 2}));
        assert_eq!(subjects(&offset), ["a2", "b1"]);
        assert_eq!(offset["data"]["nextOffset"], 4);
        assert_eq!(
            subjects(&page(json!({"reference": "HEAD", "limit": 20}))),
            ["merge", "b2", "b1", "a2", "a1", "base"]
        );
        assert_eq!(
            subjects(&page(json!({"order": "date", "limit": 20}))),
            ["merge", "b2", "a2", "b1", "a1", "base"]
        );
        assert_eq!(
            page(json!({"order": "authorDate", "limit": 20}))["ok"],
            false
        );
    }

    fn finished_session(cursor: &str, last_access: Instant) -> HistorySession {
        HistorySession {
            cursor: cursor.to_string(),
            root: "/test/repository".to_string(),
            reference: None,
            order: super::HistoryOrder::default(),
            filter: None,
            child: None,
            receiver: None,
            stdout_reader: None,
            stderr_reader: None,
            pending: None,
            emitted: 0,
            scanned: 0,
            last_access,
            finished: true,
        }
    }

    #[test]
    fn expired_sessions_are_removed_without_touching_recent_sessions() {
        let now = Instant::now();
        let mut registry = HistorySessionRegistry::default();
        registry.sessions.insert(
            "expired".to_string(),
            finished_session("expired", now - Duration::from_secs(121)),
        );
        registry.sessions.insert(
            "recent".to_string(),
            finished_session("recent", now - Duration::from_secs(119)),
        );

        let expired = take_expired_history_sessions(&mut registry, now, Duration::from_secs(120));

        assert_eq!(expired.len(), 1);
        assert_eq!(expired[0].cursor, "expired");
        assert!(registry.sessions.contains_key("recent"));
    }

    #[test]
    fn session_limit_counts_requests_that_are_still_in_flight() {
        let mut registry = HistorySessionRegistry {
            sessions: Default::default(),
            in_flight: MAX_HISTORY_SESSIONS,
        };

        let error = match reserve_history_session_slot_from(&mut registry) {
            Ok(_) => panic!("a ninth in-flight session should be rejected"),
            Err(error) => error,
        };

        assert!(matches!(error.code, ErrorCode::ProcessFailed));
        assert_eq!(registry.in_flight, MAX_HISTORY_SESSIONS);
    }
}
