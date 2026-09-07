//! Cargo binary discovery from manifests and conventional source layouts.

use super::{Detected, DirectoryContext};
use std::collections::BTreeSet;

/// Cargo binaries come from `[[bin]]` entries and from Cargo's automatic
/// discovery of `src/main.rs` and `src/bin/`. Declaring `[[bin]]` does not turn
/// automatic discovery off, so both sources contribute and the names are
/// unioned. Workspace roots with no package of their own contribute nothing --
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

    // A BTreeSet both de-duplicates a name that is declared and discoverable and
    // fixes the emission order, which the run-configuration contract requires.
    let mut names: BTreeSet<String> = document
        .get("bin")
        .and_then(|value| value.as_array())
        .map(|entries| {
            entries
                .iter()
                .filter_map(|entry| entry.get("name")?.as_str())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    // `autobins = false` opts out of the conventional layout entirely and
    // leaves only what the manifest declared.
    let autobins = package
        .get("autobins")
        .and_then(|value| value.as_bool())
        .unwrap_or(true);
    if autobins {
        if has_main(ctx) {
            names.insert(package_name.to_string());
        }
        names.extend(auto_bin_names(ctx));
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

/// `src/main.rs` is what makes a package a binary rather than a library. It sits
/// one directory below the manifest, which the scan records separately, so this
/// and [`auto_bin_names`] are the only places a detector touches the filesystem
/// directly.
fn has_main(ctx: &DirectoryContext) -> bool {
    ctx.path.join("src").join("main.rs").is_file()
}

/// Cargo's automatic discovery under `src/bin`: every `*.rs` file is a binary
/// named after its stem, and every subdirectory containing `main.rs` is a binary
/// named after the directory.
///
/// Entries are probed through their paths rather than through `file_type` so a
/// symlinked source file or command directory is treated the way Cargo treats
/// it. Unreadable directories yield nothing rather than failing the whole scan.
fn auto_bin_names(ctx: &DirectoryContext) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    let Ok(entries) = std::fs::read_dir(ctx.path.join("src").join("bin")) else {
        return names;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if path.join("main.rs").is_file() {
                if let Some(name) = path.file_name().and_then(|value| value.to_str()) {
                    names.insert(name.to_string());
                }
            }
        } else if path.extension().and_then(|value| value.to_str()) == Some("rs") {
            if let Some(name) = path.file_stem().and_then(|value| value.to_str()) {
                names.insert(name.to_string());
            }
        }
    }
    names
}
