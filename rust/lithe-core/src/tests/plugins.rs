use crate::plugins::{validate_plugin_catalog_json, PluginValidationError, PluginVersion};
const OFFICIAL_PLUGINS: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/fixtures/plugins/official-v1.json"
));
const LANGUAGE_SUPPORT_FIXTURE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/fixtures/plugins/language-support-v1.json"
));
#[test]
fn official_plugin_catalog_is_valid_and_contains_only_released_downloads() {
    let owners = validate_plugin_catalog_json(
        OFFICIAL_PLUGINS,
        PluginVersion {
            major: 0,
            minor: 3,
            patch: 0,
        },
    )
    .expect("official plugin fixture should validate");
    assert!(owners.is_empty());
}

#[test]
fn language_support_catalog_allows_execution_and_testing_to_share_a_module() {
    let owners = validate_plugin_catalog_json(
        LANGUAGE_SUPPORT_FIXTURE,
        PluginVersion {
            major: 0,
            minor: 3,
            patch: 0,
        },
    )
    .expect("language support fixture should validate");
    assert_eq!(owners.len(), 2);
    assert_eq!(
        owners.get("dev.lithe.fixture.go.language-server"),
        Some(&"dev.lithe.fixture.go-support".to_string())
    );
    assert_eq!(
        owners.get("dev.lithe.fixture.go.execution"),
        Some(&"dev.lithe.fixture.go-support".to_string())
    );
}

#[test]
fn incompatible_host_is_rejected_deterministically() {
    let error = validate_plugin_catalog_json(
        OFFICIAL_PLUGINS,
        PluginVersion {
            major: 0,
            minor: 4,
            patch: 0,
        },
    )
    .unwrap_err();
    assert_eq!(
        error,
        PluginValidationError::IncompatibleHost {
            plugin: "catalog".into()
        }
    );
}

#[test]
fn declarative_config_only_language_plugin_validates_without_modules() {
    let catalog = r#"{
      "schemaVersion": 1,
      "hostVersion": "0.3.1",
      "pluginAPIVersion": 1,
      "plugins": [
        {
          "id": "dev.lithe.plugin.acme-dsl",
          "displayName": "Acme DSL",
          "version": "0.3.1",
          "apiVersion": 1,
          "hostCompatibility": { "minimum": "0.3.1", "maximumExclusive": "0.4.0" },
          "vendor": { "id": "dev.lithe", "displayName": "Lithe", "signatureRequirement": "sameTeamAsHost" },
          "entrypoint": { "kind": "declarative" },
          "moduleIDs": [],
          "languageSupports": [
            {
              "id": "acme",
              "displayName": "Acme DSL",
              "fileExtensions": ["acme"],
              "fileNames": [],
              "projectFileNames": ["acme.toml"],
              "syntaxProfilePath": "Resources/syntax.json"
            }
          ]
        }
      ]
    }"#;
    let owners = validate_plugin_catalog_json(
        catalog,
        PluginVersion {
            major: 0,
            minor: 3,
            patch: 1,
        },
    )
    .expect("declarative language plugin should validate cleanly");
    assert!(owners.is_empty());
}

#[test]
fn declarative_plugin_rejects_traversal_syntax_profile_path() {
    let catalog = r#"{
      "schemaVersion": 1,
      "hostVersion": "0.3.1",
      "pluginAPIVersion": 1,
      "plugins": [
        {
          "id": "dev.lithe.plugin.bad-dsl",
          "displayName": "Bad DSL",
          "version": "0.3.1",
          "apiVersion": 1,
          "hostCompatibility": { "minimum": "0.3.1", "maximumExclusive": "0.4.0" },
          "vendor": { "id": "dev.lithe", "displayName": "Lithe", "signatureRequirement": "sameTeamAsHost" },
          "entrypoint": { "kind": "declarative" },
          "moduleIDs": [],
          "languageSupports": [
            {
              "id": "bad",
              "displayName": "Bad",
              "fileExtensions": ["bad"],
              "fileNames": [],
              "projectFileNames": [],
              "syntaxProfilePath": "../escape.json"
            }
          ]
        }
      ]
    }"#;
    let error = validate_plugin_catalog_json(
        catalog,
        PluginVersion {
            major: 0,
            minor: 3,
            patch: 1,
        },
    )
    .unwrap_err();
    assert_eq!(
        error,
        PluginValidationError::InvalidLanguageSupport {
            plugin: "dev.lithe.plugin.bad-dsl".into(),
            language: "bad".into()
        }
    );
}
