//! Go application discovery from module roots and conventional command layouts.

use super::super::types::Confidence;
use super::{Detected, DirectoryContext};

/// A Go directory is runnable when a `package main` sits next to its
/// `go.mod`, under the conventional `cmd/<name>` layout, or in any other
/// directory whose Go files declare the main package. There is no declaration
/// listing entry points, so all three are heuristics.
pub fn detect(ctx: &DirectoryContext) -> Vec<Detected> {
    let Some(entry) = main_entry_file(ctx) else {
        return Vec::new();
    };
    // The three rules describe the same directory-level `go run .` target with
    // increasing specificity, so their union yields one entry per directory.
    // The command stays directory-level on purpose: `go run <file>` fails for
    // main packages split across several files.
    if ctx.has("go.mod") {
        return vec![runnable(ctx, "go.main", "go.mod")];
    }
    if is_command_directory(ctx) {
        return vec![runnable(ctx, "go.command", &entry)];
    }
    vec![runnable(ctx, "go.main", &entry)]
}

fn runnable(ctx: &DirectoryContext, provider: &str, source: &str) -> Detected {
    Detected::application(provider, &ctx.label(), "go", vec!["run", "."], ctx, source)
        .with_confidence(Confidence::Heuristic)
}

fn is_command_directory(ctx: &DirectoryContext) -> bool {
    ctx.relative.split('/').rev().nth(1) == Some("cmd")
}

/// The first (sorted) non-test `.go` file whose package clause is `main`, if
/// any. `_test.go` files never make a directory runnable: a test-only main
/// package exists to drive `go test`, not to be launched.
fn main_entry_file(ctx: &DirectoryContext) -> Option<String> {
    ctx.names()
        .filter(|name| is_go_source(name))
        .find(|name| {
            ctx.read(name)
                .is_some_and(|text| declares_main_package(&text))
        })
        .map(str::to_string)
}

fn is_go_source(name: &str) -> bool {
    name.ends_with(".go") && !name.ends_with("_test.go")
}

/// Removes `//` line comments and `/* */` block comments from one line.
/// `in_block_comment` carries an open block comment into the following lines.
/// A removed block comment is replaced by one space so the tokens around it
/// stay separate, matching how the Go scanner treats comments as whitespace.
fn without_comments(line: &str, in_block_comment: &mut bool) -> String {
    let mut code = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if *in_block_comment {
            if c == '*' && chars.peek() == Some(&'/') {
                chars.next();
                *in_block_comment = false;
                code.push(' ');
            }
            continue;
        }
        match c {
            '/' if chars.peek() == Some(&'/') => break,
            '/' if chars.peek() == Some(&'*') => {
                chars.next();
                *in_block_comment = true;
                code.push(' ');
            }
            _ => code.push(c),
        }
    }
    code
}

/// Reports whether the file's package clause is `package main`.
///
/// Go only honors the clause as the first content of the file, so matching
/// stops at the first line with any code outside comments: a clause with a
/// trailing comment counts, while a clause buried in line or block comments,
/// or one after the real clause, never does. An explicit semicolon after the
/// name is accepted, as the scanner allows it.
fn declares_main_package(text: &str) -> bool {
    let mut in_block_comment = false;
    for line in text.lines() {
        let code = without_comments(line, &mut in_block_comment);
        if code.trim().is_empty() {
            continue;
        }
        let mut words = code.split_whitespace();
        let keyword = words.next();
        let name = words.next().map(|word| word.trim_end_matches(';'));
        return keyword == Some("package") && name == Some("main");
    }
    false
}
