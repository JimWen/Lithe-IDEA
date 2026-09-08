use super::support::temporary_root;
use crate::execute_json;
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;

struct SearchFixture {
    root: PathBuf,
}

impl SearchFixture {
    fn new(label: &str) -> Self {
        let fixture = Self {
            root: temporary_root(label),
        };
        fs::create_dir_all(&fixture.root).expect("search fixture should be creatable");
        fixture
    }

    fn command(&self, command: &str, mut payload: Value) -> Value {
        payload["root"] = json!(self.root);
        let response = self.response(command, payload);
        assert_eq!(response["ok"], true, "{command}: {response}");
        response["data"].clone()
    }

    fn response(&self, command: &str, mut payload: Value) -> Value {
        payload["root"] = json!(self.root);
        serde_json::from_str(&execute_json(
            &json!({
                "id": "unicode-search-fixture",
                "command": command,
                "timeoutMilliseconds": 3_000,
                "payload": payload
            })
            .to_string(),
        ))
        .expect("search response should be JSON")
    }

    fn search_paths(&self, options: Value) -> Vec<String> {
        let result = self.command("workspace.search", options);
        let mut paths = result["matches"]
            .as_array()
            .expect("search matches")
            .iter()
            .filter(|item| item["kind"] == "content")
            .map(|item| item["path"].as_str().expect("relative path").to_string())
            .collect::<Vec<_>>();
        paths.sort();
        paths
    }
}

impl Drop for SearchFixture {
    fn drop(&mut self) {
        // Release the process-global index as well as files, including when an
        // assertion unwinds before the end of a fixture case.
        let invalidation =
            crate::project::invalidate_search_index(crate::project::SearchIndexRequest {
                root: self.root.to_string_lossy().into_owned(),
                hidden_directory_names: Vec::new(),
                hidden_file_patterns: Vec::new(),
            });
        if self.root.exists() {
            if let Err(error) = fs::remove_dir_all(&self.root) {
                eprintln!("Could not remove search fixture: {error}");
                assert!(std::thread::panicking(), "Search fixture cleanup failed");
            }
        }
        if let Err(error) = invalidation {
            eprintln!("Could not invalidate search fixture: {error:?}");
            assert!(
                std::thread::panicking(),
                "Search fixture index cleanup failed"
            );
        }
    }
}

#[cfg(unix)]
#[test]
fn scoped_preview_rejects_special_files_without_opening_a_stream() {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    const CHILD_ROOT: &str = "LITHE_SPECIAL_PREVIEW_TEST_ROOT";
    if let Some(root) = std::env::var_os(CHILD_ROOT) {
        let root = root.to_string_lossy().into_owned();
        for path in ["pipe.txt", "directory"] {
            let result: Value = serde_json::from_str(&execute_json(
                &json!({
                    "id": "special-preview",
                    "command": "workspace.replacePreview",
                    "timeoutMilliseconds": 500,
                    "payload": {
                        "root": root,
                        "query": "needle",
                        "replacement": "x",
                        "scope": {"kind": "files", "paths": [path]}
                    }
                })
                .to_string(),
            ))
            .unwrap();
            assert_eq!(result["ok"], true, "{result}");
            assert_eq!(result["data"]["status"], "incomplete", "{result}");
            assert_eq!(result["data"]["files"], json!([]), "{result}");
            assert_eq!(result["data"]["issues"][0]["code"], "invalid_request");
        }
        return;
    }

    let files = SearchFixture::new("special-preview");
    let fifo = CString::new(files.root.join("pipe.txt").as_os_str().as_bytes()).unwrap();
    // The NUL-terminated path is owned for the duration of this native call.
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    fs::create_dir(files.root.join("directory")).unwrap();
    // A regression in open(2) ignores Core's cooperative deadline. Isolate it
    // in an owned subprocess so this test can terminate it without a writer.
    let mut child = PreviewChild(Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "tests::project_search::scoped_preview_rejects_special_files_without_opening_a_stream",
            "--nocapture",
        ])
        .env(CHILD_ROOT, &files.root)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap());
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if let Some(status) = child.0.try_wait().unwrap() {
            assert!(
                status.success(),
                "special-file preview subprocess failed: {status}"
            );
            break;
        }
        if Instant::now() >= deadline {
            panic!("Special-file preview did not terminate within three seconds");
        }
        // test-stability: allow(rust-real-sleep) reason: native child exit has no std callback; poll its public status with a local monotonic deadline.
        std::thread::sleep(Duration::from_millis(5));
    }
}

// Own the isolated FIFO probe through panic paths as well as normal completion.
#[cfg(unix)]
struct PreviewChild(std::process::Child);

#[cfg(unix)]
impl Drop for PreviewChild {
    fn drop(&mut self) {
        if !matches!(self.0.try_wait(), Ok(Some(_))) {
            if let Err(error) = self.0.kill() {
                eprintln!("Could not terminate special-file preview probe: {error}");
                return;
            }
            // The owned child has received SIGKILL; reap before deleting its fixture.
            if let Err(error) = self.0.wait() {
                eprintln!("Could not reap special-file preview probe: {error}");
            }
        }
    }
}

#[test]
fn unicode_search_and_replacement_follow_shared_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/search/unicode-replacement-v1.json"
    ))
    .expect("Unicode search fixture should decode");
    for case in fixture["cases"].as_array().expect("fixture cases") {
        let label = case["name"].as_str().expect("case name");
        let files = SearchFixture::new(label);
        let source = case["source"].as_str().expect("source text");
        fs::write(files.root.join("sample.txt"), source).expect("source should be writable");
        let mut request = case["options"].clone();
        request["query"] = case["query"].clone();
        request["replacement"] = case["replacement"].clone();

        for command in ["workspace.search", "workspace.searchEverywhere"] {
            let response = files.command(command, request.clone());
            let lines = response["matches"]
                .as_array()
                .expect("search matches")
                .iter()
                .filter(|item| item["kind"] == "content")
                .map(|item| item["line"].clone())
                .collect::<Vec<_>>();
            assert_eq!(json!(lines), case["matchedLines"], "{label}: {command}");
        }
        // Exercise both candidate-index traversal and explicit paths. Overrides
        // alone would hide a missing Unicode candidate from this regression.
        for scope in 0..3 {
            let mut preview_request = request.clone();
            if scope == 1 {
                preview_request["paths"] = json!(["sample.txt"]);
            }
            if scope == 2 {
                preview_request["scope"] = json!({"kind": "project"});
            }
            let response = files.command("workspace.replacePreview", preview_request);
            let results = response["files"].as_array().expect("preview files");
            if case["expectedCount"] == 0 {
                assert!(results.is_empty(), "{label}: {response}");
                continue;
            }
            assert_eq!(results.len(), 1, "{label}: {response}");
            assert_eq!(results[0]["path"], "sample.txt", "{label}");
            if scope == 2 {
                assert_eq!(results[0]["sourceText"], source);
                assert_eq!(response["status"], "complete");
                assert_edits_reconstruct(&results[0]);
            }
            assert_eq!(
                results[0]["replacementText"], case["expectedText"],
                "{label}"
            );
            let matches = results[0]["matches"].as_array().expect("preview matches");
            let lines = matches
                .iter()
                .map(|item| item["line"].clone())
                .collect::<Vec<_>>();
            assert_eq!(json!(lines), case["matchedLines"], "{label}");
            let count: u64 = matches
                .iter()
                .map(|item| item["occurrenceCount"].as_u64().expect("count"))
                .sum();
            assert_eq!(json!(count), case["expectedCount"], "{label}");
            for matched in matches {
                let line = matched["line"].as_u64().expect("line") as usize - 1;
                assert_eq!(
                    matched["before"],
                    source.split('\n').nth(line).expect("source line"),
                    "{label}"
                );
                assert_eq!(
                    matched["after"],
                    case["expectedText"]
                        .as_str()
                        .expect("expected text")
                        .split('\n')
                        .nth(line)
                        .expect("result line"),
                    "{label}"
                );
            }
        }
        assert_eq!(
            fs::read(files.root.join("sample.txt")).expect("source bytes"),
            source.as_bytes(),
            "Preview must never write: {label}"
        );
    }
}

#[test]
fn unicode_candidates_follow_warm_index_file_lifecycle() {
    let files = SearchFixture::new("unicode-index-lifecycle");
    fs::write(files.root.join("sample.txt"), "plain").expect("initial source");
    let query = json!({"query": "sxs"});
    assert!(files.search_paths(query.clone()).is_empty());

    files.command("file.write", json!({"path": "sample.txt", "text": "ſxſ"}));
    assert_eq!(files.search_paths(query.clone()), ["sample.txt"]);
    assert!(files
        .search_paths(json!({"query": "sxs", "caseSensitive": true}))
        .is_empty());
    files.command("file.write", json!({"path": "sample.txt", "text": "plain"}));
    assert!(files.search_paths(query.clone()).is_empty());

    files.command("file.write", json!({"path": "created.go", "text": "ſxſ"}));
    assert_eq!(files.search_paths(query.clone()), ["created.go"]);
    fs::remove_file(files.root.join("created.go")).expect("remove indexed file");
    files.command(
        "workspace.searchIndex.update",
        json!({"paths": ["created.go"]}),
    );
    assert!(files.search_paths(query.clone()).is_empty());

    // The removed file's ID is reusable. A new Unicode file must acquire its
    // own flag, and batched watcher updates must not retain a removed entry.
    fs::write(files.root.join("reused.txt"), "ſxſ").expect("reused ID source");
    files.command(
        "workspace.searchIndex.update",
        json!({"paths": ["reused.txt"]}),
    );
    assert_eq!(files.search_paths(query.clone()), ["reused.txt"]);
    fs::remove_file(files.root.join("reused.txt")).expect("remove reused ID file");
    fs::write(files.root.join("a.txt"), "ſxſ").expect("first batch source");
    fs::write(files.root.join("b.txt"), "SXS").expect("second batch source");
    files.command(
        "workspace.searchIndex.update",
        json!({"paths": ["a.txt", "b.txt", "reused.txt"]}),
    );
    assert_eq!(files.search_paths(query), ["a.txt", "b.txt"]);
    let preview = files.command(
        "workspace.replacePreview",
        json!({"query": "sxs", "replacement": "x"}),
    );
    let paths = preview["files"]
        .as_array()
        .expect("preview files")
        .iter()
        .map(|file| file["path"].as_str().expect("path"))
        .collect::<Vec<_>>();
    assert_eq!(paths, ["a.txt", "b.txt"]);
}

#[test]
fn unicode_candidates_preserve_masks_and_visibility() {
    let files = SearchFixture::new("unicode-visibility");
    for path in ["a.go", "b.txt", ".git/hidden.txt", "ignored/hidden.txt"] {
        let url = files.root.join(path);
        fs::create_dir_all(url.parent().expect("parent")).expect("fixture directories");
        fs::write(url, "ſxſ").expect("fixture source");
    }
    let options = json!({"query": "sxs", "fileMask": "*.txt", "hiddenDirectoryNames": ["ignored"]});
    assert_eq!(files.search_paths(options.clone()), ["b.txt"]);
    let mut request = options;
    request["replacement"] = json!("x");
    let preview = files.command("workspace.replacePreview", request);
    let results = preview["files"].as_array().expect("preview files");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["path"], "b.txt");
}

#[test]
fn unicode_replacement_uses_unsaved_original_ranges() {
    let files = SearchFixture::new("unicode-unsaved");
    fs::write(files.root.join("sample.txt"), "unrelated").expect("disk text");
    let result = files.command(
        "workspace.replacePreview",
        json!({
            "query": "needle", "replacement": "$1", "paths": ["sample.txt"],
            "textOverrides": {"sample.txt": "İ needle KNEEDLE😀"}
        }),
    );
    assert_eq!(result["files"][0]["replacementText"], "İ $1 K$1😀");
    assert_eq!(result["files"][0]["matches"][0]["occurrenceCount"], 2);
    assert_eq!(
        fs::read(files.root.join("sample.txt")).expect("disk bytes"),
        b"unrelated"
    );
}

// Reapply the protocol's UTF-16 edits, independently of Rust byte coordinates.
// This also checks order, boundaries, uniqueness and exact Unicode encoding.
fn assert_edits_reconstruct(file: &Value) {
    let source = file["sourceText"].as_str().expect("source snapshot");
    let original = source.encode_utf16().collect::<Vec<_>>();
    let mut actual = Vec::new();
    let mut cursor = 0;
    let mut ids = std::collections::HashSet::new();
    for edit in file["edits"].as_array().expect("exact edits") {
        let start = edit["utf16Start"].as_u64().expect("start") as usize;
        let end = start + edit["utf16Length"].as_u64().expect("length") as usize;
        assert!(start >= cursor && end <= original.len());
        assert!(ids.insert(edit["id"].as_str().expect("edit identity")));
        actual.extend_from_slice(&original[cursor..start]);
        actual.extend(
            edit["newText"]
                .as_str()
                .expect("replacement")
                .encode_utf16(),
        );
        cursor = end;
    }
    actual.extend_from_slice(&original[cursor..]);
    let expected = file["replacementText"]
        .as_str()
        .expect("complete replacement");
    assert_eq!(
        String::from_utf16(&actual)
            .expect("valid UTF-16")
            .as_bytes(),
        expected.as_bytes()
    );
}

#[test]
fn scoped_preview_empty_files_preserves_legacy_compatibility() {
    let files = SearchFixture::new("empty-scope");
    fs::write(files.root.join("sample.txt"), "needle").expect("source");
    let base = json!({"query": "needle", "replacement": "changed", "paths": []});
    let legacy = files.command("workspace.replacePreview", base.clone());
    assert_eq!(legacy["files"].as_array().expect("legacy files").len(), 1);
    assert!(legacy.get("status").is_none());
    assert!(legacy["files"][0].get("sourceText").is_none());
    let mut explicit = base;
    explicit["scope"] = json!({"kind": "files", "paths": []});
    explicit["textOverrides"] = json!({"sample.txt": "needle"});
    let empty = files.command("workspace.replacePreview", explicit.clone());
    assert_eq!(empty["files"], json!([]));
    assert_eq!(empty["status"], "complete");
    // Even an invalid regex cannot cause an empty file selection to traverse.
    explicit["regularExpression"] = json!(true);
    explicit["query"] = json!("(?<=x)y");
    assert_eq!(
        files.command("workspace.replacePreview", explicit)["files"],
        json!([])
    );
}

#[test]
fn scoped_preview_overrides_join_candidates_in_every_scope() {
    let files = SearchFixture::new("scope-overrides");
    fs::create_dir_all(files.root.join("src/hidden")).expect("directories");
    for (path, content) in [
        ("src/new.txt", "plain"),
        ("src/old.txt", "needle"),
        ("outside.txt", "needle"),
        ("src/hidden/ignored.txt", "needle"),
        ("src/masked.go", "needle"),
    ] {
        fs::write(files.root.join(path), content).expect("source");
    }
    files.command("workspace.search", json!({"query": "needle"}));
    let overrides = json!({"src/new.txt": "needle", "src/old.txt": "plain", "src/created.txt": "needle",
        "src/hidden/ignored.txt": "needle", "src/masked.go": "needle"});
    for (scope, expected) in [
        (
            json!({"kind": "project"}),
            json!(["outside.txt", "src/created.txt", "src/new.txt"]),
        ),
        (
            json!({"kind": "directory", "path": "src"}),
            json!(["src/created.txt", "src/new.txt"]),
        ),
        (
            json!({"kind": "files", "paths": ["src/old.txt", "src/new.txt", "src/created.txt", "src/new.txt", "src/hidden/ignored.txt"]}),
            json!(["src/created.txt", "src/hidden/ignored.txt", "src/new.txt"]),
        ),
    ] {
        let response = files.command(
            "workspace.replacePreview",
            json!({
                "query": "needle", "replacement": "changed", "scope": scope,
                "textOverrides": overrides, "hiddenDirectoryNames": ["hidden"], "fileMask": "*.txt"
            }),
        );
        let actual = response["files"]
            .as_array()
            .expect("files")
            .iter()
            .map(|file| file["path"].clone())
            .collect::<Vec<_>>();
        assert_eq!(json!(actual), expected);
        assert_eq!(response["status"], "complete");
        for file in response["files"].as_array().expect("files") {
            assert_edits_reconstruct(file);
        }
    }
    assert_eq!(
        fs::read(files.root.join("src/new.txt")).expect("unchanged disk"),
        b"plain"
    );
    assert!(!files.root.join("src/created.txt").exists());
}

#[test]
fn scoped_preview_preserves_query_whitespace_and_reports_engine_errors() {
    let files = SearchFixture::new("scoped-expression");
    fs::write(files.root.join("sample.txt"), " needle \nneedle\n  ").expect("source");
    for (query, expected) in [(" needle ", "x\nneedle\n  "), ("  ", " needle \nneedle\nx")] {
        let result = files.command(
            "workspace.replacePreview",
            json!({
                "query": query, "replacement": "x", "scope": {"kind": "project"}
            }),
        );
        assert_eq!(result["files"][0]["replacementText"], expected);
        assert_edits_reconstruct(&result["files"][0]);
    }
    for query in ["(?<=x)y", "(a)\\1", "["] {
        let error = files.response(
            "workspace.replacePreview",
            json!({
                "query": query, "replacement": "", "regularExpression": true, "scope": {"kind": "project"}
            }),
        );
        assert_eq!(error["ok"], false);
        assert_eq!(error["error"]["code"], "parse_failed");
        assert!(!error["error"]["details"]
            .as_str()
            .expect("engine reason")
            .is_empty());
    }
}

#[test]
fn scoped_preview_rejects_ambiguous_and_escaping_scopes() {
    let files = SearchFixture::new("scope-validation");
    for scope in [
        json!({"kind": "files", "paths": ["../outside.txt"]}),
        json!({"kind": "directory", "path": "/tmp"}),
        json!({"kind": "files", "paths": ["a//b"]}),
        json!({"kind": "files", "paths": ["./a"]}),
        json!({"kind": "project", "paths": []}),
    ] {
        let result = files.response(
            "workspace.replacePreview",
            json!({"query": "x", "replacement": "", "scope": scope}),
        );
        assert_eq!(result["ok"], false, "{scope}: {result}");
    }
    let result = files.response(
        "workspace.replacePreview",
        json!({
            "query": "x", "replacement": "", "scope": {"kind": "project"}, "paths": ["sample.txt"]
        }),
    );
    assert_eq!(result["ok"], false);
}

#[test]
fn scoped_preview_reports_missing_decode_and_budget_failures_without_writes() {
    let files = SearchFixture::new("scope-incomplete");
    fs::write(files.root.join("invalid.txt"), [255]).expect("invalid source");
    fs::write(files.root.join("dense.txt"), "x".repeat(10_001)).expect("dense source");
    for (path, code) in [
        ("missing.txt", "file_not_found"),
        ("invalid.txt", "parse_failed"),
        ("dense.txt", "previewBudgetExceeded"),
    ] {
        let result = files.command(
            "workspace.replacePreview",
            json!({
                "query": "x", "replacement": "y", "scope": {"kind": "files", "paths": [path]}
            }),
        );
        assert_eq!(result["status"], "incomplete");
        assert_eq!(result["issues"][0]["code"], code);
        assert_eq!(result["files"], json!([]));
    }
    assert_eq!(
        fs::read(files.root.join("dense.txt")).expect("unchanged source"),
        "x".repeat(10_001).as_bytes()
    );
}

#[cfg(unix)]
#[test]
fn scoped_preview_rejects_links_and_readonly_replacement_but_allows_readonly_search() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let files = SearchFixture::new("scope-filesystem");
    fs::write(files.root.join("sample.txt"), "needle").expect("source");
    fs::hard_link(files.root.join("sample.txt"), files.root.join("hard.txt")).expect("hardlink");
    symlink(files.root.join("sample.txt"), files.root.join("link.txt")).expect("symlink");
    fs::write(files.root.join("readonly.txt"), "needle").expect("readonly source");
    fs::set_permissions(
        files.root.join("readonly.txt"),
        fs::Permissions::from_mode(0o444),
    )
    .expect("permissions");
    for path in ["hard.txt", "link.txt", "readonly.txt"] {
        let result = files.command(
            "workspace.replacePreview",
            json!({
                "query": "needle", "replacement": "x", "scope": {"kind": "files", "paths": [path]}
            }),
        );
        assert_eq!(result["status"], "incomplete");
        assert_eq!(result["issues"][0]["code"], "permission_denied");
    }
    let search = files.command("workspace.replacePreview", json!({
        "query": "needle", "replacement": "", "purpose": "search", "scope": {"kind": "files", "paths": ["readonly.txt"]}
    }));
    assert_eq!(search["status"], "complete");
    assert_eq!(search["files"].as_array().expect("search results").len(), 1);
}

#[test]
fn scoped_preview_follows_shared_contract_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/search/scoped-preview-v1.json"
    ))
    .expect("scoped fixture");
    for case in fixture["cases"].as_array().expect("cases") {
        let files = SearchFixture::new(case["name"].as_str().expect("case name"));
        for (path, source) in case["files"].as_object().expect("source files") {
            let target = files.root.join(path);
            fs::create_dir_all(target.parent().expect("parent")).expect("fixture directories");
            fs::write(target, source.as_str().expect("source")).expect("fixture bytes");
        }
        let response = files.response("workspace.replacePreview", case["request"].clone());
        let code = &case["errorCode"];
        if !code.is_null() {
            assert_eq!(response["ok"], false, "{case}: {response}");
            assert_eq!(&response["error"]["code"], code);
            continue;
        }
        assert_eq!(response["ok"], true, "{case}: {response}");
        let data = &response["data"];
        assert_eq!(data["status"], case["status"]);
        let actual = data["files"].as_array().expect("actual files");
        let expected = case["expected"].as_array().expect("expected files");
        assert_eq!(actual.len(), expected.len());
        for (actual, expected) in actual.iter().zip(expected) {
            for field in ["path", "sourceText", "replacementText"] {
                assert_eq!(actual[field], expected[field], "{case}: {field}");
            }
            let ranges = actual["edits"]
                .as_array()
                .expect("edits")
                .iter()
                .map(|edit| json!([edit["utf16Start"], edit["utf16Length"]]))
                .collect::<Vec<_>>();
            assert_eq!(json!(ranges), expected["ranges"]);
            assert_edits_reconstruct(actual);
        }
    }
}
