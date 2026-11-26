//! Project files, search, local history, and document rendering services.

mod document_lifecycle;
pub(crate) mod files;
mod history;
mod markdown;
mod scoped_replacement;
mod search_index;
mod symbols;

pub(crate) use document_lifecycle::*;
pub(crate) use files::*;
pub(crate) use history::*;
pub(crate) use markdown::*;
pub(crate) use search_index::get_cached as get_cached_search_index;
pub(crate) use symbols::{
    document_symbols, extract_symbols, language_group_for_path, DocumentSymbolsRequest,
};
