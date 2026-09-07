use super::support::temporary_root;
use crate::execute_json;
use serde_json::Value;
use std::fs;
use std::path::Path;

/// Builds a project that mixes six ecosystems in one tree, including the
/// traps that break naive detectors: a lockfile that is not npm's, a
/// `node_modules` full of decoy manifests, and a Go command in a
/// subdirectory with no manifest of its own.
fn multi_language_project(root: &Path) {
    for directory in ["frontend/node_modules/decoy", "api", "cmd/gateway"] {
        fs::create_dir_all(root.join(directory)).unwrap();
    }
    fs::write(
        root.join("frontend/package.json"),
        r#"{"name":"web","scripts":{"dev":"vite","build":"vite build"}}"#,
    )
    .unwrap();
    fs::write(root.join("frontend/pnpm-lock.yaml"), "lockfileVersion: 9\n").unwrap();
    fs::write(
        root.join("frontend/node_modules/decoy/package.json"),
        r#"{"scripts":{"dev":"should-never-appear"}}"#,
    )
    .unwrap();
    fs::write(
        root.join("api/pyproject.toml"),
        "[tool.poetry]\nname = \"api\"\n[tool.poetry.scripts]\napi-server = \"api.main:run\"\n",
    )
    .unwrap();
    fs::write(
        root.join("api/main.py"),
        "from fastapi import FastAPI\napp = FastAPI()\n",
    )
    .unwrap();
    fs::write(root.join("go.mod"), "module example.com/gw\ngo 1.22\n").unwrap();
    fs::write(
        root.join("cmd/gateway/main.go"),
        "package main\nfunc main() {}\n",
    )
    .unwrap();
    fs::write(
        root.join("docker-compose.yml"),
        "services:\n  db:\n    image: postgres\n  cache:\n    image: redis\n",
    )
    .unwrap();
    fs::write(
        root.join("Procfile"),
        "worker: python worker/run.py\nweb: gunicorn api.main:app\n",
    )
    .unwrap();
    fs::write(
        root.join("Makefile"),
        "run:\n\techo run\nclean:\n\techo clean\n",
    )
    .unwrap();
}

fn generated_configurations(root: &Path) -> Vec<Value> {
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate",
            "command": "runConfig.generate",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["data"]["generated"]["configurations"]
        .as_array()
        .cloned()
        .unwrap()
}

/// The headline behaviour: one project, six ecosystems, every service found
/// without the user configuring anything.
#[test]
fn detectors_find_services_across_unrelated_ecosystems() {
    let root = temporary_root("detect-multi");
    fs::create_dir_all(&root).unwrap();
    multi_language_project(&root);

    let ids = generated_configurations(&root)
        .iter()
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();

    for expected in [
        "npm.script:frontend/dev",
        "python.script:api/api-server",
        "python.uvicorn:api/main",
        "go.command:cmd/gateway/gateway",
        "compose.service:db",
        "compose.stack:compose up",
        "procfile.process:web",
        "make.target:run",
    ] {
        assert!(
            ids.contains(&expected.to_string()),
            "missing {expected} in {ids:?}"
        );
    }

    fs::remove_dir_all(root).unwrap();
}

/// A dependency tree contains thousands of manifests. Descending into it
/// would both bury the real services and make project open unusably slow.
#[test]
fn detectors_never_descend_into_dependency_directories() {
    let root = temporary_root("detect-prune");
    fs::create_dir_all(&root).unwrap();
    multi_language_project(&root);
    fs::create_dir_all(root.join(".worktree/feature")).unwrap();
    fs::write(
        root.join(".worktree/feature/package.json"),
        r#"{"scripts":{"dev":"vite"}}"#,
    )
    .unwrap();
    fs::create_dir_all(root.join(".worktrees/bugfix")).unwrap();
    fs::write(
        root.join(".worktrees/bugfix/package.json"),
        r#"{"scripts":{"dev":"vite"}}"#,
    )
    .unwrap();

    let sources = generated_configurations(&root)
        .iter()
        .filter_map(|item| item["source"].as_str().map(str::to_string))
        .collect::<Vec<_>>();

    assert!(
        !sources.iter().any(|source| source.contains("node_modules")),
        "{sources:?}"
    );
    assert!(
        !sources.iter().any(|source| {
            source.starts_with(".worktree/") || source.starts_with(".worktrees/")
        }),
        "{sources:?}"
    );

    fs::remove_dir_all(root).unwrap();
}

/// Running `npm run dev` in a pnpm workspace fails at spawn time with an
/// error that points nowhere useful, so the lockfile decides the command.
#[test]
fn npm_detector_uses_the_package_manager_the_lockfile_names() {
    let root = temporary_root("detect-pnpm");
    fs::create_dir_all(&root).unwrap();
    multi_language_project(&root);

    let dev = generated_configurations(&root)
        .into_iter()
        .find(|item| item["id"] == "npm.script:frontend/dev")
        .unwrap();

    assert_eq!(dev["command"], "pnpm");
    assert_eq!(dev["args"], serde_json::json!(["run", "dev"]));
    assert_eq!(dev["cwd"], "frontend");
    assert_eq!(dev["execution"], "service");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn npm_detector_inherits_the_workspace_package_manager() {
    let root = temporary_root("detect-pnpm-workspace");
    fs::create_dir_all(root.join("apps/web")).unwrap();
    fs::write(root.join("pnpm-lock.yaml"), "lockfileVersion: 9\n").unwrap();
    fs::write(
        root.join("apps/web/package.json"),
        r#"{"scripts":{"dev":"vite"}}"#,
    )
    .unwrap();

    let dev = generated_configurations(&root)
        .into_iter()
        .find(|item| item["id"] == "npm.script:apps/web/dev")
        .unwrap();
    assert_eq!(dev["command"], "pnpm");
    assert_eq!(dev["execution"], "service");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn bun_scripts_keep_the_bun_command_without_consuming_node() {
    let root = temporary_root("detect-bun-runtime");
    fs::create_dir_all(&root).unwrap();
    fs::write(root.join("bun.lock"), "").unwrap();
    fs::write(
        root.join("package.json"),
        r#"{"packageManager":"bun@1.2.0","scripts":{"dev":"vite"}}"#,
    )
    .unwrap();

    let dev = generated_configurations(&root)
        .into_iter()
        .find(|item| item["id"] == "npm.script:dev")
        .unwrap();
    assert_eq!(dev["command"], "bun");
    assert!(dev["toolchains"].as_object().unwrap().is_empty(), "{dev}");
    let generated: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate-bun-runtime",
            "command": "runConfig.generate",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .unwrap();
    assert!(
        generated["data"]["toolchainRequirements"]["toolchains"]["project-node"].is_null(),
        "{generated}"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn detectors_preserve_application_service_and_task_semantics() {
    let root = temporary_root("detect-execution-semantics");
    fs::create_dir_all(&root).unwrap();
    multi_language_project(&root);
    let configurations = generated_configurations(&root);
    let execution = |id: &str| {
        configurations
            .iter()
            .find(|item| item["id"] == id)
            .and_then(|item| item["execution"].as_str())
    };

    assert_eq!(execution("npm.script:frontend/dev"), Some("service"));
    assert_eq!(execution("npm.script:frontend/build"), Some("task"));
    assert_eq!(
        execution("python.script:api/api-server"),
        Some("application")
    );
    assert_eq!(
        execution("go.command:cmd/gateway/gateway"),
        Some("application")
    );
    assert_eq!(execution("compose.stack:compose up"), Some("service"));

    fs::remove_dir_all(root).unwrap();
}

/// Detected entries are process-based, so they must survive the same launch
/// path as any other configuration without acquiring Java assumptions.
#[test]
fn detected_services_produce_runnable_launch_plans() {
    let root = temporary_root("detect-launch");
    fs::create_dir_all(&root).unwrap();
    multi_language_project(&root);
    let generated = serde_json::json!({
        "version": 2,
        "configurations": generated_configurations(&root)
    });
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        serde_json::to_string(&generated).unwrap(),
    )
    .unwrap();

    let plan: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "plan",
            "command": "runConfig.createLaunchPlan",
            "payload": {"root": root, "configurationId": "npm.script:frontend/dev"}
        })
        .to_string(),
    ))
    .unwrap();

    assert_eq!(plan["ok"], true, "{plan}");
    assert_eq!(plan["data"]["executable"]["command"], "pnpm");
    assert!(plan["data"]["executable"]["toolchain"].is_null());
    assert_eq!(plan["data"]["workingDirectory"], "frontend");
    assert!(plan["data"]["environment"]["JAVA_HOME"].is_null());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn every_builtin_detector_produces_a_launch_plan() {
    let root = temporary_root("detect-all-launch-plans");
    for directory in ["node", "python", "rust/src", "go", "gradle"] {
        fs::create_dir_all(root.join(directory)).unwrap();
    }
    fs::write(
        root.join("node/package.json"),
        r#"{"scripts":{"dev":"node server.js"}}"#,
    )
    .unwrap();
    fs::write(
        root.join("python/pyproject.toml"),
        "[project]\nname = \"python-app\"\n[project.scripts]\npython-app = \"app:main\"\n",
    )
    .unwrap();
    fs::write(
        root.join("rust/Cargo.toml"),
        "[package]\nname = \"rust-app\"\nversion = \"0.1.0\"\n",
    )
    .unwrap();
    fs::write(root.join("rust/src/main.rs"), "fn main() {}\n").unwrap();
    fs::write(
        root.join("go/go.mod"),
        "module example.com/go-app\ngo 1.22\n",
    )
    .unwrap();
    fs::write(root.join("go/main.go"), "package main\nfunc main() {}\n").unwrap();
    fs::write(
        root.join("gradle/build.gradle"),
        "plugins { id 'application' version '3.2.0' }\n",
    )
    .unwrap();
    fs::write(
        root.join("compose.yml"),
        "services:\n  database:\n    image: postgres\n",
    )
    .unwrap();
    fs::write(root.join("Procfile"), "worker: python worker.py\n").unwrap();
    fs::write(root.join("Makefile"), "serve:\n\t@echo serve\n").unwrap();
    fs::write(root.join("justfile"), "watch:\n    echo watch\n").unwrap();

    let configurations = generated_configurations(&root);
    let generated = serde_json::json!({
        "version": 2,
        "configurations": configurations
    });
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        serde_json::to_string(&generated).unwrap(),
    )
    .unwrap();
    fs::create_dir_all(root.join(".lithe/toolchains")).unwrap();
    fs::write(
        root.join(".lithe/toolchains/requirements.json"),
        r#"{"version":1,"toolchains":{"project-jdk":{"type":"java"},"project-gradle":{"type":"gradle","java":"project-jdk"}}}"#,
    )
    .unwrap();

    for (provider, id) in [
        ("npm.script", "npm.script:node/dev"),
        ("compose.service", "compose.service:database"),
        ("procfile.process", "procfile.process:worker"),
        ("python.script", "python.script:python/python-app"),
        ("cargo.binary", "cargo.binary:rust/rust-app"),
        ("go.main", "go.main:go/go"),
        ("gradle.application", "gradle.application:gradle/run"),
        ("make.target", "make.target:serve"),
        ("just.recipe", "just.recipe:watch"),
    ] {
        assert!(
            configurations
                .iter()
                .any(|item| item["provider"] == provider),
            "missing provider {provider} in {configurations:?}"
        );
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::json!({
                "id": format!("plan-{provider}"),
                "command": "runConfig.createLaunchPlan",
                "payload": {"root": root, "configurationId": id}
            })
            .to_string(),
        ))
        .unwrap();
        assert_eq!(
            response["ok"], true,
            "{provider} launch plan failed: {response}"
        );
    }

    fs::remove_dir_all(root).unwrap();
}

/// Ids are the join key for the team and local override layers. A detector
/// that renamed a Java configuration would silently detach every override
/// written against it, with no error anywhere.
#[test]
fn detectors_never_claim_an_id_the_java_scan_already_produced() {
    let root = temporary_root("detect-no-clobber");
    fs::create_dir_all(&root).unwrap();
    multi_language_project(&root);
    fs::create_dir_all(root.join("src")).unwrap();
    fs::write(
        root.join("src/Main.java"),
        "class Main { public static void main(String[] args) {} }",
    )
    .unwrap();

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate-with-java",
            "command": "runConfig.generate",
            "payload": {"root": root, "paths": ["src/Main.java"]}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    let ids = response["data"]["generated"]["configurations"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    let mut unique = ids.clone();
    unique.sort();
    unique.dedup();

    assert_eq!(ids.len(), unique.len(), "duplicate ids in {ids:?}");
    assert!(ids.contains(&"current-file".to_string()));

    fs::remove_dir_all(root).unwrap();
}

/// A Java project that also ships a frontend must gain the frontend's
/// services without any Java configuration changing id. Ids are the join key
/// for the team and local layers, so a shifted id detaches every override
/// silently -- there is no error to notice.
#[test]
fn detectors_extend_a_java_project_without_disturbing_its_configurations() {
    let root = temporary_root("detect-java-mixed");
    let module = root.join("backend-api/src/main/java/com/demo");
    fs::create_dir_all(&module).unwrap();
    fs::create_dir_all(root.join("frontend-web")).unwrap();
    fs::write(
        root.join("pom.xml"),
        "<project><modules><module>backend-api</module></modules></project>",
    )
    .unwrap();
    fs::write(
        module.join("BackendApplication.java"),
        "package com.demo;\n\npublic class BackendApplication { public static void main(String[] a) {} }\n",
    )
    .unwrap();
    fs::write(
        root.join("frontend-web/package.json"),
        r#"{"name":"web","scripts":{"dev":"vite"}}"#,
    )
    .unwrap();

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate",
            "command": "runConfig.generate",
            "payload": {
                "root": root,
                "paths": ["backend-api/src/main/java/com/demo/BackendApplication.java"]
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    let configurations = response["data"]["generated"]["configurations"]
        .as_array()
        .unwrap();
    let ids = configurations
        .iter()
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();

    assert!(
        ids.contains(&"java-main:com.demo.BackendApplication".to_string()),
        "{ids:?}"
    );
    assert!(
        ids.contains(&"npm.script:frontend-web/dev".to_string()),
        "{ids:?}"
    );
    // The Java entries stay toolchain-backed; only the detected ones are
    // process-based. A regression here would send npm through Java.
    let java = configurations
        .iter()
        .find(|item| item["id"] == "java-main:com.demo.BackendApplication")
        .unwrap();
    assert!(java["command"].is_null());
    assert_eq!(java["toolchains"]["java"], "project-jdk");
    // Source scanning retains the declared main class without a build framework.
    assert_eq!(
        java["extensions"]["java"]["mainClass"],
        "com.demo.BackendApplication"
    );

    fs::remove_dir_all(root).unwrap();
}

/// `src/bin/*.rs` is Cargo's conventional layout for a package with several
/// binaries, and nothing in the manifest mentions those targets. Missing them
/// leaves the Cargo tree showing binaries that have no way to run.
#[test]
fn cargo_detector_finds_binaries_under_src_bin() {
    let root = temporary_root("detect-cargo-src-bin");
    fs::create_dir_all(root.join("src/bin/packer")).unwrap();
    fs::write(
        root.join("Cargo.toml"),
        "[package]\nname = \"tools\"\nversion = \"0.1.0\"\n",
    )
    .unwrap();
    fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();
    fs::write(root.join("src/bin/scanner.rs"), "fn main() {}\n").unwrap();
    // A directory binary is named after the directory, not after `main.rs`.
    fs::write(root.join("src/bin/packer/main.rs"), "fn main() {}\n").unwrap();
    // Non-Rust files in the same directory are not targets.
    fs::write(root.join("src/bin/notes.txt"), "ignored\n").unwrap();

    let configurations = generated_configurations(&root);
    let ids: Vec<_> = configurations
        .iter()
        .filter(|item| item["provider"] == "cargo.binary")
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(
        ids,
        vec![
            "cargo.binary:packer",
            "cargo.binary:scanner",
            "cargo.binary:tools"
        ]
    );

    let scanner = configurations
        .iter()
        .find(|item| item["id"] == "cargo.binary:scanner")
        .unwrap();
    assert_eq!(scanner["command"], "cargo");
    assert_eq!(
        scanner["args"],
        serde_json::json!(["run", "--package", "tools", "--bin", "scanner"])
    );

    fs::remove_dir_all(root).unwrap();
}

/// Cargo keeps discovering `src/bin` after a `[[bin]]` section appears, so
/// treating a declaration as an opt-out would drop the conventional targets of
/// any package that declares one custom path.
#[test]
fn cargo_detector_unions_declared_and_discovered_binaries() {
    let root = temporary_root("detect-cargo-union");
    fs::create_dir_all(root.join("src/bin")).unwrap();
    fs::write(
        root.join("Cargo.toml"),
        "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n\
         [[bin]]\nname = \"custom\"\npath = \"other/entry.rs\"\n",
    )
    .unwrap();
    fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();
    fs::write(root.join("src/bin/helper.rs"), "fn main() {}\n").unwrap();

    let ids: Vec<_> = generated_configurations(&root)
        .into_iter()
        .filter(|item| item["provider"] == "cargo.binary")
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(
        ids,
        vec![
            "cargo.binary:app",
            "cargo.binary:custom",
            "cargo.binary:helper"
        ]
    );

    fs::remove_dir_all(root).unwrap();
}

/// `autobins = false` is the manifest's explicit statement that only declared
/// targets exist. Discovering anyway would offer binaries Cargo will not build.
#[test]
fn cargo_detector_honours_autobins_opt_out() {
    let root = temporary_root("detect-cargo-autobins");
    fs::create_dir_all(root.join("src/bin")).unwrap();
    fs::write(
        root.join("Cargo.toml"),
        "[package]\nname = \"app\"\nversion = \"0.1.0\"\nautobins = false\n\n\
         [[bin]]\nname = \"custom\"\npath = \"other/entry.rs\"\n",
    )
    .unwrap();
    fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();
    fs::write(root.join("src/bin/helper.rs"), "fn main() {}\n").unwrap();

    let ids: Vec<_> = generated_configurations(&root)
        .into_iter()
        .filter(|item| item["provider"] == "cargo.binary")
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(ids, vec!["cargo.binary:custom"]);

    fs::remove_dir_all(root).unwrap();
}

/// A Gradle application is runnable through its declared application plugin.
#[test]
fn gradle_detector_finds_an_application() {
    let root = temporary_root("detect-gradle-boot");
    fs::create_dir_all(&root).unwrap();
    fs::write(
        root.join("build.gradle"),
        "plugins {\n  id 'application' version '3.2.0'\n  id 'java'\n}\n",
    )
    .unwrap();

    let boot = generated_configurations(&root)
        .into_iter()
        .find(|item| item["id"] == "gradle.application:run")
        .unwrap();

    assert_eq!(boot["command"], "gradle");
    assert_eq!(boot["args"], serde_json::json!(["run"]));
    assert_eq!(boot["execution"], "application");
    assert_eq!(boot["cwd"], ".");
    assert_eq!(boot["source"], "build.gradle");

    fs::remove_dir_all(root).unwrap();
}

/// The Kotlin DSL is the current Gradle default, so matching only Groovy syntax
/// would miss newly generated projects.
#[test]
fn gradle_detector_reads_the_kotlin_dsl() {
    let root = temporary_root("detect-gradle-kts");
    fs::create_dir_all(&root).unwrap();
    fs::write(
        root.join("build.gradle.kts"),
        "plugins {\n  id(\"application\") version \"3.2.0\"\n}\n",
    )
    .unwrap();

    let boot = generated_configurations(&root)
        .into_iter()
        .find(|item| item["id"] == "gradle.application:run")
        .unwrap();
    assert_eq!(boot["execution"], "application");
    assert_eq!(boot["source"], "build.gradle.kts");

    fs::remove_dir_all(root).unwrap();
}

/// Gradle resolves task paths from the directory holding the settings file, so a
/// subproject task cannot run from the subproject directory. Getting this wrong
/// produces an entry that fails at spawn time with a task-not-found error.
#[test]
fn gradle_detector_runs_subproject_tasks_from_the_build_root() {
    let root = temporary_root("detect-gradle-multi");
    fs::create_dir_all(root.join("services/orders")).unwrap();
    fs::create_dir_all(root.join("services/shipping")).unwrap();
    fs::write(
        root.join("settings.gradle"),
        "include 'services:orders', 'services:shipping'\n",
    )
    .unwrap();
    fs::write(
        root.join("services/orders/build.gradle"),
        "plugins {\n  id 'application'\n}\n",
    )
    .unwrap();
    fs::write(
        root.join("services/shipping/build.gradle"),
        "apply plugin: 'application'\n",
    )
    .unwrap();

    let configurations = generated_configurations(&root);
    let orders = configurations
        .iter()
        .find(|item| item["id"] == "gradle.application:services:orders")
        .unwrap_or_else(|| {
            panic!(
                "missing orders service in {:?}",
                configurations
                    .iter()
                    .map(|item| item["id"].as_str().unwrap())
                    .collect::<Vec<_>>()
            )
        });

    assert_eq!(orders["args"], serde_json::json!([":services:orders:run"]));
    assert_eq!(orders["cwd"], ".");
    assert_eq!(orders["execution"], "application");

    let shipping = configurations
        .iter()
        .find(|item| item["id"] == "gradle.application:services:shipping")
        .unwrap();
    assert_eq!(
        shipping["args"],
        serde_json::json!([":services:shipping:run"])
    );
    // The `application` plugin starts a program, not a long-running service.
    assert_eq!(shipping["execution"], "application");

    fs::remove_dir_all(root).unwrap();
}

/// Identity is `(cwd, name)`, and every subproject task shares the build root as
/// its cwd. Two modules with the same leaf name must still be two services: dedup
/// drops the loser silently, so a collision here removes a service with no error.
#[test]
fn gradle_detector_keeps_same_named_modules_under_different_parents() {
    let root = temporary_root("detect-gradle-collision");
    fs::create_dir_all(root.join("internal/orders")).unwrap();
    fs::create_dir_all(root.join("public/orders")).unwrap();
    fs::write(root.join("settings.gradle"), "include 'internal:orders'\n").unwrap();
    for module in ["internal/orders", "public/orders"] {
        fs::write(
            root.join(module).join("build.gradle"),
            "plugins {\n  id 'application'\n}\n",
        )
        .unwrap();
    }

    let arguments = generated_configurations(&root)
        .iter()
        .filter(|item| item["provider"] == "gradle.application")
        .map(|item| item["args"][0].as_str().unwrap().to_string())
        .collect::<Vec<_>>();

    assert!(
        arguments.contains(&":internal:orders:run".to_string()),
        "{arguments:?}"
    );
    assert!(
        arguments.contains(&":public:orders:run".to_string()),
        "{arguments:?}"
    );

    fs::remove_dir_all(root).unwrap();
}

/// A build file with no start-task plugin has nothing runnable to offer. Listing
/// a `run` task that does not exist is worse than listing nothing.
#[test]
fn gradle_detector_ignores_builds_without_a_start_task() {
    let root = temporary_root("detect-gradle-library");
    fs::create_dir_all(&root).unwrap();
    fs::write(
        root.join("build.gradle"),
        "plugins {\n  id 'java-library'\n}\n",
    )
    .unwrap();

    let providers = generated_configurations(&root)
        .iter()
        .filter_map(|item| item["provider"].as_str().map(str::to_string))
        .collect::<Vec<_>>();

    assert!(
        !providers.iter().any(|value| value.starts_with("gradle.")),
        "{providers:?}"
    );

    fs::remove_dir_all(root).unwrap();
}

/// A commented-out plugin is not applied. Matching it would offer a task the
/// build cannot run.
#[test]
fn gradle_detector_ignores_commented_plugins() {
    let root = temporary_root("detect-gradle-comment");
    fs::create_dir_all(&root).unwrap();
    fs::write(
        root.join("build.gradle"),
        "plugins {\n  // id 'application'\n  id 'java-library'\n}\n",
    )
    .unwrap();

    let providers = generated_configurations(&root)
        .iter()
        .filter_map(|item| item["provider"].as_str().map(str::to_string))
        .collect::<Vec<_>>();

    assert!(
        !providers.iter().any(|value| value.starts_with("gradle.")),
        "{providers:?}"
    );

    fs::remove_dir_all(root).unwrap();
}

/// Gradle consumes a JDK but remains a process command until every host provides
/// a Gradle registry. Binding a synthetic Gradle toolchain would block PATH-based
/// execution on hosts that cannot discover or configure it.
#[test]
fn gradle_projects_require_a_jdk_without_replacing_the_path_command() {
    let root = temporary_root("detect-gradle-toolchain");
    fs::create_dir_all(&root).unwrap();
    fs::write(
        root.join("build.gradle"),
        "plugins {\n  id 'application'\n}\n",
    )
    .unwrap();
    fs::write(root.join("gradlew"), "#!/bin/sh\n").unwrap();

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate",
            "command": "runConfig.generate",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    let toolchains = &response["data"]["toolchainRequirements"]["toolchains"];

    assert!(toolchains["project-gradle"].is_null(), "{toolchains}");
    // Kotlin and Groovy sources mean a Gradle build can need a JDK with no
    // `.java` file anywhere in the project.
    assert_eq!(toolchains["project-jdk"]["type"], "java");
    let configuration = response["data"]["generated"]["configurations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["provider"] == "gradle.application")
        .unwrap();
    assert_eq!(configuration["command"], "gradle");
    assert_eq!(configuration["toolchains"]["java"], "project-jdk");
    assert!(configuration["toolchains"]["runtime"].is_null());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn nested_gradle_service_declares_the_jdk_requirement_from_its_consumer() {
    let root = temporary_root("detect-nested-gradle-toolchain");
    fs::create_dir_all(root.join("services/orders")).unwrap();
    fs::write(root.join("settings.gradle"), "include 'services:orders'\n").unwrap();
    fs::write(
        root.join("services/orders/build.gradle"),
        "plugins {\n  id 'application'\n}\n",
    )
    .unwrap();

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate-nested-gradle",
            "command": "runConfig.generate",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    let toolchains = &response["data"]["toolchainRequirements"]["toolchains"];
    assert_eq!(toolchains["project-jdk"]["type"], "java", "{response}");
    assert!(toolchains["project-gradle"].is_null(), "{response}");

    fs::remove_dir_all(root).unwrap();
}

/// The panel needs to say *what* a service is, not just that a script exists.
/// The framework comes from the declared dependencies, which is the only place
/// a JavaScript project states it.
#[test]
fn npm_detector_names_the_framework_from_the_dependencies() {
    let root = temporary_root("detect-npm-framework");
    fs::create_dir_all(&root).unwrap();
    fs::write(
        root.join("package.json"),
        r#"{"dependencies":{"vue":"^3.4.0"},"devDependencies":{"vite":"^5.0.0"},"scripts":{"dev":"vite"}}"#,
    )
    .unwrap();

    let dev = generated_configurations(&root)
        .into_iter()
        .find(|item| item["id"] == "npm.script:dev")
        .unwrap();

    assert_eq!(dev["extensions"]["npm"]["framework"], "vue");
    assert_eq!(dev["extensions"]["npm"]["server"], "vite");
    assert_eq!(dev["execution"], "service");
    // Reading the script body is real evidence, unlike matching the name `dev`.
    assert_eq!(dev["confidence"], "declared");

    fs::remove_dir_all(root).unwrap();
}

/// A meta-framework depends on the framework it is built on, so a Nuxt app
/// declares Vue as well. Reporting `vue` there is true and useless.
#[test]
fn npm_detector_prefers_the_most_specific_framework() {
    let root = temporary_root("detect-npm-meta-framework");
    for (directory, manifest) in [
        (
            "web",
            r#"{"dependencies":{"nuxt":"^3.11.0","vue":"^3.4.0"},"scripts":{"dev":"nuxt dev"}}"#,
        ),
        (
            "site",
            r#"{"dependencies":{"next":"^14.2.0","react":"^18.3.0"},"scripts":{"dev":"next dev"}}"#,
        ),
        (
            "app",
            r#"{"devDependencies":{"@sveltejs/kit":"^2.5.0","svelte":"^4.2.0"},"scripts":{"dev":"vite dev"}}"#,
        ),
    ] {
        fs::create_dir_all(root.join(directory)).unwrap();
        fs::write(root.join(directory).join("package.json"), manifest).unwrap();
    }

    let configurations = generated_configurations(&root);
    let framework = |id: &str| {
        configurations
            .iter()
            .find(|item| item["id"] == id)
            .and_then(|item| item["extensions"]["npm"]["framework"].as_str())
    };

    assert_eq!(framework("npm.script:web/dev"), Some("nuxt"));
    assert_eq!(framework("npm.script:site/dev"), Some("next"));
    assert_eq!(framework("npm.script:app/dev"), Some("sveltekit"));

    fs::remove_dir_all(root).unwrap();
}

/// Script names are a convention, not a declaration. What the script actually
/// runs decides whether it is a service, so a `start` that builds is a task and
/// a `local` that serves is a service.
#[test]
fn npm_detector_classifies_scripts_by_what_they_run() {
    let root = temporary_root("detect-npm-script-bodies");
    fs::create_dir_all(&root).unwrap();
    fs::write(
        root.join("package.json"),
        r#"{"scripts":{
            "start":"tsc -p .",
            "local":"NODE_ENV=development npx vite --port 3000",
            "api":"nodemon src/index.js",
            "staged":"rimraf dist && vite build",
            "e2e":"vite build && vite preview"
        }}"#,
    )
    .unwrap();

    let configurations = generated_configurations(&root);
    let execution = |id: &str| {
        configurations
            .iter()
            .find(|item| item["id"] == id)
            .and_then(|item| item["execution"].as_str())
    };

    // A build tool named `start` is still a build.
    assert_eq!(execution("npm.script:start"), Some("task"));
    // Environment assignments and `npx` wrap the program without changing it.
    assert_eq!(execution("npm.script:local"), Some("service"));
    assert_eq!(execution("npm.script:api"), Some("service"));
    // `vite build` terminates; only the serving subcommands are services.
    assert_eq!(execution("npm.script:staged"), Some("task"));
    // A script that prepares and then serves is still a service.
    assert_eq!(execution("npm.script:e2e"), Some("service"));

    fs::remove_dir_all(root).unwrap();
}

/// When a script shells out to something unrecognised the name is all there is,
/// so the guess stays available but is marked `Heuristic`. Dedup then lets any
/// detector holding real evidence for the same service win.
#[test]
fn npm_detector_demotes_service_names_it_cannot_verify() {
    let root = temporary_root("detect-npm-heuristic");
    fs::create_dir_all(&root).unwrap();
    fs::write(
        root.join("package.json"),
        r#"{"scripts":{"dev":"./scripts/dev.sh","build":"./scripts/build.sh"}}"#,
    )
    .unwrap();
    fs::write(root.join("Procfile"), "dev: python worker.py\n").unwrap();

    let configurations = generated_configurations(&root);
    let build = configurations
        .iter()
        .find(|item| item["id"] == "npm.script:build")
        .unwrap();
    assert_eq!(build["execution"], "task");

    // The Procfile declares the command for `dev`, so it outranks the guess the
    // script name supports. Both share an identity of (cwd, name).
    let dev = configurations
        .iter()
        .filter(|item| item["name"] == "dev")
        .collect::<Vec<_>>();
    assert_eq!(dev.len(), 1, "{configurations:?}");
    assert_eq!(dev[0]["provider"], "procfile.process");
    assert_eq!(dev[0]["command"], "python");

    fs::remove_dir_all(root).unwrap();
}

/// Starlette and Litestar applications are served the same way FastAPI ones are,
/// and the panel needs the framework name to label them apart.
#[test]
fn python_detector_names_asgi_frameworks_it_serves_through_uvicorn() {
    let root = temporary_root("detect-python-asgi");
    for (directory, source) in [
        (
            "edge",
            "from starlette.applications import Starlette\napp = Starlette()\n",
        ),
        (
            "orders",
            "from litestar import Litestar\napp = Litestar()\n",
        ),
    ] {
        fs::create_dir_all(root.join(directory)).unwrap();
        fs::write(root.join(directory).join("asgi.py"), source).unwrap();
    }

    let configurations = generated_configurations(&root);
    let framework = |id: &str| {
        configurations
            .iter()
            .find(|item| item["id"] == id)
            .and_then(|item| item["extensions"]["python"]["framework"].as_str())
    };

    assert_eq!(framework("python.uvicorn:edge/asgi"), Some("starlette"));
    assert_eq!(framework("python.uvicorn:orders/asgi"), Some("litestar"));
    let edge = configurations
        .iter()
        .find(|item| item["id"] == "python.uvicorn:edge/asgi")
        .unwrap();
    assert_eq!(edge["command"], "uvicorn");
    assert_eq!(edge["args"], serde_json::json!(["asgi:app", "--reload"]));
    assert_eq!(edge["execution"], "service");

    fs::remove_dir_all(root).unwrap();
}

/// Which file holds the application is a guess, but the framework itself is
/// declared. A project that lists its framework gets `Declared`, so the entry
/// survives against a lower-confidence detection of the same service.
#[test]
fn python_detector_trusts_a_declared_framework_over_a_bare_file_name() {
    let root = temporary_root("detect-python-declared");
    for (directory, files) in [
        (
            "declared",
            vec![
                ("pyproject.toml", "[project]\nname = \"declared\"\ndependencies = [\"fastapi>=0.110\", \"uvicorn[standard]\"]\n"),
                ("main.py", "from fastapi import FastAPI\napp = FastAPI()\n"),
            ],
        ),
        (
            "guessed",
            vec![("main.py", "from fastapi import FastAPI\napp = FastAPI()\n")],
        ),
        (
            "pinned",
            vec![
                ("requirements.txt", "# runtime\nflask==3.0.2\ngunicorn\n"),
                ("app.py", "from flask import Flask\napp = Flask(__name__)\n"),
            ],
        ),
    ] {
        fs::create_dir_all(root.join(directory)).unwrap();
        for (file, source) in files {
            fs::write(root.join(directory).join(file), source).unwrap();
        }
    }

    let configurations = generated_configurations(&root);
    let confidence = |id: &str| {
        configurations
            .iter()
            .find(|item| item["id"] == id)
            .and_then(|item| item["confidence"].as_str())
    };

    assert_eq!(confidence("python.uvicorn:declared/main"), Some("declared"));
    // No dependency list means the framework import in one file is all there is.
    assert_eq!(confidence("python.uvicorn:guessed/main"), Some("heuristic"));
    // A requirements file is a declaration too, version specifier and all.
    assert_eq!(confidence("python.flask:pinned/app"), Some("declared"));

    fs::remove_dir_all(root).unwrap();
}

/// Django's entry point is `manage.py` by convention, so the framework name is
/// what tells the panel this is a Django service rather than a loose script.
#[test]
fn python_detector_labels_a_declared_django_project() {
    let root = temporary_root("detect-python-django");
    fs::create_dir_all(&root).unwrap();
    fs::write(
        root.join("pyproject.toml"),
        "[tool.poetry]\nname = \"site\"\n[tool.poetry.dependencies]\ndjango = \"^5.0\"\n",
    )
    .unwrap();
    fs::write(root.join("manage.py"), "import django\n").unwrap();

    let runserver = generated_configurations(&root)
        .into_iter()
        .find(|item| item["id"] == "python.django:runserver")
        .unwrap();

    assert_eq!(runserver["extensions"]["python"]["framework"], "django");
    assert_eq!(runserver["confidence"], "declared");
    assert_eq!(runserver["execution"], "service");

    fs::remove_dir_all(root).unwrap();
}
