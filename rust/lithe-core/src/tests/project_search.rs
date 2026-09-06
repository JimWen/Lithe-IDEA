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
        let response: Value = serde_json::from_str(&execute_json(
            &json!({
                "id": "unicode-search-fixture",
                "command": command,
                "timeoutMilliseconds": 3_000,
                "payload": payload
            })
            .to_string(),
        ))
        .expect("search response should be JSON");
        assert_eq!(response["ok"], true, "{command}: {response}");
        response["data"].clone()
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
        for explicit_paths in [false, true] {
            let mut preview_request = request.clone();
            if explicit_paths {
                preview_request["paths"] = json!(["sample.txt"]);
            }
            let response = files.command("workspace.replacePreview", preview_request);
            let results = response["files"].as_array().expect("preview files");
            if case["expectedCount"] == 0 {
                assert!(results.is_empty(), "{label}: {response}");
                continue;
            }
            assert_eq!(results.len(), 1, "{label}: {response}");
            assert_eq!(results[0]["path"], "sample.txt", "{label}");
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
