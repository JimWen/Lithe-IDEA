use crate::{execute_json, ErrorCode};
use serde_json::{json, Value};

fn fixture() -> Value {
    serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/fixtures/execution/project-metadata-v1.json"
    )))
    .unwrap()
}

fn payload(language: &str, fixture: &Value) -> Value {
    let mut value = json!({"language":language, "workspaceDirectory":fixture["workspaceDirectory"], "roots":fixture["roots"]});
    if language == "rust" {
        value["cargoMetadata"] = json!(fixture["cargo"].to_string());
    } else {
        value["goModules"] = json!(stream(&fixture["goModules"]));
        value["goPackages"] = json!(stream(&fixture["goPackages"]));
    }
    value
}

fn stream(values: &Value) -> String {
    values
        .as_array()
        .unwrap()
        .iter()
        .map(Value::to_string)
        .collect::<Vec<_>>()
        .join("\n")
}

fn call(payload: Value) -> Value {
    serde_json::from_str(&execute_json(&json!({"id":"project-metadata-test", "command":"execution.normalizeProjectMetadata", "payload":payload}).to_string())).unwrap()
}

fn success(payload: Value) -> Value {
    let response = call(payload);
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["id"], "project-metadata-test");
    response["data"].clone()
}

fn failure(payload: Value, code: &str) {
    let response = call(payload);
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error"]["code"], code, "{response}");
    assert!(
        response.get("data").is_none(),
        "A broken item must not return a partial tree"
    );
}

fn member<'a>(data: &'a Value, name: &str) -> &'a Value {
    data["members"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["name"] == name)
        .unwrap()
}

fn target<'a>(member: &'a Value, name: &str) -> &'a Value {
    member["targets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["name"] == name)
        .unwrap()
}

#[test]
fn cargo_metadata_preserves_workspace_defaults_and_target_semantics() {
    let fixture = fixture();
    let result = success(payload("rust", &fixture));
    assert_eq!(result["version"], 1);
    assert_eq!(result["members"].as_array().unwrap().len(), 2);
    let alpha = member(&result, "alpha");
    let beta = member(&result, "beta");
    assert_eq!(alpha["id"], fixture["expected"]["cargoMemberIDs"]["alpha"]);
    assert_eq!(beta["id"], fixture["expected"]["cargoMemberIDs"]["beta"]);
    assert_eq!(result["defaultMemberIDs"], json!([alpha["id"]]));
    assert_eq!(alpha["defaultRun"], "tool");
    assert_ne!(target(alpha, "tool")["id"], target(beta, "tool")["id"]);
    for (name, runnable, testable) in [
        ("tool", true, true),
        ("alpha", false, true),
        ("sample", true, true),
        ("sample_lib", false, true),
        ("integration", false, true),
        ("speed", false, true),
        ("build-script-build", false, false),
        ("future", false, false),
    ] {
        let value = target(alpha, name);
        assert_eq!(value["runnable"], runnable, "{name}");
        assert_eq!(value["testable"], testable, "{name}");
    }
    assert_eq!(target(alpha, "alpha")["kind"], "lib");
    assert_eq!(target(alpha, "alpha")["doctest"], true);
    assert_eq!(
        target(alpha, "alpha")["rawKinds"],
        json!(["cdylib", "rlib"])
    );
    assert_eq!(target(alpha, "sample")["requiredFeatures"], json!(["fast"]));
    assert_eq!(
        target(alpha, "tool")["sources"][0]["location"],
        json!({"rootID":"workspace","relativePath":"alpha/entry.rs"})
    );
    assert_eq!(
        alpha["dependencies"][0],
        json!({"name":"external-lib","rename":"local_lib","versionReq":"^1.0","kind":"dev","optional":true,"defaultFeatures":false,"features":["extras"],"target":"cfg(unix)","location":{"rootID":"external","relativePath":"lib"}})
    );
    assert!(!result.to_string().contains("/fixture/"));
    assert!(!result.to_string().contains("opaque-"));
}

#[test]
fn go_metadata_groups_modules_sources_and_incomplete_diagnostics() {
    let fixture = fixture();
    let result = success(payload("go", &fixture));
    for name in ["example.invalid/alpha", "example.invalid/beta"] {
        assert_eq!(
            member(&result, name)["id"],
            fixture["expected"]["goMemberIDs"][name]
        );
    }
    let alpha = member(&result, "example.invalid/alpha");
    assert_eq!(alpha["targets"].as_array().unwrap().len(), 3);
    let packages = alpha["targets"].as_array().unwrap();
    let root = &packages[0];
    assert_eq!(root["importPath"], "example.invalid/alpha");
    assert_eq!(root["runnable"], true);
    assert_eq!(root["imports"], json!(["fmt"]));
    assert_eq!(root["sources"].as_array().unwrap().len(), 6);
    assert!(root["sources"]
        .as_array()
        .unwrap()
        .iter()
        .any(|source| source["location"]["relativePath"] == "alpha/入口.go"));
    assert_eq!(packages[1]["incomplete"], true);
    assert_eq!(packages[1]["runnable"], false);
    assert_eq!(packages[1]["diagnostics"][0]["code"], "dependencyError");
    let details: Value =
        serde_json::from_str(packages[1]["diagnostics"][0]["details"].as_str().unwrap()).unwrap();
    assert_eq!(details["Pos"], "broken.go:3:2");
    assert_eq!(packages[2]["importPath"], "example.invalid/alpha/foo.test");
    assert_eq!(
        packages[2]["runnable"], true,
        "A real .test suffix is not synthetic"
    );
    assert_eq!(result["diagnostics"][0]["code"], "packageError");
    assert_eq!(result["diagnostics"][0]["importPath"], "unknown/...");
    assert_eq!(result["defaultMemberIDs"].as_array().unwrap().len(), 2);
}

#[test]
fn metadata_identity_ignores_versions_source_paths_and_input_order() {
    let original = fixture();
    let first = success(payload("rust", &original));
    let mut changed = original.clone();
    let packages = changed["cargo"]["packages"].as_array_mut().unwrap();
    packages.reverse();
    for package in packages {
        package["version"] = json!("9.9.9");
        package["targets"].as_array_mut().unwrap().reverse();
        for target in package["targets"].as_array_mut().unwrap() {
            target["src_path"] = json!("/fixture/workspace/renamed.rs");
            target["kind"].as_array_mut().unwrap().reverse();
        }
    }
    let second = success(payload("rust", &changed));
    for name in ["alpha", "beta"] {
        assert_eq!(member(&first, name)["id"], member(&second, name)["id"]);
        assert_eq!(
            member(&first, name)["targets"]
                .as_array()
                .unwrap()
                .iter()
                .map(|target| &target["id"])
                .collect::<Vec<_>>(),
            member(&second, name)["targets"]
                .as_array()
                .unwrap()
                .iter()
                .map(|target| &target["id"])
                .collect::<Vec<_>>()
        );
    }
    let first_go = success(payload("go", &original));
    changed["goModules"].as_array_mut().unwrap().reverse();
    changed["goPackages"].as_array_mut().unwrap().reverse();
    let second_go = success(payload("go", &changed));
    assert_eq!(first_go, second_go);
}

#[test]
fn cargo_rejects_dangling_defaults_duplicates_and_malformed_items_atomically() {
    let original = fixture();
    for default in [Value::Null, json!([])] {
        let mut fixture = original.clone();
        fixture["cargo"]["workspace_default_members"] = default.clone();
        assert_eq!(
            success(payload("rust", &fixture))["defaultMemberIDs"],
            default
        );
    }
    let mut absent = original.clone();
    absent["cargo"]
        .as_object_mut()
        .unwrap()
        .remove("workspace_default_members");
    assert_eq!(
        success(payload("rust", &absent))["defaultMemberIDs"],
        Value::Null
    );
    for case in 0..10 {
        let mut fixture = original.clone();
        match case {
            0 => fixture["cargo"]["workspace_default_members"] = json!(["absent"]),
            1 => {
                fixture["cargo"]["workspace_members"] =
                    json!(["opaque-alpha-v1", "opaque-alpha-v1"])
            }
            2 => {
                fixture["cargo"]["workspace_default_members"] =
                    json!(["opaque-alpha-v1", "opaque-alpha-v1"])
            }
            3 => fixture["cargo"]["packages"][0]["id"] = json!("opaque-alpha-v1"),
            4 => {
                fixture["cargo"]["packages"][0]["manifest_path"] =
                    fixture["cargo"]["packages"][1]["manifest_path"].clone()
            }
            5 => {
                let duplicate = fixture["cargo"]["packages"][1]["targets"][0].clone();
                fixture["cargo"]["packages"][1]["targets"]
                    .as_array_mut()
                    .unwrap()
                    .push(duplicate);
            }
            6 => fixture["cargo"]["packages"][0]["targets"][0]["test"] = json!("true"),
            7 => fixture["cargo"]["packages"][1]["default_run"] = json!("sample"),
            8 => fixture["cargo"]["version"] = json!(2),
            _ => {
                fixture["cargo"]["workspace_members"] = json!(["opaque-alpha-v1"]);
                fixture["cargo"]["workspace_default_members"] = json!(["opaque-beta-v1"]);
            }
        }
        failure(payload("rust", &fixture), "parse_failed");
    }
}

#[test]
fn go_rejects_stale_or_ambiguous_ownership_and_preserves_error_only_streams() {
    let original = fixture();
    for case in 0..8 {
        let mut fixture = original.clone();
        match case {
            0 => {
                let duplicate = fixture["goPackages"][0].clone();
                fixture["goPackages"]
                    .as_array_mut()
                    .unwrap()
                    .push(duplicate);
            }
            1 => fixture["goPackages"][0]["Module"] = fixture["goModules"][1].clone(),
            2 => fixture["goPackages"][0]["ImportPath"] = json!("another.invalid/wrong"),
            3 => fixture["goPackages"][0]["ForTest"] = json!("example.invalid/beta"),
            4 => {
                fixture["goPackages"][0]["ImportPath"] =
                    json!("example.invalid/beta [example.invalid/beta.test]")
            }
            5 => {
                fixture["goPackages"][0]
                    .as_object_mut()
                    .unwrap()
                    .remove("Module");
            }
            6 => fixture["goPackages"][0]["Dir"] = json!("/fixture/workspace-other/beta"),
            _ => fixture["goPackages"][0]["Name"] = json!(""),
        }
        failure(payload("go", &fixture), "parse_failed");
    }
    let mut only_errors = original.clone();
    only_errors["goModules"] = json!([{"Path":"broken","Error":{"Err":"invalid go.mod"}}]);
    only_errors["goPackages"] = json!([original["goPackages"][1]]);
    let result = success(payload("go", &only_errors));
    assert_eq!(result["members"], json!([]));
    assert_eq!(result["diagnostics"].as_array().unwrap().len(), 2);
    let mut partial = payload("go", &original);
    partial["goPackages"] = json!(format!(
        "{}{{\"Dir\":",
        partial["goPackages"].as_str().unwrap()
    ));
    failure(partial, "parse_failed");
    let mut error_directory = original.clone();
    error_directory["goPackages"][1]["Dir"] = json!("/fixture/workspace/alpha/missing");
    assert_eq!(
        member(
            &success(payload("go", &error_directory)),
            "example.invalid/alpha"
        )["targets"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
}

#[test]
fn metadata_root_mapping_is_component_based_and_bounded() {
    let original = fixture();
    let mut mapped = payload("rust", &original);
    mapped["roots"]
        .as_array_mut()
        .unwrap()
        .push(json!({"id":"member","path":"/fixture/workspace/alpha"}));
    assert_eq!(
        member(&success(mapped), "alpha")["manifest"],
        json!({"rootID":"member","relativePath":"Cargo.toml"})
    );
    for path in [
        "relative",
        "/fixture/workspace/../escape",
        "/fixture/\u{0}workspace",
    ] {
        let mut request = payload("rust", &original);
        request["roots"][0]["path"] = json!(path);
        failure(request, "invalid_request");
    }
    for root in [
        json!({"id":"same","path":"/fixture//workspace/./"}),
        json!({"id":"workspace","path":"/another"}),
        json!({"id":"bad root","path":"/another"}),
    ] {
        let mut request = payload("rust", &original);
        request["roots"].as_array_mut().unwrap().push(root);
        failure(request, "invalid_request");
    }
    let mut escaped = original.clone();
    escaped["cargo"]["packages"][0]["targets"][0]["src_path"] =
        json!("/fixture/workspace-other/main.rs");
    failure(payload("rust", &escaped), "permission_denied");
    escaped["cargo"]["packages"][0]["targets"][0]["src_path"] =
        json!("/fixture/workspace/中文 '$(echo)/main.rs");
    let result = success(payload("rust", &escaped));
    assert_eq!(
        target(member(&result, "beta"), "tool")["sources"][0]["location"]["relativePath"],
        "中文 '$(echo)/main.rs"
    );
    let mut go = original.clone();
    go["goPackages"][0]["GoFiles"] = json!(["../escape.go"]);
    failure(payload("go", &go), "invalid_request");
}

#[test]
fn metadata_limits_cover_ignored_fields_depth_and_expanded_locations() {
    let original = fixture();
    for raw in [
        " ".repeat(16 * 1024 * 1024 + 1),
        format!("{{\"unused\":\"{}\"}}", "x".repeat(65536)),
        format!("{{\"unused\":[{}0]}}", "0,".repeat(200000)),
        format!("{{\"unused\":{}0{}}}", "[".repeat(129), "]".repeat(129)),
    ] {
        let mut request = payload("rust", &original);
        request["cargoMetadata"] = json!(raw);
        failure(request, "invalid_request");
    }
    // A short shared source path can expand the member directory repeatedly.
    // Keep raw JSON below 16 MiB while proving the output expansion is bounded.
    let mut expanded = original.clone();
    let package = &mut expanded["cargo"]["packages"][1];
    package["manifest_path"] = json!(format!(
        "/fixture/workspace/{}/Cargo.toml",
        "a".repeat(7900)
    ));
    package["default_run"] = Value::Null;
    let template = package["targets"][0].clone();
    package["targets"] = json!((0..5000)
        .map(|index| {
            let mut target = template.clone();
            target["name"] = json!(format!("bin-{index}"));
            target
        })
        .collect::<Vec<_>>());
    failure(payload("rust", &expanded), "invalid_request");
}

#[test]
fn cancelled_metadata_does_not_decode_or_publish_a_snapshot() {
    let fixture = fixture();
    let request: crate::execution::ProjectMetadataRequest =
        serde_json::from_value(payload("rust", &fixture)).unwrap();
    let _scope = crate::protocol::cancellation::Scope::begin(
        Some("metadata-cancelled-before-decode".into()),
        None,
    );
    assert!(crate::cancel_operation("metadata-cancelled-before-decode"));
    let error = crate::execution::normalize_project_metadata(request).unwrap_err();
    assert!(matches!(error.code, ErrorCode::Cancelled));
}

#[test]
fn metadata_repeated_diagnostics_are_budgeted_before_cloning_import_paths() {
    let mut fixture = fixture();
    fixture["goPackages"] = json!([{
        "ImportPath": "p".repeat(60 * 1024),
        "DepsErrors": (0..600).map(|_| json!({"Err":"missing"})).collect::<Vec<_>>()
    }]);
    failure(payload("go", &fixture), "invalid_request");
}

#[test]
fn go_module_errors_disable_targets_and_malformed_modules_fail() {
    for field in ["goModules", "goPackages"] {
        let mut fixture = fixture();
        if field == "goModules" {
            fixture[field][0]["Error"] = json!({"Err":"invalid module"});
        } else {
            fixture[field][0]["Module"]["Error"] = json!({"Err":"invalid module"});
        }
        let result = success(payload("go", &fixture));
        let target = target(member(&result, "example.invalid/beta"), "main");
        assert_eq!(target["runnable"], false);
        assert_eq!(target["testable"], false);
        assert_eq!(target["incomplete"], true);
        if field == "goModules" {
            assert_eq!(
                member(&result, "example.invalid/beta")["diagnostics"][0]["code"],
                "moduleError"
            );
        } else {
            assert_eq!(target["diagnostics"][0]["code"], "moduleError");
        }
    }
    for bad in [json!({}), json!({"Path":"\u{0}","Main":false})] {
        let mut fixture = fixture();
        fixture["goModules"].as_array_mut().unwrap().push(bad);
        failure(payload("go", &fixture), "parse_failed");
    }
    let mut fixture = fixture();
    fixture["goPackages"][0]["ImportPath"] = json!("example.invalid/beta/wrong");
    failure(payload("go", &fixture), "parse_failed");
}

#[test]
fn go_errors_are_deterministic_and_absolute_queries_stay_in_details() {
    let mut fixture = fixture();
    fixture["goPackages"][2]["DepsErrors"]
        .as_array_mut()
        .unwrap()
        .push(json!({"Err":"other error","ImportStack":["first","second"]}));
    fixture["goPackages"][1]["ImportPath"] = json!("/fixture/workspace/missing/...");
    let first = success(payload("go", &fixture));
    assert!(first["diagnostics"][0]["importPath"].is_null());
    let details: Value =
        serde_json::from_str(first["diagnostics"][0]["details"].as_str().unwrap()).unwrap();
    assert_eq!(details["Query"], "/fixture/workspace/missing/...");
    fixture["goPackages"][2]["DepsErrors"]
        .as_array_mut()
        .unwrap()
        .reverse();
    assert_eq!(first, success(payload("go", &fixture)));
    // Even complete error records must not turn a native query into a target ID.
    fixture["goPackages"][2]["ImportPath"] = json!("/fixture/private/query");
    let complete_error = success(payload("go", &fixture));
    assert_eq!(
        member(&complete_error, "example.invalid/alpha")["targets"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert!(complete_error["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .all(|value| value["importPath"].is_null()));
    fixture["goModules"][0]["Path"] = json!("/fixture/private/module");
    fixture["goModules"][0]["Error"] = json!({"Err":"invalid module path"});
    fixture["goPackages"] = json!([]);
    let bad_module = success(payload("go", &fixture));
    assert_eq!(bad_module["members"].as_array().unwrap().len(), 1);
    assert!(bad_module["diagnostics"][0]["importPath"].is_null());
}

#[test]
fn go_root_directory_module_uses_a_component_separator() {
    let module = json!({"Path":"example.invalid/root","Main":true,"Dir":"/","GoMod":"/go.mod"});
    let package = json!({"Dir":"/cmd","ImportPath":"example.invalid/root/cmd","Name":"main","Module":module,"GoFiles":["entry.go"]});
    let result = success(
        json!({"language":"go","workspaceDirectory":"/","roots":[{"id":"root","path":"/"}],"goModules":module.to_string(),"goPackages":package.to_string()}),
    );
    assert_eq!(result["members"][0]["targets"][0]["runnable"], true);
    assert_eq!(
        result["members"][0]["targets"][0]["directory"]["relativePath"],
        "cmd"
    );
}

#[test]
fn project_metadata_round_trips_through_owned_c_abi_strings() {
    use std::ffi::{CStr, CString};
    use std::os::raw::c_char;
    unsafe extern "C" {
        fn lithe_core_execute_json(request: *const c_char) -> *mut c_char;
        fn lithe_core_free_string(value: *mut c_char);
    }
    struct OwnedResponse(*mut c_char);
    impl Drop for OwnedResponse {
        fn drop(&mut self) {
            // The C ABI owns this allocation until exactly one matching free.
            unsafe {
                lithe_core_free_string(self.0);
            }
        }
    }
    let fixture = fixture();
    for language in ["go", "rust"] {
        let request=json!({"id":"metadata-native","command":"execution.normalizeProjectMetadata","payload":payload(language,&fixture)}).to_string();
        let input = CString::new(request.clone()).unwrap();
        // input remains NUL-terminated and alive throughout the synchronous call.
        let response = OwnedResponse(unsafe { lithe_core_execute_json(input.as_ptr()) });
        assert!(!response.0.is_null());
        let text = unsafe { CStr::from_ptr(response.0) }.to_str().unwrap();
        let result: Value = serde_json::from_str(text).unwrap();
        assert_eq!(result["ok"], true);
        assert_eq!(text, execute_json(&request));
    }
}
