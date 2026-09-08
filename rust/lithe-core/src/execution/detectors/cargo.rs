//! Cargo binary discovery from manifests and conventional source layouts.

use super::{Detected, DirectoryContext};
use std::collections::BTreeSet;
use std::path::PathBuf;

/// Cargo binaries come from `[[bin]]` entries and from Cargo's automatic
/// discovery of `src/main.rs` and `src/bin/`, respecting the edition default,
/// explicit `autobins` setting, and sources already assigned to declared bins.
/// Workspace roots with no package of their own contribute nothing --
/// their members are separate directories and detect independently.
pub fn detect(ctx: &DirectoryContext) -> Vec<Detected> {
    let Some(text) = ctx.read("Cargo.toml") else {
        return Vec::new();
    };
    let Ok(document) = text.parse::<toml::Table>() else {
        return Vec::new();
    };
    let Some(package) = document.get("package") else {
        return Vec::new();
    };
    // Every generated command names its package explicitly, so a package with
    // no name cannot produce an unambiguous configuration.
    let Some(package_name) = package.get("name").and_then(|value| value.as_str()) else {
        return Vec::new();
    };

    let declared = document
        .get("bin")
        .and_then(|value| value.as_array())
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    // De-duplicate both names and explicit paths: a renamed src/main.rs is
    // already a target, so Cargo must not be asked to run the package-name bin.
    let mut names: BTreeSet<String> = declared
        .iter()
        .filter_map(|entry| entry.get("name")?.as_str().map(str::to_owned))
        .collect();
    let declared_paths: BTreeSet<PathBuf> = declared
        .iter()
        .filter_map(|entry| entry.get("path")?.as_str())
        .map(|path| ctx.path.join(path))
        .collect();
    // In edition 2015, even an empty `bin = []` disables discovery by default.
    // Later editions combine declared and conventional targets unless opted out.
    let autobins = package
        .get("autobins")
        .and_then(|value| value.as_bool())
        .unwrap_or_else(|| {
            !document.contains_key("bin")
                || package_edition(ctx, &document).is_some_and(|edition| edition != "2015")
        });
    if autobins {
        let mut discovered = auto_bins(ctx);
        let main = ctx.path.join("src/main.rs");
        if main.is_file() {
            discovered.push((package_name.to_string(), main));
        }
        // Filter sources before de-duplicating names: a renamed src/main.rs
        // may coexist with an automatic src/bin/<package>.rs target.
        names.extend(
            discovered
                .into_iter()
                .filter(|(_, path)| !declared_paths.contains(path))
                .map(|(name, _)| name),
        );
    }

    names
        .into_iter()
        .map(|name| {
            Detected::application(
                "cargo.binary",
                &name,
                "cargo",
                // `--package` keeps the command unambiguous even when it is
                // replayed from somewhere other than the package directory.
                vec!["run", "--package", package_name, "--bin", name.as_str()],
                ctx,
                "Cargo.toml",
            )
            .with_extension("cargo", serde_json::json!({ "bin": name }))
        })
        .collect()
}

/// Resolves the edition used by Cargo's binary-discovery default, including
/// workspace inheritance. An absent edition retains the legacy 2015 default.
fn package_edition(ctx: &DirectoryContext, document: &toml::Table) -> Option<String> {
    let package = document.get("package")?;
    let edition = package.get("edition")?;
    if let Some(edition) = edition.as_str() {
        return Some(edition.to_string());
    }
    if edition.get("workspace").and_then(|value| value.as_bool()) != Some(true) {
        return None;
    }
    if document.contains_key("workspace") {
        return workspace_edition(document);
    }
    if let Some(workspace) = package.get("workspace").and_then(|value| value.as_str()) {
        let text = std::fs::read_to_string(ctx.path.join(workspace).join("Cargo.toml")).ok()?;
        return workspace_edition(&text.parse::<toml::Table>().ok()?);
    }
    // Cargo uses the nearest enclosing workspace; inheritance is not limited
    // to the opened IDE directory when a workspace member was opened directly.
    for directory in ctx.path.parent()?.ancestors() {
        let Ok(text) = std::fs::read_to_string(directory.join("Cargo.toml")) else {
            continue;
        };
        let Ok(parent) = text.parse::<toml::Table>() else {
            continue;
        };
        if parent.contains_key("workspace") {
            return workspace_edition(&parent);
        }
    }
    None
}

fn workspace_edition(document: &toml::Table) -> Option<String> {
    document
        .get("workspace")?
        .get("package")?
        .get("edition")?
        .as_str()
        .map(str::to_owned)
}

/// Cargo's automatic discovery under `src/bin`: every `*.rs` file is a binary
/// named after its stem, and every subdirectory containing `main.rs` is a binary
/// named after the directory.
///
/// Entries are probed through their paths rather than through `file_type` so a
/// symlinked source file or command directory is treated the way Cargo treats
/// it. Unreadable directories yield nothing rather than failing the whole scan.
fn auto_bins(ctx: &DirectoryContext) -> Vec<(String, PathBuf)> {
    let mut bins = Vec::new();
    let Ok(entries) = std::fs::read_dir(ctx.path.join("src").join("bin")) else {
        return bins;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if path.join("main.rs").is_file() {
                if let Some(name) = path.file_name().and_then(|value| value.to_str()) {
                    bins.push((name.to_string(), path.join("main.rs")));
                }
            }
        } else if path.extension().and_then(|value| value.to_str()) == Some("rs") && path.is_file()
        {
            if let Some(name) = path.file_stem().and_then(|value| value.to_str()) {
                bins.push((name.to_string(), path.clone()));
            }
        }
    }
    bins
}
