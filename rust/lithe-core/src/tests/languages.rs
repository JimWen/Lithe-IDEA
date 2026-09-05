use super::support::temporary_root;
use crate::execute_json;
use serde_json::Value;
use std::fs;

#[test]
fn jdt_workspace_key_matches_the_shared_compatibility_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/lsp/jdt-workspace-key-v1.json"
    ))
    .expect("JDT workspace-key fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("JDT workspace-key fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "lsp.jdtWorkspaceKey",
            "payload": {
                "workspaceRoot": case["workspaceRoot"],
                "workspaceFingerprint": case["workspaceFingerprint"]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("JDT workspace-key response should be JSON");

        assert_eq!(response["ok"], true, "case {}", case["name"]);
        assert_eq!(
            response["data"]["workspaceKey"], case["workspaceKey"],
            "case {}",
            case["name"]
        );
    }
}

#[test]
fn java_workspace_policy_matches_the_shared_compatibility_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/lsp/java-workspace-policy-v1.json"
    ))
    .expect("Java workspace-policy fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("Java workspace-policy fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "java.workspacePolicy",
            "payload": {
                "workspacePaths": case["workspacePaths"],
                "changedPaths": case["changedPaths"]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("Java workspace-policy response should be JSON");

        assert_eq!(response["ok"], true, "case {}", case["name"]);
        assert_eq!(response["data"], case["expected"], "case {}", case["name"]);
    }
}

#[test]
fn jdt_workspace_fingerprint_matches_the_shared_compatibility_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/lsp/jdt-workspace-fingerprint-v1.json"
    ))
    .expect("JDT workspace-fingerprint fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("JDT workspace-fingerprint fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "java.jdtWorkspaceFingerprint",
            "payload": {
                "buildFiles": case["buildFiles"],
                "jdtlsVersion": case["jdtlsVersion"]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("JDT workspace-fingerprint response should be JSON");

        assert_eq!(response["ok"], true, "case {}", case["name"]);
        assert_eq!(
            response["data"]["workspaceFingerprint"], case["workspaceFingerprint"],
            "case {}",
            case["name"]
        );
    }
}

#[test]
fn jdt_cache_retention_matches_the_shared_compatibility_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/lsp/jdt-cache-retention-v1.json"
    ))
    .expect("JDT cache-retention fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("JDT cache-retention fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "java.jdtCacheRetention",
            "payload": {
                "nowUnixSeconds": case["nowUnixSeconds"],
                "activeWorkspaceKey": case["activeWorkspaceKey"],
                "entries": case["entries"]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("JDT cache-retention response should be JSON");

        assert_eq!(response["ok"], true, "case {}", case["name"]);
        assert_eq!(response["data"], case["expected"], "case {}", case["name"]);
    }
}

#[test]
fn java_run_configurations_match_workspace_relative_nested_modules() {
    let root = temporary_root("java-nested-module");
    let source = "projects/demo/service/src/main/java/com/example/App.java";
    fs::create_dir_all(root.join("projects/demo/service/src/main/java/com/example"))
        .expect("nested Java source directory should be creatable");
    fs::write(
        root.join(source),
        "package com.example;  class App { public static void main(String[] args) {} }",
    )
    .expect("nested Java source should be writable");

    let request = serde_json::json!({
        "id": "java-nested-module",
        "command": "java.runConfigurations",
        "payload": {
            "root": root,
            "paths": [source],
            "modulePaths": ["projects/demo/service"]
        }
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("Java request should encode"),
    ))
    .expect("Java response should be JSON");

    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(
        response["data"]["configurations"][0]["modulePath"],
        "projects/demo/service"
    );
    fs::remove_dir_all(root).expect("Java fixture should be removable");
}

#[test]
fn java_core_commands_return_shared_runtime_and_structure_data() {
    let root = temporary_root("java");
    fs::create_dir_all(root.join("src/main/java/com/example"))
        .expect("Java source should be creatable");
    fs::write(
        root.join("src/main/java/com/example/App.java"),
        "package com.example;\n\nclass App {\n    static void main(String[] args) {}\n}\n",
    )
    .expect("Java source should be writable");
    let configurations = serde_json::json!({
        "id": "java-config",
        "command": "java.runConfigurations",
        "payload": {
            "root": root,
            "paths": ["src/main/java/com/example/App.java"],
            "modulePaths": ["src"]
        }
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&configurations).expect("Java request should encode"),
    ))
    .expect("Java response should be JSON");
    assert_eq!(response["ok"], true);
    assert_eq!(
        response["data"]["mainClasses"][0]["qualifiedName"],
        "com.example.App"
    );
    assert_eq!(response["data"]["configurations"][0]["kind"], "javaMain");
    assert_eq!(response["data"]["configurations"][0]["modulePath"], "src");
    assert_eq!(
        response["data"]["configurations"][0]["sourcePath"],
        "src/main/java/com/example/App.java"
    );
    assert_eq!(response["data"]["configurations"][0]["sourceSet"], "main");

    let structure = serde_json::json!({
        "id": "java-structure",
        "command": "java.structure",
        "payload": {
            "source": "import a.A;\nimport b.B;\ninterface Service { String call(String value); }\n"
        }
    });
    let structure_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&structure).expect("Java structure request should encode"),
    ))
    .expect("Java structure response should be JSON");
    assert_eq!(structure_response["ok"], true);
    assert_eq!(
        structure_response["data"]["foldRegions"][0]["kind"],
        "imports"
    );
    assert!(structure_response["data"]
        .get("implementationMarkers")
        .is_none());
    let syntax_highlights = structure_response["data"]["syntaxHighlights"]
        .as_array()
        .expect("Java structure should return syntax highlights");
    assert!(syntax_highlights
        .iter()
        .any(|highlight| highlight["role"] == "keyword"));
    for role in ["functionDeclaration", "parameter", "punctuation", "type"] {
        assert!(
            syntax_highlights
                .iter()
                .any(|highlight| highlight["role"] == role),
            "Java structure should include the {role} role"
        );
    }
    assert!(syntax_highlights.iter().all(|highlight| {
        highlight["utf16Start"].as_u64().is_some()
            && highlight["utf16Length"]
                .as_u64()
                .is_some_and(|length| length > 0)
    }));
    let swift_structure = serde_json::json!({
        "id": "swift-structure",
        "command": "java.structure",
        "payload": {
            "source": "struct Demo {\n    func run() {\n        if ready {\n            work()\n        }\n    }\n}\n"
        }
    });
    let swift_structure_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&swift_structure).expect("Swift structure request should encode"),
    ))
    .expect("Swift structure response should be JSON");
    let swift_folds = swift_structure_response["data"]["foldRegions"]
        .as_array()
        .expect("Swift structure should return fold regions");
    assert!(swift_folds
        .iter()
        .any(|fold| { fold["startLine"] == 0 && fold["endLine"] == 6 && fold["kind"] == "type" }));
    assert!(swift_folds.iter().any(|fold| {
        fold["startLine"] == 1 && fold["endLine"] == 5 && fold["kind"] == "method"
    }));
    let code_vision = serde_json::json!({
        "id": "java-vision",
        "command": "java.codeVision",
        "payload": {
            "root": root,
            "targetPath": "src/main/java/com/example/App.java",
            "paths": ["src/main/java/com/example/App.java"]
        }
    });
    let vision_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&code_vision).expect("code vision request should encode"),
    ))
    .expect("code vision response should be JSON");
    assert_eq!(vision_response["ok"], true);
    assert!(vision_response["data"]["hints"]
        .as_array()
        .unwrap()
        .iter()
        .any(|hint| hint["symbol"] == "App"));
    let class_name = serde_json::json!({
        "id": "java-class",
        "command": "java.className",
        "payload": {"source": "package com.example;\nclass App {}", "simpleName": "App"}
    });
    let class_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&class_name).expect("class name request should encode"),
    ))
    .expect("class name response should be JSON");
    assert_eq!(class_response["data"]["className"], "com.example.App");
    let definition = serde_json::json!({
        "id": "java-definition",
        "command": "java.sourceDefinition",
        "payload": {
            "source": "class App {\n    void run() {}\n}",
            "declarationName": "App",
            "memberName": "run"
        }
    });
    let definition_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&definition).expect("definition request should encode"),
    ))
    .expect("definition response should be JSON");
    assert_eq!(definition_response["data"]["line"], 1);
    fs::remove_dir_all(root).expect("Java fixture should be removable");
}
