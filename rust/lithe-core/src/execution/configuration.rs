//! Run-configuration schemas, layered overrides, and deterministic generation.

use super::types::{Confidence, Execution, RunCategory};
use crate::languages::JavaRunConfigurationsRequest;
use crate::protocol::{invalid_relative_path, CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

const VERSION: u32 = 2;
const LEGACY_VERSION: u32 = 1;
// Regenerate persisted detections when category or display-name semantics change.
const GENERATOR_REVISION: &str = "5";
const CURRENT_FILE_ID: &str = "current-file";
const EDITOR_CURRENT_FILE_PROVIDER: &str = "editor.current-file";
/// Toolchain requirements and `project.json` are separate documents that happen
/// to live under `.lithe`. Their schema did not change with run-config v2, so
/// they keep their own version and must not be validated against `VERSION`.
const SIDECAR_VERSION: u32 = 1;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to validate the layered configuration documents for a workspace.
pub struct InspectRequest {
    pub root: String,
    /// Host-owned local layer. When present, Core validates it instead of `.lithe/run/local.json`.
    #[serde(default)]
    pub local_document: Option<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to regenerate detected configurations from the current project tree.
pub struct GenerateRequest {
    pub root: String,
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub module_paths: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to merge configuration layers and resolve host toolchains.
pub struct ResolveRequest {
    pub root: String,
    #[serde(default)]
    pub toolchain_candidates: Vec<ToolchainCandidate>,
    /// Host-owned local layer. When present, Core uses it instead of `.lithe/run/local.json`.
    #[serde(default)]
    pub local_document: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Host-discovered executable that may satisfy a configuration requirement.
pub struct ToolchainCandidate {
    /// Host-stable candidate identifier referenced by resolved configurations.
    pub id: String,
    /// Toolchain role such as `java` or `runtime`, not a display label.
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub vendor: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to turn one resolved configuration into a process launch plan.
pub struct LaunchPlanRequest {
    pub root: String,
    pub configuration_id: String,
    #[serde(default)]
    pub current_file: Option<String>,
    #[serde(default)]
    pub class_path: Option<String>,
    #[serde(default)]
    pub debug_port: Option<u16>,
    /// Host-owned local layer. When present, Core uses it instead of `.lithe/run/local.json`.
    #[serde(default)]
    pub local_document: Option<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Global machine toolchain stored at document level in the local layer.
pub struct ToolchainPaths {
    #[serde(default)]
    pub java_home_path: String,
    /// Explicit executables for generic runtime toolchain IDs such as `project-node`.
    #[serde(default)]
    pub runtime_executable_paths: BTreeMap<String, String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Editable options applied to a team or machine-local configuration layer.
pub struct UpdateOptionsRequest {
    pub root: String,
    /// Persistence layer: `project` for shared configuration or `local` for this host.
    pub scope: String,
    pub configuration_id: String,
    #[serde(default)]
    pub working_directory: String,
    #[serde(default)]
    pub jvm_arguments: String,
    /// Common program arguments. `programArguments` remains a wire alias for
    /// clients from before the generic run-options migration.
    #[serde(default, alias = "programArguments")]
    pub arguments: String,
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    #[serde(default)]
    pub java_home_path: String,
    /// When present, `updateOptions` writes the document-level global toolchain
    /// into the local layer instead of patching one configuration.
    #[serde(default)]
    pub toolchain: Option<ToolchainPaths>,
    /// Host-owned local layer used when `scope` is `local` and when resolving first.
    #[serde(default)]
    pub local_document: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
/// Versioned run-configuration document stored below `.lithe/run`.
pub struct RunConfigurationDocument {
    pub version: u32,
    #[serde(default)]
    pub generator: Option<GeneratorMetadata>,
    #[serde(default)]
    pub configurations: Vec<RunConfiguration>,
}

/// Rewrites a v1 document in place into the v2 shape.
///
/// Ids are preserved verbatim. The three-layer merge matches configurations by
/// id, so rewriting them would silently detach every override a user wrote in
/// the team or local layer -- a failure with no error message.
pub fn migrate_document_value(document: &mut Value) -> bool {
    if document.get("version").and_then(Value::as_u64) != Some(LEGACY_VERSION as u64) {
        return false;
    }
    if let Some(items) = document
        .get_mut("configurations")
        .and_then(Value::as_array_mut)
    {
        for item in items {
            migrate_configuration_value(item);
        }
    }
    document["version"] = json!(VERSION);
    true
}

fn migrate_configuration_value(item: &mut Value) {
    let Some(object) = item.as_object_mut() else {
        return;
    };
    let legacy_type = object
        .remove("type")
        .and_then(|value| value.as_str().map(str::to_string))
        .unwrap_or_else(|| "java.current-file".to_string());

    let mut java = serde_json::Map::new();
    for (legacy_key, target_key) in [
        ("mainClass", "mainClass"),
        ("module", "module"),
        ("jvmArguments", "jvmArguments"),
        ("programArguments", "programArguments"),
    ] {
        if let Some(value) = object.remove(legacy_key) {
            let is_empty = value
                .as_array()
                .map(|items| items.is_empty())
                .unwrap_or(false);
            if !value.is_null() && !is_empty {
                java.insert(target_key.to_string(), value);
            }
        }
    }
    if let Some(working_directory) = object.remove("workingDirectory") {
        object.insert("cwd".to_string(), working_directory);
    }
    if !java.is_empty() {
        object
            .entry("extensions")
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .map(|extensions| extensions.insert("java".to_string(), Value::Object(java)));
    }

    let execution = match legacy_type.as_str() {
        "java.current-file" => "application",
        _ => "task",
    };
    object.insert("provider".to_string(), json!(legacy_type));
    object.insert("execution".to_string(), json!(execution));
    object.insert("confidence".to_string(), json!("native"));
    object.insert("debug".to_string(), json!({ "adapter": "jdwp" }));
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Fingerprint and inputs used to decide whether generated output is stale.
pub struct GeneratorMetadata {
    pub fingerprint: String,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub inputs: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Debug adapter supported by a runnable configuration.
pub struct DebugCapability {
    /// Stable adapter identifier, currently `jdwp` for JVM configurations.
    pub adapter: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Ecosystem-neutral command, identity, and launch metadata for one runnable item.
pub struct RunConfiguration {
    pub id: String,
    pub name: String,
    /// Open namespaced discriminator, e.g. `cargo.command`, `npm.script`.
    /// Deliberately not an enum: new ecosystems must not require a contract change.
    pub provider: String,
    #[serde(default)]
    pub execution: Execution,
    /// Whether the entry runs this project or the infrastructure it depends on.
    /// Omitted for project entries to preserve existing document shape.
    #[serde(default, skip_serializing_if = "RunCategory::is_project")]
    pub category: RunCategory,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default = "dot")]
    pub cwd: String,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub confidence: Confidence,
    #[serde(default)]
    pub toolchains: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub debug: Option<DebugCapability>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub members: Vec<String>,
    /// Ecosystem-specific payload keyed by namespace (`java`, `npm`, ...).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub extensions: BTreeMap<String, Value>,
    #[serde(default)]
    pub disabled: bool,
    /// Workspace-relative manifest or source file that produced the configuration.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

fn dot() -> String {
    ".".to_string()
}

/// Accessors for Java launch metadata outside the common configuration shape.
impl RunConfiguration {
    pub fn extension_string(&self, namespace: &str, key: &str) -> Option<String> {
        self.extensions
            .get(namespace)?
            .get(key)?
            .as_str()
            .map(str::to_string)
    }

    pub fn main_class(&self) -> Option<String> {
        self.extension_string("java", "mainClass")
    }

    pub fn module(&self) -> Option<String> {
        self.extension_string("java", "module")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Versioned requirements written separately from run configurations.
pub struct ToolchainRequirementsDocument {
    pub version: u32,
    #[serde(default)]
    pub toolchains: BTreeMap<String, ToolchainRequirement>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Constraints the host uses when selecting one toolchain candidate.
pub struct ToolchainRequirement {
    /// Toolchain role matched against [`ToolchainCandidate::kind`].
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub minimum_version: Option<String>,
    #[serde(default)]
    pub preferred_vendor: Option<String>,
    #[serde(default)]
    pub wrapper: Option<String>,
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    pub java: Option<String>,
}

/// Validates configuration and sidecar documents without mutating the workspace.
pub fn inspect(request: InspectRequest) -> Result<Value, CoreError> {
    let root = existing_root(&request.root)?;
    let generated = read_document(&root, "run/generated.json")?;
    let requirements = read_requirements(&root)?;
    let local_toolchains = read_local_toolchains(&root)?;
    for relative in [
        "run/configurations.json",
        "run/local.json",
        "toolchains/local.json",
        "project.json",
    ] {
        if relative == "run/local.json" {
            if let Some(document) = request.local_document.as_ref() {
                let mut migrated = document.clone();
                migrate_document_value(&mut migrated);
                validate_version_value(&migrated)?;
                configuration_ids(&migrated)?;
                continue;
            }
        }
        if let Some(document) = read_document_value(&root, relative)? {
            if relative.starts_with("run/") {
                validate_version_value(&document)?;
                configuration_ids(&document)?;
            } else {
                validate_sidecar_version_value(&document)?;
                if relative == "toolchains/local.json"
                    && document
                        .get("toolchains")
                        .and_then(Value::as_object)
                        .is_none()
                {
                    return Err(CoreError::new(
                        ErrorCode::ParseFailed,
                        "Local toolchains must contain a toolchains object",
                    ));
                }
            }
        }
    }
    if let Some(document) = generated.as_ref() {
        validate_version(document.version)?;
    }
    if let Some(document) = requirements.as_ref() {
        validate_sidecar_version(document.version)?;
    }
    let mut diagnostics = Vec::new();
    if let Some(metadata) = generated
        .as_ref()
        .and_then(|document| document.generator.as_ref())
    {
        let current_inputs = project_inputs(&root)?;
        if metadata.fingerprint != fingerprint_from_inputs(&current_inputs) {
            let message = if metadata.inputs.is_empty() {
                "Project inputs changed after run configuration generation".to_string()
            } else if metadata.inputs == current_inputs {
                "Run configuration generator changed; regenerate configurations".to_string()
            } else {
                input_change_summary(&metadata.inputs, &current_inputs)
            };
            diagnostics.push(json!({
                "code": "staleFingerprint",
                "message": message
            }));
        }
    }
    Ok(json!({
        "status": if generated.is_some() { "ready" } else { "missing" },
        "generated": generated,
        "toolchainRequirements": requirements,
        "localToolchains": local_toolchains,
        "diagnostics": diagnostics,
        "paths": { "generated": ".lithe/run/generated.json", "configurations": ".lithe/run/configurations.json", "local": ".lithe/run/local.json" }
    }))
}

/// Detects runnable project entries and writes a deterministic generated layer.
pub fn generate(request: GenerateRequest) -> Result<Value, CoreError> {
    let root = existing_root(&request.root)?;
    let mut paths = request
        .paths
        .into_iter()
        .filter(|path| !is_nested_checkout_path(path))
        .collect::<Vec<_>>();
    paths.sort();
    paths.dedup();
    let has_java_sources = paths
        .iter()
        .any(|path| path.to_lowercase().ends_with(".java"));
    let has_gradle_project = ["build.gradle", "build.gradle.kts", "gradlew"]
        .iter()
        .any(|name| root.join(name).is_file());
    let scanned = crate::languages::run_configurations(JavaRunConfigurationsRequest {
        root: request.root.clone(),
        paths,
        module_paths: request.module_paths,
    })?;
    let configurations = scanned
        .configurations
        .into_iter()
        .map(|value| {
            let source = value.source_path;
            RunConfiguration {
                id: value.id,
                name: value.name,
                provider: "java.main".to_string(),
                execution: Execution::Application,
                category: RunCategory::Project,
                command: None,
                args: Vec::new(),
                cwd: ".".to_string(),
                env: BTreeMap::new(),
                confidence: Confidence::Native,
                toolchains: [("java".to_string(), "project-jdk".to_string())]
                    .into_iter()
                    .collect(),
                debug: None,
                members: Vec::new(),
                disabled: false,
                extensions: [(
                    "java".to_string(),
                    json!({
                        "source": source, "sourceSet": value.source_set,
                        "mainClass": value.main_class, "module": value.module_path
                    }),
                )]
                .into_iter()
                .collect(),
                source: Some(source),
            }
        })
        .collect();
    let mut configurations = deduplicate_java_configurations(configurations);
    let java_entry_count = configurations.len();
    if has_java_sources {
        configurations.push(RunConfiguration {
            id: "current-file".to_string(),
            name: "Current File".to_string(),
            provider: "java.current-file".to_string(),
            execution: Execution::Application,
            category: RunCategory::Project,
            command: None,
            args: Vec::new(),
            cwd: ".".to_string(),
            env: BTreeMap::new(),
            confidence: Confidence::Native,
            toolchains: [("java".to_string(), "project-jdk".to_string())]
                .into_iter()
                .collect(),
            debug: Some(DebugCapability {
                adapter: "jdwp".to_string(),
            }),
            members: Vec::new(),
            extensions: BTreeMap::new(),
            disabled: false,
            source: None,
        });
    }
    let inputs = project_inputs(&root)?;
    let claimed = configurations.iter().map(|item| item.id.clone()).collect();
    let detected = detected_configurations(&root, &claimed)?;
    let entry_count = java_entry_count + detected.len();
    configurations.extend(detected);
    disambiguate_configuration_names(&mut configurations);
    let requirements = detect_requirements(
        &root,
        has_java_sources || has_gradle_project,
        &configurations,
    )?;
    let generated = RunConfigurationDocument {
        version: VERSION,
        generator: Some(GeneratorMetadata {
            fingerprint: fingerprint_from_inputs(&inputs),
            inputs,
        }),
        configurations,
    };
    Ok(
        json!({ "generated": generated, "toolchainRequirements": requirements, "entryCount": entry_count }),
    )
}

/// Qualifies display names that repeat across working directories or manifests.
///
/// Ids already carry the directory, but the Run list shows only the name: three
/// Compose files each contributing `compose up` are otherwise indistinguishable. The qualifier is the first
/// candidate that separates every entry in the group, so the shortest useful
/// label wins and unique names are never decorated.
fn disambiguate_configuration_names(configurations: &mut [RunConfiguration]) {
    let mut groups: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    for (index, configuration) in configurations.iter().enumerate() {
        groups
            .entry(configuration.name.to_lowercase())
            .or_default()
            .push(index);
    }
    for indexes in groups.into_values().filter(|indexes| indexes.len() > 1) {
        let candidates: [fn(&RunConfiguration) -> Option<String>; 2] = [
            |configuration| Some(configuration.cwd.clone()).filter(|cwd| cwd != "."),
            |configuration| configuration.source.clone(),
        ];
        let Some(qualifier) = candidates.into_iter().find(|candidate| {
            let values = indexes
                .iter()
                .map(|index| candidate(&configurations[*index]))
                .collect::<Option<BTreeSet<_>>>();
            values.is_some_and(|values| values.len() == indexes.len())
        }) else {
            continue;
        };
        for index in indexes {
            if let Some(value) = qualifier(&configurations[index]) {
                configurations[index].name = format!("{} ({value})", configurations[index].name);
            }
        }
    }
}

/// Keeps stable ids for the usual one-module case while preserving same-named
/// main classes that belong to different modules. Repeated source paths within
/// one module are genuine duplicates and still collapse to one configuration.
fn deduplicate_java_configurations(configurations: Vec<RunConfiguration>) -> Vec<RunConfiguration> {
    let mut grouped = BTreeMap::<String, BTreeMap<String, RunConfiguration>>::new();
    for configuration in configurations {
        let module = java_module_identity(configuration.module().as_deref());
        grouped
            .entry(configuration.id.clone())
            .or_default()
            .entry(module)
            .or_insert(configuration);
    }

    grouped
        .into_iter()
        .flat_map(|(base_id, modules)| {
            let has_module_collision = modules.len() > 1;
            modules.into_iter().map(move |(module, mut configuration)| {
                if has_module_collision {
                    configuration.id = format!("{base_id}:{module}");
                }
                configuration
            })
        })
        .collect()
}

fn java_module_identity(module: Option<&str>) -> String {
    let normalized = module
        .unwrap_or(".")
        .replace('\\', "/")
        .split('/')
        .filter(|component| !component.is_empty() && *component != ".")
        .collect::<Vec<_>>()
        .join("/");
    if normalized.is_empty() {
        ".".to_string()
    } else {
        normalized
    }
}

/// Translates detector output into the run-configuration contract.
///
/// Nearly every detection is process-based: the detector resolved the command,
/// so there is no ecosystem-specific launch assembly. A process may still name
/// a runtime requirement for scoped compatibility diagnostics; a detection that
/// transfers executable ownership to toolchains carries no command.
fn detected_configurations(
    root: &Path,
    claimed: &BTreeSet<String>,
) -> Result<Vec<RunConfiguration>, CoreError> {
    Ok(super::detectors::detect_all(root)?
        .into_iter()
        .map(|item| RunConfiguration {
            id: item.id(),
            name: item.name,
            provider: item.provider,
            execution: item.execution,
            category: item.category,
            command: item.command,
            args: item.args,
            cwd: item.cwd,
            env: item.env,
            confidence: item.confidence,
            toolchains: item.toolchains,
            debug: item.debug.map(|adapter| DebugCapability { adapter }),
            members: Vec::new(),
            extensions: item.extensions,
            disabled: false,
            source: Some(item.source),
        })
        .filter(|item| !claimed.contains(&item.id))
        .filter(|item| validate_configuration(item).is_ok())
        .collect())
}

fn is_nested_checkout_path(value: &str) -> bool {
    value.split(['/', '\\']).any(|component| {
        component.eq_ignore_ascii_case(".worktree") || component.eq_ignore_ascii_case(".worktrees")
    })
}

/// Merges generated, team, and local layers and selects compatible toolchains.
pub fn resolve(request: ResolveRequest) -> Result<Value, CoreError> {
    let root = existing_root(&request.root)?;
    let generated = read_document_value(&root, "run/generated.json")?.ok_or_else(|| {
        CoreError::new(
            ErrorCode::WorkspaceNotFound,
            "Run configuration has not been generated",
        )
    })?;
    let team = read_document_value(&root, "run/configurations.json")?
        .unwrap_or_else(|| json!({"version": VERSION, "configurations": []}));
    let local = local_layer_document(&root, request.local_document)?;
    let local_toolchains = read_local_toolchains(&root)?;
    let manifest = read_document_value(&root, "project.json")?;
    validate_version_value(&generated)?;
    validate_version_value(&team)?;
    validate_version_value(&local)?;
    if let Some(manifest) = manifest.as_ref() {
        validate_sidecar_version_value(manifest)?;
    }
    let generated_ids = configuration_ids(&generated)?;
    let has_editor_default = [&team, &local].iter().any(|source| {
        source["configurations"]
            .as_array()
            .is_some_and(|items| items.iter().any(is_editor_current_file))
    });
    let mut diagnostics = Vec::new();
    for source in [&team, &local] {
        for id in configuration_ids(source)?.keys() {
            if !generated_ids.contains_key(id)
                && !id.starts_with("user:")
                && !(id == CURRENT_FILE_ID && has_editor_default)
            {
                diagnostics.push(json!({
                    "id": id,
                    "code": "orphanedOverride",
                    "message": "Override no longer matches an automatically generated configuration"
                }));
            }
        }
    }
    let mut configurations = merge_values(&generated, &team, &local)?;
    // Old generated layers may outlive a product upgrade. Retire only the
    // removed providers; unrelated process configurations remain usable.
    configurations.retain(|configuration| {
        let retired = configuration.provider == "maven.module"
            || configuration.provider.ends_with(".maven");
        if retired {
            diagnostics.push(json!({
                "id": configuration.id,
                "code": "unsupportedProvider",
                "message": "This build no longer supports this provider; regenerate run configurations"
            }));
        }
        !retired
    });
    normalize_runtime_consumption(&mut configurations);
    let global_toolchain = local.get("toolchain").cloned();
    if let Some(toolchain) = global_toolchain.as_ref() {
        apply_global_toolchain(&mut configurations, toolchain);
    }
    diagnostics.extend(toolchain_diagnostics(
        &root,
        &request.toolchain_candidates,
        &configurations,
    )?);
    for configuration in &mut configurations {
        validate_configuration(configuration)?;
        if configuration.disabled {
            diagnostics.push(json!({
                "id": configuration.id,
                "code": "disabled",
                "message": "Run configuration is disabled"
            }));
            continue;
        }
        if let Some(module) = configuration.module().filter(|value| value != ".") {
            let workspace_module = if configuration.cwd == "." {
                module.clone()
            } else {
                format!("{}/{}", configuration.cwd, module)
            };
            if !project_directory_exists(&root, &workspace_module) {
                configuration.disabled = true;
                diagnostics.push(json!({
                    "id": configuration.id,
                    "code": "missingModule",
                    "message": format!("Module directory does not exist: {module}")
                }));
                continue;
            }
        }
        if !project_directory_exists(&root, &configuration.cwd) {
            configuration.disabled = true;
            diagnostics.push(json!({
                "id": configuration.id,
                "code": "missingWorkingDirectory",
                "message": format!("Working directory does not exist: {}", configuration.cwd)
            }));
            continue;
        }
        if let Some(main_class) = configuration.main_class() {
            if !main_class_exists(&root, &main_class)? {
                configuration.disabled = true;
                diagnostics.push(json!({
                    "id": configuration.id,
                    "code": "missingMainClass",
                    "message": format!("Main class source no longer exists: {main_class}")
                }));
            }
        }
    }
    configurations.retain(|configuration| !configuration.disabled);
    let mut default_run_configuration = manifest
        .as_ref()
        .and_then(|value| value.get("defaultRunConfiguration"))
        .and_then(Value::as_str)
        .map(str::to_string);
    if let Some(default_id) = default_run_configuration.as_deref() {
        if !configurations
            .iter()
            .any(|configuration| configuration.id == default_id)
        {
            diagnostics.push(json!({
                "code": "missingDefaultConfiguration",
                "message": format!("Default run configuration is unavailable: {default_id}")
            }));
            default_run_configuration = None;
        }
    }
    Ok(json!({
        "version": VERSION,
        "configurations": configurations,
        "diagnostics": diagnostics,
        "defaultRunConfiguration": default_run_configuration,
        "toolchain": global_toolchain,
        "localToolchains": local_toolchains
    }))
}

fn apply_global_toolchain(configurations: &mut [RunConfiguration], toolchain: &Value) {
    let java_home = toolchain["java"]["homePath"].as_str().unwrap_or("");
    for configuration in configurations {
        if !configuration.toolchains.contains_key("java") {
            continue;
        }
        let java = configuration
            .extensions
            .entry("java".to_string())
            .or_insert_with(|| json!({}));
        if let Some(object) = java.as_object_mut() {
            insert_toolchain_default(object, "homePath", java_home);
        }
    }
}

fn insert_toolchain_default(object: &mut serde_json::Map<String, Value>, key: &str, value: &str) {
    let has_override = object
        .get(key)
        .and_then(Value::as_str)
        .is_some_and(|configured| !configured.trim().is_empty());
    if !has_override {
        object.insert(key.to_string(), json!(value));
    }
}

/// Persists editable configuration options in the requested ownership layer.
pub fn update_options(mut request: UpdateOptionsRequest) -> Result<Value, CoreError> {
    let root = existing_root(&request.root)?;
    if let Some(toolchain) = request.toolchain.take() {
        if request.scope != "local" {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Toolchain paths can only be saved in the local layer",
            ));
        }
        let document = update_toolchain_document(&root, request.local_document, toolchain)?;
        return Ok(json!({
            "document": serde_json::to_string_pretty(&document).expect("document should encode")
        }));
    }
    let document = update_configuration_options(&root, request)?;
    Ok(json!({
        "document": serde_json::to_string_pretty(&document).expect("document should encode")
    }))
}

/// Produces every document needed to save the run-configuration editor as one operation.
pub fn save_editor_changes(mut request: UpdateOptionsRequest) -> Result<Value, CoreError> {
    let root = existing_root(&request.root)?;
    let toolchain = request.toolchain.take().ok_or_else(|| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Run configuration editor changes require a project toolchain",
        )
    })?;
    let toolchain_document =
        update_local_toolchains_document(&root, &toolchain.runtime_executable_paths)?;
    let mut local_document =
        update_toolchain_document(&root, request.local_document.take(), toolchain)?;
    request.local_document = Some(local_document.clone());
    let scope = request.scope.clone();
    let options_document = update_configuration_options(&root, request)?;
    let project_document = if scope == "project" {
        Some(serde_json::to_string_pretty(&options_document).expect("document should encode"))
    } else {
        local_document = options_document;
        None
    };
    Ok(json!({
        "localDocument": serde_json::to_string_pretty(&local_document).expect("document should encode"),
        "projectDocument": project_document,
        "toolchainDocument": toolchain_document.map(|document| {
            serde_json::to_string_pretty(&document).expect("document should encode")
        })
    }))
}

fn update_toolchain_document(
    root: &Path,
    local_document: Option<Value>,
    toolchain: ToolchainPaths,
) -> Result<Value, CoreError> {
    let mut document = local_layer_document(root, local_document)?;
    validate_version_value(&document)?;
    document["toolchain"] = json!({
        "java": { "homePath": toolchain.java_home_path }
    });
    Ok(document)
}

fn update_local_toolchains_document(
    root: &Path,
    runtime_executable_paths: &BTreeMap<String, String>,
) -> Result<Option<Value>, CoreError> {
    if runtime_executable_paths.is_empty() {
        return Ok(None);
    }
    let mut document = read_local_toolchains(root)?
        .unwrap_or_else(|| json!({"version": SIDECAR_VERSION, "toolchains": {}}));
    validate_sidecar_version_value(&document)?;
    let toolchains = document
        .get_mut("toolchains")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| {
            CoreError::new(
                ErrorCode::ParseFailed,
                "Local toolchains must contain a toolchains object",
            )
        })?;
    for (id, executable_path) in runtime_executable_paths {
        if executable_path.trim().is_empty() {
            toolchains.remove(id);
        } else {
            toolchains.insert(id.clone(), json!({ "executable": executable_path.trim() }));
        }
    }
    Ok(Some(document))
}

fn update_configuration_options(
    root: &Path,
    request: UpdateOptionsRequest,
) -> Result<Value, CoreError> {
    let relative = scope_document(&request.scope)?;
    let resolved = resolve(ResolveRequest {
        root: request.root.clone(),
        toolchain_candidates: Vec::new(),
        local_document: request.local_document.clone(),
    })?;
    let resolved_provider = resolved["configurations"]
        .as_array()
        .and_then(|items| {
            items
                .iter()
                .find(|value| value["id"] == request.configuration_id)
        })
        .and_then(|value| value["provider"].as_str());
    // The host exposes Current File even when generation finds no entry point.
    // Materialize that editor-owned target only when its options are saved;
    // adding it must not introduce a Java toolchain into non-Java projects.
    let is_editor_default =
        resolved_provider.is_none() && request.configuration_id == CURRENT_FILE_ID;
    let provider = resolved_provider
        .or_else(|| is_editor_default.then_some(EDITOR_CURRENT_FILE_PROVIDER))
        .ok_or_else(|| {
            CoreError::new(ErrorCode::InvalidRequest, "Run configuration was not found")
        })?;
    let uses_java_capability = is_java_launch(provider);
    let java_home_path =
        normalize_scoped_toolchain_path(&root, &request.scope, &request.java_home_path)?;
    let working_directory = if request.working_directory.trim().is_empty() {
        None
    } else {
        Some(normalize_project_directory(
            &root,
            request.working_directory.trim(),
            false,
        )?)
    };
    let mut document = if request.scope == "local" {
        local_layer_document(&root, request.local_document)?
    } else {
        read_document_value(&root, relative)?
            .unwrap_or_else(|| json!({"version": VERSION, "configurations": []}))
    };
    validate_version_value(&document)?;
    let configurations = document["configurations"]
        .as_array_mut()
        .ok_or_else(|| CoreError::new(ErrorCode::ParseFailed, "configurations must be an array"))?;
    let mut patch = json!({
        "id": request.configuration_id,
        "env": request.environment
    });
    if is_editor_default {
        patch["name"] = json!("Current File");
        patch["provider"] = json!(EDITOR_CURRENT_FILE_PROVIDER);
        patch["execution"] = json!("application");
    }
    if let Some(working_directory) = working_directory.as_ref() {
        patch["cwd"] = json!(working_directory);
    }
    let mut java_extension = serde_json::Map::new();
    if !java_home_path.is_empty() {
        java_extension.insert("homePath".to_string(), json!(java_home_path));
    }
    if uses_java_capability {
        let java_arguments = serde_json::Map::from_iter([
            (
                "jvmArguments".to_string(),
                json!(split_arguments(&request.jvm_arguments)),
            ),
            (
                "programArguments".to_string(),
                json!(split_arguments(&request.arguments)),
            ),
        ]);
        java_extension.extend(java_arguments);
        patch["extensions"] = json!({ "java": java_extension });
    } else {
        patch["args"] = json!(split_arguments(&request.arguments));
        if !java_extension.is_empty() {
            patch["extensions"] = json!({ "java": java_extension });
        }
    }
    if let Some(existing) = configurations
        .iter_mut()
        .find(|value| value["id"] == patch["id"])
    {
        let target = existing.as_object_mut().ok_or_else(|| {
            CoreError::new(
                ErrorCode::ParseFailed,
                "Run configuration must be an object",
            )
        })?;
        remove_java_toolchain_overrides(target)?;
        if working_directory.is_none() {
            target.remove("cwd");
        }
        for (key, value) in patch.as_object_mut().expect("patch is an object") {
            if key == "extensions" {
                merge_extensions(target, value)?;
                continue;
            }
            target.insert(key.clone(), value.take());
        }
    } else {
        configurations.push(patch);
    }
    configurations.sort_by(|left, right| {
        left["id"]
            .as_str()
            .unwrap_or("")
            .cmp(right["id"].as_str().unwrap_or(""))
    });
    Ok(document)
}

fn remove_java_toolchain_overrides(
    configuration: &mut serde_json::Map<String, Value>,
) -> Result<(), CoreError> {
    let Some(extensions) = configuration.get_mut("extensions") else {
        return Ok(());
    };
    let extensions = extensions.as_object_mut().ok_or_else(|| {
        CoreError::new(
            ErrorCode::ParseFailed,
            "Run configuration extensions must be an object",
        )
    })?;
    if let Some(java) = extensions.get_mut("java") {
        let java = java.as_object_mut().ok_or_else(|| {
            CoreError::new(
                ErrorCode::ParseFailed,
                "Run configuration Java extension must be an object",
            )
        })?;
        for key in ["homePath"] {
            java.remove(key);
        }
        if java.is_empty() {
            extensions.remove("java");
        }
    }
    if extensions.is_empty() {
        configuration.remove("extensions");
    }
    Ok(())
}

/// Resolves one configuration into the exact executable, arguments, and environment.
pub fn create_launch_plan(request: LaunchPlanRequest) -> Result<Value, CoreError> {
    let resolved = resolve(ResolveRequest {
        root: request.root.clone(),
        toolchain_candidates: Vec::new(),
        local_document: request.local_document.clone(),
    })?;
    let config = resolved["configurations"]
        .as_array()
        .and_then(|items| items.iter().find(|v| v["id"] == request.configuration_id))
        .ok_or_else(|| {
            CoreError::new(ErrorCode::InvalidRequest, "Run configuration was not found")
        })?;
    let provider = config["provider"].as_str().unwrap_or("");
    if let Some(command) = config["command"].as_str().filter(|value| !value.is_empty()) {
        return process_launch_plan(config, command);
    }
    if let Some(toolchain) = config["toolchains"]["runtime"]
        .as_str()
        .filter(|value| !value.is_empty())
    {
        return toolchain_process_launch_plan(config, toolchain);
    }
    if !is_java_launch(provider) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Run provider must declare a command or runtime toolchain",
        )
        .with_details(provider));
    }
    let java = &config["extensions"]["java"];
    let mut arguments = java["jvmArguments"].as_array().cloned().unwrap_or_default();
    if let Some(port) = request.debug_port {
        arguments.insert(
            0,
            json!(format!(
                "-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=127.0.0.1:{port}"
            )),
        );
        arguments.insert(1, json!("-Duser.language=en"));
        arguments.insert(2, json!("-Duser.country=US"));
    }
    let source = if provider == "java.current-file" {
        if let Some(class_path) = request.class_path.filter(|value| !value.is_empty()) {
            arguments.extend([json!("--class-path"), json!(class_path)]);
        }
        request.current_file
    } else {
        java["source"].as_str().map(str::to_string)
    }
    .ok_or_else(|| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Java application requires a source path",
        )
    })?;
    if invalid_relative_path(&source) || !source.to_lowercase().ends_with(".java") {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Java source path is invalid",
        ));
    }
    arguments.push(json!(source));
    arguments.extend(
        java["programArguments"]
            .as_array()
            .cloned()
            .unwrap_or_default(),
    );
    let toolchain = config["toolchains"]["java"].as_str().ok_or_else(|| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Run configuration is missing its executable toolchain",
        )
    })?;
    Ok(json!({
        "executable": { "toolchain": toolchain }, "arguments": arguments,
        "workingDirectory": config["cwd"].as_str().unwrap_or("."),
        "environment": { "JAVA_HOME": { "toolchain": toolchain, "property": "home" } },
        "env": config["env"].as_object().cloned().unwrap_or_default()
    }))
}

/// Providers the launch layer assembles a JVM command line for, rather than
/// spawning a process the detector described.
///
/// These are the providers whose `Detected` names toolchains instead of a
/// command, so `create_launch_plan` has to know each one. Every other ecosystem
/// is dispatched from the configuration itself and needs no entry here.
fn is_java_launch(provider: &str) -> bool {
    matches!(provider, "java.current-file" | "java.main")
}

/// Launch plan for configurations that name their own executable.
///
/// `executable.command` is a bare program name resolved on PATH by the host, as
/// opposed to `executable.toolchain` which the host resolves from its toolchain
/// registry. The two are mutually exclusive and the host branches on which key
/// is present. No JAVA_HOME is injected -- a Go or Node service has no use for
/// it, and injecting it would leak a Java assumption into every ecosystem.
fn process_launch_plan(config: &Value, command: &str) -> Result<Value, CoreError> {
    if command.contains('/') || command.contains('\\') {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Run configuration command must be a bare program name",
        )
        .with_details(command));
    }
    let arguments = config["args"].as_array().cloned().unwrap_or_default();
    if arguments.iter().any(|value| !value.is_string()) {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Run configuration arguments must be strings",
        ));
    }
    Ok(json!({
        "executable": { "command": command },
        "arguments": arguments,
        "workingDirectory": config["cwd"].as_str().unwrap_or("."),
        // `environment` is reserved for toolchain-derived values the host must
        // resolve. Literal key/value pairs stay in `env` so the two never
        // collide in one field.
        "environment": {},
        "env": config["env"].as_object().cloned().unwrap_or_default()
    }))
}

/// Launch plan for a language provider whose executable is supplied by the
/// host Toolchain Registry. The shared contract uses the stable `runtime` key;
/// provider-specific SDK metadata stays in other toolchain/extension entries.
fn toolchain_process_launch_plan(config: &Value, toolchain: &str) -> Result<Value, CoreError> {
    let arguments = config["args"].as_array().cloned().unwrap_or_default();
    if arguments.iter().any(|value| !value.is_string()) {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Run configuration arguments must be strings",
        ));
    }
    Ok(json!({
        "executable": { "toolchain": toolchain },
        "arguments": arguments,
        "workingDirectory": config["cwd"].as_str().unwrap_or("."),
        "environment": {},
        "env": config["env"].as_object().cloned().unwrap_or_default()
    }))
}

fn validate_version_value(document: &Value) -> Result<(), CoreError> {
    let version = document.get("version").and_then(Value::as_u64).unwrap_or(0) as u32;
    validate_version(version)
}

fn validate_version(version: u32) -> Result<(), CoreError> {
    if version != VERSION {
        return Err(CoreError::new(
            ErrorCode::NotSupported,
            "Unsupported run configuration version",
        )
        .with_details(format!("expected {VERSION}, found {version}")));
    }
    Ok(())
}

fn validate_sidecar_version(version: u32) -> Result<(), CoreError> {
    if version != SIDECAR_VERSION {
        return Err(
            CoreError::new(ErrorCode::NotSupported, "Unsupported document version")
                .with_details(format!("expected {SIDECAR_VERSION}, found {version}")),
        );
    }
    Ok(())
}

fn validate_sidecar_version_value(document: &Value) -> Result<(), CoreError> {
    let version = document.get("version").and_then(Value::as_u64).unwrap_or(0) as u32;
    validate_sidecar_version(version)
}

// Only the reserved editor target can be introduced outside the user: namespace.
// A stale override for any other generated target must still be ignored.
fn is_editor_current_file(item: &Value) -> bool {
    item["id"] == CURRENT_FILE_ID && item["provider"] == EDITOR_CURRENT_FILE_PROVIDER
}

fn merge_values(
    base: &Value,
    team: &Value,
    local: &Value,
) -> Result<Vec<RunConfiguration>, CoreError> {
    let mut result: BTreeMap<String, Value> = BTreeMap::new();
    for (source_index, source) in [base, team, local].into_iter().enumerate() {
        let Some(items) = source.get("configurations").and_then(Value::as_array) else {
            return Err(CoreError::new(
                ErrorCode::ParseFailed,
                "configurations must be an array",
            ));
        };
        for item in items {
            let Some(id) = item.get("id").and_then(Value::as_str) else {
                return Err(CoreError::new(
                    ErrorCode::ParseFailed,
                    "Run configuration id is required",
                ));
            };
            if source_index > 0
                && !result.contains_key(id)
                && !id.starts_with("user:")
                && !is_editor_current_file(item)
            {
                continue;
            }
            if let Some(existing) = result.get_mut(id) {
                let (Some(target), Some(patch)) = (existing.as_object_mut(), item.as_object())
                else {
                    return Err(CoreError::new(
                        ErrorCode::ParseFailed,
                        "Run configuration must be an object",
                    ));
                };
                for (key, value) in patch {
                    if key == "source" {
                        continue;
                    }
                    if key == "extensions" {
                        merge_extensions(target, &mut value.clone())?;
                        continue;
                    }
                    if key == "toolchains" {
                        let target_map = target
                            .entry(key.clone())
                            .or_insert_with(|| json!({}))
                            .as_object_mut()
                            .ok_or_else(|| {
                                CoreError::new(
                                    ErrorCode::ParseFailed,
                                    "Run configuration toolchains must be an object",
                                )
                            })?;
                        let patch_map = value.as_object().ok_or_else(|| {
                            CoreError::new(
                                ErrorCode::ParseFailed,
                                "Run configuration toolchains must be an object",
                            )
                        })?;
                        for (toolchain_kind, toolchain_id) in patch_map {
                            target_map.insert(toolchain_kind.clone(), toolchain_id.clone());
                        }
                    } else {
                        target.insert(key.clone(), value.clone());
                    }
                }
                target.insert(
                    "source".to_string(),
                    json!(["generated", "project", "local"][source_index]),
                );
            } else {
                let mut value = item.clone();
                if let Some(object) = value.as_object_mut() {
                    object.insert(
                        "source".to_string(),
                        json!(["generated", "project", "local"][source_index]),
                    );
                }
                result.insert(id.to_string(), value);
            }
        }
    }
    result
        .into_values()
        .map(|item| {
            serde_json::from_value::<RunConfiguration>(item).map_err(|e| {
                CoreError::new(ErrorCode::ParseFailed, "Invalid merged run configuration")
                    .with_details(e.to_string())
            })
        })
        .collect()
}

/// Reconciles runtime bindings from the effective command for generated v2
/// documents written before detectors declared their consumption explicitly.
fn normalize_runtime_consumption(configurations: &mut [RunConfiguration]) {
    for configuration in configurations {
        let command = configuration
            .command
            .as_deref()
            .unwrap_or("")
            .to_ascii_lowercase();
        if matches!(
            command.as_str(),
            "npm" | "npm.cmd" | "pnpm" | "pnpm.cmd" | "yarn" | "yarn.cmd"
        ) {
            configuration
                .toolchains
                .entry("runtime".to_string())
                .or_insert_with(|| "project-node".to_string());
        } else if matches!(command.as_str(), "bun" | "bun.exe")
            && configuration.toolchains.get("runtime").map(String::as_str) == Some("project-node")
        {
            configuration.toolchains.remove("runtime");
        }
    }
}

/// Deep-merges the `extensions` object one namespace at a time.
///
/// A shallow insert would let a layer that touches a single extension key drop the
/// whole npm namespace it never mentioned.
fn merge_extensions(
    target: &mut serde_json::Map<String, Value>,
    patch: &mut Value,
) -> Result<(), CoreError> {
    let patch_map = patch.as_object().ok_or_else(|| {
        CoreError::new(
            ErrorCode::ParseFailed,
            "Run configuration extensions must be an object",
        )
    })?;
    let target_map = target
        .entry("extensions".to_string())
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or_else(|| {
            CoreError::new(
                ErrorCode::ParseFailed,
                "Run configuration extensions must be an object",
            )
        })?;
    for (namespace, value) in patch_map {
        let slot = target_map
            .entry(namespace.clone())
            .or_insert_with(|| json!({}));
        match (slot.as_object_mut(), value.as_object()) {
            (Some(existing), Some(incoming)) => {
                for (key, item) in incoming {
                    existing.insert(key.clone(), item.clone());
                }
            }
            _ => {
                *slot = value.clone();
            }
        }
    }
    Ok(())
}

fn configuration_ids(document: &Value) -> Result<BTreeMap<String, ()>, CoreError> {
    let Some(items) = document.get("configurations").and_then(Value::as_array) else {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "configurations must be an array",
        ));
    };
    let mut result = BTreeMap::new();
    for item in items {
        let Some(id) = item.get("id").and_then(Value::as_str) else {
            return Err(CoreError::new(
                ErrorCode::ParseFailed,
                "Run configuration id is required",
            ));
        };
        result.insert(id.to_string(), ());
    }
    Ok(result)
}

fn validate_configuration(configuration: &RunConfiguration) -> Result<(), CoreError> {
    if configuration.id.trim().is_empty() || configuration.name.trim().is_empty() {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Run configuration id and name are required",
        ));
    }
    if !valid_provider(&configuration.provider) {
        return Err(CoreError::new(
            ErrorCode::NotSupported,
            "Unsupported run configuration provider",
        )
        .with_details(configuration.provider.clone()));
    }
    let module = configuration.module().unwrap_or_else(|| ".".to_string());
    for (field, value) in [
        ("module", module.as_str()),
        ("workingDirectory", configuration.cwd.as_str()),
    ] {
        if invalid_relative_path(value) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Run configuration contains an invalid project-relative path",
            )
            .with_details(format!("{field}: {value}")));
        }
    }
    Ok(())
}

fn local_layer_document(root: &Path, provided: Option<Value>) -> Result<Value, CoreError> {
    if let Some(mut document) = provided {
        // A host-owned local layer may still carry the v1 shape, mirroring the
        // migration applied to the on-disk document below.
        migrate_document_value(&mut document);
        validate_version_value(&document)?;
        configuration_ids(&document)?;
        return Ok(document);
    }
    Ok(read_document_value(root, "run/local.json")?
        .unwrap_or_else(|| json!({"version": VERSION, "configurations": []})))
}

fn scope_document(scope: &str) -> Result<&'static str, CoreError> {
    match scope {
        "local" => Ok("run/local.json"),
        "project" => Ok("run/configurations.json"),
        _ => Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Run configuration scope must be local or project",
        )),
    }
}

fn normalize_scoped_toolchain_path(
    root: &Path,
    scope: &str,
    value: &str,
) -> Result<String, CoreError> {
    let value = value.trim();
    if value.is_empty() {
        return Ok(String::new());
    }
    if scope == "project" {
        normalize_project_directory(root, value, true)
    } else {
        Ok(value.to_string())
    }
}

fn normalize_project_directory(
    root: &Path,
    value: &str,
    must_exist: bool,
) -> Result<String, CoreError> {
    let candidate = Path::new(value);
    if (!candidate.is_absolute() && invalid_relative_path(value))
        || candidate
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Project configuration paths must stay inside the project",
        ));
    }
    let canonical_root = fs::canonicalize(root)?;
    let target = if candidate.is_absolute() {
        candidate.to_path_buf()
    } else {
        root.join(candidate)
    };
    if !must_exist {
        let normalized = target.components().collect::<PathBuf>();
        let relative = normalized.strip_prefix(root).map_err(|_| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Project configuration paths must stay inside the project",
            )
        })?;
        return if relative.as_os_str().is_empty() {
            Ok(".".to_string())
        } else {
            Ok(relative.to_string_lossy().replace('\\', "/"))
        };
    }
    let canonical_target = fs::canonicalize(&target).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Project configuration directory does not exist",
        )
        .with_details(format!("{}: {error}", target.display()))
    })?;
    let relative = canonical_target
        .strip_prefix(&canonical_root)
        .map_err(|_| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Project configuration paths must stay inside the project",
            )
        })?;
    if relative.as_os_str().is_empty() {
        Ok(".".to_string())
    } else {
        Ok(relative.to_string_lossy().replace('\\', "/"))
    }
}

fn project_directory_exists(root: &Path, value: &str) -> bool {
    if invalid_relative_path(value) {
        return false;
    }
    let Ok(canonical_root) = fs::canonicalize(root) else {
        return false;
    };
    let Ok(canonical_target) = fs::canonicalize(root.join(value)) else {
        return false;
    };
    canonical_target.is_dir() && canonical_target.starts_with(canonical_root)
}

fn split_arguments(input: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut escaped = false;
    for character in input.chars() {
        if escaped {
            current.push(character);
            escaped = false;
        } else if character == '\\' && quote != Some('\'') {
            escaped = true;
        } else if matches!(character, '\'' | '"') {
            if quote == Some(character) {
                quote = None;
            } else if quote.is_none() {
                quote = Some(character);
            } else {
                current.push(character);
            }
        } else if character.is_whitespace() && quote.is_none() {
            if !current.is_empty() {
                result.push(std::mem::take(&mut current));
            }
        } else {
            current.push(character);
        }
    }
    if escaped {
        current.push('\\');
    }
    if !current.is_empty() {
        result.push(current);
    }
    result
}

fn read_document(
    root: &Path,
    relative: &str,
) -> Result<Option<RunConfigurationDocument>, CoreError> {
    let path = root.join(".lithe").join(relative);
    if !path.exists() {
        return Ok(None);
    }
    let text = fs::read_to_string(&path).map_err(|e| {
        CoreError::new(
            ErrorCode::PermissionDenied,
            format!("Could not read run configuration: .lithe/{relative}"),
        )
        .with_details(e.to_string())
    })?;
    let mut value: Value = serde_json::from_str(&text).map_err(|e| {
        CoreError::new(
            ErrorCode::ParseFailed,
            format!("Run configuration JSON is invalid: .lithe/{relative}"),
        )
        .with_details(e.to_string())
    })?;
    migrate_document_value(&mut value);
    serde_json::from_value(value).map(Some).map_err(|e| {
        CoreError::new(
            ErrorCode::ParseFailed,
            format!("Run configuration JSON is invalid: .lithe/{relative}"),
        )
        .with_details(e.to_string())
    })
}

fn read_document_value(root: &Path, relative: &str) -> Result<Option<Value>, CoreError> {
    let path = root.join(".lithe").join(relative);
    if !path.exists() {
        return Ok(None);
    }
    let text = fs::read_to_string(&path).map_err(|e| {
        CoreError::new(
            ErrorCode::PermissionDenied,
            "Could not read run configuration",
        )
        .with_details(e.to_string())
    })?;
    let mut value: Value = serde_json::from_str(&text).map_err(|e| {
        CoreError::new(
            ErrorCode::ParseFailed,
            format!("Configuration JSON is invalid: .lithe/{relative}"),
        )
        .with_details(e.to_string())
    })?;
    // Only run/* documents carry the run-configuration schema. project.json and
    // the toolchain files share the .lithe root and a version field, but their
    // schema is unrelated -- migrating them would bump a version they never own.
    if relative.starts_with("run/") {
        migrate_document_value(&mut value);
    }
    Ok(Some(value))
}

fn read_requirements(root: &Path) -> Result<Option<ToolchainRequirementsDocument>, CoreError> {
    let path = root
        .join(".lithe")
        .join("toolchains")
        .join("requirements.json");
    if !path.exists() {
        return Ok(None);
    }
    let text = fs::read_to_string(path).map_err(|error| {
        CoreError::new(
            ErrorCode::PermissionDenied,
            "Could not read toolchain requirements: .lithe/toolchains/requirements.json",
        )
        .with_details(error.to_string())
    })?;
    serde_json::from_str(&text).map(Some).map_err(|e| {
        CoreError::new(
            ErrorCode::ParseFailed,
            "Toolchain requirements JSON is invalid: .lithe/toolchains/requirements.json",
        )
        .with_details(e.to_string())
    })
}

fn read_local_toolchains(root: &Path) -> Result<Option<Value>, CoreError> {
    let Some(document) = read_document_value(root, "toolchains/local.json")? else {
        return Ok(None);
    };
    validate_sidecar_version_value(&document)?;
    if document
        .get("toolchains")
        .and_then(Value::as_object)
        .is_none()
    {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Local toolchains must contain a toolchains object",
        ));
    }
    Ok(Some(document))
}

fn detect_requirements(
    root: &Path,
    has_java_ecosystem: bool,
    configurations: &[RunConfiguration],
) -> Result<ToolchainRequirementsDocument, CoreError> {
    let mut jdk = ToolchainRequirement {
        kind: "java".to_string(),
        minimum_version: None,
        preferred_vendor: None,
        wrapper: None,
        version: None,
        java: None,
    };
    if let Some((version, vendor)) = declared_java_version(root) {
        jdk.minimum_version = Some(version);
        jdk.preferred_vendor = vendor;
    }
    let mut toolchains = BTreeMap::new();
    let consumes = |toolchain: &str| {
        configurations.iter().any(|configuration| {
            configuration
                .toolchains
                .values()
                .any(|candidate| candidate == toolchain)
        })
    };
    if has_java_ecosystem || consumes("project-jdk") {
        toolchains.insert("project-jdk".to_string(), jdk);
    }
    if consumes("project-node") {
        toolchains.insert(
            "project-node".to_string(),
            generic_requirement("node", declared_node_version(root)),
        );
    }
    Ok(ToolchainRequirementsDocument {
        version: SIDECAR_VERSION,
        toolchains,
    })
}

fn generic_requirement(kind: &str, minimum_version: Option<String>) -> ToolchainRequirement {
    ToolchainRequirement {
        kind: kind.to_string(),
        minimum_version,
        preferred_vendor: None,
        wrapper: None,
        version: None,
        java: None,
    }
}

fn toolchain_diagnostics(
    root: &Path,
    candidates: &[ToolchainCandidate],
    configurations: &[RunConfiguration],
) -> Result<Vec<Value>, CoreError> {
    let Some(requirements) = read_requirements(root)? else {
        return Ok(Vec::new());
    };
    validate_sidecar_version(requirements.version)?;
    let mut diagnostics = Vec::new();
    for (id, requirement) in requirements.toolchains {
        let mut consumer_ids = configurations
            .iter()
            .filter(|configuration| {
                configuration
                    .toolchains
                    .values()
                    .any(|toolchain| toolchain == &id)
            })
            .map(|configuration| configuration.id.clone())
            .collect::<Vec<_>>();
        consumer_ids.sort();
        consumer_ids.dedup();
        let Some(candidate) = candidates
            .iter()
            .find(|candidate| candidate.id == id && candidate.kind == requirement.kind)
        else {
            append_toolchain_diagnostics(
                &mut diagnostics,
                &consumer_ids,
                json!({
                    "code": "missingToolchain",
                    "toolchain": id,
                    "message": format!("No local {} toolchain is selected", requirement.kind)
                }),
            );
            continue;
        };
        let required_version = requirement
            .minimum_version
            .as_deref()
            .or(requirement.version.as_deref());
        if let Some(required) = required_version {
            if !version_satisfies(
                &candidate.version,
                required,
                requirement.minimum_version.is_some(),
            ) {
                append_toolchain_diagnostics(
                    &mut diagnostics,
                    &consumer_ids,
                    json!({
                        "code": "toolchainVersionMismatch",
                        "toolchain": id,
                        "message": format!(
                            "{} {} does not satisfy required version {}",
                            requirement.kind, candidate.version, required
                        )
                    }),
                );
            }
        }
        if let Some(vendor) = requirement.preferred_vendor.as_deref() {
            if !candidate
                .vendor
                .to_lowercase()
                .contains(&vendor.to_lowercase())
            {
                append_toolchain_diagnostics(
                    &mut diagnostics,
                    &consumer_ids,
                    json!({
                        "code": "toolchainVendorMismatch",
                        "toolchain": id,
                        "message": format!("Preferred Java vendor is {vendor}")
                    }),
                );
            }
        }
    }
    Ok(diagnostics)
}

fn append_toolchain_diagnostics(
    diagnostics: &mut Vec<Value>,
    consumer_ids: &[String],
    diagnostic: Value,
) {
    if consumer_ids.is_empty() {
        return;
    }
    for configuration_id in consumer_ids {
        let mut scoped = diagnostic.clone();
        scoped["id"] = json!(configuration_id);
        diagnostics.push(scoped);
    }
}

fn version_satisfies(actual: &str, required: &str, minimum: bool) -> bool {
    let actual_parts = version_parts(actual);
    let required_parts = version_parts(required);
    if actual_parts.is_empty() || required_parts.is_empty() {
        return false;
    }
    if minimum {
        actual_parts >= required_parts
    } else {
        actual_parts.starts_with(&required_parts)
    }
}

fn version_parts(value: &str) -> Vec<u32> {
    value
        .split(|character: char| !character.is_ascii_digit())
        .filter(|part| !part.is_empty())
        .filter_map(|part| part.parse().ok())
        .collect()
}

fn project_inputs(root: &Path) -> Result<BTreeMap<String, String>, CoreError> {
    let mut files = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.is_dir() {
                if !ignored_directory(&path) {
                    stack.push(path);
                }
            } else if fingerprint_input(&path) {
                if let Ok(relative) = path.strip_prefix(root) {
                    files.push(relative.to_string_lossy().replace('\\', "/"));
                }
            }
        }
    }
    files.sort();
    let mut result = BTreeMap::new();
    for relative in files {
        if let Ok(bytes) = fs::read(root.join(&relative)) {
            result.insert(relative, format!("sha256:{:x}", Sha256::digest(bytes)));
        }
    }
    Ok(result)
}

fn fingerprint_from_inputs(inputs: &BTreeMap<String, String>) -> String {
    let mut digest = Sha256::new();
    // Detection changes invalidate persisted output even when project files are
    // unchanged, so an application upgrade cannot keep launching a stale plan.
    digest.update(GENERATOR_REVISION.as_bytes());
    digest.update([0]);
    for (relative, content_hash) in inputs {
        digest.update(relative.as_bytes());
        digest.update([0]);
        digest.update(content_hash.as_bytes());
        digest.update([0]);
    }
    format!("sha256:{:x}", digest.finalize())
}

fn input_change_summary(
    previous: &BTreeMap<String, String>,
    current: &BTreeMap<String, String>,
) -> String {
    let added = current
        .keys()
        .filter(|path| !previous.contains_key(*path))
        .count();
    let removed = previous
        .keys()
        .filter(|path| !current.contains_key(*path))
        .count();
    let changed = current
        .iter()
        .filter(|(path, hash)| previous.get(*path).is_some_and(|old| old != *hash))
        .count();
    format!("Project inputs changed: {added} added, {removed} removed, {changed} modified")
}

fn ignored_directory(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    name.eq_ignore_ascii_case(".worktree")
        || name.eq_ignore_ascii_case(".worktrees")
        || matches!(
            name,
            ".git"
                | ".lithe"
                | ".idea"
                | ".gradle"
                | ".venv"
                | "venv"
                | "node_modules"
                | "vendor"
                | "target"
                | "build"
                | "dist"
                | "out"
        )
}

fn fingerprint_input(path: &Path) -> bool {
    if path.extension().and_then(|extension| extension.to_str()) == Some("java") {
        return true;
    }
    matches!(
        path.file_name().and_then(|name| name.to_str()),
        Some(
            ".java-version"
                | ".sdkmanrc"
                | "mise.toml"
                | "package.json"
                | "package-lock.json"
                | "pnpm-lock.yaml"
                | "yarn.lock"
                | "bun.lock"
                | "bun.lockb"
                | "docker-compose.yml"
                | "docker-compose.yaml"
                | "compose.yml"
                | "compose.yaml"
                | "pyproject.toml"
                | "manage.py"
                | "Cargo.toml"
                | "rust-toolchain"
                | "rust-toolchain.toml"
                | "go.mod"
                | "Procfile"
                | "Procfile.dev"
                | "Procfile.local"
                | "Makefile"
                | "makefile"
                | "GNUmakefile"
                | "justfile"
                | "Justfile"
                | ".justfile"
        )
    )
}

fn declared_node_version(root: &Path) -> Option<String> {
    highest_version(
        project_manifest_paths(root, &["package.json"])
            .into_iter()
            .filter_map(|path| fs::read_to_string(path).ok())
            .filter_map(|text| serde_json::from_str::<Value>(&text).ok())
            .filter_map(|document| {
                document
                    .get("engines")?
                    .get("node")?
                    .as_str()
                    .and_then(first_numeric_version)
            })
            .collect(),
    )
}

fn first_numeric_version(value: &str) -> Option<String> {
    regex::Regex::new(r"[0-9]+(?:\.[0-9]+)+")
        .ok()?
        .find(value)
        .map(|value| value.as_str().to_string())
}

fn highest_version(versions: Vec<String>) -> Option<String> {
    versions
        .into_iter()
        .max_by(|left, right| version_parts(left).cmp(&version_parts(right)))
}

fn project_manifest_paths(root: &Path, names: &[&str]) -> Vec<PathBuf> {
    let mut result = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(directory) = stack.pop() {
        let Ok(entries) = fs::read_dir(directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if !ignored_directory(&path) {
                    stack.push(path);
                }
            } else if path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| names.contains(&name))
            {
                result.push(path);
            }
        }
    }
    result
}

fn declared_java_version(root: &Path) -> Option<(String, Option<String>)> {
    if let Ok(text) = fs::read_to_string(root.join(".java-version")) {
        let value = text.trim();
        if let Some(version) = major_version(value) {
            return Some((version, vendor_from_version(value)));
        }
    }
    if let Ok(text) = fs::read_to_string(root.join(".sdkmanrc")) {
        if let Some(value) = text
            .lines()
            .find_map(|line| line.trim().strip_prefix("java="))
        {
            return major_version(value).map(|version| (version, vendor_from_version(value)));
        }
    }
    if let Ok(text) = fs::read_to_string(root.join("mise.toml")) {
        let expression = regex::Regex::new(r#"(?m)^\s*java\s*=\s*["']([^"']+)["']"#).ok()?;
        if let Some(value) = expression
            .captures(&text)
            .and_then(|capture| capture.get(1))
        {
            let value = value.as_str();
            return major_version(value).map(|version| (version, vendor_from_version(value)));
        }
    }
    None
}

fn major_version(value: &str) -> Option<String> {
    regex::Regex::new(r"(?:^|[^0-9])(?:1\.)?([0-9]{1,2})(?:[._+-]|$)")
        .ok()?
        .captures(value)
        .and_then(|capture| capture.get(1))
        .map(|value| value.as_str().to_string())
}

fn vendor_from_version(value: &str) -> Option<String> {
    let lower = value.to_lowercase();
    if lower.contains("tem") || lower.contains("temurin") {
        Some("temurin".to_string())
    } else if lower.contains("zulu") {
        Some("zulu".to_string())
    } else if lower.contains("graal") {
        Some("graalvm".to_string())
    } else {
        None
    }
}

fn main_class_exists(root: &Path, main_class: &str) -> Result<bool, CoreError> {
    let (package_name, simple_name) = main_class
        .rsplit_once('.')
        .map_or(("", main_class), |(package, name)| (package, name));
    let file_name = format!("{simple_name}.java");
    let package_expression =
        regex::Regex::new(r"(?m)^\s*package\s+([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\s*;")
            .map_err(|error| CoreError::new(ErrorCode::Unknown, error.to_string()))?;
    let mut stack = vec![root.to_path_buf()];
    while let Some(directory) = stack.pop() {
        for entry in fs::read_dir(directory)? {
            let path = entry?.path();
            if path.is_dir() {
                if !ignored_directory(&path) {
                    stack.push(path);
                }
            } else if path.file_name().and_then(|name| name.to_str()) == Some(file_name.as_str()) {
                let source = fs::read_to_string(&path)?;
                let declared_package = package_expression
                    .captures(&source)
                    .and_then(|capture| capture.get(1))
                    .map(|value| value.as_str())
                    .unwrap_or("");
                if declared_package == package_name {
                    return Ok(true);
                }
            }
        }
    }
    Ok(false)
}

fn existing_root(value: &str) -> Result<PathBuf, CoreError> {
    let path = PathBuf::from(value);
    if !path.is_dir() {
        return Err(CoreError::new(
            ErrorCode::WorkspaceNotFound,
            "Project root does not exist",
        ));
    }
    Ok(path)
}

#[allow(dead_code)]
fn valid_relative(value: &str) -> bool {
    !invalid_relative_path(value)
}

/// `namespace.name`, both segments lowercase kebab starting with a letter.
/// Shape is checked, membership is not: an unknown ecosystem must be able to
/// register a provider without touching this file.
fn valid_provider(value: &str) -> bool {
    let Some((namespace, name)) = value.split_once('.') else {
        return false;
    };
    [namespace, name].iter().all(|segment| {
        segment
            .chars()
            .next()
            .is_some_and(|first| first.is_ascii_lowercase())
            && segment
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    })
}
