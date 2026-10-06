//! Lossless ordered workspace-edit normalization at the LSP protocol boundary.
//!
//! This module validates protocol structure only. Workspace ownership, source
//! versions, confirmation and atomic application belong to the host transaction.

use super::types::LspClientResultError;
use serde_json::{json, Map, Value};
use url::Url;

/// A malformed response fails its request without failing the server session.
pub(crate) type WorkspaceEditParseError = LspClientResultError;

fn malformed(message: &str) -> WorkspaceEditParseError {
    WorkspaceEditParseError {
        code: "lsp.workspaceEdit.malformedEdit".into(),
        message: message.into(),
    }
}

/// Preserves documentChanges order and rejects the entire edit on any invalid
/// member. The legacy changes form is ordered by URI bytes deterministically.
pub(crate) fn parse_workspace_edit(result: &Value) -> Result<Value, WorkspaceEditParseError> {
    let object = result.as_object().ok_or_else(|| {
        malformed("Language server returned a workspace edit that is not an object.")
    })?;
    let annotations = parse_annotations(object.get("changeAnnotations"))?;
    let mut operations = Vec::new();
    // documentChanges is authoritative even when empty. Combining both forms
    // would apply the same edit twice or resurrect explicitly superseded edits.
    if let Some(changes) = object.get("documentChanges") {
        for change in changes.as_array().ok_or_else(|| {
            malformed("Language server workspace documentChanges must be an array.")
        })? {
            operations.push(parse_operation(change, &annotations)?);
        }
    } else if let Some(changes) = object.get("changes") {
        let changes = changes.as_object().ok_or_else(|| {
            malformed("Language server workspace changes must be a URI-to-edits object.")
        })?;
        let mut entries: Vec<_> = changes.iter().collect();
        entries.sort_by(|(left, _), (right, _)| left.as_bytes().cmp(right.as_bytes()));
        for (uri, edits) in entries {
            validate_uri(Some(&Value::String(uri.clone())))?;
            operations.push(json!({
                "kind": "edit", "uri": uri, "version": null,
                "edits": parse_edits(edits, &annotations)?
            }));
        }
    }
    Ok(json!({ "operations": operations, "changeAnnotations": annotations }))
}

fn parse_operation(
    change: &Value,
    annotations: &Map<String, Value>,
) -> Result<Value, WorkspaceEditParseError> {
    let object = change
        .as_object()
        .ok_or_else(|| malformed("Language server workspace operation must be an object."))?;
    if let Some(kind) = object.get("kind") {
        let kind = kind
            .as_str()
            .ok_or_else(|| malformed("Workspace operation kind must be a string."))?;
        let option_keys: &[&str] = match kind {
            "create" | "rename" => &["overwrite", "ignoreIfExists"],
            "delete" => &["recursive", "ignoreIfNotExists"],
            _ => {
                return Err(WorkspaceEditParseError {
                    code: "lsp.workspaceEdit.unknownOperation".into(),
                    message: "Language server returned an unsupported workspace operation.".into(),
                })
            }
        };
        let mut operation = json!({ "kind": kind });
        let uri_keys: &[&str] = if kind == "rename" {
            &["oldUri", "newUri"]
        } else {
            &["uri"]
        };
        for key in uri_keys {
            operation[key] = json!(validate_uri(object.get(*key))?);
        }
        if let Some(options) = object.get("options") {
            let options = options
                .as_object()
                .ok_or_else(|| malformed("Resource operation options must be an object."))?;
            for (key, value) in options {
                if !option_keys.contains(&key.as_str()) || !value.is_boolean() {
                    return Err(malformed(
                        "Resource operation options must contain supported boolean flags.",
                    ));
                }
            }
            operation["options"] = json!(options);
        }
        copy_annotation(object, &mut operation, annotations)?;
        return Ok(operation);
    }
    let document = object
        .get("textDocument")
        .and_then(Value::as_object)
        .ok_or_else(|| malformed("Workspace text edit is missing its document identifier."))?;
    let uri = validate_uri(document.get("uri"))?;
    let version = match document.get("version") {
        None | Some(Value::Null) => Value::Null,
        Some(value)
            if value
                .as_i64()
                .is_some_and(|version| i32::try_from(version).is_ok()) =>
        {
            value.clone()
        }
        _ => {
            return Err(malformed(
                "Workspace document version must be an integer or null.",
            ))
        }
    };
    let edits = object
        .get("edits")
        .ok_or_else(|| malformed("Workspace text edit is missing its edits array."))?;
    Ok(
        json!({ "kind": "edit", "uri": uri, "version": version, "edits": parse_edits(edits, annotations)? }),
    )
}

fn validate_uri(value: Option<&Value>) -> Result<&str, WorkspaceEditParseError> {
    let uri = value
        .and_then(Value::as_str)
        .filter(|uri| !uri.is_empty())
        .ok_or_else(|| WorkspaceEditParseError {
            code: "lsp.workspaceEdit.missingURI".into(),
            message: "Language server workspace edit is missing a file URI.".into(),
        })?;
    let parsed =
        Url::parse(uri).map_err(|_| malformed("Workspace edit contains an invalid URI."))?;
    if parsed.scheme() != "file" {
        return Err(WorkspaceEditParseError {
            code: "lsp.workspaceEdit.unsupportedScheme".into(),
            message: "Language server workspace edits must target file URIs.".into(),
        });
    }
    // Url is intentionally used only for validation. Re-serializing it would
    // change the server's URI identity, and filesystem ownership is host-owned.
    let bytes = uri.as_bytes();
    let invalid_escape = bytes.iter().enumerate().any(|(index, byte)| {
        *byte == b'%'
            && (bytes
                .get(index + 1)
                .is_none_or(|value| !value.is_ascii_hexdigit())
                || bytes
                    .get(index + 2)
                    .is_none_or(|value| !value.is_ascii_hexdigit()))
    });
    let absolute_file_path = uri
        .split_once(':')
        .is_some_and(|(_, path)| path.starts_with('/'));
    if !absolute_file_path
        // URL parsing repairs forbidden raw ASCII. Reject it before returning
        // the original spelling, while preserving valid percent escapes.
        || uri.bytes().any(|value| {
            value.is_ascii() && !value.is_ascii_alphanumeric()
                && !b"-._~:/?#[]@!$&'()*+,;=%".contains(&value)
        })
        || !parsed.path().starts_with('/')
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || uri
            .chars()
            .any(|value| value.is_control() || value.is_whitespace())
        || invalid_escape
    {
        return Err(malformed("Workspace edit contains an invalid file URI."));
    }
    Ok(uri)
}

fn parse_annotations(value: Option<&Value>) -> Result<Map<String, Value>, WorkspaceEditParseError> {
    let Some(value) = value else {
        return Ok(Map::new());
    };
    let annotations = value
        .as_object()
        .ok_or_else(|| malformed("Workspace changeAnnotations must be an object."))?;
    let mut normalized = Map::new();
    for (id, annotation) in annotations {
        let label = annotation
            .get("label")
            .and_then(Value::as_str)
            .ok_or_else(|| malformed("Workspace change annotation must have a label."))?;
        let mut result = json!({ "label": label });
        for key in ["needsConfirmation", "description"] {
            if let Some(value) = annotation.get(key) {
                if (key == "needsConfirmation" && !value.is_boolean())
                    || (key == "description" && !value.is_string())
                {
                    return Err(malformed(
                        "Workspace change annotation has an invalid field.",
                    ));
                }
                result[key] = value.clone();
            }
        }
        normalized.insert(id.clone(), result);
    }
    Ok(normalized)
}

fn copy_annotation(
    source: &Map<String, Value>,
    target: &mut Value,
    annotations: &Map<String, Value>,
) -> Result<(), WorkspaceEditParseError> {
    if let Some(id) = source.get("annotationId") {
        let id = id
            .as_str()
            .filter(|id| annotations.contains_key(*id))
            .ok_or_else(|| malformed("Workspace edit references an unknown change annotation."))?;
        target["annotationId"] = json!(id);
    }
    Ok(())
}

/// Validates a standalone TextEdit array used by formatting and completion.
/// These edits have no annotation table, so annotation references are invalid.
pub(crate) fn parse_plain_text_edits(value: &Value) -> Result<Vec<Value>, WorkspaceEditParseError> {
    parse_edits(value, &Map::new())
}

/// Validates a single completion TextEdit without inventing missing coordinates.
pub(crate) fn parse_plain_text_edit(value: &Value) -> Result<Value, WorkspaceEditParseError> {
    parse_text_edit(value, &Map::new())
}

fn parse_edits(
    value: &Value,
    annotations: &Map<String, Value>,
) -> Result<Vec<Value>, WorkspaceEditParseError> {
    value
        .as_array()
        .ok_or_else(|| malformed("Workspace text edits must be an array."))?
        .iter()
        .map(|edit| parse_text_edit(edit, annotations))
        .collect()
}

fn parse_text_edit(
    edit: &Value,
    annotations: &Map<String, Value>,
) -> Result<Value, WorkspaceEditParseError> {
    let object = edit
        .as_object()
        .ok_or_else(|| malformed("Workspace text edit must be an object."))?;
    let range = object
        .get("range")
        .ok_or_else(|| malformed("Workspace text edit is missing its range."))?;
    let start = parse_position(range.get("start"))?;
    let end = parse_position(range.get("end"))?;
    if end < start {
        return Err(malformed(
            "Workspace text edit range ends before it starts.",
        ));
    }
    let text = object
        .get("newText")
        .and_then(Value::as_str)
        .ok_or_else(|| malformed("Workspace text edit is missing its replacement text."))?;
    let mut result = json!({
        "range": {
            "start": { "line": start.0, "utf16Column": start.1 },
            "end": { "line": end.0, "utf16Column": end.1 }
        },
        "newText": text
    });
    copy_annotation(object, &mut result, annotations)?;
    Ok(result)
}

fn parse_position(value: Option<&Value>) -> Result<(u64, u64), WorkspaceEditParseError> {
    let value =
        value.ok_or_else(|| malformed("Workspace text edit is missing a range position."))?;
    let component = |key: &str| {
        value
            .get(key)
            .and_then(Value::as_u64)
            .filter(|value| *value <= i32::MAX as u64)
            .ok_or_else(|| malformed("Workspace range positions must be nonnegative LSP integers."))
    };
    Ok((component("line")?, component("character")?))
}
