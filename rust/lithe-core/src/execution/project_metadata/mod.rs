//! Pure, bounded normalization of Cargo metadata and Go package/module JSON streams.

mod cargo;
mod go;
mod paths;
mod types;

use crate::protocol::{cancellation, CoreError, ErrorCode};
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::io::{self, Write};
pub(crate) use types::ProjectMetadataRequest;

const MAX_INPUT_BYTES: usize = 16 * 1024 * 1024;
const MAX_OUTPUT_BYTES: usize = 32 * 1024 * 1024;
const MAX_STRING_BYTES: usize = 64 * 1024;
const MAX_STRUCTURAL_ITEMS: usize = 200_000;
const MAX_NESTING: usize = 128;
const MAX_MEMBERS: usize = 10_000;
const MAX_TARGETS: usize = 100_000;

/// Normalizes already captured stdout without touching processes or the filesystem.
pub(crate) fn normalize_project_metadata(
    request: ProjectMetadataRequest,
) -> Result<Value, CoreError> {
    let mut budget = Budget::default();
    let mut roots = paths::Roots::new(request.roots)?;
    let workspace_path = paths::absolute(&request.workspace_directory)?;
    let workspace = roots.location(&workspace_path)?;
    let project = match request.language.as_str() {
        "rust" => {
            if request.go_modules.is_some() || request.go_packages.is_some() {
                return Err(invalid("Unexpected Go metadata for a Rust project"));
            }
            let raw = request
                .cargo_metadata
                .ok_or_else(|| invalid("Missing Cargo metadata"))?;
            budget.scan(&raw)?;
            cargo::normalize(&raw, &workspace_path, workspace, &mut roots)?
        }
        "go" => {
            if request.cargo_metadata.is_some() {
                return Err(invalid("Unexpected Cargo metadata for a Go project"));
            }
            let modules = request
                .go_modules
                .ok_or_else(|| invalid("Missing Go modules"))?;
            let packages = request
                .go_packages
                .ok_or_else(|| invalid("Missing Go packages"))?;
            budget.scan(&modules)?;
            budget.scan(&packages)?;
            go::normalize(&modules, &packages, workspace, &mut roots)?
        }
        _ => {
            return Err(CoreError::new(
                ErrorCode::NotSupported,
                "Unsupported project metadata language",
            ))
        }
    };
    cancellation::check()?;
    // Bound serialization before constructing the dispatcher Value. Repeated
    // path expansion is also charged while mapping locations, before allocation.
    let mut writer = LimitedWriter(Vec::new());
    serde_json::to_writer(&mut writer, &project).map_err(|_| limit())?;
    cancellation::check()?;
    let value = serde_json::from_slice(&writer.0).map_err(|_| parse_error())?;
    cancellation::check()?;
    Ok(value)
}

#[derive(Default)]
struct Budget {
    bytes: usize,
    items: usize,
}

impl Budget {
    fn scan(&mut self, raw: &str) -> Result<(), CoreError> {
        self.bytes = self.bytes.saturating_add(raw.len());
        if self.bytes > MAX_INPUT_BYTES {
            return Err(limit());
        }
        let mut quoted = false;
        let mut escaped = false;
        let mut string_bytes = 0;
        let mut depth = 0_usize;
        // This is a resource preflight, not a second JSON parser. Serde still
        // validates syntax, UTF-8 escapes, field types, and its recursion limit.
        for (index, byte) in raw.bytes().enumerate() {
            if index % (64 * 1024) == 0 {
                cancellation::check()?;
            }
            if quoted {
                string_bytes += 1;
                if string_bytes > MAX_STRING_BYTES {
                    return Err(limit());
                }
                if escaped {
                    escaped = false;
                } else if byte == b'\\' {
                    escaped = true;
                } else if byte == b'"' {
                    quoted = false;
                }
            } else if byte == b'"' {
                quoted = true;
                string_bytes = 0;
            } else if matches!(byte, b'[' | b'{' | b',') {
                if byte != b',' {
                    depth += 1;
                    if depth > MAX_NESTING {
                        return Err(limit());
                    }
                }
                self.items += 1;
                if self.items > MAX_STRUCTURAL_ITEMS {
                    return Err(limit());
                }
            } else if matches!(byte, b']' | b'}') {
                depth = depth.saturating_sub(1);
            }
        }
        cancellation::check()
    }
}

struct LimitedWriter(Vec<u8>);
impl Write for LimitedWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.0.len().saturating_add(bytes.len()) > MAX_OUTPUT_BYTES {
            return Err(io::Error::other("project metadata output limit"));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn stable_id(parts: impl Serialize) -> String {
    let bytes = serde_json::to_vec(&parts).expect("metadata identity consists of strings");
    format!("sha256:{:x}", Sha256::digest(bytes))
}

fn sorted(mut values: Vec<String>) -> Vec<String> {
    values.sort();
    values.dedup();
    values
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}
fn parse_error() -> CoreError {
    CoreError::new(
        ErrorCode::ParseFailed,
        "Invalid or inconsistent project metadata",
    )
}
fn limit() -> CoreError {
    CoreError::new(
        ErrorCode::InvalidRequest,
        "Project metadata exceeds its size or item limit",
    )
}

fn nonempty(value: &str) -> Result<(), CoreError> {
    if value.is_empty() || value.contains('\0') {
        Err(parse_error())
    } else {
        Ok(())
    }
}
