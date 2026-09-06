//! Lexical native-to-portable path mapping; authorization and symlinks stay native.

use super::{
    invalid, limit,
    types::{Location, NativeRoot},
    MAX_OUTPUT_BYTES,
};
use crate::protocol::{CoreError, ErrorCode};
use std::collections::BTreeSet;

const MAX_PATH_BYTES: usize = 8 * 1024;
const MAX_ROOTS: usize = 128;

pub(super) struct Roots {
    entries: Vec<NativeRoot>,
    /// Includes every expanded location, including temporary intermediate values.
    expanded_bytes: usize,
}

impl Roots {
    pub fn charge_expansion(&mut self, bytes: usize) -> Result<(), CoreError> {
        self.expanded_bytes = self.expanded_bytes.saturating_add(bytes);
        if self.expanded_bytes > MAX_OUTPUT_BYTES {
            return Err(limit());
        }
        Ok(())
    }
    pub fn new(mut entries: Vec<NativeRoot>) -> Result<Self, CoreError> {
        if entries.is_empty() || entries.len() > MAX_ROOTS {
            return Err(limit());
        }
        let mut ids = BTreeSet::new();
        let mut paths = BTreeSet::new();
        for entry in &mut entries {
            if entry.id.is_empty()
                || entry.id.len() > 64
                || !entry
                    .id
                    .bytes()
                    .all(|v| v.is_ascii_alphanumeric() || b"._-".contains(&v))
                || !ids.insert(entry.id.clone())
            {
                return Err(invalid("Invalid or duplicate project metadata root ID"));
            }
            entry.path = absolute(&entry.path)?;
            if !paths.insert(entry.path.clone()) {
                return Err(invalid("Duplicate project metadata root path"));
            }
        }
        entries.sort_by(|a, b| b.path.len().cmp(&a.path.len()).then(a.id.cmp(&b.id)));
        Ok(Self {
            entries,
            expanded_bytes: 0,
        })
    }

    pub fn location(&mut self, path: &str) -> Result<Location, CoreError> {
        let path = absolute(path)?;
        let entry = self
            .entries
            .iter()
            .find(|entry| contains(&entry.path, &path))
            .ok_or_else(|| {
                CoreError::new(
                    ErrorCode::PermissionDenied,
                    "Project metadata path has no mapped root",
                )
            })?;
        let relative = if entry.path == path {
            "."
        } else {
            path[entry.path.len()..].trim_start_matches('/')
        };
        self.expanded_bytes = self
            .expanded_bytes
            .saturating_add(relative.len() + entry.id.len() + 64);
        if self.expanded_bytes > MAX_OUTPUT_BYTES {
            return Err(limit());
        }
        Ok(Location {
            root_id: entry.id.clone(),
            relative_path: relative.into(),
        })
    }

    pub fn copy_location(&mut self, location: &Location) -> Result<Location, CoreError> {
        self.expanded_bytes = self
            .expanded_bytes
            .saturating_add(location.relative_path.len() + location.root_id.len() + 64);
        if self.expanded_bytes > MAX_OUTPUT_BYTES {
            return Err(limit());
        }
        Ok(location.clone())
    }
}

pub(super) fn absolute(value: &str) -> Result<String, CoreError> {
    if !value.starts_with('/') || value.len() > MAX_PATH_BYTES || value.contains('\0') {
        return Err(invalid(
            "Project metadata requires bounded absolute POSIX paths",
        ));
    }
    let mut parts = Vec::new();
    for part in value.split('/') {
        if part == ".." {
            return Err(invalid(
                "Parent traversal is not allowed in project metadata paths",
            ));
        }
        if !part.is_empty() && part != "." {
            parts.push(part);
        }
    }
    Ok(format!("/{}", parts.join("/")))
}

pub(super) fn contains(root: &str, path: &str) -> bool {
    path == root
        || root == "/"
        || path
            .strip_prefix(root)
            .is_some_and(|tail| tail.starts_with('/'))
}

pub(super) fn parent(path: &str) -> Result<String, CoreError> {
    let path = absolute(path)?;
    if path == "/" {
        return Err(invalid("A project manifest must name a file"));
    }
    Ok(path
        .rsplit_once('/')
        .map(|(head, _)| if head.is_empty() { "/" } else { head })
        .unwrap()
        .into())
}

pub(super) fn source(directory: &str, filename: &str) -> Result<String, CoreError> {
    if filename.is_empty()
        || filename.starts_with('/')
        || filename.split('/').any(|part| part == "..")
    {
        return Err(invalid(
            "Go source paths must be relative to their package directory",
        ));
    }
    absolute(&format!("{directory}/{filename}"))
}
