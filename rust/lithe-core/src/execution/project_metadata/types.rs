//! Portable project-tool topology; native paths exist only in input root mappings.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Complete stdout from successful, fully drained native metadata commands.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectMetadataRequest {
    pub language: String,
    pub workspace_directory: String,
    /// Frozen for one workspace incarnation; native adapters own authorization.
    pub roots: Vec<NativeRoot>,
    pub cargo_metadata: Option<String>,
    pub go_modules: Option<String>,
    pub go_packages: Option<String>,
}

/// Host-owned native location, never serialized into project identities.
#[derive(Deserialize)]
pub(crate) struct NativeRoot {
    pub id: String,
    pub path: String,
}

/// A component-relative location in an explicitly mapped project or external root.
#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Location {
    #[serde(rename = "rootID")]
    pub root_id: String,
    /// The root itself is represented by `.`.
    pub relative_path: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProjectMetadata {
    pub version: u8,
    pub language: String,
    pub workspace: Location,
    pub members: Vec<Member>,
    /// None means the tool did not report defaults; an empty list is authoritative.
    #[serde(rename = "defaultMemberIDs")]
    pub default_member_ids: Option<Vec<String>>,
    pub diagnostics: Vec<Diagnostic>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Member {
    pub id: String,
    pub name: String,
    pub version: Option<String>,
    /// Rust edition or Go language version, not the executable toolchain version.
    pub language_version: Option<String>,
    pub directory: Location,
    pub manifest: Location,
    pub default_run: Option<String>,
    pub targets: Vec<Target>,
    pub features: BTreeMap<String, Vec<String>>,
    /// Cargo declarations, not a resolved dependency graph.
    pub dependencies: Vec<Dependency>,
    pub incomplete: bool,
    pub diagnostics: Vec<Diagnostic>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Target {
    pub id: String,
    pub name: String,
    /// Stable semantic grouping; raw tool kinds remain available separately.
    pub kind: String,
    pub raw_kinds: Vec<String>,
    pub crate_types: Vec<String>,
    pub edition: Option<String>,
    pub directory: Location,
    pub sources: Vec<Source>,
    pub import_path: Option<String>,
    pub required_features: Vec<String>,
    /// Declared target eligibility, not proof a build or toolchain will succeed.
    pub runnable: bool,
    pub testable: bool,
    pub doctest: bool,
    pub incomplete: bool,
    pub imports: Vec<String>,
    pub test_imports: Vec<String>,
    pub external_test_imports: Vec<String>,
    pub diagnostics: Vec<Diagnostic>,
}

#[derive(Serialize)]
pub(super) struct Source {
    pub location: Location,
    /// Go, cgo, test, externalTest, ignored, or target root.
    pub role: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Dependency {
    pub name: String,
    pub rename: Option<String>,
    pub version_req: String,
    /// Cargo uses null for normal dependencies and dev/build for the other kinds.
    pub kind: Option<String>,
    pub optional: bool,
    pub default_features: bool,
    pub features: Vec<String>,
    pub target: Option<String>,
    pub location: Option<Location>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Diagnostic {
    pub code: String,
    pub import_path: Option<String>,
    /// Raw tool diagnostics may contain native paths; never use them as IDs.
    pub details: String,
}
