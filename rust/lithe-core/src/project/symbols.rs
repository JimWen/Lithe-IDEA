//! Deterministic multi-language workspace symbol extraction for Search Everywhere,
//! offline document outlines, and zero-LSP lightweight intelligence.

use crate::protocol::CoreError;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

/// Request payload for extracting deterministic outline symbols from one source buffer.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentSymbolsRequest {
    /// File name or relative path used to select the language extractor.
    pub path: String,
    /// Complete UTF-8 text of the document buffer.
    pub source: String,
}

/// One deterministic outline symbol returned when an LSP outline is unavailable.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DocumentSymbolItem {
    /// Declared identifier name.
    pub name: String,
    /// Normalized category (`"type"` or `"symbol"`).
    pub kind: String,
    /// One-based source line number.
    pub line: usize,
    /// Trimmed declaration line for concise preview display.
    pub signature: String,
}

/// Response payload returned by `workspace.documentSymbols`.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DocumentSymbolsResponse {
    /// Declarations discovered in declaration order.
    pub symbols: Vec<DocumentSymbolItem>,
}

/// Extracts offline outline symbols for one source buffer.
pub(crate) fn document_symbols(
    request: DocumentSymbolsRequest,
) -> Result<DocumentSymbolsResponse, CoreError> {
    let symbols = extract_symbols(&request.path, &request.source)
        .into_iter()
        .map(|symbol| DocumentSymbolItem {
            name: symbol.name,
            kind: symbol.kind,
            line: symbol.line,
            signature: symbol.signature,
        })
        .collect();
    Ok(DocumentSymbolsResponse { symbols })
}

/// Normalized declaration surfaced in Search Everywhere and lightweight navigation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SourceSymbol {
    pub(crate) name: String,
    /// `"type"` for types/classes/structs/traits/interfaces, `"symbol"` for functions/methods/constants.
    pub(crate) kind: String,
    /// One-based declaration line number.
    pub(crate) line: usize,
    /// Zero-based UTF-16 column where `name` starts on `line`.
    pub(crate) utf16_column: usize,
    /// Trimmed source line displayed as the symbol preview.
    pub(crate) signature: String,
    /// Optional cleaned documentation comment or docstring attached to the declaration.
    pub(crate) doc_comment: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Language {
    Go,
    Rust,
    Python,
    JavaScript,
    Swift,
    Kotlin,
    Java,
}

/// Returns a canonical language family key for cross-file lightweight symbol matching.
pub(crate) fn language_group_for_path(path: &str) -> Option<&'static str> {
    let extension = path.rsplit('.').next()?.to_ascii_lowercase();
    match extension.as_str() {
        "go" => Some("go"),
        "rs" => Some("rust"),
        "py" | "pyi" | "pyw" => Some("python"),
        "ts" | "tsx" | "mts" | "cts" | "js" | "jsx" | "mjs" | "cjs" => Some("javascript"),
        "swift" => Some("swift"),
        "kt" | "kts" => Some("kotlin"),
        "java" => Some("java"),
        "c" | "h" | "cc" | "cpp" | "cxx" | "hpp" | "hh" | "m" | "mm" => Some("c_family"),
        _ => None,
    }
}

/// Extracts top-level and member declarations in one linear pass over `source`.
pub(crate) fn extract_symbols(path: &str, source: &str) -> Vec<SourceSymbol> {
    let Some(language) = language_for_path(path) else {
        return Vec::new();
    };
    let lines: Vec<&str> = source.split('\n').collect();
    let mut symbols = match language {
        Language::Go => extract_go(&lines),
        Language::Rust => extract_rust(&lines),
        Language::Python => extract_python(&lines),
        Language::JavaScript => extract_javascript(&lines),
        Language::Swift => extract_swift(&lines),
        Language::Kotlin => extract_kotlin(&lines),
        Language::Java => extract_java(&lines),
    };
    symbols.sort_by(|left, right| {
        left.line
            .cmp(&right.line)
            .then_with(|| left.utf16_column.cmp(&right.utf16_column))
            .then_with(|| left.name.cmp(&right.name))
            .then_with(|| left.kind.cmp(&right.kind))
    });
    symbols.dedup_by(|left, right| {
        left.line == right.line && left.name == right.name && left.kind == right.kind
    });
    symbols
}

fn language_for_path(path: &str) -> Option<Language> {
    let extension = path.rsplit('.').next()?.to_ascii_lowercase();
    match extension.as_str() {
        "go" => Some(Language::Go),
        "rs" => Some(Language::Rust),
        "py" | "pyi" | "pyw" => Some(Language::Python),
        "ts" | "tsx" | "mts" | "cts" | "js" | "jsx" | "mjs" | "cjs" => Some(Language::JavaScript),
        "swift" => Some(Language::Swift),
        "kt" | "kts" => Some(Language::Kotlin),
        "java" => Some(Language::Java),
        _ => None,
    }
}

/// Tracks C-style `/* ... */` block comments across lines while stripping
/// single-line comments so commented-out declarations are ignored.
struct CStyleCommentFilter {
    block_depth: usize,
    nested_blocks: bool,
}

impl CStyleCommentFilter {
    fn new(nested_blocks: bool) -> Self {
        Self {
            block_depth: 0,
            nested_blocks,
        }
    }

    /// Returns `(byte_offset_in_line, code_slice)` outside block/line comments.
    fn strip_line<'a>(&mut self, line: &'a str) -> Option<(usize, &'a str)> {
        let bytes = line.as_bytes();
        let mut index = 0;
        let mut code_start: Option<usize> = None;
        let mut code_end: usize = 0;
        let mut in_string: Option<u8> = None;

        while index < bytes.len() {
            if self.block_depth > 0 {
                if self.nested_blocks
                    && index + 1 < bytes.len()
                    && bytes[index] == b'/'
                    && bytes[index + 1] == b'*'
                {
                    self.block_depth += 1;
                    index += 2;
                    continue;
                }
                if index + 1 < bytes.len() && bytes[index] == b'*' && bytes[index + 1] == b'/' {
                    self.block_depth -= 1;
                    index += 2;
                    continue;
                }
                index += 1;
                continue;
            }

            let byte = bytes[index];
            if let Some(quote) = in_string {
                if byte == b'\\' && quote != b'`' && index + 1 < bytes.len() {
                    index += 2;
                    code_end = index;
                    continue;
                }
                if byte == quote {
                    in_string = None;
                }
                index += 1;
                code_end = index;
                continue;
            }

            if index + 1 < bytes.len() && byte == b'/' && bytes[index + 1] == b'/' {
                break;
            }
            if index + 1 < bytes.len() && byte == b'/' && bytes[index + 1] == b'*' {
                self.block_depth = 1;
                index += 2;
                continue;
            }
            if byte == b'"' || byte == b'`' {
                if code_start.is_none() {
                    code_start = Some(index);
                }
                in_string = Some(byte);
                index += 1;
                code_end = index;
                continue;
            }
            if code_start.is_none() {
                if !byte.is_ascii_whitespace() {
                    code_start = Some(0);
                    code_end = index + 1;
                }
            } else {
                code_end = index + 1;
            }
            index += 1;
        }

        let start = code_start?;
        let slice = &line[start..code_end];
        (!slice.trim().is_empty()).then_some((start, slice))
    }
}

fn push_symbol(
    symbols: &mut Vec<SourceSymbol>,
    name: &str,
    kind: &str,
    line_index: usize,
    name_byte_offset: usize,
    lines: &[&str],
    doc_comment: Option<String>,
) {
    let raw = lines[line_index];
    let clamped = name_byte_offset.min(raw.len());
    let utf16_column = raw[..clamped].encode_utf16().count();
    symbols.push(SourceSymbol {
        name: name.to_string(),
        kind: kind.to_string(),
        line: line_index + 1,
        utf16_column,
        signature: raw.trim().to_string(),
        doc_comment,
    });
}

fn extract_c_style_doc(lines: &[&str], line_index: usize) -> Option<String> {
    const MAX_DOC_LINES: usize = 12;
    let mut cursor = line_index;
    while cursor > 0 {
        let candidate = lines[cursor - 1].trim();
        if candidate.starts_with("#[") || candidate.starts_with('@') {
            cursor -= 1;
            continue;
        }
        break;
    }
    if cursor == 0 {
        return None;
    }
    let last_comment_line = lines[cursor - 1].trim();
    if last_comment_line.starts_with("//") {
        let mut collected = Vec::new();
        let mut idx = cursor;
        while idx > 0 && collected.len() < MAX_DOC_LINES {
            let trimmed = lines[idx - 1].trim();
            if let Some(rest) = trimmed
                .strip_prefix("///")
                .or_else(|| trimmed.strip_prefix("//!"))
                .or_else(|| trimmed.strip_prefix("//"))
            {
                collected.push(rest.trim_start().to_string());
                idx -= 1;
            } else {
                break;
            }
        }
        collected.reverse();
        return normalize_doc_lines(collected);
    }
    if last_comment_line.ends_with("*/") {
        let mut collected = Vec::new();
        let mut idx = cursor;
        while idx > 0 && collected.len() < MAX_DOC_LINES {
            let trimmed = lines[idx - 1].trim();
            let mut body = trimmed;
            let starts_block = body.starts_with("/**") || body.starts_with("/*");
            if let Some(stripped) = body.strip_prefix("/**") {
                body = stripped;
            } else if let Some(stripped) = body.strip_prefix("/*") {
                body = stripped;
            }
            if let Some(stripped) = body.strip_suffix("*/") {
                body = stripped;
            }
            body = body.trim();
            if let Some(stripped) = body.strip_prefix('*') {
                body = stripped.trim_start();
            }
            collected.push(body.to_string());
            idx -= 1;
            if starts_block {
                collected.reverse();
                return normalize_doc_lines(collected);
            }
        }
    }
    None
}

fn extract_python_doc(lines: &[&str], line_index: usize) -> Option<String> {
    const MAX_DOC_LINES: usize = 10;
    // Find the end of a potentially multi-line def/class header (`:`) within 6 lines.
    let mut header_end = line_index;
    let search_limit = (line_index + 6).min(lines.len());
    while header_end < search_limit {
        let trimmed = lines[header_end].trim();
        let code_part = trimmed.split('#').next().unwrap_or("").trim_end();
        if code_part.ends_with(':') {
            break;
        }
        header_end += 1;
    }
    let body_start = header_end + 1;
    if body_start < lines.len() {
        let first_body = lines[body_start].trim();
        let delimiter = if first_body.starts_with("\"\"\"")
            || first_body.starts_with("r\"\"\"")
            || first_body.starts_with("f\"\"\"")
        {
            Some("\"\"\"")
        } else if first_body.starts_with("'''")
            || first_body.starts_with("r'''")
            || first_body.starts_with("f'''")
        {
            Some("'''")
        } else {
            None
        };
        if let Some(delim) = delimiter {
            let start_pos = first_body.find(delim).unwrap_or(0) + 3;
            let rest = &first_body[start_pos..];
            if let Some(end_pos) = rest.find(delim) {
                return normalize_doc_lines(vec![rest[..end_pos].trim().to_string()]);
            }
            let mut collected = Vec::new();
            if !rest.trim().is_empty() {
                collected.push(rest.trim().to_string());
            }
            let mut idx = body_start + 1;
            while idx < lines.len() && collected.len() < MAX_DOC_LINES {
                let line = lines[idx].trim();
                if let Some(end_pos) = line.find(delim) {
                    let prefix = line[..end_pos].trim();
                    if !prefix.is_empty() {
                        collected.push(prefix.to_string());
                    }
                    break;
                }
                collected.push(line.to_string());
                idx += 1;
            }
            if let Some(doc) = normalize_doc_lines(collected) {
                return Some(doc);
            }
        }
    }

    // Fall back to preceding `#` comments above optional `@decorator` lines.
    let mut cursor = line_index;
    while cursor > 0 && lines[cursor - 1].trim().starts_with('@') {
        cursor -= 1;
    }
    let mut collected = Vec::new();
    while cursor > 0 && collected.len() < MAX_DOC_LINES {
        let trimmed = lines[cursor - 1].trim();
        if let Some(rest) = trimmed.strip_prefix('#') {
            collected.push(rest.trim_start().to_string());
            cursor -= 1;
        } else {
            break;
        }
    }
    collected.reverse();
    normalize_doc_lines(collected)
}

fn normalize_doc_lines(mut lines: Vec<String>) -> Option<String> {
    while lines.first().is_some_and(|line| line.trim().is_empty()) {
        lines.remove(0);
    }
    while lines.last().is_some_and(|line| line.trim().is_empty()) {
        lines.pop();
    }
    if lines.is_empty() {
        return None;
    }
    let joined = lines.join("\n");
    (!joined.trim().is_empty()).then_some(joined)
}

fn extract_go(lines: &[&str]) -> Vec<SourceSymbol> {
    static TYPE_RE: OnceLock<Regex> = OnceLock::new();
    static TYPE_BLOCK_START_RE: OnceLock<Regex> = OnceLock::new();
    static TYPE_BLOCK_ENTRY_RE: OnceLock<Regex> = OnceLock::new();
    static FUNC_RE: OnceLock<Regex> = OnceLock::new();
    static VALUE_RE: OnceLock<Regex> = OnceLock::new();
    static VALUE_BLOCK_START_RE: OnceLock<Regex> = OnceLock::new();
    static VALUE_BLOCK_ENTRY_RE: OnceLock<Regex> = OnceLock::new();
    static INTERFACE_START_RE: OnceLock<Regex> = OnceLock::new();
    static INTERFACE_METHOD_RE: OnceLock<Regex> = OnceLock::new();

    let type_re =
        TYPE_RE.get_or_init(|| Regex::new(r"^[ \t]*type\s+([A-Za-z_][A-Za-z0-9_]*)\b").unwrap());
    let type_block_start_re =
        TYPE_BLOCK_START_RE.get_or_init(|| Regex::new(r"^[ \t]*type\s*\(").unwrap());
    let type_block_entry_re = TYPE_BLOCK_ENTRY_RE.get_or_init(|| {
        Regex::new(r"^[ \t]+([A-Za-z_][A-Za-z0-9_]*)\s+(?:=|[A-Za-z_\[\(*])").unwrap()
    });
    let func_re = FUNC_RE.get_or_init(|| {
        Regex::new(
            r"^[ \t]*func\s+(?:\([^)\n]*\)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[[^\]]*\]\s*)?\(",
        )
        .unwrap()
    });
    let value_re = VALUE_RE
        .get_or_init(|| Regex::new(r"^(?:const|var)\s+([A-Za-z_][A-Za-z0-9_]*)\b").unwrap());
    let value_block_start_re =
        VALUE_BLOCK_START_RE.get_or_init(|| Regex::new(r"^(?:const|var)\s*\(").unwrap());
    let value_block_entry_re = VALUE_BLOCK_ENTRY_RE
        .get_or_init(|| Regex::new(r"^[ \t]+([A-Za-z_][A-Za-z0-9_]*)(?:\s*[,= \t]|$)").unwrap());
    let interface_start_re = INTERFACE_START_RE.get_or_init(|| {
        Regex::new(r"^[ \t]*type\s+[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\s+interface\s*\{").unwrap()
    });
    let interface_method_re = INTERFACE_METHOD_RE
        .get_or_init(|| Regex::new(r"^[ \t]+([A-Za-z_][A-Za-z0-9_]*)\s*\(").unwrap());

    let mut symbols = Vec::new();
    let mut filter = CStyleCommentFilter::new(false);
    let mut in_type_block = false;
    let mut in_value_block = false;
    let mut interface_brace_depth: usize = 0;

    for (index, raw_line) in lines.iter().enumerate() {
        let Some((code_offset, code)) = filter.strip_line(raw_line) else {
            continue;
        };
        if interface_brace_depth > 0 {
            if interface_brace_depth == 1 {
                if let Some(captures) = interface_method_re.captures(code) {
                    if let Some(name) = captures.get(1) {
                        push_symbol(
                            &mut symbols,
                            name.as_str(),
                            "symbol",
                            index,
                            code_offset + name.start(),
                            lines,
                            extract_c_style_doc(lines, index),
                        );
                    }
                }
            }
            for byte in code.bytes() {
                if byte == b'{' {
                    interface_brace_depth += 1;
                } else if byte == b'}' {
                    interface_brace_depth = interface_brace_depth.saturating_sub(1);
                }
            }
            continue;
        }
        if in_type_block {
            let trimmed = code.trim();
            if trimmed.starts_with(')') {
                in_type_block = false;
                continue;
            }
            if let Some(captures) = type_block_entry_re.captures(code) {
                if let Some(name) = captures.get(1) {
                    if name.as_str() != "_" {
                        push_symbol(
                            &mut symbols,
                            name.as_str(),
                            "type",
                            index,
                            code_offset + name.start(),
                            lines,
                            extract_c_style_doc(lines, index),
                        );
                    }
                }
            }
            if trimmed.contains(')') && !trimmed.contains('(') {
                in_type_block = false;
            }
            continue;
        }
        if in_value_block {
            let trimmed = code.trim();
            if trimmed.starts_with(')') {
                in_value_block = false;
                continue;
            }
            if let Some(captures) = value_block_entry_re.captures(code) {
                if let Some(name) = captures.get(1) {
                    if name.as_str() != "_" {
                        push_symbol(
                            &mut symbols,
                            name.as_str(),
                            "symbol",
                            index,
                            code_offset + name.start(),
                            lines,
                            extract_c_style_doc(lines, index),
                        );
                    }
                }
            }
            if trimmed.contains(')') && !trimmed.contains('(') {
                in_value_block = false;
            }
            continue;
        }
        if type_block_start_re.is_match(code) {
            if !code.contains(')') {
                in_type_block = true;
            }
            continue;
        }
        if value_block_start_re.is_match(code) {
            if !code.contains(')') {
                in_value_block = true;
            }
            continue;
        }
        if let Some(captures) = type_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(
                    &mut symbols,
                    name.as_str(),
                    "type",
                    index,
                    code_offset + name.start(),
                    lines,
                    extract_c_style_doc(lines, index),
                );
            }
            if interface_start_re.is_match(code) && !code.contains('}') {
                interface_brace_depth = 1;
            }
        } else if let Some(captures) = func_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(
                    &mut symbols,
                    name.as_str(),
                    "symbol",
                    index,
                    code_offset + name.start(),
                    lines,
                    extract_c_style_doc(lines, index),
                );
            }
        } else if let Some(captures) = value_re.captures(code) {
            if let Some(name) = captures.get(1) {
                if name.as_str() != "_" {
                    push_symbol(
                        &mut symbols,
                        name.as_str(),
                        "symbol",
                        index,
                        code_offset + name.start(),
                        lines,
                        extract_c_style_doc(lines, index),
                    );
                }
            }
        }
    }
    symbols
}

fn extract_rust(lines: &[&str]) -> Vec<SourceSymbol> {
    static TYPE_RE: OnceLock<Regex> = OnceLock::new();
    static FN_RE: OnceLock<Regex> = OnceLock::new();
    static VALUE_RE: OnceLock<Regex> = OnceLock::new();
    static MACRO_RE: OnceLock<Regex> = OnceLock::new();

    let type_re = TYPE_RE.get_or_init(|| {
        Regex::new(
            r"^[ \t]*(?:pub(?:\([^)\n]*\))?\s+)?(?:unsafe\s+)?(?:struct|enum|trait|union|type)\s+([A-Za-z_][A-Za-z0-9_]*)\b",
        )
        .unwrap()
    });
    let fn_re = FN_RE.get_or_init(|| {
        Regex::new(
            r"^[ \t]*(?:pub(?:\([^)\n]*\))?\s+)?(?:default\s+)?(?:const\s+)?(?:async\s+)?(?:unsafe\s+)?(?:extern(?:\s+\x22[^\x22]*\x22)?\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\b",
        )
        .unwrap()
    });
    let value_re = VALUE_RE.get_or_init(|| {
        Regex::new(
            r"^[ \t]*(?:pub(?:\([^)\n]*\))?\s+)?(?:const|static(?:\s+mut)?|mod)\s+([A-Za-z_][A-Za-z0-9_]*)\b",
        )
        .unwrap()
    });
    let macro_re = MACRO_RE
        .get_or_init(|| Regex::new(r"^[ \t]*macro_rules!\s+([A-Za-z_][A-Za-z0-9_]*)\b").unwrap());

    let mut symbols = Vec::new();
    let mut filter = CStyleCommentFilter::new(true);

    for (index, raw_line) in lines.iter().enumerate() {
        let Some((code_offset, code)) = filter.strip_line(raw_line) else {
            continue;
        };
        if let Some(captures) = type_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(
                    &mut symbols,
                    name.as_str(),
                    "type",
                    index,
                    code_offset + name.start(),
                    lines,
                    extract_c_style_doc(lines, index),
                );
            }
        } else if let Some(captures) = fn_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(
                    &mut symbols,
                    name.as_str(),
                    "symbol",
                    index,
                    code_offset + name.start(),
                    lines,
                    extract_c_style_doc(lines, index),
                );
            }
        } else if let Some(captures) = value_re.captures(code) {
            if let Some(name) = captures.get(1) {
                if name.as_str() != "_" {
                    push_symbol(
                        &mut symbols,
                        name.as_str(),
                        "symbol",
                        index,
                        code_offset + name.start(),
                        lines,
                        extract_c_style_doc(lines, index),
                    );
                }
            }
        } else if let Some(captures) = macro_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(
                    &mut symbols,
                    name.as_str(),
                    "symbol",
                    index,
                    code_offset + name.start(),
                    lines,
                    extract_c_style_doc(lines, index),
                );
            }
        }
    }
    symbols
}

fn extract_python(lines: &[&str]) -> Vec<SourceSymbol> {
    static CLASS_RE: OnceLock<Regex> = OnceLock::new();
    static DEF_RE: OnceLock<Regex> = OnceLock::new();
    static TOP_CONST_RE: OnceLock<Regex> = OnceLock::new();

    let class_re =
        CLASS_RE.get_or_init(|| Regex::new(r"^[ \t]*class\s+([A-Za-z_][A-Za-z0-9_]*)\b").unwrap());
    let def_re = DEF_RE.get_or_init(|| {
        Regex::new(r"^[ \t]*(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(").unwrap()
    });
    let top_const_re = TOP_CONST_RE
        .get_or_init(|| Regex::new(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=\n]+)?=\s*\S").unwrap());

    let mut symbols = Vec::new();
    let mut triple_quote: Option<&'static str> = None;

    for (index, raw_line) in lines.iter().enumerate() {
        if let Some(delimiter) = triple_quote {
            if let Some(end) = raw_line.find(delimiter) {
                triple_quote = None;
                update_python_triple_quote_state(&raw_line[end + 3..], &mut triple_quote);
            }
            continue;
        }

        let trimmed = raw_line.trim_start();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if let Some(captures) = class_re.captures(raw_line) {
            if let Some(name) = captures.get(1) {
                push_symbol(
                    &mut symbols,
                    name.as_str(),
                    "type",
                    index,
                    name.start(),
                    lines,
                    extract_python_doc(lines, index),
                );
            }
        } else if let Some(captures) = def_re.captures(raw_line) {
            if let Some(name) = captures.get(1) {
                push_symbol(
                    &mut symbols,
                    name.as_str(),
                    "symbol",
                    index,
                    name.start(),
                    lines,
                    extract_python_doc(lines, index),
                );
            }
        } else if let Some(captures) = top_const_re.captures(raw_line) {
            if let Some(name) = captures.get(1) {
                let candidate = name.as_str();
                if candidate != "_"
                    && !matches!(
                        candidate,
                        "if" | "elif"
                            | "else"
                            | "for"
                            | "while"
                            | "return"
                            | "import"
                            | "from"
                            | "assert"
                            | "del"
                            | "raise"
                            | "yield"
                    )
                {
                    push_symbol(
                        &mut symbols,
                        candidate,
                        "symbol",
                        index,
                        name.start(),
                        lines,
                        extract_python_doc(lines, index),
                    );
                }
            }
        }
        update_python_triple_quote_state(raw_line, &mut triple_quote);
    }
    symbols
}

fn update_python_triple_quote_state(line: &str, state: &mut Option<&'static str>) {
    let bytes = line.as_bytes();
    let mut index = 0;
    let mut single_quote: Option<u8> = None;
    while index < bytes.len() {
        if let Some(delimiter) = *state {
            if bytes[index..].starts_with(delimiter.as_bytes()) {
                *state = None;
                index += 3;
            } else {
                index += 1;
            }
            continue;
        }
        let byte = bytes[index];
        if let Some(quote) = single_quote {
            if byte == b'\\' && index + 1 < bytes.len() {
                index += 2;
                continue;
            }
            if byte == quote {
                single_quote = None;
            }
            index += 1;
            continue;
        }
        if byte == b'#' {
            break;
        }
        if bytes[index..].starts_with(b"\"\"\"") {
            *state = Some("\"\"\"");
            index += 3;
            continue;
        }
        if bytes[index..].starts_with(b"'''") {
            *state = Some("'''");
            index += 3;
            continue;
        }
        if byte == b'"' || byte == b'\'' {
            single_quote = Some(byte);
        }
        index += 1;
    }
}

fn extract_javascript(lines: &[&str]) -> Vec<SourceSymbol> {
    static TYPE_RE: OnceLock<Regex> = OnceLock::new();
    static FUNC_RE: OnceLock<Regex> = OnceLock::new();

    let type_re = TYPE_RE.get_or_init(|| {
        Regex::new(
            r"^[ \t]*(?:export\s+)?(?:default\s+)?(?:declare\s+)?(?:abstract\s+)?(?:const\s+)?(?:class|interface|type|enum)\s+([A-Za-z_$][A-Za-z0-9_$]*)\b",
        )
        .unwrap()
    });
    let func_re = FUNC_RE.get_or_init(|| {
        Regex::new(
            r"^[ \t]*(?:export\s+)?(?:default\s+)?(?:declare\s+)?(?:async\s+)?function\*?\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*(?:<[^>\n]*>\s*)?\(",
        )
        .unwrap()
    });

    let mut symbols = Vec::new();
    let mut filter = CStyleCommentFilter::new(false);

    for (index, raw_line) in lines.iter().enumerate() {
        let Some((code_offset, code)) = filter.strip_line(raw_line) else {
            continue;
        };
        if let Some(captures) = type_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(
                    &mut symbols,
                    name.as_str(),
                    "type",
                    index,
                    code_offset + name.start(),
                    lines,
                    extract_c_style_doc(lines, index),
                );
            }
        } else if let Some(captures) = func_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(
                    &mut symbols,
                    name.as_str(),
                    "symbol",
                    index,
                    code_offset + name.start(),
                    lines,
                    extract_c_style_doc(lines, index),
                );
            }
        }
    }
    symbols
}

fn extract_swift(lines: &[&str]) -> Vec<SourceSymbol> {
    static TYPE_RE: OnceLock<Regex> = OnceLock::new();
    static FUNC_RE: OnceLock<Regex> = OnceLock::new();

    let type_re = TYPE_RE.get_or_init(|| {
        Regex::new(
            r"^[ \t]*(?:(?:open|public|package|internal|fileprivate|private|final|indirect|nonisolated)\s+)*(?:class|struct|enum|protocol|actor|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)\b",
        )
        .unwrap()
    });
    let func_re = FUNC_RE.get_or_init(|| {
        Regex::new(
            r"^[ \t]*(?:(?:open|public|package|internal|fileprivate|private|final|static|class|override|mutating|nonmutating|nonisolated|convenience|required)\s+)*func\s+([A-Za-z_][A-Za-z0-9_]*)\b",
        )
        .unwrap()
    });

    let mut symbols = Vec::new();
    let mut filter = CStyleCommentFilter::new(true);

    for (index, raw_line) in lines.iter().enumerate() {
        let Some((code_offset, code)) = filter.strip_line(raw_line) else {
            continue;
        };
        if let Some(captures) = type_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(
                    &mut symbols,
                    name.as_str(),
                    "type",
                    index,
                    code_offset + name.start(),
                    lines,
                    extract_c_style_doc(lines, index),
                );
            }
        } else if let Some(captures) = func_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(
                    &mut symbols,
                    name.as_str(),
                    "symbol",
                    index,
                    code_offset + name.start(),
                    lines,
                    extract_c_style_doc(lines, index),
                );
            }
        }
    }
    symbols
}

fn extract_kotlin(lines: &[&str]) -> Vec<SourceSymbol> {
    static TYPE_RE: OnceLock<Regex> = OnceLock::new();
    static FUN_RE: OnceLock<Regex> = OnceLock::new();

    let type_re = TYPE_RE.get_or_init(|| {
        Regex::new(
            r"^[ \t]*(?:(?:public|protected|private|internal|abstract|final|open|sealed|data|value|inline|enum|inner|annotation|expect|actual|fun)\s+)*(?:class|interface|object|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)\b",
        )
        .unwrap()
    });
    let fun_re = FUN_RE.get_or_init(|| {
        Regex::new(
            r"^[ \t]*(?:(?:public|protected|private|internal|abstract|final|open|override|suspend|inline|infix|operator|tailrec|external|expect|actual)\s+)*fun\s+(?:<[^>\n]+>\s+)?(?:[A-Za-z_][A-Za-z0-9_<>,.?\[\]]*\.)?([A-Za-z_][A-Za-z0-9_]*)\s*\(",
        )
        .unwrap()
    });

    let mut symbols = Vec::new();
    let mut filter = CStyleCommentFilter::new(true);

    for (index, raw_line) in lines.iter().enumerate() {
        let Some((code_offset, code)) = filter.strip_line(raw_line) else {
            continue;
        };
        if let Some(captures) = type_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(
                    &mut symbols,
                    name.as_str(),
                    "type",
                    index,
                    code_offset + name.start(),
                    lines,
                    extract_c_style_doc(lines, index),
                );
            }
        } else if let Some(captures) = fun_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(
                    &mut symbols,
                    name.as_str(),
                    "symbol",
                    index,
                    code_offset + name.start(),
                    lines,
                    extract_c_style_doc(lines, index),
                );
            }
        }
    }
    symbols
}

fn extract_java(lines: &[&str]) -> Vec<SourceSymbol> {
    static TYPE_RE: OnceLock<Regex> = OnceLock::new();
    static METHOD_RE: OnceLock<Regex> = OnceLock::new();

    let type_re = TYPE_RE.get_or_init(|| {
        Regex::new(
            r"^[ \t]*(?:(?:public|protected|private|abstract|final|static|sealed|non-sealed)\s+)*(class|interface|enum|record)\s+([A-Za-z_$][A-Za-z0-9_$]*)",
        )
        .unwrap()
    });
    let method_re = METHOD_RE.get_or_init(|| {
        Regex::new(
            r"^[ \t]*(?:(?:public|protected|private|static|final|abstract|synchronized|native|default|strictfp)\s+)*(?:<[^>\n]+>\s+)?(?:[A-Za-z_$][A-Za-z0-9_$<>,.?\[\]]*\s+)+([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^;\n{}]*\)",
        )
        .unwrap()
    });

    let mut symbols = Vec::new();
    let mut filter = CStyleCommentFilter::new(false);

    for (index, raw_line) in lines.iter().enumerate() {
        let Some((code_offset, code)) = filter.strip_line(raw_line) else {
            continue;
        };
        if let Some(captures) = type_re.captures(code) {
            if let Some(name) = captures.get(2) {
                push_symbol(
                    &mut symbols,
                    name.as_str(),
                    "type",
                    index,
                    code_offset + name.start(),
                    lines,
                    extract_c_style_doc(lines, index),
                );
            }
        } else if let Some(captures) = method_re.captures(code) {
            if let Some(name) = captures.get(1) {
                let candidate = name.as_str();
                if !matches!(
                    candidate,
                    "if" | "for" | "while" | "switch" | "catch" | "return"
                ) {
                    push_symbol(
                        &mut symbols,
                        candidate,
                        "symbol",
                        index,
                        code_offset + name.start(),
                        lines,
                        extract_c_style_doc(lines, index),
                    );
                }
            }
        }
    }
    symbols
}
