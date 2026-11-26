//! Incremental workspace search indexing with exact final-content matching.

use crate::project::files::{
    read_indexed_file_content, relative_path, FileContentOutcome, VisibilityRules,
};
use crate::project::symbols::extract_symbols;
use crate::protocol::{CoreError, ErrorCode, SearchMatch};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, RwLock};

/// A workspace-local search index shared by file search, Search Everywhere,
/// Replace in Files, and zero-LSP lightweight symbol lookup. The postings are
/// file-level on purpose: the final matcher still reads the current file, so
/// regex, whole-word and unsaved-buffer semantics remain exact.
pub(crate) struct WorkspaceSearchIndex {
    files: Vec<Option<IndexedFile>>,
    free_ids: Vec<u32>,
    path_to_id: HashMap<String, u32>,
    postings: HashMap<u32, Vec<u32>>,
    /// Lowercased symbol name mapped to `(file_id, symbol_index)` entries for
    /// O(log N) exact and prefix cross-file lightweight lookup.
    symbols_by_lower_name: BTreeMap<String, Vec<(u32, u32)>>,
}

/// Content indexing outcome distinguishing binary assets from short or unreadable files.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ContentIndexState {
    /// Plain UTF-8 text with at least one indexed trigram.
    Indexed,
    /// Plain UTF-8 text shorter than three lowercase UTF-8 bytes; must still be inspected directly.
    ShortText,
    /// Regular file within the size budget that is non-UTF-8 or contains binary bytes.
    Binary,
    /// Unreadable, oversize, or non-regular file that scoped previews must report explicitly.
    UnreadableOrOversize,
}

/// Searchable file contents and symbols stored under a stable numeric ID.
pub(crate) struct IndexedFile {
    pub(crate) path: String,
    trigrams: Vec<u32>,
    content_state: ContentIndexState,
    /// True only when the text contains a non-ASCII scalar that Unicode simple-case-folds
    /// to ASCII (`U+017F` long s -> `s`, `U+212A` Kelvin -> `k`).
    has_ascii_casefold_non_ascii: bool,
    pub(crate) symbols: Vec<IndexedSymbol>,
}

#[derive(Clone)]
/// Normalized workspace symbol retained for Search Everywhere and lightweight lookup.
pub(crate) struct IndexedSymbol {
    pub(crate) name: String,
    pub(crate) kind: String,
    pub(crate) line: usize,
    pub(crate) utf16_column: usize,
    pub(crate) signature: String,
    pub(crate) doc_comment: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// Result of attempting to apply watcher paths to an existing index.
pub(crate) enum UpdateOutcome {
    /// No compatible cached index existed, so there was nothing to update.
    NotIndexed,
    /// Every changed file was applied to the existing index in place.
    Updated,
    /// A directory or visibility change invalidated the index's global file set.
    RequiresRebuild,
}

#[derive(Debug, Clone, Copy)]
/// Counts surfaced after building or updating a workspace index.
pub(crate) struct SearchIndexStats {
    pub(crate) file_count: usize,
    pub(crate) symbol_count: usize,
    pub(crate) posting_count: usize,
}

#[derive(Clone, Hash, PartialEq, Eq)]
struct IndexKey {
    root: PathBuf,
    hidden_directories: Vec<String>,
    hidden_file_patterns: Vec<String>,
}

type SharedIndex = Arc<RwLock<WorkspaceSearchIndex>>;
type IndexSlot = Arc<Mutex<Option<SharedIndex>>>;

static INDEX_CACHE: OnceLock<Mutex<HashMap<IndexKey, IndexSlot>>> = OnceLock::new();

fn cache() -> &'static Mutex<HashMap<IndexKey, IndexSlot>> {
    INDEX_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn key(root: &Path, rules: &VisibilityRules) -> IndexKey {
    IndexKey {
        root: root.to_path_buf(),
        hidden_directories: rules.hidden_directories.clone(),
        hidden_file_patterns: rules.hidden_file_patterns.clone(),
    }
}

pub(crate) fn get_or_build(root: &Path, rules: &VisibilityRules) -> Result<SharedIndex, CoreError> {
    // Deduplicate concurrent builds per workspace key without holding the global
    // cache lock across directory traversal and file reads of unrelated workspaces.
    let cache_key = key(root, rules);
    let slot = {
        let mut indexes = cache()
            .lock()
            .map_err(|_| CoreError::new(ErrorCode::Unknown, "Search index lock was poisoned"))?;
        Arc::clone(
            indexes
                .entry(cache_key)
                .or_insert_with(|| Arc::new(Mutex::new(None))),
        )
    };
    let mut entry = slot
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Search index slot lock was poisoned"))?;
    if let Some(index) = entry.as_ref() {
        return Ok(Arc::clone(index));
    }
    let index = Arc::new(RwLock::new(WorkspaceSearchIndex::build(root, rules)?));
    *entry = Some(Arc::clone(&index));
    Ok(index)
}

pub(crate) fn get_cached(root: &Path) -> Option<SharedIndex> {
    let canonical_root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let slots = {
        let Ok(indexes) = cache().lock() else {
            return None;
        };
        indexes
            .iter()
            .filter(|(key, _)| key.root == canonical_root)
            .map(|(_, slot)| Arc::clone(slot))
            .collect::<Vec<_>>()
    };
    for slot in slots {
        // Never block lightweight editor interactions on an in-flight disk build.
        if let Ok(guard) = slot.try_lock() {
            if let Some(index) = guard.as_ref() {
                return Some(Arc::clone(index));
            }
        }
    }
    None
}

pub(crate) fn invalidate_root(root: &Path) {
    let Ok(mut indexes) = cache().lock() else {
        return;
    };
    indexes.retain(|key, _| key.root != root);
}

pub(crate) fn update_cached_file(root: &Path, path: &Path) {
    let slots = {
        let Ok(indexes) = cache().lock() else {
            return;
        };
        indexes
            .iter()
            .filter(|(key, _)| key.root == root)
            .map(|(key, slot)| (key.clone(), Arc::clone(slot)))
            .collect::<Vec<_>>()
    };
    if slots.is_empty() {
        return;
    }
    let Some(absolute) = normalized_update_path(root, &path.to_string_lossy()) else {
        return;
    };
    let relative = relative_path(&absolute, root);
    let metadata = fs::symlink_metadata(&absolute).ok();
    for (cache_key, slot) in slots {
        let index = slot.lock().ok().and_then(|guard| guard.clone());
        let Some(index) = index else {
            continue;
        };
        let rules = VisibilityRules {
            hidden_directories: cache_key.hidden_directories,
            hidden_file_patterns: cache_key.hidden_file_patterns,
        };
        if let Ok(mut guard) = index.write() {
            guard.update_file(&absolute, &relative, metadata.as_ref(), &rules);
        };
    }
}

/// Updates existing files in-place when a watcher reports file-only changes.
/// Directory events deliberately request a full rebuild because they can add or
/// remove an arbitrary number of descendants.
pub(crate) fn update_paths(
    root: &Path,
    rules: &VisibilityRules,
    paths: &[String],
) -> UpdateOutcome {
    let cache_key = key(root, rules);
    let slot = {
        let Ok(indexes) = cache().lock() else {
            return UpdateOutcome::NotIndexed;
        };
        indexes.get(&cache_key).cloned()
    };
    let Some(slot) = slot else {
        return UpdateOutcome::NotIndexed;
    };
    let Some(index) = slot.lock().ok().and_then(|guard| guard.clone()) else {
        return UpdateOutcome::NotIndexed;
    };
    let Ok(mut index) = index.write() else {
        return UpdateOutcome::RequiresRebuild;
    };

    for value in paths {
        let Some(absolute) = normalized_update_path(root, value) else {
            continue;
        };
        let relative = relative_path(&absolute, root);
        let metadata = fs::symlink_metadata(&absolute).ok();
        if metadata.as_ref().is_some_and(|value| value.is_dir()) {
            return UpdateOutcome::RequiresRebuild;
        }
        if metadata.is_none() && index.has_descendant(&relative) {
            return UpdateOutcome::RequiresRebuild;
        }
        index.update_file(&absolute, &relative, metadata.as_ref(), rules);
    }
    UpdateOutcome::Updated
}

impl WorkspaceSearchIndex {
    fn build(root: &Path, rules: &VisibilityRules) -> Result<Self, CoreError> {
        let mut paths = Vec::new();
        collect_files(root, root, rules, &mut paths)?;
        let mut index = Self {
            files: Vec::new(),
            free_ids: Vec::new(),
            path_to_id: HashMap::with_capacity(paths.len()),
            postings: HashMap::new(),
            symbols_by_lower_name: BTreeMap::new(),
        };
        for path in paths {
            crate::protocol::cancellation::check()?;
            let relative = relative_path(&path, root);
            index.add_file(&path, relative);
        }
        Ok(index)
    }

    fn add_file(&mut self, path: &Path, relative: String) {
        if let Some(existing) = self.path_to_id.get(&relative).copied() {
            self.remove_id(existing);
        }
        let (trigrams, content_state, symbols, has_ascii_casefold_non_ascii) =
            read_search_data(path, &relative);
        let id = self
            .free_ids
            .pop()
            .unwrap_or_else(|| u32::try_from(self.files.len()).expect("search index is too large"));
        for trigram in &trigrams {
            let posting = self.postings.entry(*trigram).or_default();
            if let Err(position) = posting.binary_search(&id) {
                posting.insert(position, id);
            }
        }
        for (sym_index, symbol) in symbols.iter().enumerate() {
            if let Ok(sym_idx) = u32::try_from(sym_index) {
                self.symbols_by_lower_name
                    .entry(symbol.name.to_ascii_lowercase())
                    .or_default()
                    .push((id, sym_idx));
            }
        }
        let file = Some(IndexedFile {
            path: relative.clone(),
            trigrams,
            content_state,
            has_ascii_casefold_non_ascii,
            symbols,
        });
        let id_index = id as usize;
        if id_index == self.files.len() {
            self.files.push(file);
        } else {
            self.files[id_index] = file;
        }
        self.path_to_id.insert(relative, id);
    }

    fn update_file(
        &mut self,
        absolute: &Path,
        relative: &str,
        metadata: Option<&fs::Metadata>,
        rules: &VisibilityRules,
    ) {
        self.remove_file(relative);
        if metadata.is_some_and(|metadata| {
            metadata.is_file()
                && !metadata.file_type().is_symlink()
                && !rules.is_hidden(relative, false)
        }) {
            self.add_file(absolute, relative.to_string());
        }
    }

    fn remove_file(&mut self, relative: &str) {
        if let Some(id) = self.path_to_id.remove(relative) {
            self.remove_id(id);
        }
    }

    fn remove_id(&mut self, id: u32) {
        let Some(file) = self.files.get_mut(id as usize).and_then(Option::take) else {
            return;
        };
        for trigram in file.trigrams {
            if let Some(posting) = self.postings.get_mut(&trigram) {
                posting.retain(|value| *value != id);
                if posting.is_empty() {
                    self.postings.remove(&trigram);
                }
            }
        }
        for symbol in &file.symbols {
            let lower = symbol.name.to_ascii_lowercase();
            if let Some(entries) = self.symbols_by_lower_name.get_mut(&lower) {
                entries.retain(|(file_id, _)| *file_id != id);
                if entries.is_empty() {
                    self.symbols_by_lower_name.remove(&lower);
                }
            }
        }
        self.free_ids.push(id);
    }

    fn has_descendant(&self, relative: &str) -> bool {
        let prefix = if relative.is_empty() {
            String::new()
        } else {
            format!("{relative}/")
        };
        self.path_to_id.keys().any(|path| path.starts_with(&prefix))
    }

    pub(crate) fn all_file_ids(&self) -> Vec<u32> {
        self.files
            .iter()
            .enumerate()
            .filter_map(|(id, file)| file.as_ref().map(|_| id as u32))
            .collect()
    }

    pub(crate) fn file(&self, id: u32) -> Option<&IndexedFile> {
        self.files.get(id as usize).and_then(Option::as_ref)
    }

    pub(crate) fn id_for_path(&self, path: &str) -> Option<u32> {
        self.path_to_id.get(path).copied()
    }

    /// Candidate pruning cannot prove a negative for short plain-text files
    /// (`< 3` bytes) or files that could not be read during indexing. Binary
    /// files are excluded here so project/directory replacement previews are
    /// not permanently blocked by non-text assets such as images or fonts.
    pub(crate) fn unindexed_content_ids(&self) -> impl Iterator<Item = u32> + '_ {
        self.files.iter().enumerate().filter_map(|(id, file)| {
            file.as_ref()
                .filter(|file| {
                    matches!(
                        file.content_state,
                        ContentIndexState::ShortText | ContentIndexState::UnreadableOrOversize
                    )
                })
                .map(|_| id as u32)
        })
    }

    pub(crate) fn candidate_ids(
        &self,
        query: &str,
        regular_expression: bool,
        case_sensitive: bool,
    ) -> Vec<u32> {
        let Some(anchor) = search_anchor(query, regular_expression) else {
            return self.all_file_ids();
        };
        let trigrams = unique_trigrams(&anchor);
        if trigrams.is_empty() {
            return self.all_file_ids();
        }
        let mut candidates = self.posting_candidates(&trigrams);
        if !case_sensitive {
            // Only `U+017F` (`ſ` -> `s`) and `U+212A` (`K` -> `k`) simple-case-fold
            // from non-ASCII to ASCII in Unicode. Restricting the extra candidate set
            // to those files keeps trigram pruning active for all other UTF-8 sources.
            candidates.extend(self.files.iter().enumerate().filter_map(|(id, file)| {
                file.as_ref()
                    .filter(|file| file.has_ascii_casefold_non_ascii)
                    .map(|_| id as u32)
            }));
        }
        candidates.sort_unstable();
        candidates.dedup();
        candidates
    }

    fn posting_candidates(&self, trigrams: &[u32]) -> Vec<u32> {
        let mut postings = Vec::with_capacity(trigrams.len());
        for trigram in trigrams {
            let Some(posting) = self.postings.get(trigram) else {
                return Vec::new();
            };
            postings.push(posting);
        }
        postings.sort_by_key(|posting| posting.len());
        let mut candidates = postings[0]
            .iter()
            .copied()
            .filter(|id| self.file(*id).is_some())
            .collect::<Vec<_>>();
        candidates.retain(|id| {
            postings[1..]
                .iter()
                .all(|posting| posting.binary_search(id).is_ok())
        });
        candidates.sort_unstable();
        candidates
    }

    pub(crate) fn symbols(&self, id: u32) -> &[IndexedSymbol] {
        self.file(id)
            .map(|file| file.symbols.as_slice())
            .unwrap_or(&[])
    }

    /// Returns `(relative_path, symbol)` entries whose name matches `name` exactly.
    pub(crate) fn exact_symbols(&self, name: &str) -> Vec<(&str, &IndexedSymbol)> {
        let lower = name.to_ascii_lowercase();
        let Some(entries) = self.symbols_by_lower_name.get(&lower) else {
            return Vec::new();
        };
        entries
            .iter()
            .filter_map(|&(file_id, sym_idx)| {
                let file = self.file(file_id)?;
                let symbol = file.symbols.get(sym_idx as usize)?;
                (symbol.name == name).then_some((file.path.as_str(), symbol))
            })
            .collect()
    }

    /// Returns up to `limit` `(relative_path, symbol)` entries matching a lowercased prefix.
    pub(crate) fn prefix_symbols(
        &self,
        prefix_lower: &str,
        limit: usize,
    ) -> Vec<(&str, &IndexedSymbol)> {
        if prefix_lower.is_empty() || limit == 0 {
            return Vec::new();
        }
        let mut results = Vec::new();
        for (key, entries) in self.symbols_by_lower_name.range(prefix_lower.to_string()..) {
            if !key.starts_with(prefix_lower) {
                break;
            }
            for &(file_id, sym_idx) in entries {
                if let Some(file) = self.file(file_id) {
                    if let Some(symbol) = file.symbols.get(sym_idx as usize) {
                        results.push((file.path.as_str(), symbol));
                        if results.len() >= limit {
                            return results;
                        }
                    }
                }
            }
        }
        results
    }

    pub(crate) fn stats(&self) -> SearchIndexStats {
        SearchIndexStats {
            file_count: self.files.iter().filter(|file| file.is_some()).count(),
            symbol_count: self
                .files
                .iter()
                .filter_map(Option::as_ref)
                .map(|file| file.symbols.len())
                .sum(),
            posting_count: self.postings.values().map(Vec::len).sum(),
        }
    }
}

fn normalized_update_path(root: &Path, value: &str) -> Option<PathBuf> {
    let path = PathBuf::from(value);
    let absolute = if path.is_absolute() {
        path
    } else {
        root.join(path)
    };
    let normalized = canonicalize_with_missing_components(&absolute)?;
    normalized.starts_with(root).then_some(normalized)
}

pub(crate) fn canonicalize_with_missing_components(path: &Path) -> Option<PathBuf> {
    if let Ok(canonical) = path.canonicalize() {
        return Some(canonical);
    }
    // Deleted paths cannot be canonicalized directly. Canonicalize their
    // nearest surviving ancestor, then append the missing path components.
    let mut ancestor = path;
    let mut suffix = Vec::<OsString>::new();
    while !ancestor.exists() {
        suffix.push(ancestor.file_name()?.to_os_string());
        ancestor = ancestor.parent()?;
    }
    let mut normalized = ancestor.canonicalize().ok()?;
    for component in suffix.iter().rev() {
        normalized.push(component);
    }
    Some(normalized)
}

fn collect_files(
    root: &Path,
    path: &Path,
    rules: &VisibilityRules,
    files: &mut Vec<PathBuf>,
) -> Result<(), CoreError> {
    crate::protocol::cancellation::check()?;
    let mut children = Vec::new();
    for entry in fs::read_dir(path)? {
        crate::protocol::cancellation::check()?;
        let child_path = entry?.path();
        // An unreadable directory entry is not evidence of an empty scope.
        // Propagate it so scoped callers cannot label an incomplete index as a
        // complete replacement preview.
        let metadata = fs::symlink_metadata(&child_path)?;
        if metadata.file_type().is_symlink() {
            continue;
        }
        let relative = relative_path(&child_path, root);
        if !rules.is_hidden(&relative, metadata.is_dir()) {
            children.push((child_path, metadata.is_dir()));
        }
    }
    children.sort_by(|left, right| {
        right.1.cmp(&left.1).then_with(|| {
            left.0
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or_default()
                .to_lowercase()
                .cmp(
                    &right
                        .0
                        .file_name()
                        .and_then(|value| value.to_str())
                        .unwrap_or_default()
                        .to_lowercase(),
                )
        })
    });
    for (child, is_directory) in children {
        if is_directory {
            collect_files(root, &child, rules, files)?;
        } else {
            files.push(child);
        }
    }
    Ok(())
}

fn read_search_data(
    path: &Path,
    relative: &str,
) -> (Vec<u32>, ContentIndexState, Vec<IndexedSymbol>, bool) {
    let text = match read_indexed_file_content(path) {
        FileContentOutcome::Text(text) => text,
        FileContentOutcome::Binary => {
            return (Vec::new(), ContentIndexState::Binary, Vec::new(), false);
        }
        FileContentOutcome::UnreadableOrOversize => {
            return (
                Vec::new(),
                ContentIndexState::UnreadableOrOversize,
                Vec::new(),
                false,
            );
        }
    };
    let trigrams = unique_trigrams(&text);
    let content_state = if trigrams.is_empty() {
        ContentIndexState::ShortText
    } else {
        ContentIndexState::Indexed
    };
    let symbols = extract_symbols(relative, &text)
        .into_iter()
        .map(|symbol| IndexedSymbol {
            name: symbol.name,
            kind: symbol.kind,
            line: symbol.line,
            utf16_column: symbol.utf16_column,
            signature: symbol.signature,
            doc_comment: symbol.doc_comment,
        })
        .collect();
    let has_ascii_casefold_non_ascii = text
        .chars()
        .any(|character| matches!(character, '\u{017F}' | '\u{212A}'));
    (
        trigrams,
        content_state,
        symbols,
        has_ascii_casefold_non_ascii,
    )
}

fn unique_trigrams(value: &str) -> Vec<u32> {
    let normalized = value.to_lowercase();
    let bytes = normalized.as_bytes();
    let mut unique = HashSet::new();
    for window in bytes.windows(3) {
        unique.insert(encode_trigram(window));
    }
    let mut result = unique.into_iter().collect::<Vec<_>>();
    result.sort_unstable();
    result
}

fn encode_trigram(window: &[u8]) -> u32 {
    (u32::from(window[0]) << 16) | (u32::from(window[1]) << 8) | u32::from(window[2])
}

fn search_anchor(query: &str, regular_expression: bool) -> Option<String> {
    if regular_expression {
        return None;
    }
    let anchor = query.to_string();
    if anchor.is_ascii() && anchor.len() >= 3 {
        Some(anchor)
    } else {
        None
    }
}

pub(crate) fn make_symbol_match(indexed: &IndexedSymbol, path: String) -> SearchMatch {
    SearchMatch {
        kind: indexed.kind.clone(),
        path,
        line: Some(indexed.line),
        preview: indexed.signature.clone(),
        symbol_name: Some(indexed.name.clone()),
    }
}
