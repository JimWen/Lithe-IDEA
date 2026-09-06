//! Go list object-stream projection, including incomplete packages and tool errors.

use super::{nonempty, parse_error, paths, sorted, stable_id, types::*, MAX_MEMBERS, MAX_TARGETS};
use crate::protocol::{cancellation, CoreError};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Deserialize, Default)]
#[serde(rename_all = "PascalCase")]
struct GoModule {
    #[serde(default)]
    path: String,
    #[serde(default)]
    main: bool,
    #[serde(default)]
    dir: String,
    #[serde(default)]
    go_mod: String,
    version: Option<String>,
    go_version: Option<String>,
    error: Option<GoError>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "PascalCase")]
struct GoError {
    err: String,
    #[serde(default)]
    pos: String,
    #[serde(default)]
    import_stack: Vec<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "PascalCase", default)]
struct GoPackage {
    dir: String,
    import_path: String,
    name: String,
    module: Option<GoModule>,
    for_test: String,
    go_files: Vec<String>,
    cgo_files: Vec<String>,
    test_go_files: Vec<String>,
    x_test_go_files: Vec<String>,
    ignored_go_files: Vec<String>,
    imports: Vec<String>,
    test_imports: Vec<String>,
    x_test_imports: Vec<String>,
    incomplete: bool,
    error: Option<GoError>,
    deps_errors: Vec<GoError>,
}

pub(super) fn normalize(
    modules: &str,
    packages: &str,
    workspace: Location,
    roots: &mut paths::Roots,
) -> Result<ProjectMetadata, CoreError> {
    let mut members = Vec::new();
    let mut module_locations = Vec::new();
    let mut module_names = BTreeSet::new();
    let mut module_paths = BTreeSet::new();
    let mut diagnostics = Vec::new();
    for (index, item) in serde_json::Deserializer::from_str(modules)
        .into_iter::<GoModule>()
        .enumerate()
    {
        cancellation::check()?;
        if index >= MAX_MEMBERS {
            return Err(super::limit());
        }
        let module = item.map_err(|_| parse_error())?;
        if module.error.is_none() {
            nonempty(&module.path)?;
        }
        let mut module_diagnostics = Vec::new();
        if let Some(error) = module.error {
            module_diagnostics.push(diagnostic("moduleError", &module.path, error, roots)?);
            if module.dir.is_empty()
                || module.go_mod.is_empty()
                || !is_import_identity(&module.path)
            {
                diagnostics.extend(module_diagnostics);
                continue;
            }
        }
        if !module.main {
            diagnostics.extend(module_diagnostics);
            continue;
        }
        if !is_import_identity(&module.path) {
            return Err(parse_error());
        }
        nonempty(&module.path)?;
        let directory_path = paths::absolute(&module.dir)?;
        let manifest_path = paths::absolute(&module.go_mod)?;
        if paths::parent(&manifest_path)? != directory_path
            || !module_names.insert(module.path.clone())
            || !module_paths.insert(directory_path.clone())
        {
            return Err(parse_error());
        }
        let directory = roots.location(&directory_path)?;
        let manifest = roots.location(&manifest_path)?;
        let id = stable_id(("go", &manifest));
        module_locations.push((directory_path, members.len(), module.path.clone()));
        members.push(Member {
            id,
            name: module.path,
            version: module.version,
            language_version: module.go_version,
            directory,
            manifest,
            default_run: None,
            targets: vec![],
            features: BTreeMap::new(),
            dependencies: vec![],
            incomplete: !module_diagnostics.is_empty(),
            diagnostics: module_diagnostics,
        });
    }
    if members.is_empty() && diagnostics.is_empty() {
        return Err(parse_error());
    }
    module_locations.sort_by(|a, b| b.0.len().cmp(&a.0.len()));
    let mut package_imports = BTreeSet::new();
    let mut package_directories = BTreeSet::new();
    for (index, item) in serde_json::Deserializer::from_str(packages)
        .into_iter::<GoPackage>()
        .enumerate()
    {
        cancellation::check()?;
        if index >= MAX_TARGETS {
            return Err(super::limit());
        }
        let mut package = item.map_err(|_| parse_error())?;
        nonempty(&package.import_path)?;
        // `.test` is also a legitimate import-path suffix. Only explicit
        // synthetic-package evidence is rejected; discovery never asks -test.
        if !package.for_test.is_empty() || package.import_path.contains(" [") {
            return Err(parse_error());
        }
        let module_error = package
            .module
            .as_mut()
            .and_then(|module| module.error.take());
        let has_error =
            package.error.is_some() || !package.deps_errors.is_empty() || module_error.is_some();
        let mut package_diagnostics = Vec::new();
        if let Some(error) = package.error {
            package_diagnostics.push(diagnostic(
                "packageError",
                &package.import_path,
                error,
                roots,
            )?);
        }
        for error in package.deps_errors {
            package_diagnostics.push(diagnostic(
                "dependencyError",
                &package.import_path,
                error,
                roots,
            )?);
        }
        if let Some(error) = module_error {
            package_diagnostics.push(diagnostic(
                "moduleError",
                &package.import_path,
                error,
                roots,
            )?);
        }
        if package.dir.is_empty()
            || package.module.is_none()
            || !is_import_identity(&package.import_path)
        {
            // With -e, Go explicitly permits records containing only ImportPath
            // and Error. Preserve them without inventing a package location.
            if !has_error {
                return Err(parse_error());
            }
            diagnostics.extend(package_diagnostics);
            continue;
        }
        let directory_path = paths::absolute(&package.dir)?;
        let (module_dir, member_index, module_name) = module_locations
            .iter()
            .find(|entry| paths::contains(&entry.0, &directory_path))
            .ok_or_else(parse_error)?;
        let relative_directory = directory_path[module_dir.len()..].trim_start_matches('/');
        let expected_import = if relative_directory.is_empty() {
            module_name.clone()
        } else {
            format!("{module_name}/{relative_directory}")
        };
        if !has_error && package.import_path != expected_import {
            return Err(parse_error());
        }
        if let Some(module) = &package.module {
            if !module.main
                || &module.path != module_name
                || paths::absolute(&module.dir)? != *module_dir
            {
                return Err(parse_error());
            }
            if !module.go_mod.is_empty()
                && roots.location(&module.go_mod)? != members[*member_index].manifest
            {
                return Err(parse_error());
            }
        }
        if (!has_error && package.name.is_empty())
            || !package_imports.insert(package.import_path.clone())
            || !package_directories.insert(directory_path.clone())
        {
            return Err(parse_error());
        }
        let member = &mut members[*member_index];
        package_diagnostics.sort_by(|a, b| {
            (&a.code, &a.import_path, &a.details).cmp(&(&b.code, &b.import_path, &b.details))
        });
        let id = stable_id((&member.id, "package", &package.import_path));
        let mut sources = Vec::new();
        let has_source = !package.go_files.is_empty() || !package.cgo_files.is_empty();
        for (role, names) in [
            ("go", package.go_files),
            ("cgo", package.cgo_files),
            ("test", package.test_go_files),
            ("externalTest", package.x_test_go_files),
            ("ignored", package.ignored_go_files),
        ] {
            for filename in sorted(names) {
                cancellation::check()?;
                sources.push(Source {
                    location: roots.location(&paths::source(&directory_path, &filename)?)?,
                    role: role.into(),
                });
            }
        }
        sources.sort_by(|a, b| (&a.role, &a.location).cmp(&(&b.role, &b.location)));
        member.targets.push(Target {
            id,
            name: if package.name.is_empty() {
                package.import_path.clone()
            } else {
                package.name.clone()
            },
            kind: "package".into(),
            raw_kinds: vec![],
            crate_types: vec![],
            edition: None,
            directory: roots.location(&directory_path)?,
            sources,
            import_path: Some(package.import_path),
            required_features: vec![],
            runnable: package.name == "main"
                && has_source
                && !package.incomplete
                && !has_error
                && !member.incomplete,
            testable: !package.incomplete && !has_error && !member.incomplete,
            doctest: false,
            incomplete: package.incomplete || has_error || member.incomplete,
            imports: sorted(package.imports),
            test_imports: sorted(package.test_imports),
            external_test_imports: sorted(package.x_test_imports),
            diagnostics: package_diagnostics,
        });
    }
    for member in &mut members {
        member
            .targets
            .sort_by(|a, b| a.import_path.cmp(&b.import_path));
    }
    members.sort_by(|a, b| a.manifest.cmp(&b.manifest));
    diagnostics.sort_by(|a, b| {
        (&a.import_path, &a.code, &a.details).cmp(&(&b.import_path, &b.code, &b.details))
    });
    let default_member_ids = Some(members.iter().map(|member| member.id.clone()).collect());
    Ok(ProjectMetadata {
        version: 1,
        language: "go".into(),
        workspace,
        members,
        default_member_ids,
        diagnostics,
    })
}

fn diagnostic(
    code: &str,
    import_path: &str,
    error: GoError,
    roots: &mut paths::Roots,
) -> Result<Diagnostic, CoreError> {
    #[derive(Serialize)]
    struct Details<'a> {
        #[serde(flatten)]
        error: GoError,
        #[serde(rename = "Query", skip_serializing_if = "Option::is_none")]
        query: Option<&'a str>,
    }
    let is_import = is_import_identity(import_path);
    let details = serde_json::to_string(&Details {
        error,
        query: (!is_import).then_some(import_path),
    })
    .expect("Go diagnostics consist of strings");
    // A package may have thousands of dependency errors sharing one long
    // import path. Charge the repeated text before cloning it for each error.
    roots.charge_expansion(import_path.len() + details.len() + code.len() + 64)?;
    Ok(Diagnostic {
        code: code.into(),
        import_path: is_import.then(|| import_path.into()),
        details,
    })
}

fn is_import_identity(value: &str) -> bool {
    !value.is_empty()
        && !value.starts_with('/')
        && !value
            .chars()
            .any(|value| value.is_whitespace() || matches!(value, ':' | '\\' | '\0'))
}
