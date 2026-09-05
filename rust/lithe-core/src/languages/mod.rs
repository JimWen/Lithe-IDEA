//! Language-specific project inspection that is independent from LSP transport.

mod java;
mod java_syntax;

pub(crate) use java::*;
