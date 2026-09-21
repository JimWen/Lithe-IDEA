//! Deterministic editor text-transform commands owned by Rust Core.
//!
//! macOS applies returned UTF-16 replacements through its native text engine;
//! the JSON contract and fixtures remain independent of the presentation host.

pub(crate) mod line_edit;

pub(crate) use line_edit::{
    line_comment_token, line_edit, LineCommentTokenRequest, LineEditRequest,
};

#[cfg(test)]
mod tests;
