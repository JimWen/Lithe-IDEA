//! Deterministic single-pass multi-language fold region scanner for the native editor.
//!
//! Produces the exact `JavaFoldRegionResponse` wire shape (zero-based lines and
//! UTF-16 hidden spans) so macOS folding controls work identically across Go,
//! Rust, Python, Java, Swift, TypeScript, and C-family buffers without starting
//! an LSP server.

use crate::protocol::JavaFoldRegionResponse;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Request payload for `editor.foldRegions`.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorFoldRegionsRequest {
    /// File path or name whose extension selects the language fold scanner.
    pub path: String,
    /// Complete UTF-8 text of the editor buffer.
    pub source: String,
}

/// Response payload returned by `editor.foldRegions`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorFoldRegionsResponse {
    /// Deterministically sorted non-duplicate fold regions.
    pub fold_regions: Vec<JavaFoldRegionResponse>,
}

/// Precomputed line byte and UTF-16 offset table for O(1) line/offset queries.
struct LineTable<'a> {
    source: &'a str,
    /// One entry `(byte_start, utf16_start)` per line plus one EOF sentinel.
    starts: Vec<(usize, usize)>,
}

impl<'a> LineTable<'a> {
    fn new(source: &'a str) -> Self {
        let mut starts = Vec::with_capacity(source.len() / 32 + 2);
        starts.push((0, 0));
        let mut utf16 = 0usize;
        for (byte_idx, ch) in source.char_indices() {
            utf16 += ch.len_utf16();
            if ch == '\n' {
                starts.push((byte_idx + 1, utf16));
            }
        }
        if starts.last().map(|&(b, _)| b) != Some(source.len()) {
            starts.push((source.len(), utf16));
        }
        Self { source, starts }
    }

    fn line_count(&self) -> usize {
        self.starts.len().saturating_sub(1)
    }

    fn line_str(&self, line: usize) -> &'a str {
        let start = self.starts[line].0;
        let end = self.starts[line + 1].0;
        self.source[start..end].trim_end_matches(['\r', '\n'])
    }

    fn line_start_utf16(&self, line: usize) -> usize {
        self.starts[line].1
    }

    fn line_end_utf16(&self, line: usize) -> usize {
        self.starts[line + 1].1
    }

    fn line_for_byte(&self, byte_offset: usize) -> usize {
        let count = self.line_count();
        if count == 0 {
            return 0;
        }
        match self.starts[..count].binary_search_by_key(&byte_offset, |&(b, _)| b) {
            Ok(index) => index,
            Err(index) => index.saturating_sub(1),
        }
    }

    fn make_brace_region(
        &self,
        kind: &str,
        start_line: usize,
        end_line: usize,
    ) -> Option<JavaFoldRegionResponse> {
        if end_line <= start_line || end_line >= self.line_count() {
            return None;
        }
        let hidden_start = self.line_end_utf16(start_line);
        let hidden_end = self.line_start_utf16(end_line);
        if hidden_end <= hidden_start {
            return None;
        }
        Some(JavaFoldRegionResponse {
            kind: kind.to_string(),
            start_line,
            end_line,
            hidden_start,
            hidden_length: hidden_end - hidden_start,
        })
    }

    fn make_inclusive_region(
        &self,
        kind: &str,
        start_line: usize,
        end_line: usize,
    ) -> Option<JavaFoldRegionResponse> {
        if end_line <= start_line || end_line >= self.line_count() {
            return None;
        }
        let hidden_start = self.line_end_utf16(start_line);
        let hidden_end = self.line_end_utf16(end_line);
        if hidden_end <= hidden_start {
            return None;
        }
        Some(JavaFoldRegionResponse {
            kind: kind.to_string(),
            start_line,
            end_line,
            hidden_start,
            hidden_length: hidden_end - hidden_start,
        })
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum FoldLanguage {
    Go,
    Rust,
    Python,
    GenericBrace,
}

/// Computes deterministic multi-language fold regions for `request`.
pub(crate) fn fold_regions(request: EditorFoldRegionsRequest) -> EditorFoldRegionsResponse {
    if request.source.is_empty() {
        return EditorFoldRegionsResponse {
            fold_regions: Vec::new(),
        };
    }
    let Some(language) = fold_language_for_path(&request.path) else {
        return EditorFoldRegionsResponse {
            fold_regions: Vec::new(),
        };
    };
    let table = LineTable::new(&request.source);
    let regions = match language {
        FoldLanguage::Python => scan_python_folds(&table),
        FoldLanguage::Go => scan_brace_language_folds(&table, FoldLanguage::Go),
        FoldLanguage::Rust => scan_brace_language_folds(&table, FoldLanguage::Rust),
        FoldLanguage::GenericBrace => scan_brace_language_folds(&table, FoldLanguage::GenericBrace),
    };
    EditorFoldRegionsResponse {
        fold_regions: finalize_regions(regions),
    }
}

fn fold_language_for_path(path: &str) -> Option<FoldLanguage> {
    let ext = path.rsplit('.').next()?.to_ascii_lowercase();
    match ext.as_str() {
        "go" => Some(FoldLanguage::Go),
        "rs" => Some(FoldLanguage::Rust),
        "py" | "pyi" | "pyw" => Some(FoldLanguage::Python),
        "java" | "kt" | "kts" | "swift" | "js" | "jsx" | "mjs" | "cjs" | "ts" | "tsx" | "mts"
        | "cts" | "c" | "h" | "cc" | "cpp" | "cxx" | "hpp" | "hh" | "m" | "mm" | "cs" | "php"
        | "css" | "scss" | "less" | "json" | "jsonc" | "zig" | "dart" | "scala" => {
            Some(FoldLanguage::GenericBrace)
        }
        _ => None,
    }
}

fn scan_brace_language_folds(
    table: &LineTable<'_>,
    language: FoldLanguage,
) -> Vec<JavaFoldRegionResponse> {
    let mut regions = Vec::new();
    let nested_block_comments = matches!(language, FoldLanguage::Rust | FoldLanguage::GenericBrace);
    let source = table.source;
    let bytes = source.as_bytes();
    let mut index = 0usize;
    let mut brace_stack: Vec<(usize, String)> = Vec::new();
    let mut import_paren_start: Option<usize> = None;

    while index < bytes.len() {
        let byte = bytes[index];
        let next = bytes.get(index + 1).copied().unwrap_or(0);

        // Single-line comment: skip to newline.
        if byte == b'/' && next == b'/' {
            index += 2;
            while index < bytes.len() && bytes[index] != b'\n' {
                index += 1;
            }
            continue;
        }

        // Block comment (supports Rust nested `/* /* */ */`).
        if byte == b'/' && next == b'*' {
            let start_byte = index;
            let mut depth = 1usize;
            index += 2;
            while index < bytes.len() && depth > 0 {
                let c = bytes[index];
                let n = bytes.get(index + 1).copied().unwrap_or(0);
                if nested_block_comments && c == b'/' && n == b'*' {
                    depth += 1;
                    index += 2;
                } else if c == b'*' && n == b'/' {
                    depth -= 1;
                    index += 2;
                } else {
                    index += 1;
                }
            }
            let start_line = table.line_for_byte(start_byte);
            let end_line = table.line_for_byte(index.saturating_sub(1));
            if let Some(region) = table.make_inclusive_region("comment", start_line, end_line) {
                regions.push(region);
            }
            continue;
        }

        // Rust raw strings: `r"..."`, `r#"..."#`, `br#"..."#`, `cr#"..."#`.
        if language == FoldLanguage::Rust {
            if let Some(end_idx) = try_skip_rust_raw_string(bytes, index) {
                index = end_idx;
                continue;
            }
        }

        // Double-quoted string literal.
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

        // Go raw string literal or JS/TS template literal.
        if byte == b'`' && language != FoldLanguage::Rust {
            index += 1;
            while index < bytes.len() {
                if language == FoldLanguage::GenericBrace && bytes[index] == b'\\' {
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

        // Character literal vs Rust lifetime (`'a`, `'static`).
        if byte == b'\'' {
            if language == FoldLanguage::Rust {
                if let Some(end_idx) = try_skip_rust_char_literal(source, index) {
                    index = end_idx;
                    continue;
                }
                index += 1;
                continue;
            } else {
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
        }

        // Go grouped `import ( ... )` fold region.
        if language == FoldLanguage::Go {
            if byte == b'(' {
                let line = table.line_for_byte(index);
                let prefix = table.line_str(line).trim();
                if prefix.starts_with("import") && import_paren_start.is_none() {
                    import_paren_start = Some(line);
                }
            } else if byte == b')' {
                if let Some(start_line) = import_paren_start.take() {
                    let end_line = table.line_for_byte(index);
                    if let Some(region) = table.make_brace_region("imports", start_line, end_line) {
                        regions.push(region);
                    }
                }
            }
        }

        if byte == b'{' {
            let start_line = table.line_for_byte(index);
            let header = table.line_str(start_line).trim().to_string();
            brace_stack.push((start_line, header));
        } else if byte == b'}' {
            if let Some((start_line, header)) = brace_stack.pop() {
                let end_line = table.line_for_byte(index);
                let kind = classify_brace_header(&header, language);
                if let Some(region) = table.make_brace_region(kind, start_line, end_line) {
                    regions.push(region);
                }
            }
        }

        index += 1;
    }

    // Collect contiguous line-comment blocks (>= 3 lines) and contiguous import/use runs (>= 2 lines).
    collect_line_runs(table, language, &mut regions);

    regions
}

fn try_skip_rust_raw_string(bytes: &[u8], index: usize) -> Option<usize> {
    let mut cursor = index;
    if matches!(bytes[cursor], b'b' | b'c') && bytes.get(cursor + 1) == Some(&b'r') {
        // Ensure `b`/`c` is not the tail of an identifier.
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

fn try_skip_rust_char_literal(source: &str, quote_byte: usize) -> Option<usize> {
    let rest = &source[quote_byte + 1..];
    let mut chars = rest.char_indices();
    let (_, first) = chars.next()?;
    if first == '\n' || first == '\'' {
        return None;
    }
    if first == '\\' {
        // Escaped character literal such as `'\n'`, `'\''`, `'\x7f'`, `'\u{1234}'`.
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
    // Plain single-scalar char literal `'x'`.
    if let Some((offset, '\'')) = chars.next() {
        return Some(quote_byte + 1 + offset + 1);
    }
    None
}

fn classify_brace_header(header: &str, language: FoldLanguage) -> &'static str {
    let trimmed = header.trim();
    match language {
        FoldLanguage::Go => {
            if trimmed.starts_with("func ") || trimmed.starts_with("func(") {
                "method"
            } else if trimmed.starts_with("type ")
                && (trimmed.contains("struct") || trimmed.contains("interface"))
            {
                "type"
            } else {
                "block"
            }
        }
        FoldLanguage::Rust => {
            if contains_word(trimmed, "fn") {
                "method"
            } else if contains_word(trimmed, "struct")
                || contains_word(trimmed, "enum")
                || contains_word(trimmed, "trait")
                || contains_word(trimmed, "union")
                || contains_word(trimmed, "impl")
                || contains_word(trimmed, "mod")
            {
                "type"
            } else {
                "block"
            }
        }
        FoldLanguage::GenericBrace => {
            if contains_word(trimmed, "class")
                || contains_word(trimmed, "interface")
                || contains_word(trimmed, "enum")
                || contains_word(trimmed, "record")
                || contains_word(trimmed, "struct")
                || contains_word(trimmed, "protocol")
                || contains_word(trimmed, "extension")
                || contains_word(trimmed, "actor")
                || contains_word(trimmed, "namespace")
            {
                "type"
            } else if trimmed.contains('(') && trimmed.contains(')') {
                "method"
            } else {
                "block"
            }
        }
        FoldLanguage::Python => "block",
    }
}

fn collect_line_runs(
    table: &LineTable<'_>,
    language: FoldLanguage,
    regions: &mut Vec<JavaFoldRegionResponse>,
) {
    let line_count = table.line_count();
    let mut comment_start: Option<usize> = None;
    let mut import_start: Option<usize> = None;
    let mut import_last: usize = 0;

    for line in 0..line_count {
        let trimmed = table.line_str(line).trim();

        // Contiguous `//` comment blocks (>= 3 lines).
        if trimmed.starts_with("//") {
            if comment_start.is_none() {
                comment_start = Some(line);
            }
        } else if let Some(start) = comment_start.take() {
            if line >= start + 3 {
                if let Some(region) = table.make_inclusive_region("comment", start, line - 1) {
                    regions.push(region);
                }
            }
        }

        // Contiguous single-line imports / `use` / `#include` statements (>= 2 lines).
        let is_import_line = match language {
            FoldLanguage::Go => {
                trimmed.starts_with("import \"")
                    || trimmed.starts_with("import ") && !trimmed.contains('(')
            }
            FoldLanguage::Rust => {
                (trimmed.starts_with("use ") || trimmed.starts_with("pub use "))
                    && trimmed.ends_with(';')
            }
            FoldLanguage::GenericBrace => {
                trimmed.starts_with("import ") || trimmed.starts_with("#include ")
            }
            FoldLanguage::Python => false,
        };
        if is_import_line {
            if import_start.is_none() {
                import_start = Some(line);
            }
            import_last = line;
        } else if !trimmed.is_empty() {
            if let Some(start) = import_start.take() {
                if import_last > start {
                    if let Some(region) = table.make_inclusive_region("imports", start, import_last)
                    {
                        regions.push(region);
                    }
                }
            }
        }
    }

    if let Some(start) = comment_start {
        if line_count >= start + 3 {
            if let Some(region) = table.make_inclusive_region("comment", start, line_count - 1) {
                regions.push(region);
            }
        }
    }
    if let Some(start) = import_start {
        if import_last > start {
            if let Some(region) = table.make_inclusive_region("imports", start, import_last) {
                regions.push(region);
            }
        }
    }
}

fn scan_python_folds(table: &LineTable<'_>) -> Vec<JavaFoldRegionResponse> {
    let mut regions = Vec::new();
    let line_count = table.line_count();
    let mut stack: Vec<(usize, usize, &'static str)> = Vec::new(); // (indent, start_line, kind)
    let mut last_non_blank_line: usize = 0;
    let mut triple_quote: Option<(&'static str, usize)> = None;
    let mut hash_comment_start: Option<usize> = None;
    let mut import_start: Option<usize> = None;
    let mut import_last: usize = 0;

    for line in 0..line_count {
        let raw = table.line_str(line);
        let trimmed = raw.trim();

        // Inside a multi-line triple-quoted string / docstring.
        if let Some((delim, start_line)) = triple_quote {
            if trimmed.contains(delim) {
                if line > start_line {
                    if let Some(region) = table.make_inclusive_region("comment", start_line, line) {
                        regions.push(region);
                    }
                }
                triple_quote = None;
            }
            if !trimmed.is_empty() {
                last_non_blank_line = line;
            }
            continue;
        }

        if trimmed.is_empty() {
            continue;
        }

        let indent = leading_indent_width(raw);

        // Contiguous `#` comment block (>= 3 lines).
        if trimmed.starts_with('#') {
            if hash_comment_start.is_none() {
                hash_comment_start = Some(line);
            }
            continue;
        } else if let Some(start) = hash_comment_start.take() {
            if line >= start + 3 {
                if let Some(region) = table.make_inclusive_region("comment", start, line - 1) {
                    regions.push(region);
                }
            }
        }

        // Contiguous top-level `import` / `from ... import` lines (>= 2 lines).
        if indent == 0 && (trimmed.starts_with("import ") || trimmed.starts_with("from ")) {
            if import_start.is_none() {
                import_start = Some(line);
            }
            import_last = line;
        } else if let Some(start) = import_start.take() {
            if import_last > start {
                if let Some(region) = table.make_inclusive_region("imports", start, import_last) {
                    regions.push(region);
                }
            }
        }

        // Close any open indentation blocks whose indent >= current line's indent.
        while let Some(&(top_indent, start_line, kind)) = stack.last() {
            if indent <= top_indent {
                stack.pop();
                if last_non_blank_line > start_line {
                    if let Some(region) =
                        table.make_inclusive_region(kind, start_line, last_non_blank_line)
                    {
                        regions.push(region);
                    }
                }
            } else {
                break;
            }
        }

        // Detect start of multi-line triple-quoted string/docstring on this line.
        if let Some(delim) = python_unclosed_triple_quote(raw) {
            triple_quote = Some((delim, line));
            last_non_blank_line = line;
            continue;
        }

        // Detect suite header ending with `:` outside trailing comments.
        let code_without_comment = strip_python_inline_comment(trimmed);
        if code_without_comment.ends_with(':') {
            let kind = if trimmed.starts_with("class ") {
                "type"
            } else if trimmed.starts_with("def ") || trimmed.starts_with("async def ") {
                "method"
            } else {
                "block"
            };
            stack.push((indent, line, kind));
        }

        last_non_blank_line = line;
    }

    // Flush open blocks at EOF.
    while let Some((_, start_line, kind)) = stack.pop() {
        if last_non_blank_line > start_line {
            if let Some(region) = table.make_inclusive_region(kind, start_line, last_non_blank_line)
            {
                regions.push(region);
            }
        }
    }
    if let Some(start) = hash_comment_start {
        if line_count >= start + 3 {
            if let Some(region) = table.make_inclusive_region("comment", start, line_count - 1) {
                regions.push(region);
            }
        }
    }
    if let Some(start) = import_start {
        if import_last > start {
            if let Some(region) = table.make_inclusive_region("imports", start, import_last) {
                regions.push(region);
            }
        }
    }

    regions
}

fn leading_indent_width(line: &str) -> usize {
    let mut width = 0usize;
    for byte in line.bytes() {
        match byte {
            b' ' => width += 1,
            b'\t' => width += 4,
            _ => break,
        }
    }
    width
}

fn strip_python_inline_comment(line: &str) -> &str {
    let bytes = line.as_bytes();
    let mut index = 0usize;
    let mut quote: Option<u8> = None;
    while index < bytes.len() {
        let byte = bytes[index];
        if let Some(q) = quote {
            if byte == b'\\' {
                index += 2;
                continue;
            }
            if byte == q {
                quote = None;
            }
        } else if byte == b'"' || byte == b'\'' {
            quote = Some(byte);
        } else if byte == b'#' {
            return line[..index].trim_end();
        }
        index += 1;
    }
    line.trim_end()
}

fn python_unclosed_triple_quote(line: &str) -> Option<&'static str> {
    let bytes = line.as_bytes();
    let mut index = 0usize;
    let mut open: Option<&'static str> = None;
    let mut single_quote: Option<u8> = None;
    while index < bytes.len() {
        if let Some(delim) = open {
            if bytes[index..].starts_with(delim.as_bytes()) {
                open = None;
                index += 3;
            } else {
                index += 1;
            }
            continue;
        }
        let byte = bytes[index];
        if let Some(q) = single_quote {
            if byte == b'\\' && index + 1 < bytes.len() {
                index += 2;
                continue;
            }
            if byte == q {
                single_quote = None;
            }
            index += 1;
            continue;
        }
        if byte == b'#' {
            break;
        }
        if bytes[index..].starts_with(b"\"\"\"") {
            open = Some("\"\"\"");
            index += 3;
            continue;
        }
        if bytes[index..].starts_with(b"'''") {
            open = Some("'''");
            index += 3;
            continue;
        }
        if byte == b'"' || byte == b'\'' {
            single_quote = Some(byte);
        }
        index += 1;
    }
    open
}

fn contains_word(haystack: &str, needle: &str) -> bool {
    haystack
        .split(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .any(|token| token == needle)
}

fn finalize_regions(regions: Vec<JavaFoldRegionResponse>) -> Vec<JavaFoldRegionResponse> {
    let mut by_span = BTreeMap::<(usize, usize), JavaFoldRegionResponse>::new();
    for region in regions {
        let key = (region.start_line, region.end_line);
        let replace = match by_span.get(&key) {
            None => true,
            Some(existing) => kind_priority(&region.kind) > kind_priority(&existing.kind),
        };
        if replace {
            by_span.insert(key, region);
        }
    }
    let mut result: Vec<JavaFoldRegionResponse> = by_span.into_values().collect();
    result.sort_by(|left, right| {
        left.start_line
            .cmp(&right.start_line)
            .then_with(|| right.end_line.cmp(&left.end_line))
    });
    result
}

fn kind_priority(kind: &str) -> u8 {
    match kind {
        "imports" => 5,
        "type" => 4,
        "method" => 3,
        "comment" => 2,
        _ => 1,
    }
}
