//! Explicit, bounded text scopes and exact-source replacement previews.

use super::files::{
    existing_root, file_mask_allows, is_plain_text, parse_file_mask, safe_relative_path_string,
    Matcher, ReplacementPreviewRequest, VisibilityRules,
};
use super::search_index;
use crate::protocol::{
    CoreError, ErrorCode, ReplacementEdit, ReplacementFile, ReplacementMatch,
    ReplacementPreviewIssue, ReplacementPreviewResponse,
};
use serde::Deserialize;
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

const MAX_FILES: usize = 1_000;
const MAX_OCCURRENCES: usize = 10_000;
const MAX_SOURCE_BYTES: usize = 16 * 1024 * 1024;
const MAX_OUTPUT_BYTES: usize = 16 * 1024 * 1024;
const MAX_FILE_BYTES: usize = 2 * 1024 * 1024;
const MAX_REPLACEMENT_BYTES: usize = 64 * 1024;

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
/// Scope identity is relative to the original workspace, never a different root.
pub enum ReplacementScope {
    /// Visible project files, including unindexed editor overrides.
    Project {},
    /// Visible files beneath one workspace-relative directory.
    Directory { path: String },
    /// The exact captured file set. An empty list does no traversal or matching.
    Files { paths: Vec<String> },
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
/// Search is non-mutating and does not require replacement-target eligibility.
pub enum PreviewPurpose {
    Search,
    Replace,
}

impl ReplacementScope {
    fn includes(&self, path: &str) -> bool {
        match self {
            Self::Project {} | Self::Files { .. } => true,
            Self::Directory { path: directory } => {
                directory.is_empty()
                    || path
                        .strip_prefix(directory)
                        .is_some_and(|tail| tail.starts_with('/'))
            }
        }
    }
}

/// Produces a complete or explicitly incomplete preview without writing files.
pub(super) fn preview(
    request: ReplacementPreviewRequest,
) -> Result<ReplacementPreviewResponse, CoreError> {
    if !request.paths.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Explicit scope cannot be combined with legacy paths",
        ));
    }
    let mut scope = request
        .scope
        .as_ref()
        .expect("scoped request")
        .to_owned_scope()?;
    let root = existing_root(&request.root)?;
    let mut response = ReplacementPreviewResponse {
        files: Vec::new(),
        status: Some("complete".into()),
        issues: Vec::new(),
    };
    if request.query.is_empty()
        || matches!(&scope, ReplacementScope::Files { paths } if paths.is_empty())
    {
        return Ok(response);
    }
    if request.replacement.len() > MAX_REPLACEMENT_BYTES {
        mark_incomplete(
            &mut response,
            None,
            "previewBudgetExceeded",
            "Narrow the preview scope or replacement text.",
        );
        return Ok(response);
    }
    let matcher = Matcher::new(
        &request.query,
        request.case_sensitive,
        request.whole_words,
        request.regular_expression,
    )?;
    let rules = VisibilityRules::new(
        request.hidden_directory_names.clone(),
        request.hidden_file_patterns.clone(),
    );
    let masks = parse_file_mask(&request.file_mask);
    if let ReplacementScope::Directory { path } = &mut scope {
        validate_path(&root, path, false, false, false)?;
        if !root.join(path).is_dir() {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Search scope must be a directory",
            ));
        }
    }
    let mut paths = BTreeSet::new();
    match &scope {
        ReplacementScope::Files { paths: explicit } => paths.extend(explicit.iter().cloned()),
        _ => {
            let shared = search_index::get_or_build(&root, &rules)?;
            let index = shared.read().map_err(|_| {
                CoreError::new(ErrorCode::Unknown, "Search index lock was poisoned")
            })?;
            for id in index
                .candidate_ids(
                    &request.query,
                    request.regular_expression,
                    request.case_sensitive,
                )
                .into_iter()
                .chain(index.unindexed_content_ids())
            {
                if let Some(file) = index.file(id) {
                    paths.insert(file.path.clone());
                }
            }
            // The disk index cannot know about newly typed matches. Overrides
            // must join candidates before matching, including new files.
            for path in request.text_overrides.keys() {
                paths.insert(checked_relative(path)?);
            }
        }
    }
    let purpose = request.purpose.unwrap_or(PreviewPurpose::Replace);
    let mut source_bytes = 0usize;
    let mut output_bytes = 0usize;
    let mut occurrences = 0usize;
    let mut inspected = 0usize;
    for path in paths {
        crate::protocol::cancellation::check()?;
        if !scope.includes(&path)
            || !file_mask_allows(&masks, &path)
            || (!matches!(scope, ReplacementScope::Files { .. }) && rules.is_hidden(&path, false))
        {
            continue;
        }
        if inspected == MAX_FILES {
            mark_incomplete(
                &mut response,
                None,
                "previewBudgetExceeded",
                "Narrow the preview to fewer files.",
            );
            break;
        }
        inspected += 1;
        let override_text = request.text_overrides.get(&path);
        if let Err(error) = validate_path(
            &root,
            &path,
            purpose == PreviewPurpose::Replace,
            override_text.is_some(),
            true,
        ) {
            mark_incomplete(
                &mut response,
                Some(path),
                error_code(&error),
                &error.message,
            );
            continue;
        }
        let text = match override_text {
            Some(text) if text.len() <= MAX_FILE_BYTES => text.clone(),
            Some(_) => {
                mark_incomplete(
                    &mut response,
                    Some(path),
                    "previewBudgetExceeded",
                    "The editor buffer exceeds the preview size limit.",
                );
                continue;
            }
            None => match read_bounded(&root.join(&path)) {
                Ok(text) => text,
                Err(error) => {
                    mark_incomplete(
                        &mut response,
                        Some(path),
                        error_code(&error),
                        &error.message,
                    );
                    continue;
                }
            },
        };
        if !is_plain_text(&text) {
            mark_incomplete(
                &mut response,
                Some(path),
                "parse_failed",
                "The target is not a plain text document.",
            );
            continue;
        }
        if text.len() > MAX_SOURCE_BYTES - source_bytes {
            mark_incomplete(
                &mut response,
                None,
                "previewBudgetExceeded",
                "Narrow the preview source size.",
            );
            break;
        }
        source_bytes += text.len();
        let file = match preview_file(
            &path,
            text,
            &matcher,
            &request.replacement,
            request.preserve_case,
            MAX_OCCURRENCES - occurrences,
            MAX_OUTPUT_BYTES - output_bytes,
        ) {
            Ok(file) => file,
            Err(error) if matches!(error.code, ErrorCode::Cancelled | ErrorCode::TimedOut) => {
                return Err(error)
            }
            Err(error) => {
                mark_incomplete(
                    &mut response,
                    Some(path),
                    error_code(&error),
                    &error.message,
                );
                break;
            }
        };
        if !file.edits.is_empty() {
            occurrences += file.edits.len();
            output_bytes += file.replacement_text.len()
                + file
                    .edits
                    .iter()
                    .map(|edit| edit.new_text.len())
                    .sum::<usize>()
                + file
                    .matches
                    .iter()
                    .map(|item| item.before.len() + item.after.len())
                    .sum::<usize>();
            response.files.push(file);
        }
    }
    Ok(response)
}

impl ReplacementScope {
    fn to_owned_scope(&self) -> Result<Self, CoreError> {
        Ok(match self {
            Self::Project {} => Self::Project {},
            Self::Directory { path } => Self::Directory {
                path: if path.is_empty() {
                    String::new()
                } else {
                    checked_relative(path)?
                },
            },
            Self::Files { paths } => Self::Files {
                paths: paths
                    .iter()
                    .map(|path| checked_relative(path))
                    .collect::<Result<_, _>>()?,
            },
        })
    }
}

fn checked_relative(path: &str) -> Result<String, CoreError> {
    let normalized = safe_relative_path_string(path)?;
    if normalized.is_empty()
        || normalized != path
        || path.split('/').any(|part| part == "." || part.is_empty())
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Scope paths must be normalized workspace-relative paths",
        ));
    }
    Ok(normalized)
}

fn validate_path(
    root: &Path,
    relative: &str,
    replacing: bool,
    allow_missing: bool,
    require_regular: bool,
) -> Result<(), CoreError> {
    let mut path = root.to_path_buf();
    for component in relative.split('/').filter(|part| !part.is_empty()) {
        path.push(component);
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(CoreError::new(
                    ErrorCode::PermissionDenied,
                    "Symbolic link targets are not supported in this preview",
                ));
            }
            Ok(metadata)
                if path == root.join(relative) && require_regular && !metadata.is_file() =>
            {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Preview target must be a regular file",
                ));
            }
            Ok(metadata) if path == root.join(relative) && replacing && metadata.is_file() => {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::MetadataExt;
                    if metadata.nlink() > 1 {
                        return Err(CoreError::new(
                            ErrorCode::PermissionDenied,
                            "Hardlinked replacement targets are not supported",
                        ));
                    }
                }
                if metadata.permissions().readonly() {
                    return Err(CoreError::new(
                        ErrorCode::PermissionDenied,
                        "The replacement target is read-only",
                    ));
                }
            }
            Ok(_) => {}
            Err(error) if allow_missing && error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(())
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

fn read_bounded(path: &Path) -> Result<String, CoreError> {
    let bytes = super::files::read_regular_file(path, MAX_FILE_BYTES)?;
    String::from_utf8(bytes)
        .map_err(|_| CoreError::new(ErrorCode::ParseFailed, "Preview target is not UTF-8"))
}

fn preview_file(
    path: &str,
    text: String,
    matcher: &Matcher,
    replacement: &str,
    preserve_case: bool,
    max_occurrences: usize,
    max_bytes: usize,
) -> Result<ReplacementFile, CoreError> {
    let budget_error = || {
        CoreError::new(
            ErrorCode::NotSupported,
            "Narrow the preview match count or output size.",
        )
    };
    let mut edits = Vec::new();
    let mut matches = Vec::new();
    let mut result = String::new();
    let mut utf16_offset = 0usize;
    let mut projected_bytes = 0usize;
    for (line_index, line) in text.split('\n').enumerate() {
        crate::protocol::cancellation::check()?;
        let line_edits = matcher.replacement_edits(
            line,
            replacement,
            preserve_case,
            max_occurrences - edits.len(),
            max_bytes
                .checked_sub(projected_bytes)
                .ok_or_else(budget_error)?,
        )?;
        let mut after = String::new();
        let mut cursor = 0;
        let mut line_utf16 = 0;
        for (start, end, new_text) in &line_edits {
            after.push_str(&line[cursor..*start]);
            after.push_str(new_text);
            // Count disjoint spans once; repeatedly counting the full prefix
            // makes a dense single-line preview quadratic.
            line_utf16 += line[cursor..*start].encode_utf16().count();
            let utf16_start = utf16_offset + line_utf16;
            let utf16_length = line[*start..*end].encode_utf16().count();
            edits.push(ReplacementEdit {
                id: format!("{path}:{utf16_start}:{}", edits.len()),
                line: line_index + 1,
                utf16_start,
                utf16_length,
                new_text: new_text.clone(),
            });
            line_utf16 += utf16_length;
            cursor = *end;
        }
        after.push_str(&line[cursor..]);
        projected_bytes += after.len()
            + line_edits
                .iter()
                .map(|(_, _, text)| text.len())
                .sum::<usize>();
        if !line_edits.is_empty() {
            projected_bytes += line.len() + after.len();
            matches.push(ReplacementMatch {
                line: line_index + 1,
                before: line.into(),
                after: after.clone(),
                occurrence_count: line_edits.len(),
            });
        }
        if line_index > 0 {
            result.push('\n');
            projected_bytes += 1;
        }
        if projected_bytes > max_bytes {
            return Err(budget_error());
        }
        result.push_str(&after);
        utf16_offset += line.encode_utf16().count() + 1;
    }
    Ok(ReplacementFile {
        path: path.into(),
        matches,
        replacement_text: result,
        source_text: Some(text),
        edits,
    })
}

fn error_code(error: &CoreError) -> &'static str {
    match error.code {
        ErrorCode::WorkspaceNotFound => "file_not_found",
        ErrorCode::PermissionDenied => "permission_denied",
        ErrorCode::ParseFailed => "parse_failed",
        ErrorCode::NotSupported => "previewBudgetExceeded",
        _ => "invalid_request",
    }
}

fn mark_incomplete(
    response: &mut ReplacementPreviewResponse,
    path: Option<String>,
    code: &str,
    message: &str,
) {
    response.status = Some("incomplete".into());
    response.issues.push(ReplacementPreviewIssue {
        path,
        code: code.into(),
        message: message.into(),
    });
}
