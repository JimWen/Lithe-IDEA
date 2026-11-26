//! Deterministic multi-language workspace symbol extraction for Search Everywhere.

use regex::Regex;
use std::sync::OnceLock;

/// Normalized declaration surfaced in Search Everywhere Classes and Symbols.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SourceSymbol {
    pub(crate) name: String,
    /// `"type"` for types/classes/structs/traits/interfaces, `"symbol"` for functions/methods/constants.
    pub(crate) kind: String,
    /// One-based declaration line number.
    pub(crate) line: usize,
    /// Trimmed source line displayed as the symbol preview.
    pub(crate) signature: String,
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

/// Extracts top-level and member declarations in one linear pass over `source`.
pub(crate) fn extract_symbols(path: &str, source: &str) -> Vec<SourceSymbol> {
    let Some(language) = language_for_path(path) else {
        return Vec::new();
    };
    let mut symbols = match language {
        Language::Go => extract_go(source),
        Language::Rust => extract_rust(source),
        Language::Python => extract_python(source),
        Language::JavaScript => extract_javascript(source),
        Language::Swift => extract_swift(source),
        Language::Kotlin => extract_kotlin(source),
        Language::Java => extract_java(source),
    };
    symbols.sort_by(|left, right| {
        left.line
            .cmp(&right.line)
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
        "py" | "pyi" => Some(Language::Python),
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

    /// Returns the code prefix of `line` outside block/line comments.
    fn strip_line<'a>(&mut self, line: &'a str) -> Option<&'a str> {
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
        (!slice.trim().is_empty()).then_some(slice)
    }
}

fn push_symbol(symbols: &mut Vec<SourceSymbol>, name: &str, kind: &str, line: usize, raw: &str) {
    symbols.push(SourceSymbol {
        name: name.to_string(),
        kind: kind.to_string(),
        line,
        signature: raw.trim().to_string(),
    });
}

fn extract_go(source: &str) -> Vec<SourceSymbol> {
    static TYPE_RE: OnceLock<Regex> = OnceLock::new();
    static TYPE_BLOCK_START_RE: OnceLock<Regex> = OnceLock::new();
    static TYPE_BLOCK_ENTRY_RE: OnceLock<Regex> = OnceLock::new();
    static FUNC_RE: OnceLock<Regex> = OnceLock::new();

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

    let mut symbols = Vec::new();
    let mut filter = CStyleCommentFilter::new(false);
    let mut in_type_block = false;

    for (index, raw_line) in source.split('\n').enumerate() {
        let line_no = index + 1;
        let Some(code) = filter.strip_line(raw_line) else {
            continue;
        };
        if in_type_block {
            let trimmed = code.trim();
            if trimmed.starts_with(')') {
                in_type_block = false;
                continue;
            }
            if let Some(captures) = type_block_entry_re.captures(code) {
                if let Some(name) = captures.get(1) {
                    push_symbol(&mut symbols, name.as_str(), "type", line_no, raw_line);
                }
            }
            if trimmed.contains(')') && !trimmed.contains('(') {
                in_type_block = false;
            }
            continue;
        }
        if type_block_start_re.is_match(code) {
            if !code.contains(')') {
                in_type_block = true;
            }
            continue;
        }
        if let Some(captures) = type_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(&mut symbols, name.as_str(), "type", line_no, raw_line);
            }
        } else if let Some(captures) = func_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(&mut symbols, name.as_str(), "symbol", line_no, raw_line);
            }
        }
    }
    symbols
}

fn extract_rust(source: &str) -> Vec<SourceSymbol> {
    static TYPE_RE: OnceLock<Regex> = OnceLock::new();
    static FN_RE: OnceLock<Regex> = OnceLock::new();
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
    let macro_re = MACRO_RE
        .get_or_init(|| Regex::new(r"^[ \t]*macro_rules!\s+([A-Za-z_][A-Za-z0-9_]*)\b").unwrap());

    let mut symbols = Vec::new();
    let mut filter = CStyleCommentFilter::new(true);

    for (index, raw_line) in source.split('\n').enumerate() {
        let line_no = index + 1;
        let Some(code) = filter.strip_line(raw_line) else {
            continue;
        };
        if let Some(captures) = type_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(&mut symbols, name.as_str(), "type", line_no, raw_line);
            }
        } else if let Some(captures) = fn_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(&mut symbols, name.as_str(), "symbol", line_no, raw_line);
            }
        } else if let Some(captures) = macro_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(&mut symbols, name.as_str(), "symbol", line_no, raw_line);
            }
        }
    }
    symbols
}

fn extract_python(source: &str) -> Vec<SourceSymbol> {
    static CLASS_RE: OnceLock<Regex> = OnceLock::new();
    static DEF_RE: OnceLock<Regex> = OnceLock::new();

    let class_re =
        CLASS_RE.get_or_init(|| Regex::new(r"^[ \t]*class\s+([A-Za-z_][A-Za-z0-9_]*)\b").unwrap());
    let def_re = DEF_RE.get_or_init(|| {
        Regex::new(r"^[ \t]*(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(").unwrap()
    });

    let mut symbols = Vec::new();
    let mut triple_quote: Option<&'static str> = None;

    for (index, raw_line) in source.split('\n').enumerate() {
        let line_no = index + 1;
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
                push_symbol(&mut symbols, name.as_str(), "type", line_no, raw_line);
            }
        } else if let Some(captures) = def_re.captures(raw_line) {
            if let Some(name) = captures.get(1) {
                push_symbol(&mut symbols, name.as_str(), "symbol", line_no, raw_line);
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
            if line[index..].starts_with(delimiter) {
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
        if line[index..].starts_with("\"\"\"") {
            *state = Some("\"\"\"");
            index += 3;
            continue;
        }
        if line[index..].starts_with("'''") {
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

fn extract_javascript(source: &str) -> Vec<SourceSymbol> {
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

    for (index, raw_line) in source.split('\n').enumerate() {
        let line_no = index + 1;
        let Some(code) = filter.strip_line(raw_line) else {
            continue;
        };
        if let Some(captures) = type_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(&mut symbols, name.as_str(), "type", line_no, raw_line);
            }
        } else if let Some(captures) = func_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(&mut symbols, name.as_str(), "symbol", line_no, raw_line);
            }
        }
    }
    symbols
}

fn extract_swift(source: &str) -> Vec<SourceSymbol> {
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

    for (index, raw_line) in source.split('\n').enumerate() {
        let line_no = index + 1;
        let Some(code) = filter.strip_line(raw_line) else {
            continue;
        };
        if let Some(captures) = type_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(&mut symbols, name.as_str(), "type", line_no, raw_line);
            }
        } else if let Some(captures) = func_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(&mut symbols, name.as_str(), "symbol", line_no, raw_line);
            }
        }
    }
    symbols
}

fn extract_kotlin(source: &str) -> Vec<SourceSymbol> {
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

    for (index, raw_line) in source.split('\n').enumerate() {
        let line_no = index + 1;
        let Some(code) = filter.strip_line(raw_line) else {
            continue;
        };
        if let Some(captures) = type_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(&mut symbols, name.as_str(), "type", line_no, raw_line);
            }
        } else if let Some(captures) = fun_re.captures(code) {
            if let Some(name) = captures.get(1) {
                push_symbol(&mut symbols, name.as_str(), "symbol", line_no, raw_line);
            }
        }
    }
    symbols
}

fn extract_java(source: &str) -> Vec<SourceSymbol> {
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

    for (index, raw_line) in source.split('\n').enumerate() {
        let line_no = index + 1;
        let Some(code) = filter.strip_line(raw_line) else {
            continue;
        };
        if let Some(captures) = type_re.captures(code) {
            if let Some(name) = captures.get(2) {
                push_symbol(&mut symbols, name.as_str(), "type", line_no, raw_line);
            }
        } else if let Some(captures) = method_re.captures(code) {
            if let Some(name) = captures.get(1) {
                let candidate = name.as_str();
                if !matches!(
                    candidate,
                    "if" | "for" | "while" | "switch" | "catch" | "return"
                ) {
                    push_symbol(&mut symbols, candidate, "symbol", line_no, raw_line);
                }
            }
        }
    }
    symbols
}
