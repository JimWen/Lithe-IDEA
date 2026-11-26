//! In-process lightweight language intelligence (completions, rich hover,
//! signature help, cross-file go-to-definition, and trigram-pruned references)
//! backed by deterministic source scanning and the cached `WorkspaceSearchIndex`.

use super::edits::utf16_position_to_byte_offset;
use crate::lsp::interface::{
    LspParameterInformationResponse, LspPosition, LspPositionResponse, LspRangeResponse,
    LspSignatureHelpResponse, LspSignatureInformationResponse, LspTextEditResponse,
};
use crate::project::{
    extract_symbols, get_cached_search_index, language_group_for_path, read_indexed_file_content,
    FileContentOutcome,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

const MAX_COMPLETION_ITEMS: usize = 80;
const MAX_WORKSPACE_COMPLETION_SCAN: usize = 200;
const MAX_REFERENCE_LOCATIONS: usize = 300;
const MAX_REFERENCE_FILES_TO_READ: usize = 150;
const MAX_SIGNATURE_CANDIDATES: usize = 5;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Document, cursor, and optional workspace context used by lightweight completion,
/// hover, and signature help.
pub struct BuiltinRequest {
    /// Absolute or display path of the active document.
    pub file_path: String,
    /// Full UTF-8 text of the active document.
    pub text: String,
    /// Zero-based line and UTF-16 column cursor position.
    pub position: LspPosition,
    /// Optional workspace root used to query the cached `WorkspaceSearchIndex`.
    #[serde(default)]
    pub workspace_root: Option<String>,
    /// Optional map of unsaved/open sibling buffer paths to their current text.
    #[serde(default)]
    pub open_buffers: Option<BTreeMap<String, String>>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Document, cursor, LSP method, and optional workspace context used by lightweight navigation.
pub struct BuiltinNavigationRequest {
    /// Absolute or display path of the active document.
    pub file_path: String,
    /// Full UTF-8 text of the active document.
    pub text: String,
    /// Zero-based line and UTF-16 column cursor position.
    pub position: LspPosition,
    /// Requested LSP navigation method (`definition`, `declaration`, `typeDefinition`, `references`, `implementation`).
    pub method: String,
    /// Optional workspace root used to query the cached `WorkspaceSearchIndex`.
    #[serde(default)]
    pub workspace_root: Option<String>,
    /// Optional map of unsaved/open sibling buffer paths to their current text.
    #[serde(default)]
    pub open_buffers: Option<BTreeMap<String, String>>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Deterministically ranked completion candidates from the current document and workspace index.
pub struct BuiltinCompletionResponse {
    /// Ranked completion items ready for popup presentation.
    pub items: Vec<BuiltinCompletionItem>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Completion candidate expressed in the normalized Core response shape.
pub struct BuiltinCompletionItem {
    /// Primary identifier displayed in the completion list.
    pub label: String,
    /// Text inserted when accepting the item.
    pub insert_text: String,
    /// Numeric LSP `CompletionItemKind`, when the fallback can infer one.
    pub kind: Option<i32>,
    /// Concise signature or provenance label displayed next to the item.
    pub detail: Option<String>,
    /// Replacement range and text anchored to the typed identifier prefix.
    pub text_edit: LspTextEditResponse,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Optional hover result for the identifier at the cursor.
pub struct BuiltinHoverResponse {
    /// Resolved hover payload when an identifier is present under the cursor.
    pub hover: Option<BuiltinHover>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Lightweight hover contents and the identifier range they describe.
pub struct BuiltinHover {
    /// Formatted Markdown declaration signature, documentation, and location.
    pub contents: String,
    /// Always true for Markdown-formatted hover bodies.
    pub is_markdown: bool,
    /// Identifier span covered by this hover.
    pub range: LspRangeResponse,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Locations found by the lightweight navigation fallback.
pub struct BuiltinNavigationResponse {
    /// Ranked definition targets or code-only reference matches.
    pub locations: Vec<BuiltinLocation>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One normalized navigation target.
pub struct BuiltinLocation {
    /// Absolute file path of the target location.
    pub file_path: String,
    /// Zero-based UTF-16 range of the matched identifier.
    pub range: LspRangeResponse,
    /// Whether the target should be opened read-only.
    pub is_read_only: bool,
    /// Optional workspace-relative path for compact UI display.
    pub display_path: Option<String>,
}

#[derive(Debug, Clone)]
struct IdentifierOccurrence {
    value: String,
    start: usize,
    end: usize,
    range: LspRangeResponse,
}

#[derive(Debug, Clone)]
struct ResolvedSymbol {
    file_path: String,
    display_path: Option<String>,
    name: String,
    /// One-based declaration line.
    line: usize,
    /// Zero-based UTF-16 start column of `name`.
    utf16_column: usize,
    signature: String,
    doc_comment: Option<String>,
    rank: u8,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum LexDialect {
    Go,
    Rust,
    Python,
    CStyle,
}

fn lex_dialect_for_path(path: &str) -> LexDialect {
    match path
        .rsplit('.')
        .next()
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("go") => LexDialect::Go,
        Some("rs") => LexDialect::Rust,
        Some("py" | "pyi" | "pyw" | "sh" | "bash" | "zsh" | "yaml" | "yml" | "toml") => {
            LexDialect::Python
        }
        _ => LexDialect::CStyle,
    }
}

/// Produces proximity- and workspace-ranked completions skipping comments and string literals.
pub fn builtin_completions(
    request: BuiltinRequest,
) -> Result<BuiltinCompletionResponse, CoreError> {
    validate_file_path(&request.file_path)?;
    let cursor = utf16_position_to_byte_offset(&request.text, request.position)?;
    let prefix = identifier_prefix_at(&request.text, cursor);
    let prefix_lower = prefix.to_ascii_lowercase();
    let start_column = request.position.utf16_column - prefix.encode_utf16().count() as i64;
    let replacement_range = LspRangeResponse {
        start: LspPositionResponse {
            line: request.position.line,
            utf16_column: start_column.max(0),
        },
        end: LspPositionResponse {
            line: request.position.line,
            utf16_column: request.position.utf16_column,
        },
    };

    struct Candidate {
        label: String,
        kind: i32,
        detail: String,
        /// Lower is better: `(match_tier, source_tier, distance, label)`.
        match_tier: u8,
        source_tier: u8,
        distance: i64,
    }

    let mut best_by_label: HashMap<String, Candidate> = HashMap::new();
    let mut consider =
        |label: String, kind: i32, detail: String, source_tier: u8, distance: i64| {
            if label.is_empty() || label == prefix || is_language_keyword(&label) {
                return;
            }
            let Some(match_tier) = completion_match_tier(&label, &prefix, &prefix_lower) else {
                return;
            };
            let replace = match best_by_label.get(&label) {
                None => true,
                Some(existing) => {
                    (match_tier, source_tier, distance)
                        < (existing.match_tier, existing.source_tier, existing.distance)
                }
            };
            if replace {
                best_by_label.insert(
                    label.clone(),
                    Candidate {
                        label,
                        kind,
                        detail,
                        match_tier,
                        source_tier,
                        distance,
                    },
                );
            }
        };

    // 1. Current-file extracted declarations (richest signatures and kinds).
    for symbol in extract_symbols(&request.file_path, &request.text) {
        let distance = (symbol.line as i64 - 1 - request.position.line).abs();
        let kind = completion_kind_for_symbol(&symbol.kind, &symbol.signature);
        consider(symbol.name, kind, symbol.signature, 0, distance);
    }

    // 2. Current-file code identifiers (excluding comments and strings), ranked by proximity.
    for occurrence in identifier_occurrences_in_code(&request.file_path, &request.text) {
        // Ignore the incomplete identifier currently being typed at the cursor.
        if occurrence.start <= cursor && cursor <= occurrence.end {
            continue;
        }
        let distance = (occurrence.range.start.line - request.position.line).abs();
        let kind = builtin_completion_kind(&request.text, occurrence.start);
        consider(
            occurrence.value,
            kind,
            "Current file symbol".to_string(),
            1,
            distance,
        );
    }

    let active_lang = language_group_for_path(&request.file_path);
    let active_canonical = normalize_file_key(&request.file_path);
    let mut open_paths = HashSet::<String>::new();
    open_paths.insert(active_canonical.clone());

    // 3. Open sibling buffers (in-memory edits beat stale disk index).
    if let Some(open_buffers) = &request.open_buffers {
        for (buf_path, buf_text) in open_buffers {
            let key = normalize_file_key(buf_path);
            if !open_paths.insert(key) {
                continue;
            }
            if active_lang.is_some() && language_group_for_path(buf_path) != active_lang {
                continue;
            }
            let file_name = Path::new(buf_path)
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or(buf_path);
            for symbol in extract_symbols(buf_path, buf_text) {
                let kind = completion_kind_for_symbol(&symbol.kind, &symbol.signature);
                let detail = format!("{}  ({})", symbol.signature, file_name);
                consider(symbol.name, kind, detail, 2, symbol.line as i64);
            }
        }
    }

    // 4. Cached workspace symbol index via O(log N) prefix range query.
    if !prefix_lower.is_empty() {
        if let Some(root_str) = request.workspace_root.as_deref() {
            let root = PathBuf::from(root_str);
            if let Some(shared) = get_cached_search_index(&root) {
                if let Ok(index) = shared.read() {
                    let canonical_root = root.canonicalize().unwrap_or(root);
                    for (rel_path, symbol) in
                        index.prefix_symbols(&prefix_lower, MAX_WORKSPACE_COMPLETION_SCAN)
                    {
                        let full = canonical_root.join(rel_path);
                        let key = normalize_file_key(&full.to_string_lossy());
                        if open_paths.contains(&key) {
                            continue;
                        }
                        let same_lang = active_lang.is_none()
                            || language_group_for_path(rel_path) == active_lang;
                        if !same_lang {
                            continue;
                        }
                        let kind = completion_kind_for_symbol(&symbol.kind, &symbol.signature);
                        let detail = format!("{}  ({})", symbol.signature, rel_path);
                        consider(symbol.name.clone(), kind, detail, 3, symbol.line as i64);
                    }
                }
            }
        }
    }

    let mut ranked: Vec<Candidate> = best_by_label.into_values().collect();
    ranked.sort_by(|left, right| {
        (
            left.match_tier,
            left.source_tier,
            left.distance,
            &left.label,
        )
            .cmp(&(
                right.match_tier,
                right.source_tier,
                right.distance,
                &right.label,
            ))
    });

    let items = ranked
        .into_iter()
        .take(MAX_COMPLETION_ITEMS)
        .map(|candidate| BuiltinCompletionItem {
            insert_text: candidate.label.clone(),
            label: candidate.label.clone(),
            kind: Some(candidate.kind),
            detail: Some(candidate.detail),
            text_edit: LspTextEditResponse {
                range: replacement_range,
                new_text: candidate.label,
            },
        })
        .collect();
    Ok(BuiltinCompletionResponse { items })
}

/// Returns a rich Markdown signature + doc hover for the identifier under the cursor.
pub fn builtin_hover(request: BuiltinRequest) -> Result<BuiltinHoverResponse, CoreError> {
    validate_file_path(&request.file_path)?;
    let cursor = utf16_position_to_byte_offset(&request.text, request.position)?;
    let Some(identifier) = identifier_at(&request.file_path, &request.text, cursor) else {
        return Ok(BuiltinHoverResponse { hover: None });
    };

    let qualifier = preceding_qualifier(&request.text, identifier.start);
    let declarations = resolve_declarations(
        &request.file_path,
        &request.text,
        request.workspace_root.as_deref(),
        request.open_buffers.as_ref(),
        &identifier.value,
        qualifier.as_deref(),
    );

    if let Some(best) = declarations.first() {
        let fence = markdown_fence_for_path(&best.file_path);
        let mut sections = Vec::new();
        sections.push(format!("```{fence}\n{}\n```", best.signature));
        if let Some(doc) = &best.doc_comment {
            sections.push(doc.clone());
        }
        let location_label = best
            .display_path
            .as_deref()
            .or_else(|| Path::new(&best.file_path).file_name()?.to_str())
            .unwrap_or(&best.file_path);
        sections.push(format!("*`{location_label}:{}`*", best.line));
        return Ok(BuiltinHoverResponse {
            hover: Some(BuiltinHover {
                contents: sections.join("\n\n"),
                is_markdown: true,
                range: identifier.range,
            }),
        });
    }

    // Check local variable / parameter binding in the current file.
    if let Some(local_line) = find_local_declaration_line(&request.text, &identifier.value) {
        let fence = markdown_fence_for_path(&request.file_path);
        let snippet = request
            .text
            .split('\n')
            .nth(local_line.saturating_sub(1))
            .unwrap_or("")
            .trim();
        if !snippet.is_empty() {
            let file_name = Path::new(&request.file_path)
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or(&request.file_path);
            let contents = format!("```{fence}\n{snippet}\n```\n\n*`{file_name}:{local_line}`*");
            return Ok(BuiltinHoverResponse {
                hover: Some(BuiltinHover {
                    contents,
                    is_markdown: true,
                    range: identifier.range,
                }),
            });
        }
    }

    Ok(BuiltinHoverResponse {
        hover: Some(BuiltinHover {
            contents: format!("`{}`", identifier.value),
            is_markdown: true,
            range: identifier.range,
        }),
    })
}

/// Computes lightweight parameter hints for the enclosing call expression at the cursor.
pub fn builtin_signature_help(
    request: BuiltinRequest,
) -> Result<LspSignatureHelpResponse, CoreError> {
    validate_file_path(&request.file_path)?;
    let cursor = utf16_position_to_byte_offset(&request.text, request.position)?;
    let Some((callee, qualifier, active_param)) =
        enclosing_call_at(&request.file_path, &request.text, cursor)
    else {
        return Ok(LspSignatureHelpResponse {
            signatures: Vec::new(),
            active_signature: None,
            active_parameter: None,
        });
    };

    let declarations = resolve_declarations(
        &request.file_path,
        &request.text,
        request.workspace_root.as_deref(),
        request.open_buffers.as_ref(),
        &callee,
        qualifier.as_deref(),
    );

    let mut signatures = Vec::new();
    let mut seen_labels = HashSet::new();
    for symbol in declarations {
        let Some(parsed) = parse_callable_signature(&symbol) else {
            continue;
        };
        if !seen_labels.insert(parsed.label.clone()) {
            continue;
        }
        signatures.push(parsed);
        if signatures.len() >= MAX_SIGNATURE_CANDIDATES {
            break;
        }
    }

    if signatures.is_empty() {
        return Ok(LspSignatureHelpResponse {
            signatures: Vec::new(),
            active_signature: None,
            active_parameter: None,
        });
    }

    let clamped_param = signatures[0]
        .parameters
        .len()
        .checked_sub(1)
        .map(|max_idx| active_param.min(max_idx) as i64);

    Ok(LspSignatureHelpResponse {
        signatures,
        active_signature: Some(0),
        active_parameter: clamped_param,
    })
}

/// Finds cross-file definitions or trigram-pruned code-only references without an LSP server.
pub fn builtin_navigation(
    request: BuiltinNavigationRequest,
) -> Result<BuiltinNavigationResponse, CoreError> {
    validate_file_path(&request.file_path)?;
    if request.method == "textDocument/implementation" {
        // Honest capability boundary: interface/trait implementations require Precision LSP.
        return Ok(BuiltinNavigationResponse {
            locations: Vec::new(),
        });
    }

    let cursor = utf16_position_to_byte_offset(&request.text, request.position)?;
    let Some(identifier) = identifier_at(&request.file_path, &request.text, cursor) else {
        return Ok(BuiltinNavigationResponse {
            locations: Vec::new(),
        });
    };

    if matches!(
        request.method.as_str(),
        "textDocument/definition" | "textDocument/declaration" | "textDocument/typeDefinition"
    ) {
        let qualifier = preceding_qualifier(&request.text, identifier.start);
        let declarations = resolve_declarations(
            &request.file_path,
            &request.text,
            request.workspace_root.as_deref(),
            request.open_buffers.as_ref(),
            &identifier.value,
            qualifier.as_deref(),
        );
        if !declarations.is_empty() {
            let locations = declarations
                .into_iter()
                .take(40)
                .map(|symbol| {
                    let start_col = symbol.utf16_column as i64;
                    let end_col = start_col + symbol.name.encode_utf16().count() as i64;
                    let zero_line = symbol.line.saturating_sub(1) as i64;
                    BuiltinLocation {
                        file_path: symbol.file_path,
                        range: LspRangeResponse {
                            start: LspPositionResponse {
                                line: zero_line,
                                utf16_column: start_col,
                            },
                            end: LspPositionResponse {
                                line: zero_line,
                                utf16_column: end_col,
                            },
                        },
                        is_read_only: false,
                        display_path: symbol.display_path,
                    }
                })
                .collect();
            return Ok(BuiltinNavigationResponse { locations });
        }

        // Fall back to local variable / parameter declarations in the current file.
        let occurrences: Vec<_> = identifier_occurrences_in_code(&request.file_path, &request.text)
            .into_iter()
            .filter(|occurrence| occurrence.value == identifier.value)
            .collect();
        let local_decls: Vec<_> = occurrences
            .iter()
            .filter(|occurrence| looks_like_declaration(&request.text, occurrence.start))
            .cloned()
            .collect();
        let chosen = if !local_decls.is_empty() {
            local_decls
        } else {
            occurrences.into_iter().take(1).collect()
        };
        let locations = chosen
            .into_iter()
            .map(|occurrence| BuiltinLocation {
                file_path: request.file_path.clone(),
                range: occurrence.range,
                is_read_only: false,
                display_path: None,
            })
            .collect();
        return Ok(BuiltinNavigationResponse { locations });
    }

    // `textDocument/references`: scan current file + open sibling buffers + trigram-pruned workspace files.
    let mut locations = Vec::new();
    let active_display =
        relative_display_path(&request.file_path, request.workspace_root.as_deref());
    for occurrence in identifier_occurrences_in_code(&request.file_path, &request.text) {
        if occurrence.value == identifier.value {
            locations.push(BuiltinLocation {
                file_path: request.file_path.clone(),
                range: occurrence.range,
                is_read_only: false,
                display_path: active_display.clone(),
            });
            if locations.len() >= MAX_REFERENCE_LOCATIONS {
                return Ok(BuiltinNavigationResponse { locations });
            }
        }
    }

    let active_lang = language_group_for_path(&request.file_path);
    let mut scanned_paths = HashSet::<String>::new();
    scanned_paths.insert(normalize_file_key(&request.file_path));

    if let Some(open_buffers) = &request.open_buffers {
        for (buf_path, buf_text) in open_buffers {
            let key = normalize_file_key(buf_path);
            if !scanned_paths.insert(key) {
                continue;
            }
            if active_lang.is_some() && language_group_for_path(buf_path) != active_lang {
                continue;
            }
            let display = relative_display_path(buf_path, request.workspace_root.as_deref());
            for occurrence in identifier_occurrences_in_code(buf_path, buf_text) {
                if occurrence.value == identifier.value {
                    locations.push(BuiltinLocation {
                        file_path: buf_path.clone(),
                        range: occurrence.range,
                        is_read_only: false,
                        display_path: display.clone(),
                    });
                    if locations.len() >= MAX_REFERENCE_LOCATIONS {
                        return Ok(BuiltinNavigationResponse { locations });
                    }
                }
            }
        }
    }

    if let Some(root_str) = request.workspace_root.as_deref() {
        let root = PathBuf::from(root_str);
        if let Some(shared) = get_cached_search_index(&root) {
            let candidate_paths: Vec<(PathBuf, String)> = {
                if let Ok(index) = shared.read() {
                    let canonical_root = root.canonicalize().unwrap_or(root);
                    index
                        .candidate_ids(&identifier.value, false, true)
                        .into_iter()
                        .filter_map(|id| {
                            let file = index.file(id)?;
                            if active_lang.is_some()
                                && language_group_for_path(&file.path) != active_lang
                            {
                                return None;
                            }
                            let full = canonical_root.join(&file.path);
                            let key = normalize_file_key(&full.to_string_lossy());
                            if !scanned_paths.insert(key) {
                                return None;
                            }
                            Some((full, file.path.clone()))
                        })
                        .take(MAX_REFERENCE_FILES_TO_READ)
                        .collect()
                } else {
                    Vec::new()
                }
            };

            for (full_path, rel_path) in candidate_paths {
                let FileContentOutcome::Text(content) = read_indexed_file_content(&full_path)
                else {
                    continue;
                };
                let full_str = full_path.to_string_lossy().to_string();
                for occurrence in identifier_occurrences_in_code(&full_str, &content) {
                    if occurrence.value == identifier.value {
                        locations.push(BuiltinLocation {
                            file_path: full_str.clone(),
                            range: occurrence.range,
                            is_read_only: false,
                            display_path: Some(rel_path.clone()),
                        });
                        if locations.len() >= MAX_REFERENCE_LOCATIONS {
                            return Ok(BuiltinNavigationResponse { locations });
                        }
                    }
                }
            }
        }
    }

    Ok(BuiltinNavigationResponse { locations })
}

fn resolve_declarations(
    file_path: &str,
    text: &str,
    workspace_root: Option<&str>,
    open_buffers: Option<&BTreeMap<String, String>>,
    ident_name: &str,
    qualifier: Option<&str>,
) -> Vec<ResolvedSymbol> {
    let mut results = Vec::new();
    let active_lang = language_group_for_path(file_path);
    let active_dir = Path::new(file_path).parent().map(Path::to_path_buf);
    let active_display = relative_display_path(file_path, workspace_root);
    let mut covered_paths = HashSet::<String>::new();
    covered_paths.insert(normalize_file_key(file_path));

    // 1. Active file declarations.
    for symbol in extract_symbols(file_path, text) {
        if symbol.name == ident_name {
            let rank = if qualifier.is_some() { 2 } else { 0 };
            results.push(ResolvedSymbol {
                file_path: file_path.to_string(),
                display_path: active_display.clone(),
                name: symbol.name,
                line: symbol.line,
                utf16_column: symbol.utf16_column,
                signature: symbol.signature,
                doc_comment: symbol.doc_comment,
                rank,
            });
        }
    }

    // 2. Open sibling buffers.
    if let Some(buffers) = open_buffers {
        for (buf_path, buf_text) in buffers {
            let key = normalize_file_key(buf_path);
            if !covered_paths.insert(key) {
                continue;
            }
            let same_lang =
                active_lang.is_none() || language_group_for_path(buf_path) == active_lang;
            let same_dir = active_dir
                .as_ref()
                .is_some_and(|dir| Path::new(buf_path).parent() == Some(dir.as_path()));
            let display = relative_display_path(buf_path, workspace_root);
            let qualifier_hit =
                qualifier_matches_path(qualifier, display.as_deref().unwrap_or(buf_path));
            let rank = declaration_rank(false, qualifier_hit, same_dir, same_lang);
            for symbol in extract_symbols(buf_path, buf_text) {
                if symbol.name == ident_name {
                    results.push(ResolvedSymbol {
                        file_path: buf_path.clone(),
                        display_path: display.clone(),
                        name: symbol.name,
                        line: symbol.line,
                        utf16_column: symbol.utf16_column,
                        signature: symbol.signature,
                        doc_comment: symbol.doc_comment,
                        rank,
                    });
                }
            }
        }
    }

    // 3. Cached workspace search index (non-blocking O(log N) lookup).
    if let Some(root_str) = workspace_root {
        let root = PathBuf::from(root_str);
        if let Some(shared) = get_cached_search_index(&root) {
            if let Ok(index) = shared.read() {
                let canonical_root = root.canonicalize().unwrap_or(root);
                let active_canonical_dir = Path::new(file_path)
                    .canonicalize()
                    .ok()
                    .and_then(|p| p.parent().map(Path::to_path_buf))
                    .or(active_dir);
                for (rel_path, symbol) in index.exact_symbols(ident_name) {
                    let full = canonical_root.join(rel_path);
                    let full_str = full.to_string_lossy().to_string();
                    let key = normalize_file_key(&full_str);
                    if covered_paths.contains(&key) {
                        continue;
                    }
                    let same_lang =
                        active_lang.is_none() || language_group_for_path(rel_path) == active_lang;
                    let same_dir = active_canonical_dir
                        .as_ref()
                        .is_some_and(|dir| full.parent() == Some(dir.as_path()));
                    let qualifier_hit = qualifier_matches_path(qualifier, rel_path);
                    let rank = declaration_rank(false, qualifier_hit, same_dir, same_lang);
                    results.push(ResolvedSymbol {
                        file_path: full_str,
                        display_path: Some(rel_path.to_string()),
                        name: symbol.name.clone(),
                        line: symbol.line,
                        utf16_column: symbol.utf16_column,
                        signature: symbol.signature.clone(),
                        doc_comment: symbol.doc_comment.clone(),
                        rank,
                    });
                }
            }
        }
    }

    // Drop cross-language noise when at least one same-language declaration exists.
    if results.iter().any(|symbol| symbol.rank < 5) {
        results.retain(|symbol| symbol.rank < 5);
    }

    results.sort_by(|left, right| {
        left.rank
            .cmp(&right.rank)
            .then_with(|| left.display_path.cmp(&right.display_path))
            .then_with(|| left.file_path.cmp(&right.file_path))
            .then_with(|| left.line.cmp(&right.line))
    });
    results
}

fn declaration_rank(
    is_current_file: bool,
    qualifier_hit: bool,
    same_dir: bool,
    same_lang: bool,
) -> u8 {
    if is_current_file {
        0
    } else if qualifier_hit && same_lang {
        1
    } else if same_dir && same_lang {
        2
    } else if same_lang {
        3
    } else if qualifier_hit {
        4
    } else {
        5
    }
}

fn qualifier_matches_path(qualifier: Option<&str>, path: &str) -> bool {
    let Some(q) = qualifier else {
        return false;
    };
    let q_lower = q.to_ascii_lowercase();
    Path::new(path).components().any(|component| {
        let text = component.as_os_str().to_string_lossy();
        let stem = Path::new(text.as_ref())
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or(text.as_ref());
        stem.eq_ignore_ascii_case(&q_lower)
    })
}

fn preceding_qualifier(text: &str, ident_start: usize) -> Option<String> {
    let prefix = text[..ident_start].trim_end();
    let before_sep = prefix
        .strip_suffix("::")
        .or_else(|| prefix.strip_suffix('.'))?
        .trim_end();
    let end = before_sep.len();
    let mut start = end;
    while start > 0 {
        let Some((prev_idx, ch)) = before_sep[..start].char_indices().next_back() else {
            break;
        };
        if !is_identifier_character(ch) {
            break;
        }
        start = prev_idx;
    }
    let candidate = &before_sep[start..end];
    (!candidate.is_empty() && !is_language_keyword(candidate)).then(|| candidate.to_string())
}

fn enclosing_call_at(
    path: &str,
    text: &str,
    cursor: usize,
) -> Option<(String, Option<String>, usize)> {
    let mut clamped = cursor.min(text.len());
    while clamped > 0 && !text.is_char_boundary(clamped) {
        clamped -= 1;
    }
    // Scan a bounded window ending at cursor using byte-level newline lookup
    // so multi-byte UTF-8 characters can never split across the window boundary.
    let window_start = if clamped > 16_384 {
        text.as_bytes()[..clamped - 16_384]
            .iter()
            .rposition(|&byte| byte == b'\n')
            .map_or(0, |idx| idx + 1)
    } else {
        0
    };
    let slice = &text[window_start..clamped];
    let dialect = lex_dialect_for_path(path);
    let mut stack: Vec<(u8, usize, usize)> = Vec::new(); // (open_byte, abs_byte, comma_count)

    scan_code_bytes(slice, dialect, |rel_idx, byte| match byte {
        b'(' | b'[' | b'{' => stack.push((byte, window_start + rel_idx, 0)),
        b')' => {
            if stack.last().is_some_and(|&(b, _, _)| b == b'(') {
                stack.pop();
            }
        }
        b']' => {
            if stack.last().is_some_and(|&(b, _, _)| b == b'[') {
                stack.pop();
            }
        }
        b'}' => {
            if stack.last().is_some_and(|&(b, _, _)| b == b'{') {
                stack.pop();
            }
        }
        b',' => {
            if let Some(top) = stack.last_mut() {
                top.2 += 1;
            }
        }
        _ => {}
    });

    let &(_, open_paren_byte, comma_count) = stack.iter().rev().find(|&&(b, _, _)| b == b'(')?;
    let mut before = text[..open_paren_byte].trim_end();

    // Skip optional generic type arguments `foo::<T>(...)` / `foo[int](...)`.
    if let Some(stripped) = strip_trailing_balanced(before, '<', '>') {
        before = stripped.trim_end().trim_end_matches("::").trim_end();
    } else if let Some(stripped) = strip_trailing_balanced(before, '[', ']') {
        before = stripped.trim_end();
    }

    let ident_end = before.len();
    let mut ident_start = ident_end;
    while ident_start > 0 {
        let Some((prev_idx, ch)) = before[..ident_start].char_indices().next_back() else {
            break;
        };
        if !is_identifier_character(ch) {
            break;
        }
        ident_start = prev_idx;
    }
    let callee = &before[ident_start..ident_end];
    if callee.is_empty()
        || !callee.chars().next().is_some_and(is_identifier_start)
        || is_language_keyword(callee)
    {
        return None;
    }
    // Avoid triggering on declaration headers themselves (`func Foo(`, `fn bar(`, `def baz(`).
    let prefix_line = before[..ident_start]
        .rsplit('\n')
        .next()
        .unwrap_or("")
        .trim_end();
    if prefix_line
        .split(|c: char| !is_identifier_character(c))
        .filter(|tok| !tok.is_empty())
        .next_back()
        .is_some_and(|kw| matches!(kw, "func" | "fn" | "def" | "function" | "class" | "type"))
    {
        return None;
    }

    let qualifier = preceding_qualifier(text, ident_start);
    Some((callee.to_string(), qualifier, comma_count))
}

fn strip_trailing_balanced(text: &str, open: char, close: char) -> Option<&str> {
    if !text.ends_with(close) {
        return None;
    }
    let mut depth = 0usize;
    for (idx, ch) in text.char_indices().rev() {
        if ch == close {
            depth += 1;
        } else if ch == open {
            depth = depth.saturating_sub(1);
            if depth == 0 {
                return Some(&text[..idx]);
            }
        }
    }
    None
}

fn parse_callable_signature(symbol: &ResolvedSymbol) -> Option<LspSignatureInformationResponse> {
    let sig = symbol.signature.trim().trim_end_matches('{').trim();
    // Anchor search after `symbol.name` so Go receiver `(s *Svc)` is skipped.
    let name_pos = find_word_in_signature(sig, &symbol.name)?;
    let after_name = &sig[name_pos + symbol.name.len()..];
    let open_rel = after_name.find('(')?;
    let open_abs = name_pos + symbol.name.len() + open_rel;
    let close_abs = find_matching_paren(sig, open_abs)?;
    let params_slice = &sig[open_abs + 1..close_abs];

    let mut parameters = Vec::new();
    let mut part_start = 0usize;
    let mut depth_paren = 0usize;
    let mut depth_bracket = 0usize;
    let mut depth_brace = 0usize;
    let mut depth_angle = 0usize;

    let push_param =
        |raw_start: usize, raw_end: usize, out: &mut Vec<LspParameterInformationResponse>| {
            let segment = &params_slice[raw_start..raw_end];
            let trimmed = segment.trim();
            if trimmed.is_empty() {
                return;
            }
            let leading_ws = segment.len() - segment.trim_start().len();
            let abs_start = open_abs + 1 + raw_start + leading_ws;
            let abs_end = abs_start + trimmed.len();
            let label_start = sig[..abs_start].encode_utf16().count() as i64;
            let label_end = sig[..abs_end].encode_utf16().count() as i64;
            out.push(LspParameterInformationResponse {
                label: trimmed.to_string(),
                label_start: Some(label_start),
                label_end: Some(label_end),
                documentation: None,
            });
        };

    for (idx, ch) in params_slice.char_indices() {
        match ch {
            '(' => depth_paren += 1,
            ')' => depth_paren = depth_paren.saturating_sub(1),
            '[' => depth_bracket += 1,
            ']' => depth_bracket = depth_bracket.saturating_sub(1),
            '{' => depth_brace += 1,
            '}' => depth_brace = depth_brace.saturating_sub(1),
            '<' => depth_angle += 1,
            '>' => depth_angle = depth_angle.saturating_sub(1),
            ',' if depth_paren == 0
                && depth_bracket == 0
                && depth_brace == 0
                && depth_angle == 0 =>
            {
                push_param(part_start, idx, &mut parameters);
                part_start = idx + 1;
            }
            _ => {}
        }
    }
    push_param(part_start, params_slice.len(), &mut parameters);

    Some(LspSignatureInformationResponse {
        label: sig.to_string(),
        documentation: symbol.doc_comment.clone(),
        parameters,
        active_parameter: None,
    })
}

fn find_word_in_signature(signature: &str, name: &str) -> Option<usize> {
    if name.is_empty() {
        return None;
    }
    let mut search_from = 0usize;
    while let Some(pos) = signature[search_from..].find(name) {
        let abs = search_from + pos;
        let before_ok = abs == 0
            || !signature[..abs]
                .chars()
                .next_back()
                .is_some_and(is_identifier_character);
        let after_idx = abs + name.len();
        let after_ok = after_idx == signature.len()
            || !signature[after_idx..]
                .chars()
                .next()
                .is_some_and(is_identifier_character);
        if before_ok && after_ok {
            return Some(abs);
        }
        let step = signature[abs..].chars().next().map_or(1, char::len_utf8);
        search_from = abs + step;
    }
    None
}

fn find_matching_paren(text: &str, open_index: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (offset, ch) in text[open_index..].char_indices() {
        if ch == '(' {
            depth += 1;
        } else if ch == ')' {
            depth -= 1;
            if depth == 0 {
                return Some(open_index + offset);
            }
        }
    }
    None
}

/// Scans code-only bytes in `text`, invoking `visit(byte_index, byte)` outside comments and strings.
fn scan_code_bytes<F: FnMut(usize, u8)>(text: &str, dialect: LexDialect, mut visit: F) {
    let bytes = text.as_bytes();
    let mut index = 0usize;
    while index < bytes.len() {
        let byte = bytes[index];
        let next = bytes.get(index + 1).copied().unwrap_or(0);

        // Comments.
        if dialect == LexDialect::Python {
            if byte == b'#' {
                while index < bytes.len() && bytes[index] != b'\n' {
                    index += 1;
                }
                continue;
            }
            if bytes[index..].starts_with(b"\"\"\"") {
                index += 3;
                while index < bytes.len() {
                    if bytes[index] == b'\\' && index + 1 < bytes.len() {
                        index += 2;
                        continue;
                    }
                    if bytes[index..].starts_with(b"\"\"\"") {
                        index += 3;
                        break;
                    }
                    index += 1;
                }
                continue;
            }
            if bytes[index..].starts_with(b"'''") {
                index += 3;
                while index < bytes.len() {
                    if bytes[index] == b'\\' && index + 1 < bytes.len() {
                        index += 2;
                        continue;
                    }
                    if bytes[index..].starts_with(b"'''") {
                        index += 3;
                        break;
                    }
                    index += 1;
                }
                continue;
            }
        } else {
            if byte == b'/' && next == b'/' {
                index += 2;
                while index < bytes.len() && bytes[index] != b'\n' {
                    index += 1;
                }
                continue;
            }
            if byte == b'/' && next == b'*' {
                let nested = dialect == LexDialect::Rust;
                let mut depth = 1usize;
                index += 2;
                while index < bytes.len() && depth > 0 {
                    let c = bytes[index];
                    let n = bytes.get(index + 1).copied().unwrap_or(0);
                    if nested && c == b'/' && n == b'*' {
                        depth += 1;
                        index += 2;
                    } else if c == b'*' && n == b'/' {
                        depth -= 1;
                        index += 2;
                    } else {
                        index += 1;
                    }
                }
                continue;
            }
        }

        // Rust raw strings `r#"..."#`.
        if dialect == LexDialect::Rust {
            if let Some(end_idx) = skip_rust_raw_string(bytes, index) {
                index = end_idx;
                continue;
            }
        }

        // Double-quoted strings.
        if byte == b'"' {
            index += 1;
            while index < bytes.len() {
                if bytes[index] == b'\\' {
                    index += 2;
                    continue;
                }
                if bytes[index] == b'"' {
                    index += 1;
                    break;
                }
                index += 1;
            }
            continue;
        }

        // Go raw strings and JS/TS template literals.
        if byte == b'`' && matches!(dialect, LexDialect::Go | LexDialect::CStyle) {
            index += 1;
            while index < bytes.len() {
                if dialect == LexDialect::CStyle && bytes[index] == b'\\' {
                    index += 2;
                    continue;
                }
                if bytes[index] == b'`' {
                    index += 1;
                    break;
                }
                index += 1;
            }
            continue;
        }

        // Single-quoted strings / chars (preserving Rust lifetimes `'a`).
        if byte == b'\'' {
            if dialect == LexDialect::Rust {
                if let Some(end_idx) = skip_rust_char_literal(text, index) {
                    index = end_idx;
                    continue;
                }
                visit(index, byte);
                index += 1;
                continue;
            }
            index += 1;
            while index < bytes.len() && bytes[index] != b'\n' {
                if bytes[index] == b'\\' {
                    index += 2;
                    continue;
                }
                if bytes[index] == b'\'' {
                    index += 1;
                    break;
                }
                index += 1;
            }
            continue;
        }

        visit(index, byte);
        index += 1;
    }
}

fn skip_rust_raw_string(bytes: &[u8], index: usize) -> Option<usize> {
    let mut cursor = index;
    if matches!(bytes[cursor], b'b' | b'c') && bytes.get(cursor + 1) == Some(&b'r') {
        if cursor > 0 && (bytes[cursor - 1].is_ascii_alphanumeric() || bytes[cursor - 1] == b'_') {
            return None;
        }
        cursor += 1;
    }
    if bytes.get(cursor) != Some(&b'r') {
        return None;
    }
    if cursor > 0 && (bytes[cursor - 1].is_ascii_alphanumeric() || bytes[cursor - 1] == b'_') {
        return None;
    }
    cursor += 1;
    let mut hashes = 0usize;
    while bytes.get(cursor) == Some(&b'#') {
        hashes += 1;
        cursor += 1;
    }
    if bytes.get(cursor) != Some(&b'"') {
        return None;
    }
    cursor += 1;
    while cursor < bytes.len() {
        if bytes[cursor] == b'"' {
            let mut matched = 0usize;
            while matched < hashes && bytes.get(cursor + 1 + matched) == Some(&b'#') {
                matched += 1;
            }
            if matched == hashes {
                return Some(cursor + 1 + hashes);
            }
        }
        cursor += 1;
    }
    Some(bytes.len())
}

fn skip_rust_char_literal(text: &str, quote_byte: usize) -> Option<usize> {
    let rest = &text[quote_byte + 1..];
    let mut chars = rest.char_indices();
    let (_, first) = chars.next()?;
    if first == '\n' || first == '\'' {
        return None;
    }
    if first == '\\' {
        for (offset, ch) in chars {
            if ch == '\n' {
                return None;
            }
            if ch == '\'' {
                return Some(quote_byte + 1 + offset + 1);
            }
            if offset > 12 {
                return None;
            }
        }
        return None;
    }
    if let Some((offset, '\'')) = chars.next() {
        return Some(quote_byte + 1 + offset + 1);
    }
    None
}

/// Extracts identifier occurrences strictly outside comments and string literals.
fn identifier_occurrences_in_code(path: &str, text: &str) -> Vec<IdentifierOccurrence> {
    let dialect = lex_dialect_for_path(path);
    let mut code_mask = vec![false; text.len()];
    scan_code_bytes(text, dialect, |idx, _| {
        code_mask[idx] = true;
    });

    let mut values = Vec::new();
    let mut current_start: Option<(usize, i64, i64)> = None;
    let mut line: i64 = 0;
    let mut utf16_col: i64 = 0;
    for (index, character) in text.char_indices() {
        if code_mask[index] && is_identifier_character(character) {
            if current_start.is_none() {
                current_start = Some((index, line, utf16_col));
            }
        } else if let Some((start, start_line, start_col)) = current_start.take() {
            push_identifier(
                text,
                start,
                index,
                LspRangeResponse {
                    start: LspPositionResponse {
                        line: start_line,
                        utf16_column: start_col,
                    },
                    end: LspPositionResponse {
                        line,
                        utf16_column: utf16_col,
                    },
                },
                &mut values,
            );
        }
        if character == '\n' {
            line += 1;
            utf16_col = 0;
        } else {
            utf16_col += character.len_utf16() as i64;
        }
    }
    if let Some((start, start_line, start_col)) = current_start {
        push_identifier(
            text,
            start,
            text.len(),
            LspRangeResponse {
                start: LspPositionResponse {
                    line: start_line,
                    utf16_column: start_col,
                },
                end: LspPositionResponse {
                    line,
                    utf16_column: utf16_col,
                },
            },
            &mut values,
        );
    }
    values
}

fn raw_identifier_at(text: &str, cursor: usize) -> Option<IdentifierOccurrence> {
    let clamped = cursor.min(text.len());
    let mut start = clamped;
    while start > 0 {
        let Some((prev_idx, ch)) = text[..start].char_indices().next_back() else {
            break;
        };
        if !is_identifier_character(ch) {
            break;
        }
        start = prev_idx;
    }
    let mut end = clamped;
    for (offset, ch) in text[clamped..].char_indices() {
        if !is_identifier_character(ch) {
            break;
        }
        end = clamped + offset + ch.len_utf8();
    }
    let value = &text[start..end];
    if value.is_empty()
        || !value.chars().next().is_some_and(is_identifier_start)
        || is_language_keyword(value)
        || value.len() > 120
    {
        return None;
    }
    let line = text[..start].bytes().filter(|&b| b == b'\n').count() as i64;
    let line_start = text[..start].rfind('\n').map_or(0, |idx| idx + 1);
    let start_col = text[line_start..start].encode_utf16().count() as i64;
    let end_col = start_col + value.encode_utf16().count() as i64;
    Some(IdentifierOccurrence {
        value: value.to_string(),
        start,
        end,
        range: LspRangeResponse {
            start: LspPositionResponse {
                line,
                utf16_column: start_col,
            },
            end: LspPositionResponse {
                line,
                utf16_column: end_col,
            },
        },
    })
}

fn identifier_at(path: &str, text: &str, cursor: usize) -> Option<IdentifierOccurrence> {
    identifier_occurrences_in_code(path, text)
        .into_iter()
        .find(|occurrence| occurrence.start <= cursor && cursor <= occurrence.end)
        .or_else(|| raw_identifier_at(text, cursor))
}

fn push_identifier(
    text: &str,
    start: usize,
    end: usize,
    range: LspRangeResponse,
    values: &mut Vec<IdentifierOccurrence>,
) {
    let value = &text[start..end];
    if value.chars().next().is_some_and(is_identifier_start)
        && !is_language_keyword(value)
        && value.len() <= 120
    {
        values.push(IdentifierOccurrence {
            value: value.to_string(),
            start,
            end,
            range,
        });
    }
}

fn completion_match_tier(label: &str, prefix: &str, prefix_lower: &str) -> Option<u8> {
    if prefix.is_empty() {
        return Some(0);
    }
    if label.starts_with(prefix) {
        return Some(0);
    }
    let label_lower = label.to_ascii_lowercase();
    if label_lower.starts_with(prefix_lower) {
        return Some(1);
    }
    if is_subsequence(prefix_lower, &label_lower) {
        return Some(2);
    }
    None
}

fn is_subsequence(needle: &str, haystack: &str) -> bool {
    let mut needle_chars = needle.chars();
    let Some(mut expected) = needle_chars.next() else {
        return true;
    };
    for ch in haystack.chars() {
        if ch == expected {
            match needle_chars.next() {
                Some(next) => expected = next,
                None => return true,
            }
        }
    }
    false
}

fn completion_kind_for_symbol(kind: &str, signature: &str) -> i32 {
    if kind == "type" {
        7
    } else if signature.contains('(') {
        3
    } else if signature.starts_with("const ") || signature.starts_with("pub const ") {
        21
    } else {
        6
    }
}

fn find_local_declaration_line(text: &str, name: &str) -> Option<usize> {
    let mut line_start = 0usize;
    for (idx, line) in text.split('\n').enumerate() {
        let trimmed = line.trim();
        if !trimmed.starts_with("//") && !trimmed.starts_with('#') {
            if let Some(pos) = find_word_in_signature(line, name) {
                if looks_like_declaration(text, line_start + pos) {
                    return Some(idx + 1);
                }
            }
        }
        line_start += line.len() + 1;
    }
    None
}

fn markdown_fence_for_path(path: &str) -> &'static str {
    match path
        .rsplit('.')
        .next()
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("go") => "go",
        Some("rs") => "rust",
        Some("py" | "pyi" | "pyw") => "python",
        Some("swift") => "swift",
        Some("ts" | "tsx" | "mts" | "cts") => "typescript",
        Some("js" | "jsx" | "mjs" | "cjs") => "javascript",
        Some("kt" | "kts") => "kotlin",
        Some("java") => "java",
        Some("c" | "h") => "c",
        Some("cc" | "cpp" | "cxx" | "hpp") => "cpp",
        _ => "",
    }
}

fn normalize_file_key(path: &str) -> String {
    Path::new(path)
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from(path))
        .to_string_lossy()
        .to_string()
}

fn relative_display_path(file_path: &str, workspace_root: Option<&str>) -> Option<String> {
    let root = workspace_root?;
    let file_canon = Path::new(file_path)
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from(file_path));
    let root_canon = Path::new(root)
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from(root));
    file_canon
        .strip_prefix(&root_canon)
        .ok()
        .map(|rel| rel.to_string_lossy().replace('\\', "/"))
}

fn identifier_prefix_at(text: &str, cursor: usize) -> String {
    let mut start = cursor.min(text.len());
    while start > 0 {
        let Some((previous_index, previous)) = text[..start].char_indices().next_back() else {
            break;
        };
        if !is_identifier_character(previous) {
            break;
        }
        start = previous_index;
    }
    text[start..cursor.min(text.len())].to_string()
}

fn is_identifier_start(character: char) -> bool {
    character == '_' || character.is_alphabetic()
}

fn is_identifier_character(character: char) -> bool {
    character == '_' || character.is_alphanumeric()
}

fn is_language_keyword(value: &str) -> bool {
    matches!(
        value,
        "as" | "async"
            | "await"
            | "break"
            | "case"
            | "catch"
            | "class"
            | "const"
            | "continue"
            | "def"
            | "default"
            | "defer"
            | "do"
            | "else"
            | "enum"
            | "export"
            | "extends"
            | "false"
            | "final"
            | "fn"
            | "for"
            | "func"
            | "function"
            | "if"
            | "impl"
            | "import"
            | "in"
            | "interface"
            | "let"
            | "match"
            | "mod"
            | "mut"
            | "nil"
            | "null"
            | "package"
            | "private"
            | "protected"
            | "public"
            | "return"
            | "self"
            | "static"
            | "struct"
            | "switch"
            | "this"
            | "throw"
            | "throws"
            | "trait"
            | "true"
            | "try"
            | "type"
            | "var"
            | "while"
    )
}

fn builtin_completion_kind(text: &str, start: usize) -> i32 {
    if looks_like_declaration_with_keywords(
        text,
        start,
        &["class", "struct", "enum", "interface", "trait"],
    ) {
        7
    } else if looks_like_declaration_with_keywords(text, start, &["func", "function", "def", "fn"])
    {
        3
    } else {
        6
    }
}

fn looks_like_declaration(text: &str, start: usize) -> bool {
    if looks_like_declaration_with_keywords(
        text,
        start,
        &[
            "class",
            "struct",
            "enum",
            "interface",
            "trait",
            "func",
            "function",
            "def",
            "fn",
            "let",
            "mut",
            "var",
            "const",
            "static",
            "type",
        ],
    ) {
        return true;
    }
    // Check Go short variable declaration (`name := ...`) or Python assignment (`name = ...`).
    let line_end = text[start..]
        .find('\n')
        .map_or(text.len(), |offset| start + offset);
    let mut ident_end = start;
    for (offset, ch) in text[start..line_end].char_indices() {
        if !is_identifier_character(ch) {
            break;
        }
        ident_end = start + offset + ch.len_utf8();
    }
    let after = text[ident_end..line_end].trim_start();
    if after.starts_with(":=") {
        return true;
    }
    if after.starts_with('=') && !after.starts_with("==") {
        let line_start = text[..start].rfind('\n').map_or(0, |idx| idx + 1);
        if text[line_start..start].trim().is_empty() {
            return true;
        }
    }
    false
}

fn looks_like_declaration_with_keywords(text: &str, start: usize, keywords: &[&str]) -> bool {
    let line_start = text[..start].rfind('\n').map_or(0, |index| index + 1);
    let prefix = &text[line_start..start];
    let tokens: Vec<&str> = prefix
        .split(|character: char| !is_identifier_character(character))
        .filter(|token| !token.is_empty())
        .collect();
    tokens
        .last()
        .is_some_and(|token| keywords.iter().any(|keyword| keyword == token))
}

fn validate_file_path(value: &str) -> Result<(), CoreError> {
    if value.trim().is_empty() {
        Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "LSP builtin request requires a file path.",
        ))
    } else {
        Ok(())
    }
}
