use super::*;
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn temporary_root(label: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock should be valid")
        .as_nanos();
    std::env::temp_dir().join(format!("lithe-lsp-{label}-{}-{nonce}", std::process::id()))
}

#[test]
fn builtin_catalog_describes_market_lsp_providers() {
    let catalog = provider_catalog(None);
    let ids: Vec<_> = catalog
        .providers
        .iter()
        .map(|provider| provider.id.as_str())
        .collect();
    assert!(ids.starts_with(&["java", "go", "python", "node", "rust"]));
    assert!(ids.contains(&"swift"));
    assert!(ids.contains(&"clangd"));
    assert!(ids.contains(&"dockerfile"));
    assert!(ids.contains(&"graphql"));
    let clangd = catalog
        .providers
        .iter()
        .find(|provider| provider.id == "clangd")
        .expect("clangd provider should exist");
    assert_eq!(
        clangd.language_ids_by_extension.get("m"),
        Some(&"objective-c".to_string())
    );
    let swift = catalog
        .providers
        .iter()
        .find(|provider| provider.id == "swift")
        .expect("swift provider should exist");
    let swift_launch = swift
        .language_server_launch
        .as_ref()
        .expect("swift launch descriptor should exist");
    assert_eq!(
        swift_launch.executable_names,
        vec!["sourcekit-lsp".to_string()]
    );
    let go = catalog
        .providers
        .iter()
        .find(|provider| provider.id == "go")
        .expect("go provider should exist");
    let go_installation = go
        .language_server_installation
        .as_ref()
        .expect("go installation descriptor should exist");
    assert_eq!(go_installation.homebrew_formula.as_deref(), Some("gopls"));
    assert_eq!(
        go_installation.official_download_url.as_deref(),
        Some("https://go.dev/gopls/")
    );
    let rust = catalog
        .providers
        .iter()
        .find(|provider| provider.id == "rust")
        .expect("rust provider should exist");
    assert_eq!(
        rust.language_server_launch
            .as_ref()
            .expect("rust launch descriptor should exist")
            .validation_arguments,
        vec!["--version".to_string()]
    );
}

#[test]
fn project_config_extends_and_overrides_builtin_catalog() {
    let root = temporary_root("project-config");
    fs::create_dir_all(root.join(".lithe").join("lsp")).unwrap();
    fs::write(
        root.join(".lithe")
            .join("lsp")
            .join("language-providers.json"),
        r#"{
              "version": 1,
              "providers": [
                {
                  "id": "roc",
                  "displayName": "Roc",
                  "fileExtensions": ["roc"],
                  "capabilities": ["languageServer", "formatting"],
                  "activationPolicy": "onDemand",
                  "languageId": "roc"
                },
                {
                  "id": "swift",
                  "fileExtensions": ["swift", "swiftinterface"],
                  "languageServerLaunch": {
                    "executableNames": ["custom-sourcekit-lsp"],
                    "arguments": ["--stdio"],
                    "environment": {
                      "SOURCEKIT_TOOLCHAIN": "custom"
                    },
                    "initializationOptions": {
                      "indexing": true
                    }
                  },
                  "languageServerInstallation": {
                    "homebrewFormula": "custom-sourcekit-lsp",
                    "officialDownloadURL": "https://example.com/sourcekit-lsp"
                  }
                },
                {
                  "id": "perl",
                  "disabled": true
                }
              ]
            }"#,
    )
    .unwrap();

    let catalog = provider_catalog(Some(&root));
    assert_eq!(catalog.origin, LspProviderCatalogOrigin::WorkspaceOverride);
    assert!(catalog
        .providers
        .iter()
        .any(|provider| provider.id == "roc"));
    let swift = catalog
        .providers
        .iter()
        .find(|provider| provider.id == "swift")
        .expect("swift provider should still exist");
    assert!(swift
        .file_extensions
        .contains(&"swiftinterface".to_string()));
    let swift_launch = swift
        .language_server_launch
        .as_ref()
        .expect("swift launch descriptor should be overridden");
    assert_eq!(
        swift_launch.executable_names,
        vec!["custom-sourcekit-lsp".to_string()]
    );
    assert_eq!(swift_launch.arguments, vec!["--stdio".to_string()]);
    assert_eq!(
        swift_launch.environment.get("SOURCEKIT_TOOLCHAIN"),
        Some(&"custom".to_string())
    );
    assert_eq!(
        swift_launch.initialization_options,
        Some(json!({ "indexing": true }))
    );
    let swift_installation = swift
        .language_server_installation
        .as_ref()
        .expect("swift installation descriptor should be overridden");
    assert_eq!(
        swift_installation.homebrew_formula.as_deref(),
        Some("custom-sourcekit-lsp")
    );
    assert!(!catalog
        .providers
        .iter()
        .any(|provider| provider.id == "perl"));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn ffi_json_is_a_standalone_catalog_document() {
    let raw = provider_catalog_json(None);
    let value: Value = serde_json::from_str(&raw).expect("catalog should be JSON");
    assert_eq!(value["version"], 2);
    assert_eq!(value["origin"], "builtin");
    assert!(value["providers"].as_array().unwrap().len() > 10);
    assert!(value.get("ok").is_none());
    assert!(value.get("command").is_none());
}

#[test]
fn project_catalog_reports_unknown_configuration_fields() {
    let root = temporary_root("project-config-unknown-field");
    fs::create_dir_all(root.join(".lithe").join("lsp")).unwrap();
    fs::write(
        root.join(".lithe")
            .join("lsp")
            .join("language-providers.json"),
        r#"{
              "version": 2,
              "providers": [{ "id": "go", "languageServerLanch": {} }]
            }"#,
    )
    .unwrap();

    let catalog = provider_catalog(Some(&root));
    assert_eq!(catalog.origin, LspProviderCatalogOrigin::Builtin);
    assert_eq!(catalog.diagnostics.len(), 1);
    assert!(catalog.diagnostics[0].message.contains("unknown field"));
    assert!(catalog.providers.iter().any(|provider| provider.id == "go"));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn malformed_project_catalog_is_rejected_with_a_visible_diagnostic() {
    let root = temporary_root("project-config-malformed");
    let config_path = root
        .join(".lithe")
        .join("lsp")
        .join("language-providers.json");
    fs::create_dir_all(config_path.parent().unwrap()).unwrap();
    fs::write(&config_path, r#"{"version":2,"providers":["#).unwrap();

    let catalog = provider_catalog(Some(&root));

    assert_eq!(catalog.origin, LspProviderCatalogOrigin::Builtin);
    assert!(catalog.providers.iter().any(|provider| provider.id == "go"));
    assert_eq!(catalog.diagnostics.len(), 1);
    assert_eq!(
        catalog.diagnostics[0].path,
        config_path.display().to_string()
    );
    assert!(catalog.diagnostics[0].message.contains("EOF"));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn text_edits_use_lsp_utf16_positions() {
    let response = apply_text_edits(ApplyTextEditsRequest {
        text: "one 😀\ntwo three\n".to_string(),
        edits: vec![
            LspTextEdit {
                range: LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 4,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 6,
                    },
                },
                new_text: "rocket".to_string(),
            },
            LspTextEdit {
                range: LspRange {
                    start: LspPosition {
                        line: 1,
                        utf16_column: 4,
                    },
                    end: LspPosition {
                        line: 1,
                        utf16_column: 9,
                    },
                },
                new_text: "four".to_string(),
            },
        ],
    })
    .unwrap();

    assert_eq!(response.text, "one rocket\ntwo four\n");
}

#[test]
fn text_edits_reject_invalid_and_overlapping_ranges() {
    let invalid = apply_text_edits(ApplyTextEditsRequest {
        text: "one line".to_string(),
        edits: vec![LspTextEdit {
            range: LspRange {
                start: LspPosition {
                    line: 9,
                    utf16_column: 0,
                },
                end: LspPosition {
                    line: 9,
                    utf16_column: 1,
                },
            },
            new_text: "x".to_string(),
        }],
    })
    .unwrap_err();
    assert_eq!(invalid.details.as_deref(), Some("invalidRange"));

    let overlapping = apply_text_edits(ApplyTextEditsRequest {
        text: "one line".to_string(),
        edits: vec![
            LspTextEdit {
                range: LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 0,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 4,
                    },
                },
                new_text: "a".to_string(),
            },
            LspTextEdit {
                range: LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 2,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 6,
                    },
                },
                new_text: "b".to_string(),
            },
        ],
    })
    .unwrap_err();
    assert_eq!(overlapping.details.as_deref(), Some("overlappingEdits"));
}

#[test]
fn snippet_plain_text_removes_tab_stops_and_keeps_defaults() {
    assert_eq!(snippet_plain_text("print(${1:value})$0"), "print(value)");
    assert_eq!(snippet_plain_text("${1:let} ${2:name} = $3"), "let name = ");
}

#[test]
fn builtin_completion_returns_current_file_identifiers_for_prefix() {
    let response = builtin_completions(BuiltinRequest {
        file_path: "/tmp/main.swift".to_string(),
        text: "struct RocketShip {}\nlet rocketSpeed = Roc\n".to_string(),
        position: LspPosition {
            line: 1,
            utf16_column: 19,
        },
        workspace_root: None,
        open_buffers: None,
    })
    .unwrap();

    assert!(response.items.iter().any(|item| item.label == "RocketShip"));
    let item = response
        .items
        .iter()
        .find(|item| item.label == "RocketShip")
        .unwrap();
    assert_eq!(item.text_edit.range.start.utf16_column, 18);
    assert_eq!(item.text_edit.new_text, "RocketShip");
}

#[test]
fn builtin_hover_returns_current_identifier_range() {
    let response = builtin_hover(BuiltinRequest {
        file_path: "/tmp/main.rs".to_string(),
        text: "/// Launches the rocket.\nfn launch() {}\n".to_string(),
        position: LspPosition {
            line: 1,
            utf16_column: 4,
        },
        workspace_root: None,
        open_buffers: None,
    })
    .unwrap();

    let hover = response.hover.unwrap();
    assert!(hover.contents.contains("```rust\nfn launch() {}\n```"));
    assert!(hover.contents.contains("Launches the rocket."));
    assert_eq!(hover.range.start.utf16_column, 3);
    assert_eq!(hover.range.end.utf16_column, 9);

    let fallback = builtin_hover(BuiltinRequest {
        file_path: "/tmp/main.rs".to_string(),
        text: "unknownSymbol\n".to_string(),
        position: LspPosition {
            line: 0,
            utf16_column: 3,
        },
        workspace_root: None,
        open_buffers: None,
    })
    .unwrap();
    assert_eq!(fallback.hover.unwrap().contents, "`unknownSymbol`");
}

#[test]
fn builtin_navigation_prefers_declarations_and_finds_references() {
    let text = "let service = 1\nprint(service)\n";
    let definitions = builtin_navigation(BuiltinNavigationRequest {
        file_path: "/tmp/main.swift".to_string(),
        text: text.to_string(),
        position: LspPosition {
            line: 1,
            utf16_column: 8,
        },
        method: "textDocument/definition".to_string(),
        workspace_root: None,
        open_buffers: None,
    })
    .unwrap();
    assert_eq!(definitions.locations.len(), 1);
    assert_eq!(definitions.locations[0].range.start.line, 0);
    assert_eq!(definitions.locations[0].range.start.utf16_column, 4);

    let references = builtin_navigation(BuiltinNavigationRequest {
        file_path: "/tmp/main.swift".to_string(),
        text: text.to_string(),
        position: LspPosition {
            line: 1,
            utf16_column: 8,
        },
        method: "textDocument/references".to_string(),
        workspace_root: None,
        open_buffers: None,
    })
    .unwrap();
    assert_eq!(references.locations.len(), 2);
}

#[test]
fn file_uri_paths_decode_spaces_and_utf8_characters() {
    assert_eq!(
        file_path_from_uri("file:///tmp/go%20project/%E4%B8%AD%E6%96%87/main.go"),
        "/tmp/go project/中文/main.go"
    );
    assert_eq!(
        file_path_from_uri("file://server/share/Main.java"),
        "//server/share/Main.java"
    );
}

#[test]
fn client_core_initializes_and_applies_server_capabilities() {
    let initialized = client_initialize(ClientInitializeRequest {
        state: LspClientState::default(),
        root_uri: "file:///tmp/project".to_string(),
        process_id: Some(42),
        initialization_options: Some(json!({
            "ui.semanticTokens": true
        })),
    })
    .unwrap();
    assert_eq!(
        initialized.state.pending_requests.get("1").unwrap(),
        "initialize"
    );
    let initialize_message: Value =
        serde_json::from_str(&initialized.messages[0]).expect("initialize JSON");
    // Snapshot the actual emitted request so later capability changes must
    // explicitly update the contract; the package version is build metadata.
    let mut expected_initialize: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/lsp/client-initialize-v1.json"
    ))
    .expect("initialize fixture");
    expected_initialize["params"]["clientInfo"]["version"] = json!(env!("CARGO_PKG_VERSION"));
    assert_eq!(initialize_message, expected_initialize);
    assert_eq!(initialize_message["method"], "initialize");
    assert_eq!(
        initialize_message["params"]["rootUri"],
        "file:///tmp/project"
    );
    assert_eq!(initialize_message["params"]["clientInfo"]["name"], "Lithe");
    assert_eq!(
        initialize_message["params"]["clientInfo"]["version"],
        env!("CARGO_PKG_VERSION")
    );
    assert_eq!(
        initialize_message["params"]["workspaceFolders"],
        json!([{
            "uri": "file:///tmp/project",
            "name": "project"
        }])
    );
    let client_capabilities = &initialize_message["params"]["capabilities"];
    assert_eq!(client_capabilities["workspace"]["configuration"], true);
    assert_eq!(client_capabilities["workspace"]["applyEdit"], false);
    assert_eq!(client_capabilities["workspace"]["workspaceFolders"], true);
    assert_eq!(
        client_capabilities["workspace"]["symbol"]["dynamicRegistration"],
        true
    );
    assert_eq!(
        client_capabilities["textDocument"]["completion"]["completionItem"]["snippetSupport"],
        true
    );
    assert_eq!(
        client_capabilities["textDocument"]["completion"]["completionItem"]["resolveSupport"]
            ["properties"],
        json!(["detail", "documentation", "textEdit", "additionalTextEdits"])
    );
    assert_eq!(
        initialize_message["params"]["initializationOptions"]["ui.semanticTokens"],
        true
    );
    assert_eq!(
        client_capabilities["textDocument"]["inlayHint"]["dynamicRegistration"],
        true
    );
    assert_eq!(
        client_capabilities["textDocument"]["foldingRange"]["dynamicRegistration"],
        true
    );
    assert_eq!(
        client_capabilities["textDocument"]["codeLens"]["dynamicRegistration"],
        true
    );
    assert!(client_capabilities["textDocument"]["synchronization"]
        .get("didSave")
        .is_none());
    assert_eq!(
        client_capabilities["textDocument"]["publishDiagnostics"]["relatedInformation"],
        true
    );
    assert_eq!(
        client_capabilities["textDocument"]["publishDiagnostics"]["versionSupport"],
        true
    );
    assert_eq!(
        client_capabilities["textDocument"]["publishDiagnostics"]["tagSupport"]["valueSet"],
        json!([1, 2])
    );
    assert_eq!(client_capabilities["window"]["workDoneProgress"], true);

    let applied = client_apply_server_message(ClientApplyServerMessageRequest {
        state: initialized.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "1",
                "result": {
                    "capabilities": {
                        "definitionProvider": true,
                        "hoverProvider": true,
                        "completionProvider": { "resolveProvider": true },
                        "codeActionProvider": { "resolveProvider": true },
                        "inlayHintProvider": true,
                        "foldingRangeProvider": {},
                        "codeLensProvider": { "resolveProvider": false },
                        "workspaceSymbolProvider": true
                    }
                }
            }"#
        .to_string(),
    })
    .unwrap();

    assert!(applied.state.initialized);
    assert!(applied.state.pending_requests.is_empty());
    assert!(applied
        .state
        .server_capabilities
        .contains(&"definition".to_string()));
    assert!(applied
        .state
        .server_capabilities
        .contains(&"completionResolve".to_string()));
    for feature in [
        "inlayHints",
        "foldingRanges",
        "codeLens",
        "workspaceSymbols",
    ] {
        assert!(applied
            .state
            .server_capabilities
            .contains(&feature.to_string()));
    }
    assert_eq!(applied.messages.len(), 1);
    let initialized_notification: Value =
        serde_json::from_str(&applied.messages[0]).expect("initialized JSON");
    assert_eq!(initialized_notification["method"], "initialized");
}

#[test]
fn client_core_does_not_initialize_without_valid_capabilities() {
    for message in [
        r#"{"jsonrpc":"2.0","id":"1","result":null}"#,
        r#"{"jsonrpc":"2.0","id":"1","result":{}}"#,
        r#"{"jsonrpc":"2.0","id":"1","error":{"code":-32603,"message":"rejected"}}"#,
    ] {
        let initialized = client_initialize(ClientInitializeRequest {
            state: LspClientState::default(),
            root_uri: "file:///tmp/project".to_string(),
            process_id: None,
            initialization_options: None,
        })
        .unwrap();
        let applied = client_apply_server_message(ClientApplyServerMessageRequest {
            state: initialized.state,
            message: message.to_string(),
        })
        .unwrap();

        assert!(!applied.state.initialized);
        assert!(applied.messages.is_empty());
        assert!(applied.state.server_capabilities.is_empty());
    }
}

#[test]
fn client_core_tracks_documents_and_feature_requests() {
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: "file:///tmp/project/main.rs".to_string(),
        language_id: "rust".to_string(),
        text: "fn main() {}\n".to_string(),
    })
    .unwrap();
    assert_eq!(
        opened
            .state
            .open_documents
            .get("file:///tmp/project/main.rs")
            .unwrap()
            .version,
        1
    );
    let did_open: Value = serde_json::from_str(&opened.messages[0]).unwrap();
    assert_eq!(did_open["method"], "textDocument/didOpen");

    let changed = client_change_document(ClientChangeDocumentRequest {
        state: opened.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        text: "fn main() { launch(); }\n".to_string(),
        content_changes: Vec::new(),
    })
    .unwrap();
    assert_eq!(
        changed
            .state
            .open_documents
            .get("file:///tmp/project/main.rs")
            .unwrap()
            .version,
        2
    );
    let did_change: Value = serde_json::from_str(&changed.messages[0]).unwrap();
    assert_eq!(did_change["method"], "textDocument/didChange");

    let requested = client_feature_request(ClientFeatureRequest {
        state: changed.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "textDocument/definition".to_string(),
        position: Some(LspPosition {
            line: 0,
            utf16_column: 12,
        }),
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    assert_eq!(
        requested.state.pending_requests.get("1").unwrap(),
        "textDocument/definition"
    );
    let request_message: Value = serde_json::from_str(&requested.messages[0]).unwrap();
    assert_eq!(request_message["method"], "textDocument/definition");
    assert_eq!(request_message["params"]["position"]["character"], 12);
}

#[test]
fn client_change_document_emits_incremental_ranges_when_the_server_supports_them() {
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: "file:///tmp/project/main.rs".to_string(),
        language_id: "rust".to_string(),
        text: "fn main() {}\n".to_string(),
    })
    .unwrap();
    let mut state = opened.state;
    state.text_document_sync = LspTextDocumentSyncKind::Incremental;
    let changed = client_change_document(ClientChangeDocumentRequest {
        state,
        uri: "file:///tmp/project/main.rs".to_string(),
        text: String::new(),
        content_changes: vec![LspDocumentContentChange {
            range: Some(LspRange {
                start: LspPosition {
                    line: 0,
                    utf16_column: 8,
                },
                end: LspPosition {
                    line: 0,
                    utf16_column: 8,
                },
            }),
            text: "launch".to_string(),
        }],
    })
    .unwrap();
    assert_eq!(
        changed
            .state
            .open_documents
            .get("file:///tmp/project/main.rs")
            .unwrap()
            .text,
        "fn main(launch) {}\n"
    );
    let did_change: Value = serde_json::from_str(&changed.messages[0]).unwrap();
    assert_eq!(did_change["method"], "textDocument/didChange");
    assert_eq!(did_change["params"]["contentChanges"][0]["text"], "launch");
    assert_eq!(
        did_change["params"]["contentChanges"][0]["range"]["start"]["character"],
        8
    );
}

#[test]
fn client_change_document_replays_multi_change_batches_end_to_start() {
    // Pre-event document. Both Monaco ranges are relative to this text:
    // insert "X" at column 1, and insert a newline at column 3 (between "c" and "d").
    // Sequential LSP apply in original left-to-right order would shift the
    // second range and diverge; end-to-start order keeps Core and wire aligned.
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: "file:///tmp/project/multi.rs".to_string(),
        language_id: "rust".to_string(),
        text: "abcd".to_string(),
    })
    .unwrap();
    let mut state = opened.state;
    state.text_document_sync = LspTextDocumentSyncKind::Incremental;
    let changed = client_change_document(ClientChangeDocumentRequest {
        state,
        uri: "file:///tmp/project/multi.rs".to_string(),
        text: String::new(),
        content_changes: vec![
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 1,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 1,
                    },
                }),
                text: "X".to_string(),
            },
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 3,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 3,
                    },
                }),
                text: "\n".to_string(),
            },
        ],
    })
    .unwrap();

    let document = changed
        .state
        .open_documents
        .get("file:///tmp/project/multi.rs")
        .unwrap();
    assert_eq!(document.text, "aXbc\nd");

    let did_change: Value = serde_json::from_str(&changed.messages[0]).unwrap();
    let content_changes = did_change["params"]["contentChanges"].as_array().unwrap();
    assert_eq!(content_changes.len(), 2);
    // Wire order must be end-to-start so sequential replay matches document.text.
    assert_eq!(content_changes[0]["text"], "\n");
    assert_eq!(content_changes[0]["range"]["start"]["character"], 3);
    assert_eq!(content_changes[1]["text"], "X");
    assert_eq!(content_changes[1]["range"]["start"]["character"], 1);

    let replayed = apply_content_changes_sequential(
        "abcd",
        &[
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 3,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 3,
                    },
                }),
                text: "\n".to_string(),
            },
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 1,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 1,
                    },
                }),
                text: "X".to_string(),
            },
        ],
    )
    .unwrap();
    assert_eq!(replayed, document.text);

    // Left-to-right sequential apply of the original Monaco order diverges,
    // which is exactly the bug the end-to-start wire order prevents.
    let diverged = apply_content_changes_sequential(
        "abcd",
        &[
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 1,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 1,
                    },
                }),
                text: "X".to_string(),
            },
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 3,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 3,
                    },
                }),
                text: "\n".to_string(),
            },
        ],
    )
    .unwrap();
    assert_ne!(diverged, document.text);
}

#[test]
fn client_change_document_falls_back_to_full_sync_for_overlapping_ranges() {
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: "file:///tmp/project/overlap.rs".to_string(),
        language_id: "rust".to_string(),
        text: "abcdef".to_string(),
    })
    .unwrap();
    let mut state = opened.state;
    state.text_document_sync = LspTextDocumentSyncKind::Incremental;
    let changed = client_change_document(ClientChangeDocumentRequest {
        state,
        uri: "file:///tmp/project/overlap.rs".to_string(),
        text: "Z".to_string(),
        content_changes: vec![
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 0,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 3,
                    },
                }),
                text: "AA".to_string(),
            },
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 2,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 5,
                    },
                }),
                text: "BB".to_string(),
            },
        ],
    })
    .unwrap();

    assert_eq!(
        changed
            .state
            .open_documents
            .get("file:///tmp/project/overlap.rs")
            .unwrap()
            .text,
        "Z"
    );
    let did_change: Value = serde_json::from_str(&changed.messages[0]).unwrap();
    assert_eq!(
        did_change["params"]["contentChanges"],
        json!([{ "text": "Z" }])
    );
}

#[test]
fn client_core_closes_open_documents() {
    let uri = "file:///tmp/project/main.go";
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: uri.to_string(),
        language_id: "go".to_string(),
        text: "package main\n".to_string(),
    })
    .unwrap();
    let diagnosed = client_apply_server_message(ClientApplyServerMessageRequest {
        state: opened.state,
        message: json!({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "version": 1,
                "diagnostics": [{
                    "range": {
                        "start": { "line": 0, "character": 0 },
                        "end": { "line": 0, "character": 7 }
                    },
                    "message": "Example diagnostic"
                }]
            }
        })
        .to_string(),
    })
    .unwrap();
    assert!(diagnosed.state.diagnostics.contains_key(uri));
    assert_eq!(diagnosed.state.diagnostic_versions.get(uri), Some(&1));

    let closed = client_close_document(ClientCloseDocumentRequest {
        state: diagnosed.state,
        uri: uri.to_string(),
    })
    .unwrap();

    assert!(!closed.state.open_documents.contains_key(uri));
    assert!(!closed.state.diagnostics.contains_key(uri));
    assert!(!closed.state.diagnostic_versions.contains_key(uri));
    assert_eq!(closed.messages.len(), 1);
    let did_close: Value = serde_json::from_str(&closed.messages[0]).unwrap();
    assert_eq!(
        did_close,
        json!({
            "jsonrpc": "2.0",
            "method": "textDocument/didClose",
            "params": {
                "textDocument": {
                    "uri": uri
                }
            }
        })
    );

    let error = client_close_document(ClientCloseDocumentRequest {
        state: closed.state,
        uri: uri.to_string(),
    })
    .unwrap_err();
    assert_eq!(serde_json::to_value(error.code).unwrap(), "invalid_request");
}

#[test]
fn client_core_ignores_diagnostics_for_unopened_or_stale_document_versions() {
    let uri = "file:///tmp/project/main.rs";
    let unopened = client_apply_server_message(ClientApplyServerMessageRequest {
        state: LspClientState::default(),
        message: json!({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "version": 1,
                "diagnostics": []
            }
        })
        .to_string(),
    })
    .unwrap();
    assert!(unopened.events.is_empty());
    assert!(!unopened.state.diagnostics.contains_key(uri));

    let opened = client_open_document(ClientOpenDocumentRequest {
        state: unopened.state,
        uri: uri.to_string(),
        language_id: "rust".to_string(),
        text: "fn main() {}\n".to_string(),
    })
    .unwrap();
    let changed = client_change_document(ClientChangeDocumentRequest {
        state: opened.state,
        uri: uri.to_string(),
        text: "fn main() { launch(); }\n".to_string(),
        content_changes: Vec::new(),
    })
    .unwrap();

    for stale_version in [1, 3] {
        let stale = client_apply_server_message(ClientApplyServerMessageRequest {
            state: changed.state.clone(),
            message: json!({
                "jsonrpc": "2.0",
                "method": "textDocument/publishDiagnostics",
                "params": {
                    "uri": uri,
                    "version": stale_version,
                    "diagnostics": [{
                        "range": {
                            "start": { "line": 0, "character": 0 },
                            "end": { "line": 0, "character": 2 }
                        },
                        "message": "Stale diagnostic"
                    }]
                }
            })
            .to_string(),
        })
        .unwrap();
        assert!(stale.events.is_empty());
        assert!(!stale.state.diagnostics.contains_key(uri));
    }

    let current = client_apply_server_message(ClientApplyServerMessageRequest {
        state: changed.state,
        message: json!({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "version": 2,
                "diagnostics": [{
                    "range": {
                        "start": { "line": 0, "character": 0 },
                        "end": { "line": 0, "character": 2 }
                    },
                    "message": "Current diagnostic"
                }]
            }
        })
        .to_string(),
    })
    .unwrap();
    assert_eq!(current.events.len(), 1);
    assert_eq!(current.events[0].version, Some(2));
    assert_eq!(current.state.diagnostic_versions.get(uri), Some(&2));

    let stale_after_current = client_apply_server_message(ClientApplyServerMessageRequest {
        state: current.state,
        message: json!({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "version": 1,
                "diagnostics": []
            }
        })
        .to_string(),
    })
    .unwrap();
    assert!(stale_after_current.events.is_empty());
    assert_eq!(
        stale_after_current.state.diagnostics[uri][0].message,
        "Current diagnostic"
    );
    assert_eq!(
        stale_after_current.state.diagnostic_versions.get(uri),
        Some(&2)
    );

    let unversioned = client_apply_server_message(ClientApplyServerMessageRequest {
        state: stale_after_current.state,
        message: json!({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "diagnostics": []
            }
        })
        .to_string(),
    })
    .unwrap();
    assert_eq!(unversioned.events.len(), 1);
    assert_eq!(unversioned.events[0].version, None);
    assert!(!unversioned.state.diagnostic_versions.contains_key(uri));
    assert!(serde_json::to_value(&unversioned.events[0])
        .unwrap()
        .get("version")
        .is_none());
}

#[test]
fn client_state_keeps_legacy_diagnostics_shape_compatible() {
    let uri = "file:///tmp/project/main.rs";
    let state: LspClientState = serde_json::from_value(json!({
        "diagnostics": {
            uri: []
        }
    }))
    .unwrap();

    assert!(state.diagnostics.contains_key(uri));
    assert!(state.diagnostic_versions.is_empty());
    let serialized = serde_json::to_value(state).unwrap();
    assert!(serialized["diagnostics"][uri].is_array());
    assert!(serialized.get("diagnosticVersions").is_none());
}

#[test]
fn client_core_waits_for_shutdown_response_before_exiting() {
    let mut state = LspClientState {
        initialized: true,
        ..LspClientState::default()
    };
    state.server_capabilities.push("completion".to_string());
    state.open_documents.insert(
        "file:///tmp/project/main.go".to_string(),
        LspClientDocument {
            uri: "file:///tmp/project/main.go".to_string(),
            language_id: "go".to_string(),
            version: 1,
            text: "package main\n".to_string(),
        },
    );

    let shutting_down = client_shutdown(ClientShutdownRequest { state }).unwrap();
    assert!(shutting_down.state.shutdown_requested);
    assert_eq!(
        shutting_down.state.pending_requests.get("1"),
        Some(&"shutdown".to_string())
    );
    let shutdown: Value = serde_json::from_str(&shutting_down.messages[0]).unwrap();
    assert_eq!(
        shutdown,
        json!({
            "jsonrpc": "2.0",
            "id": "1",
            "method": "shutdown"
        })
    );

    let exited = client_apply_server_message(ClientApplyServerMessageRequest {
        state: shutting_down.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "1",
            "result": null
        })
        .to_string(),
    })
    .unwrap();

    assert!(!exited.state.initialized);
    assert!(!exited.state.shutdown_requested);
    assert!(exited.state.pending_requests.is_empty());
    assert!(exited.state.server_capabilities.is_empty());
    assert!(exited.state.open_documents.is_empty());
    assert_eq!(exited.messages.len(), 1);
    let exit: Value = serde_json::from_str(&exited.messages[0]).unwrap();
    assert_eq!(
        exit,
        json!({
            "jsonrpc": "2.0",
            "method": "exit"
        })
    );
    assert_eq!(exited.events.len(), 1);
    assert_eq!(exited.events[0].method.as_deref(), Some("shutdown"));
}

#[test]
fn client_core_rejects_duplicate_shutdown_requests() {
    let shutting_down = client_shutdown(ClientShutdownRequest {
        state: LspClientState::default(),
    })
    .unwrap();

    let error = client_shutdown(ClientShutdownRequest {
        state: shutting_down.state,
    })
    .unwrap_err();
    assert_eq!(serde_json::to_value(error.code).unwrap(), "invalid_request");
}

#[test]
fn frame_message_uses_lsp_content_length_bytes() {
    let message = r#"{"jsonrpc":"2.0","method":"window/logMessage","params":{"message":"你好"}}"#;
    let framed = frame_message(FrameMessageRequest {
        message: message.to_string(),
    })
    .unwrap();
    assert!(framed
        .frame
        .starts_with(&format!("Content-Length: {}\r\n\r\n", message.len())));
    assert!(framed.frame.ends_with(message));
}

#[test]
fn parse_server_messages_returns_complete_messages_and_remaining_buffer() {
    let first = r#"{"jsonrpc":"2.0","id":1,"result":null}"#;
    let second = r#"{"jsonrpc":"2.0","method":"window/logMessage","params":{"message":"ok"}}"#;
    let first_frame = frame_message(FrameMessageRequest {
        message: first.to_string(),
    })
    .unwrap()
    .frame;
    let second_frame = frame_message(FrameMessageRequest {
        message: second.to_string(),
    })
    .unwrap()
    .frame;
    let split_at = first_frame.len() - 3;
    let partial = parse_server_messages(ParseServerMessagesRequest {
        buffer: Vec::new(),
        chunk: first_frame.as_bytes()[..split_at].to_vec(),
    })
    .unwrap();
    assert!(partial.messages.is_empty());
    assert_eq!(partial.buffer, first_frame.as_bytes()[..split_at]);

    let mut next_chunk = first_frame.as_bytes()[split_at..].to_vec();
    next_chunk.extend(second_frame.as_bytes());
    let parsed = parse_server_messages(ParseServerMessagesRequest {
        buffer: partial.buffer,
        chunk: next_chunk,
    })
    .unwrap();
    assert_eq!(parsed.messages, vec![first.to_string(), second.to_string()]);
    assert!(parsed.buffer.is_empty());
}

#[test]
fn client_core_shapes_feature_responses_for_swift_models() {
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: "file:///tmp/project/main.rs".to_string(),
        language_id: "rust".to_string(),
        text: "fn main() { la }\n".to_string(),
    })
    .unwrap();
    let requested = client_feature_request(ClientFeatureRequest {
        state: opened.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "textDocument/completion".to_string(),
        position: Some(LspPosition {
            line: 0,
            utf16_column: 14,
        }),
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let completed = client_apply_server_message(ClientApplyServerMessageRequest {
        state: requested.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "1",
                "result": {
                    "items": [{
                        "label": "launch",
                        "kind": 3,
                        "detail": "fn()",
                        "textEdit": {
                            "range": {
                                "start": { "line": 0, "character": 12 },
                                "end": { "line": 0, "character": 14 }
                            },
                            "newText": "launch"
                        }
                    }]
                }
            }"#
        .to_string(),
    })
    .unwrap();

    let result = completed.events[0].result.as_ref().unwrap();
    assert_eq!(result["items"][0]["label"], "launch");
    assert_eq!(
        result["items"][0]["textEdit"]["range"]["start"]["utf16Column"],
        12
    );

    let rename = client_feature_request(ClientFeatureRequest {
        state: completed.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "textDocument/rename".to_string(),
        position: Some(LspPosition {
            line: 0,
            utf16_column: 12,
        }),
        new_name: Some("start".to_string()),
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let renamed = client_apply_server_message(ClientApplyServerMessageRequest {
        state: rename.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "2",
                "result": {
                    "changes": {
                        "file:///tmp/project/main.rs": [{
                            "range": {
                                "start": { "line": 0, "character": 12 },
                                "end": { "line": 0, "character": 18 }
                            },
                            "newText": "start"
                        }]
                    }
                }
            }"#
        .to_string(),
    })
    .unwrap();
    let rename_result = renamed.events[0].result.as_ref().unwrap();
    assert_eq!(
        rename_result["operations"][0]["edits"][0]["newText"],
        "start"
    );

    let formatting = client_feature_request(ClientFeatureRequest {
        state: renamed.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "textDocument/formatting".to_string(),
        position: None,
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let formatted = client_apply_server_message(ClientApplyServerMessageRequest {
        state: formatting.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "3",
                "result": [{
                    "range": {
                        "start": { "line": 0, "character": 2 },
                        "end": { "line": 0, "character": 2 }
                    },
                    "newText": " "
                }]
            }"#
        .to_string(),
    })
    .unwrap();
    let format_result = formatted.events[0].result.as_ref().unwrap();
    assert_eq!(
        format_result["edits"][0]["range"]["start"]["utf16Column"],
        2
    );

    let code_actions = client_feature_request(ClientFeatureRequest {
        state: formatted.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "textDocument/codeAction".to_string(),
        position: None,
        new_name: None,
        range: Some(LspRange {
            start: LspPosition {
                line: 0,
                utf16_column: 0,
            },
            end: LspPosition {
                line: 0,
                utf16_column: 0,
            },
        }),
        diagnostics: vec![LspClientDiagnostic {
            range: LspRangeResponse {
                start: LspPositionResponse {
                    line: 0,
                    utf16_column: 12,
                },
                end: LspPositionResponse {
                    line: 0,
                    utf16_column: 18,
                },
            },
            severity: Some(2),
            message: "rename suggestion".to_string(),
            source: Some("rust-analyzer".to_string()),
            code: None,
            tags: vec![1, 99],
            related_information: vec![LspClientDiagnosticRelatedInformation {
                location: LspClientDiagnosticLocation {
                    uri: "file:///tmp/project/lib.rs".to_string(),
                    range: LspRangeResponse {
                        start: LspPositionResponse {
                            line: 3,
                            utf16_column: 4,
                        },
                        end: LspPositionResponse {
                            line: 3,
                            utf16_column: 8,
                        },
                    },
                },
                message: "declared here".to_string(),
            }],
        }],
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let code_action_request: Value = serde_json::from_str(&code_actions.messages[0]).unwrap();
    assert_eq!(code_action_request["method"], "textDocument/codeAction");
    assert_eq!(
        code_action_request["params"]["context"]["diagnostics"][0]["range"]["start"]["character"],
        12
    );
    assert_eq!(
        code_action_request["params"]["context"]["diagnostics"][0]["tags"],
        json!([1, 99])
    );
    assert_eq!(
        code_action_request["params"]["context"]["diagnostics"][0]["relatedInformation"][0]
            ["location"]["uri"],
        "file:///tmp/project/lib.rs"
    );
    assert_eq!(
        code_action_request["params"]["context"]["diagnostics"][0]["relatedInformation"][0]
            ["location"]["range"]["start"]["character"],
        4
    );
    let code_actioned = client_apply_server_message(ClientApplyServerMessageRequest {
        state: code_actions.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "4",
                "result": [{
                    "title": "Apply rename",
                    "kind": "quickfix",
                    "isPreferred": true,
                    "edit": {
                        "changes": {
                            "file:///tmp/project/main.rs": [{
                                "range": {
                                    "start": { "line": 0, "character": 12 },
                                    "end": { "line": 0, "character": 18 }
                                },
                                "newText": "start"
                            }]
                        }
                    },
                    "command": {
                        "title": "Apply",
                        "command": "rust-analyzer.applySourceChange",
                        "arguments": [{ "label": "rename" }]
                    },
                    "data": { "id": "action-1" }
                }]
            }"#
        .to_string(),
    })
    .unwrap();
    let action_result = code_actioned.events[0].result.as_ref().unwrap();
    assert_eq!(action_result["actions"][0]["title"], "Apply rename");
    assert_eq!(
        action_result["actions"][0]["edit"]["operations"][0]["edits"][0]["newText"],
        "start"
    );
    assert_eq!(
        action_result["actions"][0]["command"]["command"],
        "rust-analyzer.applySourceChange"
    );

    let code_action_resolve = client_feature_request(ClientFeatureRequest {
        state: code_actioned.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "codeAction/resolve".to_string(),
        position: None,
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: Some(json!({
            "title": "Apply rename",
            "kind": "quickfix",
            "isPreferred": true,
            "data": { "id": "action-1" }
        })),
        command: None,
    })
    .unwrap();
    let code_action_resolve_request: Value =
        serde_json::from_str(&code_action_resolve.messages[0]).unwrap();
    assert_eq!(code_action_resolve_request["method"], "codeAction/resolve");
    assert_eq!(
        code_action_resolve_request["params"]["title"],
        "Apply rename"
    );
    let code_action_resolved = client_apply_server_message(ClientApplyServerMessageRequest {
        state: code_action_resolve.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "5",
                "result": {
                    "title": "Apply rename",
                    "kind": "quickfix",
                    "edit": {
                        "changes": {
                            "file:///tmp/project/main.rs": [{
                                "range": {
                                    "start": { "line": 0, "character": 12 },
                                    "end": { "line": 0, "character": 18 }
                                },
                                "newText": "start"
                            }]
                        }
                    },
                    "data": { "id": "action-1" }
                }
            }"#
        .to_string(),
    })
    .unwrap();
    let code_action_resolve_result = code_action_resolved.events[0].result.as_ref().unwrap();
    assert_eq!(
        code_action_resolve_result["action"]["edit"]["operations"][0]["edits"][0]["newText"],
        "start"
    );

    let completion_resolve = client_feature_request(ClientFeatureRequest {
        state: code_action_resolved.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "completionItem/resolve".to_string(),
        position: None,
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: Some(json!({
            "label": "launch",
            "insertText": "launch",
            "kind": 3,
            "textEdit": {
                "range": {
                    "start": { "line": 0, "utf16Column": 12 },
                    "end": { "line": 0, "utf16Column": 14 }
                },
                "newText": "launch"
            },
            "data": { "id": "completion-1" }
        })),
        code_action: None,
        command: None,
    })
    .unwrap();
    let completion_resolve_request: Value =
        serde_json::from_str(&completion_resolve.messages[0]).unwrap();
    assert_eq!(
        completion_resolve_request["method"],
        "completionItem/resolve"
    );
    assert_eq!(
        completion_resolve_request["params"]["textEdit"]["range"]["start"]["character"],
        12
    );
    let completion_resolved = client_apply_server_message(ClientApplyServerMessageRequest {
        state: completion_resolve.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "6",
                "result": {
                    "label": "launch",
                    "kind": 3,
                    "detail": "fn launch()",
                    "documentation": { "kind": "markdown", "value": "Launches the app." },
                    "insertText": "launch",
                    "data": { "id": "completion-1" }
                }
            }"#
        .to_string(),
    })
    .unwrap();
    let completion_resolve_result = completion_resolved.events[0].result.as_ref().unwrap();
    assert_eq!(
        completion_resolve_result["item"]["documentation"],
        "Launches the app."
    );

    let execute_command = client_feature_request(ClientFeatureRequest {
        state: completion_resolved.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "workspace/executeCommand".to_string(),
        position: None,
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: Some(json!({
            "title": "Apply",
            "command": "rust-analyzer.applySourceChange",
            "arguments": [{ "label": "rename" }]
        })),
    })
    .unwrap();
    let execute_request: Value = serde_json::from_str(&execute_command.messages[0]).unwrap();
    assert_eq!(execute_request["method"], "workspace/executeCommand");
    assert_eq!(
        execute_request["params"]["command"],
        "rust-analyzer.applySourceChange"
    );
    let executed = client_apply_server_message(ClientApplyServerMessageRequest {
        state: execute_command.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "7",
                "result": 5005
            }"#
        .to_string(),
    })
    .unwrap();
    assert_eq!(executed.events[0].result.as_ref().unwrap()["value"], 5005);
}

#[test]
fn client_core_requests_and_shapes_inlay_hints_folding_ranges_and_code_lenses() {
    let uri = "file:///tmp/project/Main.java";
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: uri.to_string(),
        language_id: "java".to_string(),
        text: "class Main {}\n".to_string(),
    })
    .unwrap();

    let inlay_request = client_feature_request(ClientFeatureRequest {
        state: opened.state,
        uri: uri.to_string(),
        method: "textDocument/inlayHint".to_string(),
        position: None,
        new_name: None,
        range: Some(LspRange {
            start: LspPosition {
                line: 0,
                utf16_column: 0,
            },
            end: LspPosition {
                line: 20,
                utf16_column: 0,
            },
        }),
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let request_json: Value = serde_json::from_str(&inlay_request.messages[0]).unwrap();
    assert_eq!(request_json["method"], "textDocument/inlayHint");
    assert_eq!(request_json["params"]["range"]["end"]["line"], 20);

    let inlay_response = client_apply_server_message(ClientApplyServerMessageRequest {
        state: inlay_request.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "1",
            "result": [{
                "position": { "line": 4, "character": 12 },
                "label": [{ "value": "parameter" }, { "value": ":" }],
                "kind": 2,
                "tooltip": { "kind": "markdown", "value": "Parameter name" },
                "paddingLeft": true,
                "paddingRight": false,
                "textEdits": [{
                    "range": {
                        "start": { "line": 4, "character": 12 },
                        "end": { "line": 4, "character": 12 }
                    },
                    "newText": "parameter: "
                }],
                "data": { "id": "hint-1" }
            }]
        })
        .to_string(),
    })
    .unwrap();
    let hint = &inlay_response.events[0].result.as_ref().unwrap()["hints"][0];
    assert_eq!(hint["position"]["utf16Column"], 12);
    assert_eq!(hint["label"], "parameter:");
    assert_eq!(hint["kind"], 2);
    assert_eq!(hint["tooltip"], "Parameter name");
    assert_eq!(hint["paddingLeft"], true);
    assert_eq!(hint["textEdits"][0]["range"]["start"]["utf16Column"], 12);
    assert_eq!(hint["data"]["id"], "hint-1");

    let folding_request = client_feature_request(ClientFeatureRequest {
        state: inlay_response.state,
        uri: uri.to_string(),
        method: "textDocument/foldingRange".to_string(),
        position: None,
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let request_json: Value = serde_json::from_str(&folding_request.messages[0]).unwrap();
    assert_eq!(request_json["method"], "textDocument/foldingRange");
    assert_eq!(request_json["params"]["textDocument"]["uri"], uri);
    let folding_response = client_apply_server_message(ClientApplyServerMessageRequest {
        state: folding_request.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "2",
            "result": [{
                "startLine": 2,
                "startCharacter": 4,
                "endLine": 8,
                "endCharacter": 1,
                "kind": "region",
                "collapsedText": "methods"
            }]
        })
        .to_string(),
    })
    .unwrap();
    let range = &folding_response.events[0].result.as_ref().unwrap()["ranges"][0];
    assert_eq!(range["startLine"], 2);
    assert_eq!(range["startUtf16Column"], 4);
    assert_eq!(range["endLine"], 8);
    assert_eq!(range["endUtf16Column"], 1);
    assert_eq!(range["kind"], "region");
    assert_eq!(range["collapsedText"], "methods");

    let code_lens_request = client_feature_request(ClientFeatureRequest {
        state: folding_response.state,
        uri: uri.to_string(),
        method: "textDocument/codeLens".to_string(),
        position: None,
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let code_lens_response = client_apply_server_message(ClientApplyServerMessageRequest {
        state: code_lens_request.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "3",
            "result": [{
                "range": {
                    "start": { "line": 3, "character": 2 },
                    "end": { "line": 3, "character": 7 }
                },
                "command": {
                    "title": "Run test",
                    "command": "java.test.run",
                    "arguments": [{ "test": "MainTest" }]
                },
                "data": { "id": "lens-1" }
            }]
        })
        .to_string(),
    })
    .unwrap();
    let lens = &code_lens_response.events[0].result.as_ref().unwrap()["lenses"][0];
    assert_eq!(lens["range"]["start"]["utf16Column"], 2);
    assert_eq!(lens["command"]["command"], "java.test.run");
    assert_eq!(lens["command"]["arguments"][0]["test"], "MainTest");
    assert_eq!(lens["data"]["id"], "lens-1");
}

#[test]
fn navigation_locations_preserve_uris_without_fabricating_virtual_file_paths() {
    let uri = "file:///tmp/project/Main.java";
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: uri.to_string(),
        language_id: "java".to_string(),
        text: "class Main {}\n".to_string(),
    })
    .unwrap();
    let requested = client_feature_request(ClientFeatureRequest {
        state: opened.state,
        uri: uri.to_string(),
        method: "textDocument/definition".to_string(),
        position: Some(LspPosition {
            line: 0,
            utf16_column: 6,
        }),
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let response = client_apply_server_message(ClientApplyServerMessageRequest {
        state: requested.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "1",
            "result": [{
                "uri": "file:///tmp/project/Main%20File.java",
                "range": {
                    "start": { "line": 1, "character": 2 },
                    "end": { "line": 1, "character": 6 }
                }
            }, {
                "uri": "jdt://contents/java.base/java/lang/String.class",
                "range": {
                    "start": { "line": 10, "character": 4 },
                    "end": { "line": 10, "character": 10 }
                }
            }]
        })
        .to_string(),
    })
    .unwrap();
    let locations = &response.events[0].result.as_ref().unwrap()["locations"];

    assert_eq!(locations[0]["uri"], "file:///tmp/project/Main%20File.java");
    assert_eq!(locations[0]["filePath"], "/tmp/project/Main File.java");
    assert_eq!(locations[0]["isReadOnly"], false);
    assert_eq!(
        locations[1]["uri"],
        "jdt://contents/java.base/java/lang/String.class"
    );
    assert!(locations[1]["filePath"].is_null());
    assert_eq!(locations[1]["isReadOnly"], true);
    assert!(locations[1]["displayPath"].is_null());
}

#[test]
fn client_core_applies_diagnostics_and_dynamic_registrations() {
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: "file:///tmp/project/main.py".to_string(),
        language_id: "python".to_string(),
        text: "example = value\n".to_string(),
    })
    .unwrap();
    let diagnostics = client_apply_server_message(ClientApplyServerMessageRequest {
        state: opened.state,
        message: r#"{
                "jsonrpc": "2.0",
                "method": "textDocument/publishDiagnostics",
                "params": {
                    "uri": "file:///tmp/project/main.py",
                    "version": 1,
                    "diagnostics": [{
                        "range": {
                            "start": { "line": 2, "character": 4 },
                            "end": { "line": 2, "character": 9 }
                        },
                        "source": "pyright",
                        "code": "reportGeneralTypeIssues",
                        "message": "Example diagnostic",
                        "tags": [1, 2, 99],
                        "relatedInformation": [{
                            "location": {
                                "uri": "file:///tmp/project/types.py",
                                "range": {
                                    "start": { "line": 8, "character": 2 },
                                    "end": { "line": 8, "character": 7 }
                                }
                            },
                            "message": "Type declared here"
                        }]
                    }]
                }
            }"#
        .to_string(),
    })
    .unwrap();
    let stored = diagnostics
        .state
        .diagnostics
        .get("file:///tmp/project/main.py")
        .unwrap();
    assert_eq!(stored[0].message, "Example diagnostic");
    assert_eq!(stored[0].range.start.utf16_column, 4);
    assert_eq!(stored[0].severity, None);
    assert_eq!(stored[0].tags, vec![1, 2, 99]);
    assert_eq!(stored[0].related_information.len(), 1);
    assert_eq!(
        stored[0].related_information[0].location.uri,
        "file:///tmp/project/types.py"
    );
    assert_eq!(
        stored[0].related_information[0]
            .location
            .range
            .start
            .utf16_column,
        2
    );
    assert_eq!(
        stored[0].related_information[0].message,
        "Type declared here"
    );
    assert_eq!(diagnostics.events[0].kind, "diagnostics");
    assert_eq!(diagnostics.events[0].version, Some(1));
    assert_eq!(
        diagnostics
            .state
            .diagnostic_versions
            .get("file:///tmp/project/main.py"),
        Some(&1)
    );
    let event_json = serde_json::to_value(&diagnostics.events[0]).unwrap();
    assert_eq!(event_json["version"], 1);
    assert_eq!(event_json["diagnostics"][0]["tags"], json!([1, 2, 99]));
    assert_eq!(
        event_json["diagnostics"][0]["relatedInformation"][0]["location"]["range"]["start"]
            ["utf16Column"],
        2
    );

    let registered = client_apply_server_message(ClientApplyServerMessageRequest {
        state: diagnostics.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": 77,
                "method": "client/registerCapability",
                "params": {
                    "registrations": [{
                        "id": "formatting",
                        "method": "textDocument/formatting",
                        "registerOptions": {}
                    }, {
                        "id": "inlay-hints",
                        "method": "textDocument/inlayHint",
                        "registerOptions": {}
                    }, {
                        "id": "folding-ranges",
                        "method": "textDocument/foldingRange",
                        "registerOptions": {}
                    }, {
                        "id": "code-lens",
                        "method": "textDocument/codeLens",
                        "registerOptions": {}
                    }, {
                        "id": "workspace-symbols",
                        "method": "workspace/symbol",
                        "registerOptions": {}
                    }]
                }
            }"#
        .to_string(),
    })
    .unwrap();
    assert!(registered
        .state
        .server_capabilities
        .contains(&"formatting".to_string()));
    for feature in [
        "inlayHints",
        "foldingRanges",
        "codeLens",
        "workspaceSymbols",
    ] {
        assert!(registered
            .state
            .server_capabilities
            .contains(&feature.to_string()));
    }
    let response: Value = serde_json::from_str(&registered.messages[0]).unwrap();
    assert_eq!(
        response,
        json!({ "jsonrpc": "2.0", "id": 77, "result": null })
    );

    let unregistered = client_apply_server_message(ClientApplyServerMessageRequest {
        state: registered.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "unregister-1",
                "method": "client/unregisterCapability",
                "params": {
                    "unregisterations": [{
                        "id": "formatting",
                        "method": "textDocument/formatting"
                    }, {
                        "id": "inlay-hints",
                        "method": "textDocument/inlayHint"
                    }, {
                        "id": "folding-ranges",
                        "method": "textDocument/foldingRange"
                    }, {
                        "id": "code-lens",
                        "method": "textDocument/codeLens"
                    }, {
                        "id": "workspace-symbols",
                        "method": "workspace/symbol"
                    }]
                }
            }"#
        .to_string(),
    })
    .unwrap();
    assert!(!unregistered
        .state
        .server_capabilities
        .contains(&"formatting".to_string()));
    for feature in [
        "inlayHints",
        "foldingRanges",
        "codeLens",
        "workspaceSymbols",
    ] {
        assert!(!unregistered
            .state
            .server_capabilities
            .contains(&feature.to_string()));
    }
    let response: Value = serde_json::from_str(&unregistered.messages[0]).unwrap();
    assert_eq!(
        response,
        json!({ "jsonrpc": "2.0", "id": "unregister-1", "result": null })
    );
}

#[test]
fn client_core_answers_workspace_configuration_requests_by_item() {
    let response = client_apply_server_message(ClientApplyServerMessageRequest {
        state: LspClientState::default(),
        message: r#"{
                "jsonrpc": "2.0",
                "id": "configuration-1",
                "method": "workspace/configuration",
                "params": {
                    "items": [
                        { "section": "gopls" },
                        { "scopeUri": "file:///tmp/project", "section": "gopls.ui" }
                    ]
                }
            }"#
        .to_string(),
    })
    .unwrap();

    assert!(response.events.is_empty());
    assert_eq!(response.messages.len(), 1);
    let message: Value = serde_json::from_str(&response.messages[0]).unwrap();
    assert_eq!(
        message,
        json!({
            "jsonrpc": "2.0",
            "id": "configuration-1",
            "result": [null, null]
        })
    );
}

#[test]
fn client_core_answers_workspace_folder_and_progress_requests() {
    for (method, id) in [
        ("workspace/workspaceFolders", json!(42)),
        ("window/workDoneProgress/create", json!("progress-1")),
    ] {
        let response = client_apply_server_message(ClientApplyServerMessageRequest {
            state: LspClientState::default(),
            message: json!({
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": {}
            })
            .to_string(),
        })
        .unwrap();

        assert!(response.events.is_empty());
        assert_eq!(response.messages.len(), 1);
        let message: Value = serde_json::from_str(&response.messages[0]).unwrap();
        assert_eq!(
            message,
            json!({ "jsonrpc": "2.0", "id": id, "result": null })
        );
    }
}

#[test]
fn client_core_rejects_unknown_server_requests_with_method_not_found() {
    let response = client_apply_server_message(ClientApplyServerMessageRequest {
        state: LspClientState::default(),
        message: r#"{
                "jsonrpc": "2.0",
                "id": 91,
                "method": "experimental/notSupported",
                "params": { "value": true }
            }"#
        .to_string(),
    })
    .unwrap();

    assert!(response.events.is_empty());
    assert_eq!(response.messages.len(), 1);
    let message: Value = serde_json::from_str(&response.messages[0]).unwrap();
    assert_eq!(
        message,
        json!({
            "jsonrpc": "2.0",
            "id": 91,
            "error": {
                "code": -32601,
                "message": "Method not found"
            }
        })
    );
}

// Workspace edits cross both the pure client and the runtime bridge. These
// fixtures assert observable normalized payloads, not a private parser shape.
fn workspace_edit_fixture() -> Value {
    serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/fixtures/lsp/workspace-edit-v1.json"
    )))
    .expect("shared workspace edit fixture must be valid JSON")
}

fn workspace_edit_response_event(method: &str, result: Value) -> Value {
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: "file:///workspace/main.go".to_string(),
        language_id: "go".to_string(),
        text: "package main\n".to_string(),
    })
    .expect("fixture document should open");
    let requested = client_feature_request(ClientFeatureRequest {
        state: opened.state,
        uri: "file:///workspace/main.go".to_string(),
        method: method.to_string(),
        position: Some(LspPosition {
            line: 0,
            utf16_column: 0,
        }),
        new_name: Some("renamed".to_string()),
        range: Some(LspRange {
            start: LspPosition {
                line: 0,
                utf16_column: 0,
            },
            end: LspPosition {
                line: 0,
                utf16_column: 0,
            },
        }),
        diagnostics: Vec::new(),
        completion_item: Some(json!({ "label": "completion", "data": { "id": 3 } })),
        code_action: Some(json!({ "title": "Update sources", "data": { "id": 3 } })),
        command: None,
    })
    .expect("existing language request should be accepted");
    let outgoing: Value = serde_json::from_str(&requested.messages[0]).unwrap();
    let response = client_apply_server_message(ClientApplyServerMessageRequest {
        state: requested.state,
        message: json!({ "jsonrpc": "2.0", "id": outgoing["id"], "result": result }).to_string(),
    })
    .expect("a malformed feature payload must finish its request, not fail the message reducer");
    assert!(response.state.pending_requests.is_empty());
    assert_eq!(
        response.events.len(),
        1,
        "each response has one terminal event"
    );
    let event = serde_json::to_value(&response.events[0]).unwrap();
    assert_eq!(event["requestId"], outgoing["id"]);
    assert_eq!(event["method"], method);
    event
}

#[test]
fn workspace_edit_rename_preserves_shared_valid_matrix() {
    let fixture = workspace_edit_fixture();
    let mismatches: Vec<_> = fixture["valid"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|case| {
            let event = workspace_edit_response_event("textDocument/rename", case["wire"].clone());
            (event["result"] != case["normalized"] || event["kind"] != "response")
                .then(|| format!("{}: {}", case["name"], event))
        })
        .collect();
    assert!(
        mismatches.is_empty(),
        "workspace edit fidelity failures: {mismatches:#?}"
    );
}

#[test]
fn workspace_edit_malformed_matrix_fails_without_partial_results() {
    let fixture = workspace_edit_fixture();
    let mismatches: Vec<_> = fixture["invalid"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|case| {
            let event = workspace_edit_response_event("textDocument/rename", case["wire"].clone());
            let expected = event["kind"] == "error"
                && event["result"].is_null()
                && event["resultError"]["code"] == case["code"]
                && event["resultError"]["message"]
                    .as_str()
                    .is_some_and(|message| !message.is_empty());
            (!expected).then(|| format!("{}: {}", case["name"], event))
        })
        .collect();
    assert!(
        mismatches.is_empty(),
        "unsafe partial/defaulted edits: {mismatches:#?}"
    );
}

#[test]
fn workspace_edit_code_actions_preserve_ordered_edits_and_opaque_data() {
    let fixture = workspace_edit_fixture();
    let case = &fixture["valid"][0];
    let data = json!({ "opaque": [null, false, 0, "🦀"], "nested": { "token": "fixture-token" } });
    let event = workspace_edit_response_event(
        "textDocument/codeAction",
        json!([{
            "title": "Update sources", "edit": case["wire"], "data": data
        }]),
    );
    assert_eq!(event["result"]["actions"][0]["edit"], case["normalized"]);
    assert_eq!(event["result"]["actions"][0]["data"], data);
}

#[test]
fn workspace_edit_resolve_preserves_resource_options_and_versions() {
    let fixture = workspace_edit_fixture();
    let case = &fixture["valid"][0];
    let event = workspace_edit_response_event(
        "codeAction/resolve",
        json!({
            "title": "Update sources", "edit": case["wire"], "data": { "id": 3 }
        }),
    );
    assert_eq!(event["result"]["action"]["edit"], case["normalized"]);
    assert_eq!(event["result"]["action"]["data"], json!({ "id": 3 }));
}

#[test]
fn workspace_edit_malformed_action_rejects_the_entire_action_response() {
    let event = workspace_edit_response_event(
        "textDocument/codeAction",
        json!([
            { "title": "Valid", "edit": { "changes": { "file:///workspace/a.go": [] } } },
            { "title": "Invalid", "edit": { "documentChanges": [{ "kind": "unknown" }] } }
        ]),
    );
    assert_eq!(event["kind"], "error");
    assert!(
        event["result"].is_null(),
        "no successful subset may escape validation"
    );
    assert_eq!(
        event["resultError"]["code"],
        "lsp.workspaceEdit.unknownOperation"
    );
}

#[test]
fn workspace_edit_malformed_resolve_has_a_stable_error() {
    let event = workspace_edit_response_event(
        "codeAction/resolve",
        json!({
            "title": "Invalid", "edit": { "documentChanges": [{ "kind": "create" }] }
        }),
    );
    assert_eq!(event["kind"], "error");
    assert!(event["result"].is_null());
    assert_eq!(event["resultError"]["code"], "lsp.workspaceEdit.missingURI");
}

#[test]
fn workspace_edit_null_action_edit_cannot_release_its_command() {
    for method in ["textDocument/codeAction", "codeAction/resolve"] {
        let action = json!({
            "title": "Malformed action", "edit": null,
            "command": { "title": "Follow-up", "command": "fixture.command" }
        });
        let result = if method == "textDocument/codeAction" {
            json!([action])
        } else {
            action
        };
        let event = workspace_edit_response_event(method, result);
        assert_eq!(event["kind"], "error", "{method}: {event}");
        assert!(event["result"].is_null());
        assert_eq!(
            event["resultError"]["code"],
            "lsp.workspaceEdit.malformedEdit"
        );
    }
}

#[test]
fn workspace_edit_formatting_and_completion_never_drop_or_default_malformed_edits() {
    let valid = json!({
        "range": { "start": { "line": 0, "character": 0 }, "end": { "line": 0, "character": 0 } },
        "newText": "valid"
    });
    let invalid = json!({
        "range": { "start": { "character": 0 }, "end": { "line": 0, "character": 0 } },
        "newText": "invalid"
    });
    let cases = [
        ("textDocument/formatting", json!([valid, invalid])),
        (
            "textDocument/completion",
            json!([{"label": "invalid", "textEdit": invalid}]),
        ),
        (
            "textDocument/completion",
            json!([{"label": "invalid", "additionalTextEdits": [valid, invalid]}]),
        ),
        (
            "completionItem/resolve",
            json!({"label": "invalid", "textEdit": invalid}),
        ),
    ];
    let failures: Vec<_> = cases
        .into_iter()
        .filter_map(|(method, result)| {
            let event = workspace_edit_response_event(method, result);
            let rejected = event["kind"] == "error"
                && event["result"].is_null()
                && event["resultError"]["code"] == "lsp.workspaceEdit.malformedEdit";
            (!rejected).then(|| format!("{method}: {event}"))
        })
        .collect();
    assert!(
        failures.is_empty(),
        "Malformed edits escaped validation: {failures:#?}"
    );
}

#[test]
fn prepare_rename_capability_and_result_shapes_are_normalized() {
    let mut state = LspClientState::default();
    let initialized = client_initialize(ClientInitializeRequest {
        state,
        root_uri: "file:///tmp/project".to_string(),
        process_id: Some(7),
        initialization_options: None,
    })
    .unwrap();
    let init_msg: Value = serde_json::from_str(&initialized.messages[0]).unwrap();
    assert_eq!(
        init_msg["params"]["capabilities"]["textDocument"]["rename"]["prepareSupport"],
        true
    );
    assert_eq!(
        init_msg["params"]["capabilities"]["textDocument"]["rename"]
            ["prepareSupportDefaultBehavior"],
        1
    );
    assert_eq!(
        init_msg["params"]["capabilities"]["textDocument"]["codeAction"]["dataSupport"],
        true
    );
    state = initialized.state;

    let applied = client_apply_server_message(ClientApplyServerMessageRequest {
        state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "1",
            "result": {
                "capabilities": {
                    "renameProvider": { "prepareProvider": true }
                }
            }
        })
        .to_string(),
    })
    .unwrap();
    state = applied.state;
    assert!(state.server_capabilities.iter().any(|c| c == "rename"));
    assert!(state
        .server_capabilities
        .iter()
        .any(|c| c == "prepareRename"));

    let opened = client_open_document(ClientOpenDocumentRequest {
        state,
        uri: "file:///tmp/project/main.go".to_string(),
        language_id: "go".to_string(),
        text: "package main\nfunc greet() {}\n".to_string(),
    })
    .unwrap();
    state = opened.state;

    let cases = [
        (
            json!({
                "start": { "line": 1, "character": 5 },
                "end": { "line": 1, "character": 10 }
            }),
            json!({
                "prepareRename": {
                    "range": {
                        "start": { "line": 1, "utf16Column": 5 },
                        "end": { "line": 1, "utf16Column": 10 }
                    },
                    "placeholder": null,
                    "defaultBehavior": false
                }
            }),
        ),
        (
            json!({
                "range": {
                    "start": { "line": 1, "character": 5 },
                    "end": { "line": 1, "character": 10 }
                },
                "placeholder": "greet"
            }),
            json!({
                "prepareRename": {
                    "range": {
                        "start": { "line": 1, "utf16Column": 5 },
                        "end": { "line": 1, "utf16Column": 10 }
                    },
                    "placeholder": "greet",
                    "defaultBehavior": false
                }
            }),
        ),
        (
            json!({ "defaultBehavior": true }),
            json!({
                "prepareRename": {
                    "range": null,
                    "placeholder": null,
                    "defaultBehavior": true
                }
            }),
        ),
        (Value::Null, json!({ "prepareRename": null })),
    ];

    for (wire_result, expected) in cases {
        let req = client_feature_request_canonical(ClientFeatureRequest {
            state,
            uri: "file:///tmp/project/main.go".to_string(),
            method: "textDocument/prepareRename".to_string(),
            position: Some(LspPosition {
                line: 1,
                utf16_column: 6,
            }),
            new_name: None,
            range: None,
            diagnostics: Vec::new(),
            completion_item: None,
            code_action: None,
            command: None,
        })
        .unwrap();
        let req_msg: Value = serde_json::from_str(&req.messages[0]).unwrap();
        assert_eq!(req_msg["method"], "textDocument/prepareRename");
        let req_id = req_msg["id"].as_str().unwrap().to_string();
        state = req.state;

        let resp = client_apply_server_message(ClientApplyServerMessageRequest {
            state,
            message: json!({
                "jsonrpc": "2.0",
                "id": req_id,
                "result": wire_result
            })
            .to_string(),
        })
        .unwrap();
        state = resp.state;
        assert_eq!(resp.events[0].kind, "response");
        assert_eq!(resp.events[0].result, Some(expected));
    }

    // Dynamic unregistration of textDocument/rename clears both rename and prepareRename;
    // dynamic registration with prepareProvider restores both.
    let unreg = client_apply_server_message(ClientApplyServerMessageRequest {
        state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "srv-1",
            "method": "client/unregisterCapability",
            "params": {
                "unregisterations": [{ "id": "r1", "method": "textDocument/rename" }]
            }
        })
        .to_string(),
    })
    .unwrap();
    state = unreg.state;
    assert!(!state.server_capabilities.iter().any(|c| c == "rename"));
    assert!(!state
        .server_capabilities
        .iter()
        .any(|c| c == "prepareRename"));

    let reg = client_apply_server_message(ClientApplyServerMessageRequest {
        state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "srv-2",
            "method": "client/registerCapability",
            "params": {
                "registrations": [{
                    "id": "r2",
                    "method": "textDocument/rename",
                    "registerOptions": { "prepareProvider": true }
                }]
            }
        })
        .to_string(),
    })
    .unwrap();
    assert!(reg.state.server_capabilities.iter().any(|c| c == "rename"));
    assert!(reg
        .state
        .server_capabilities
        .iter()
        .any(|c| c == "prepareRename"));
}

#[test]
fn client_normalizes_p1a_signature_highlight_symbol_semantic_tokens_and_completion_fields() {
    let initialized = client_initialize(ClientInitializeRequest {
        state: LspClientState::default(),
        root_uri: "file:///tmp/project".to_string(),
        process_id: Some(7),
        initialization_options: None,
    })
    .unwrap();

    let applied = client_apply_server_message(ClientApplyServerMessageRequest {
        state: initialized.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "1",
            "result": {
                "capabilities": {
                    "completionProvider": { "resolveProvider": true },
                    "signatureHelpProvider": { "triggerCharacters": ["(", ","] },
                    "documentHighlightProvider": true,
                    "documentSymbolProvider": true,
                    "semanticTokensProvider": {
                        "full": true,
                        "legend": {
                            "tokenTypes": ["type", "function", "parameter", "variable"],
                            "tokenModifiers": ["declaration", "readonly"]
                        }
                    }
                }
            }
        })
        .to_string(),
    })
    .unwrap();
    let mut state = applied.state;
    for cap in [
        "signatureHelp",
        "documentHighlight",
        "documentSymbol",
        "semanticTokens",
    ] {
        assert!(
            state.server_capabilities.iter().any(|c| c == cap),
            "missing capability {cap}"
        );
    }

    let opened = client_open_document(ClientOpenDocumentRequest {
        state,
        uri: "file:///tmp/project/main.go".to_string(),
        language_id: "go".to_string(),
        text: "package main\nfunc add(a int, b int) int { return a + b }\n".to_string(),
    })
    .unwrap();
    state = opened.state;

    // 1. SignatureHelp with both string label and UTF-16 offset tuple label.
    let sig_req = client_feature_request_canonical(ClientFeatureRequest {
        state,
        uri: "file:///tmp/project/main.go".to_string(),
        method: "textDocument/signatureHelp".to_string(),
        position: Some(LspPosition {
            line: 1,
            utf16_column: 12,
        }),
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let sig_id = serde_json::from_str::<Value>(&sig_req.messages[0]).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let sig_resp = client_apply_server_message(ClientApplyServerMessageRequest {
        state: sig_req.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": sig_id,
            "result": {
                "activeSignature": 0,
                "activeParameter": 1,
                "signatures": [{
                    "label": "add(a int, b int) int",
                    "documentation": { "kind": "markdown", "value": "Adds two ints." },
                    "parameters": [
                        { "label": [4, 9], "documentation": "first" },
                        { "label": "b int", "documentation": { "kind": "plaintext", "value": "second" } }
                    ]
                }]
            }
        })
        .to_string(),
    })
    .unwrap();
    state = sig_resp.state;
    let sig_value = &sig_resp.events[0].result.as_ref().unwrap()["signatureHelp"];
    assert_eq!(sig_value["activeParameter"], 1);
    assert_eq!(
        sig_value["signatures"][0]["parameters"][0]["label"],
        "a int"
    );
    assert_eq!(sig_value["signatures"][0]["parameters"][0]["labelStart"], 4);
    assert_eq!(sig_value["signatures"][0]["parameters"][0]["labelEnd"], 9);
    assert_eq!(
        sig_value["signatures"][0]["parameters"][1]["label"],
        "b int"
    );

    // 2. DocumentHighlight (read + write + omitted kind defaulting to text=1).
    let hl_req = client_feature_request_canonical(ClientFeatureRequest {
        state,
        uri: "file:///tmp/project/main.go".to_string(),
        method: "textDocument/documentHighlight".to_string(),
        position: Some(LspPosition {
            line: 1,
            utf16_column: 9,
        }),
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let hl_id = serde_json::from_str::<Value>(&hl_req.messages[0]).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let hl_resp = client_apply_server_message(ClientApplyServerMessageRequest {
        state: hl_req.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": hl_id,
            "result": [
                { "range": { "start": { "line": 1, "character": 9 }, "end": { "line": 1, "character": 10 } }, "kind": 3 },
                { "range": { "start": { "line": 1, "character": 37 }, "end": { "line": 1, "character": 38 } } }
            ]
        })
        .to_string(),
    })
    .unwrap();
    state = hl_resp.state;
    let highlights = hl_resp.events[0].result.as_ref().unwrap()["highlights"]
        .as_array()
        .unwrap();
    assert_eq!(highlights.len(), 2);
    assert_eq!(highlights[0]["kind"], 3);
    assert_eq!(highlights[1]["kind"], 1);

    // 3. DocumentSymbol (hierarchical + flat SymbolInformation).
    let sym_req = client_feature_request_canonical(ClientFeatureRequest {
        state,
        uri: "file:///tmp/project/main.go".to_string(),
        method: "textDocument/documentSymbol".to_string(),
        position: None,
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let sym_id = serde_json::from_str::<Value>(&sym_req.messages[0]).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let sym_resp = client_apply_server_message(ClientApplyServerMessageRequest {
        state: sym_req.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": sym_id,
            "result": [
                {
                    "name": "Server",
                    "detail": "struct",
                    "kind": 23,
                    "range": { "start": { "line": 0, "character": 0 }, "end": { "line": 4, "character": 1 } },
                    "selectionRange": { "start": { "line": 0, "character": 5 }, "end": { "line": 0, "character": 11 } },
                    "children": [{
                        "name": "Serve",
                        "kind": 6,
                        "range": { "start": { "line": 1, "character": 0 }, "end": { "line": 3, "character": 1 } },
                        "selectionRange": { "start": { "line": 1, "character": 5 }, "end": { "line": 1, "character": 10 } }
                    }]
                },
                {
                    "name": "legacyHelper",
                    "kind": 12,
                    "containerName": "pkg",
                    "location": {
                        "uri": "file:///tmp/project/main.go",
                        "range": { "start": { "line": 5, "character": 0 }, "end": { "line": 5, "character": 12 } }
                    }
                }
            ]
        })
        .to_string(),
    })
    .unwrap();
    state = sym_resp.state;
    let symbols = sym_resp.events[0].result.as_ref().unwrap()["symbols"]
        .as_array()
        .unwrap();
    assert_eq!(symbols.len(), 2);
    assert_eq!(symbols[0]["name"], "Server");
    assert_eq!(symbols[0]["children"][0]["name"], "Serve");
    assert_eq!(symbols[1]["name"], "legacyHelper");
    assert_eq!(symbols[1]["detail"], "pkg");

    // 4. SemanticTokens delta decoding across lines and same-line tokens + modifiers bitmask.
    let tok_req = client_feature_request_canonical(ClientFeatureRequest {
        state,
        uri: "file:///tmp/project/main.go".to_string(),
        method: "textDocument/semanticTokens/full".to_string(),
        position: None,
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let tok_id = serde_json::from_str::<Value>(&tok_req.messages[0]).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let tok_resp = client_apply_server_message(ClientApplyServerMessageRequest {
        state: tok_req.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": tok_id,
            "result": {
                // Token 0: line 1, col 5, len 3, type=1(function), mods=1(declaration)
                // Token 1: same line 1, col 5+4=9, len 1, type=2(parameter), mods=0
                // Token 2: line 1+1=2, col 2, len 4, type=3(variable), mods=3(declaration+readonly)
                "data": [1, 5, 3, 1, 1, 0, 4, 1, 2, 0, 1, 2, 4, 3, 3]
            }
        })
        .to_string(),
    })
    .unwrap();
    state = tok_resp.state;
    let tokens = tok_resp.events[0].result.as_ref().unwrap()["tokens"]
        .as_array()
        .unwrap();
    assert_eq!(tokens.len(), 3);
    assert_eq!(tokens[0]["line"], 1);
    assert_eq!(tokens[0]["utf16Column"], 5);
    assert_eq!(tokens[0]["tokenType"], "function");
    assert_eq!(tokens[0]["tokenModifiers"], json!(["declaration"]));
    assert_eq!(tokens[1]["line"], 1);
    assert_eq!(tokens[1]["utf16Column"], 9);
    assert_eq!(tokens[1]["tokenType"], "parameter");
    assert_eq!(tokens[2]["line"], 2);
    assert_eq!(tokens[2]["utf16Column"], 2);
    assert_eq!(
        tokens[2]["tokenModifiers"],
        json!(["declaration", "readonly"])
    );

    // 5. Completion items preserve insertTextFormat and preselect.
    let comp_req = client_feature_request_canonical(ClientFeatureRequest {
        state,
        uri: "file:///tmp/project/main.go".to_string(),
        method: "textDocument/completion".to_string(),
        position: Some(LspPosition {
            line: 1,
            utf16_column: 5,
        }),
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let comp_id = serde_json::from_str::<Value>(&comp_req.messages[0]).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let comp_resp = client_apply_server_message(ClientApplyServerMessageRequest {
        state: comp_req.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": comp_id,
            "result": {
                "isIncomplete": false,
                "items": [{
                    "label": "Println",
                    "insertText": "Println(${1:a})",
                    "insertTextFormat": 2,
                    "preselect": true
                }]
            }
        })
        .to_string(),
    })
    .unwrap();
    let comp_items = comp_resp.events[0].result.as_ref().unwrap()["items"]
        .as_array()
        .unwrap();
    assert_eq!(comp_items[0]["insertTextFormat"], 2);
    assert_eq!(comp_items[0]["preselect"], true);

    // 6. Dynamic unregistration clears semanticTokens capability and legend.
    let unreg = client_apply_server_message(ClientApplyServerMessageRequest {
        state: comp_resp.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "srv-unreg",
            "method": "client/unregisterCapability",
            "params": {
                "unregisterations": [{ "id": "st-1", "method": "textDocument/semanticTokens/full" }]
            }
        })
        .to_string(),
    })
    .unwrap();
    assert!(!unreg
        .state
        .server_capabilities
        .iter()
        .any(|c| c == "semanticTokens"));
    assert!(unreg.state.semantic_tokens_legend.is_none());

    // 7. Offline workspace.documentSymbols command works for Go, Rust, Python.
    let doc_syms_raw = crate::execute_json(
        &json!({
            "command": "workspace.documentSymbols",
            "payload": {
                "path": "src/main.rs",
                "source": "pub struct Config {}\npub fn run() {}\n"
            }
        })
        .to_string(),
    );
    let doc_syms: Value = serde_json::from_str(&doc_syms_raw).unwrap();
    assert_eq!(doc_syms["ok"], true);
    let offline_symbols = doc_syms["data"]["symbols"].as_array().unwrap();
    assert_eq!(offline_symbols.len(), 2);
    assert_eq!(offline_symbols[0]["name"], "Config");
    assert_eq!(offline_symbols[0]["kind"], "type");
    assert_eq!(offline_symbols[1]["name"], "run");
    assert_eq!(offline_symbols[1]["kind"], "symbol");
}

#[test]
fn lightweight_cross_file_go_rust_python_navigation_hover_signature_and_completions() {
    let root = temporary_root("lightweight-cross-file");
    let pkg_dir = root.join("billing");
    let other_dir = root.join("other");
    fs::create_dir_all(&pkg_dir).unwrap();
    fs::create_dir_all(&other_dir).unwrap();

    let go_svc = pkg_dir.join("service.go");
    fs::write(
        &go_svc,
        concat!(
            "package billing\n",
            "\n",
            "// CalculateTotal computes invoice totals.\n",
            "func (s *Service) CalculateTotal(amount int, tax float64) float64 {\n",
            "    return float64(amount) * tax\n",
            "}\n",
            "\n",
            "const DefaultTaxRate = 1.08\n",
        ),
    )
    .unwrap();

    let go_other = other_dir.join("dup.go");
    fs::write(
        &go_other,
        "package other\nfunc CalculateTotal(x int) int { return x }\n",
    )
    .unwrap();

    let go_main = root.join("main.go");
    let go_main_text = concat!(
        "package main\n",
        "\n",
        "func run(s *Service) {\n",
        "    // CalculateTotal mentioned in comment must not count as a reference\n",
        "    msg := \"CalculateTotal in string\"\n",
        "    _ = msg\n",
        "    _ = billing.CalculateTotal(10, DefaultTaxRate)\n",
        "}\n",
    );
    fs::write(&go_main, go_main_text).unwrap();

    let py_helper = root.join("helpers.py");
    fs::write(
        &py_helper,
        concat!(
            "def compute_score(items: list[int], scale: float = 1.0) -> float:\n",
            "    \"\"\"Return weighted total score.\"\"\"\n",
            "    return sum(items) * scale\n",
        ),
    )
    .unwrap();

    // Warm the cached WorkspaceSearchIndex so cross-file O(log N) lookups and trigram pruning activate.
    let warm_raw = crate::execute_json(
        &json!({
            "command": "workspace.searchIndex.warm",
            "payload": { "root": root.to_string_lossy() }
        })
        .to_string(),
    );
    let warm: Value = serde_json::from_str(&warm_raw).unwrap();
    assert_eq!(warm["ok"], true);

    // 1. Go cross-file definition with qualifier (`billing.CalculateTotal`) prefers `billing/service.go`
    // and lands on `CalculateTotal` (past the receiver `(s *Service)`).
    let defs = builtin_navigation(BuiltinNavigationRequest {
        file_path: go_main.to_string_lossy().to_string(),
        text: go_main_text.to_string(),
        position: LspPosition {
            line: 6,
            utf16_column: 20,
        },
        method: "textDocument/definition".to_string(),
        workspace_root: Some(root.to_string_lossy().to_string()),
        open_buffers: None,
    })
    .unwrap();
    assert!(!defs.locations.is_empty());
    assert_eq!(
        defs.locations[0].display_path.as_deref(),
        Some("billing/service.go")
    );
    assert_eq!(defs.locations[0].range.start.line, 3);
    assert_eq!(defs.locations[0].range.start.utf16_column, 18);

    // 2. `textDocument/implementation` stays honestly empty in Lightweight Mode.
    let impls = builtin_navigation(BuiltinNavigationRequest {
        file_path: go_main.to_string_lossy().to_string(),
        text: go_main_text.to_string(),
        position: LspPosition {
            line: 6,
            utf16_column: 20,
        },
        method: "textDocument/implementation".to_string(),
        workspace_root: Some(root.to_string_lossy().to_string()),
        open_buffers: None,
    })
    .unwrap();
    assert!(impls.locations.is_empty());

    // 3. Cross-file references use trigram pruning and skip comment & string occurrences.
    let refs = builtin_navigation(BuiltinNavigationRequest {
        file_path: go_main.to_string_lossy().to_string(),
        text: go_main_text.to_string(),
        position: LspPosition {
            line: 6,
            utf16_column: 20,
        },
        method: "textDocument/references".to_string(),
        workspace_root: Some(root.to_string_lossy().to_string()),
        open_buffers: None,
    })
    .unwrap();
    assert_eq!(refs.locations.len(), 3); // main.go:7, billing/service.go:4, other/dup.go:2
    assert!(!refs
        .locations
        .iter()
        .any(|loc| loc.file_path.ends_with("main.go")
            && (loc.range.start.line == 3 || loc.range.start.line == 4)));

    // 4. Cross-file hover includes fenced Go signature, doc comment, and relative path:line.
    let hover = builtin_hover(BuiltinRequest {
        file_path: go_main.to_string_lossy().to_string(),
        text: go_main_text.to_string(),
        position: LspPosition {
            line: 6,
            utf16_column: 20,
        },
        workspace_root: Some(root.to_string_lossy().to_string()),
        open_buffers: None,
    })
    .unwrap()
    .hover
    .expect("hover should resolve cross-file Go method");
    assert!(hover
        .contents
        .contains("```go\nfunc (s *Service) CalculateTotal(amount int, tax float64) float64"));
    assert!(hover
        .contents
        .contains("CalculateTotal computes invoice totals."));
    assert!(hover.contents.contains("billing/service.go:4"));

    // 5. Cross-file signature help via `lsp.builtinSignatureHelp` highlights 2nd param after comma
    // and skips the Go receiver `(s *Service)`.
    let sig_raw = crate::execute_json(
        &json!({
            "command": "lsp.builtinSignatureHelp",
            "payload": {
                "filePath": go_main.to_string_lossy(),
                "text": go_main_text,
                "position": { "line": 6, "utf16Column": 38 },
                "workspaceRoot": root.to_string_lossy()
            }
        })
        .to_string(),
    );
    let sig_json: Value = serde_json::from_str(&sig_raw).unwrap();
    assert_eq!(sig_json["ok"], true);
    assert_eq!(sig_json["data"]["activeParameter"], 1);
    let params = sig_json["data"]["signatures"][0]["parameters"]
        .as_array()
        .unwrap();
    assert_eq!(params.len(), 2);
    assert_eq!(params[0]["label"], "amount int");
    assert_eq!(params[1]["label"], "tax float64");
    let sig_label = sig_json["data"]["signatures"][0]["label"].as_str().unwrap();
    let p1_start = params[1]["labelStart"].as_u64().unwrap() as usize;
    let p1_end = params[1]["labelEnd"].as_u64().unwrap() as usize;
    assert_eq!(&sig_label[p1_start..p1_end], "tax float64");

    // 6. Cross-file completions surface workspace symbols, skip comment words, and match case-insensitively.
    let comp = builtin_completions(BuiltinRequest {
        file_path: go_main.to_string_lossy().to_string(),
        text: "package main\n// secretCommentWord\nfunc f() { calc }\n".to_string(),
        position: LspPosition {
            line: 2,
            utf16_column: 15,
        },
        workspace_root: Some(root.to_string_lossy().to_string()),
        open_buffers: None,
    })
    .unwrap();
    assert!(comp.items.iter().any(|item| item.label == "CalculateTotal"));
    assert!(!comp
        .items
        .iter()
        .any(|item| item.label == "secretCommentWord"));

    // 7. Python cross-file hover extracts docstring & signature help tracks active parameter inside nested calls.
    let py_caller = root.join("app.py");
    let py_caller_text = "result = compute_score(list(range(3)), 2.5)\n";
    let py_hover = builtin_hover(BuiltinRequest {
        file_path: py_caller.to_string_lossy().to_string(),
        text: py_caller_text.to_string(),
        position: LspPosition {
            line: 0,
            utf16_column: 12,
        },
        workspace_root: Some(root.to_string_lossy().to_string()),
        open_buffers: None,
    })
    .unwrap()
    .hover
    .expect("hover should resolve Python docstring");
    assert!(py_hover.contents.contains("Return weighted total score."));

    let py_sig = builtin_signature_help(BuiltinRequest {
        file_path: py_caller.to_string_lossy().to_string(),
        text: py_caller_text.to_string(),
        position: LspPosition {
            line: 0,
            utf16_column: 40,
        },
        workspace_root: Some(root.to_string_lossy().to_string()),
        open_buffers: None,
    })
    .unwrap();
    assert_eq!(py_sig.active_parameter, Some(1));
    assert_eq!(py_sig.signatures[0].parameters.len(), 2);
    assert_eq!(
        py_sig.signatures[0].parameters[1].label,
        "scale: float = 1.0"
    );

    // Clean up cached search index and temp root.
    let _ = crate::execute_json(
        &json!({
            "command": "workspace.searchIndex.invalidate",
            "payload": { "root": root.to_string_lossy() }
        })
        .to_string(),
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn lightweight_unicode_python_docstrings_and_large_multibyte_signature_help_never_panic() {
    // Regression for P1: Python triple-quoted strings containing multibyte UTF-8 text.
    let py_source = concat!(
        "def greet(name: str, count: int) -> str:\n",
        "    \"\"\"中文文档说明 🚀\"\"\"\n",
        "    note = '''多字节单引号'''\n",
        "    return f\"{name}:{count}:{note}\"\n",
        "\n",
        "result = greet(\"世界\", 2)\n",
    );
    let symbols_raw = crate::execute_json(
        &json!({
            "command": "workspace.documentSymbols",
            "payload": { "path": "demo.py", "source": py_source }
        })
        .to_string(),
    );
    let symbols_json: Value = serde_json::from_str(&symbols_raw).unwrap();
    assert_eq!(symbols_json["ok"], true);
    assert!(symbols_json["data"]["symbols"]
        .as_array()
        .unwrap()
        .iter()
        .any(|item| item["name"] == "greet"));

    let py_hover = builtin_hover(BuiltinRequest {
        file_path: "/tmp/demo.py".to_string(),
        text: py_source.to_string(),
        position: LspPosition {
            line: 5,
            utf16_column: 11,
        },
        workspace_root: None,
        open_buffers: None,
    })
    .unwrap();
    assert!(py_hover.hover.unwrap().contents.contains("中文文档说明"));

    let py_sig = builtin_signature_help(BuiltinRequest {
        file_path: "/tmp/demo.py".to_string(),
        text: py_source.to_string(),
        position: LspPosition {
            line: 5,
            utf16_column: 22,
        },
        workspace_root: None,
        open_buffers: None,
    })
    .unwrap();
    assert_eq!(py_sig.active_parameter, Some(1));

    let py_comp = builtin_completions(BuiltinRequest {
        file_path: "/tmp/demo.py".to_string(),
        text: py_source.to_string(),
        position: LspPosition {
            line: 5,
            utf16_column: 12,
        },
        workspace_root: None,
        open_buffers: None,
    })
    .unwrap();
    assert!(!py_comp.items.is_empty());

    // Regression for P1: cursor > 16,384 bytes after dense multibyte UTF-8 characters
    // must align the signature-help scan window to a UTF-8 boundary without panicking.
    let mut go_large = String::from("package main\nfunc foo(a int, b string) {}\n// ");
    for _ in 0..6_000 {
        go_large.push('中');
    }
    go_large.push_str("\nfunc main() { foo(1, \"x\") }\n");
    let target_line = go_large.lines().count() as i64 - 1;
    let go_sig = builtin_signature_help(BuiltinRequest {
        file_path: "/tmp/large_utf8.go".to_string(),
        text: go_large,
        position: LspPosition {
            line: target_line,
            utf16_column: 22,
        },
        workspace_root: None,
        open_buffers: None,
    })
    .unwrap();
    assert_eq!(go_sig.active_parameter, Some(1));
    assert_eq!(go_sig.signatures[0].parameters.len(), 2);
}

#[test]
fn lightweight_hover_utf8_word_boundary_and_linear_large_file() {
    // Regression for P1: non-whole-word multibyte identifier matches must advance along
    // UTF-8 character boundaries instead of `abs + 1`.
    let py_utf8 = "变量x = 1\nprint(变量)\n";
    let hover = builtin_hover(BuiltinRequest {
        file_path: "/tmp/utf8_vars.py".to_string(),
        text: py_utf8.to_string(),
        position: LspPosition {
            line: 1,
            utf16_column: 7,
        },
        workspace_root: None,
        open_buffers: None,
    })
    .unwrap();
    assert!(hover.hover.unwrap().contents.contains("变量"));

    // Regression for P2: repeated identifier occurrences without a local declaration must scan
    // in O(N) time rather than recomputing prefix line offsets quadratically.
    let mut repeated = String::with_capacity(110_000);
    for _ in 0..10_000 {
        repeated.push_str("print(foo)\n");
    }
    let started = std::time::Instant::now();
    let large_hover = builtin_hover(BuiltinRequest {
        file_path: "/tmp/large_hover.py".to_string(),
        text: repeated,
        position: LspPosition {
            line: 9_999,
            utf16_column: 7,
        },
        workspace_root: None,
        open_buffers: None,
    })
    .unwrap();
    assert!(large_hover.hover.unwrap().contents.contains("foo"));
    assert!(
        started.elapsed() < std::time::Duration::from_secs(2),
        "hover lookup exceeded linear-time budget: {:?}",
        started.elapsed()
    );
}
