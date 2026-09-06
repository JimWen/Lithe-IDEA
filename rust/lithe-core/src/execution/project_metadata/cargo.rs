//! Cargo format-version 1 projection, preserving workspace and target semantics.

use super::{nonempty, parse_error, paths, sorted, stable_id, types::*, MAX_MEMBERS, MAX_TARGETS};
use crate::protocol::{cancellation, CoreError};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Deserialize)]
struct CargoMetadata {
    version: u32,
    workspace_root: String,
    workspace_members: Vec<String>,
    workspace_default_members: Option<Vec<String>>,
    packages: Vec<CargoPackage>,
}

#[derive(Deserialize)]
struct CargoPackage {
    id: String,
    name: String,
    version: String,
    edition: String,
    manifest_path: String,
    default_run: Option<String>,
    targets: Vec<CargoTarget>,
    features: BTreeMap<String, Vec<String>>,
    dependencies: Vec<CargoDependency>,
}

#[derive(Deserialize)]
struct CargoTarget {
    name: String,
    kind: Vec<String>,
    crate_types: Vec<String>,
    src_path: String,
    edition: String,
    #[serde(rename = "required-features", default)]
    required_features: Vec<String>,
    test: bool,
    doctest: bool,
}

#[derive(Deserialize)]
struct CargoDependency {
    name: String,
    rename: Option<String>,
    req: String,
    kind: Option<String>,
    optional: bool,
    uses_default_features: bool,
    features: Vec<String>,
    target: Option<String>,
    path: Option<String>,
}

pub(super) fn normalize(
    raw: &str,
    workspace_path: &str,
    workspace: Location,
    roots: &mut paths::Roots,
) -> Result<ProjectMetadata, CoreError> {
    let data: CargoMetadata = serde_json::from_str(raw).map_err(|_| parse_error())?;
    cancellation::check()?;
    if data.version != 1 || paths::absolute(&data.workspace_root)? != workspace_path {
        return Err(parse_error());
    }
    if data.packages.len() > MAX_MEMBERS {
        return Err(super::limit());
    }
    let wanted: BTreeSet<_> = data.workspace_members.iter().cloned().collect();
    if wanted.len() != data.workspace_members.len() {
        return Err(parse_error());
    }
    if let Some(defaults) = &data.workspace_default_members {
        let set: BTreeSet<_> = defaults.iter().collect();
        if set.len() != defaults.len() || defaults.iter().any(|id| !wanted.contains(id)) {
            return Err(parse_error());
        }
    }
    let mut all_ids = BTreeSet::new();
    let mut manifests = BTreeSet::new();
    let mut mapped_ids = BTreeMap::new();
    let mut members = Vec::new();
    let mut targets_seen = 0_usize;
    for package in data.packages {
        cancellation::check()?;
        nonempty(&package.id)?;
        if !all_ids.insert(package.id.clone()) {
            return Err(parse_error());
        }
        targets_seen = targets_seen.saturating_add(package.targets.len());
        if targets_seen > MAX_TARGETS {
            return Err(super::limit());
        }
        if !wanted.contains(&package.id) {
            continue;
        }
        nonempty(&package.name)?;
        nonempty(&package.version)?;
        nonempty(&package.edition)?;
        let manifest_path = paths::absolute(&package.manifest_path)?;
        if !manifests.insert(manifest_path.clone()) {
            return Err(parse_error());
        }
        let directory = roots.location(&paths::parent(&manifest_path)?)?;
        let manifest = roots.location(&manifest_path)?;
        let id = stable_id(("rust", &manifest));
        mapped_ids.insert(package.id, id.clone());
        let mut identities = BTreeSet::new();
        let mut targets = Vec::new();
        for target in package.targets {
            cancellation::check()?;
            nonempty(&target.name)?;
            nonempty(&target.edition)?;
            if target.kind.is_empty() || target.crate_types.is_empty() {
                return Err(parse_error());
            }
            for value in target.kind.iter().chain(&target.crate_types) {
                nonempty(value)?;
            }
            let kind = canonical_kind(&target.kind).to_owned();
            let target_id = stable_id((&id, &kind, &target.name));
            if !identities.insert(target_id.clone()) {
                return Err(parse_error());
            }
            // Example libraries share the example kind with binaries. A build
            // script or unknown future target must never acquire a Run action.
            let runnable = (kind == "bin" || kind == "example") && target.crate_types == ["bin"];
            targets.push(Target {
                id: target_id,
                name: target.name,
                kind: kind.clone(),
                raw_kinds: sorted(target.kind),
                crate_types: sorted(target.crate_types),
                edition: Some(target.edition),
                directory: roots.copy_location(&directory)?,
                sources: vec![Source {
                    location: roots.location(&target.src_path)?,
                    role: "root".into(),
                }],
                import_path: None,
                required_features: sorted(target.required_features),
                runnable,
                testable: target.test && kind != "custom-build" && kind != "unknown",
                doctest: target.doctest,
                incomplete: false,
                imports: vec![],
                test_imports: vec![],
                external_test_imports: vec![],
                diagnostics: vec![],
            });
        }
        targets.sort_by(|a, b| (&a.kind, &a.name).cmp(&(&b.kind, &b.name)));
        if let Some(default_run) = &package.default_run {
            if !targets
                .iter()
                .any(|target| target.kind == "bin" && &target.name == default_run)
            {
                return Err(parse_error());
            }
        }
        let mut dependencies = Vec::new();
        let mut dependency_ids = BTreeSet::new();
        for dependency in package.dependencies {
            cancellation::check()?;
            nonempty(&dependency.name)?;
            if !dependency_ids.insert((
                dependency.name.clone(),
                dependency.rename.clone(),
                dependency.kind.clone(),
                dependency.target.clone(),
            )) {
                return Err(parse_error());
            }
            dependencies.push(Dependency {
                name: dependency.name,
                rename: dependency.rename,
                version_req: dependency.req,
                kind: dependency.kind,
                optional: dependency.optional,
                default_features: dependency.uses_default_features,
                features: sorted(dependency.features),
                target: dependency.target,
                location: dependency
                    .path
                    .as_deref()
                    .map(|path| roots.location(path))
                    .transpose()?,
            });
        }
        dependencies.sort_by(|a, b| {
            (&a.name, &a.rename, &a.kind, &a.target).cmp(&(&b.name, &b.rename, &b.kind, &b.target))
        });
        members.push(Member {
            id,
            name: package.name,
            version: Some(package.version),
            language_version: Some(package.edition),
            directory,
            manifest,
            default_run: package.default_run,
            targets,
            features: FeatureDeclarations(
                package
                    .features
                    .into_iter()
                    .map(|(name, values)| (name, sorted(values)))
                    .collect(),
            ),
            dependencies,
            incomplete: false,
            diagnostics: vec![],
        });
    }
    if mapped_ids.len() != wanted.len() {
        return Err(parse_error());
    }
    members.sort_by(|a, b| a.manifest.cmp(&b.manifest));
    let default_member_ids = data.workspace_default_members.map(|defaults| {
        let selected: BTreeSet<_> = defaults.iter().map(|id| &mapped_ids[id]).collect();
        members
            .iter()
            .filter(|member| selected.contains(&member.id))
            .map(|member| member.id.clone())
            .collect()
    });
    Ok(ProjectMetadata {
        version: 1,
        language: "rust".into(),
        workspace,
        members,
        default_member_ids,
        diagnostics: vec![],
    })
}

fn canonical_kind(kinds: &[String]) -> &str {
    const LIBRARY_KINDS: &[&str] = &["lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro"];
    if kinds
        .iter()
        .all(|kind| LIBRARY_KINDS.contains(&kind.as_str()))
    {
        return "lib";
    }
    if kinds.len() == 1
        && ["bin", "example", "test", "bench", "custom-build"].contains(&kinds[0].as_str())
    {
        return &kinds[0];
    }
    "unknown"
}
