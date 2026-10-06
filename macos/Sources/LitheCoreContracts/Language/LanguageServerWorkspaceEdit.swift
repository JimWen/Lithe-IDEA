import Foundation

/// A version is meaningful only within its producing session and for these
/// exact accepted source bytes; editor revision numbers are a different clock.
package struct LanguageServerSynchronizedDocumentSnapshot: Equatable, Sendable {
    package let sessionIdentity: String
    package let version: Int
    package let sourceText: String

    package init(sessionIdentity: String, version: Int, sourceText: String) {
        self.sessionIdentity = sessionIdentity
        self.version = version
        self.sourceText = sourceText
    }
}

/// The normalized Core contract retains server order and URI identity. Turning
/// these operations into filesystem paths is a separate host validation step.
package struct LanguageServerWorkspaceEdit: Codable, Equatable, Sendable {
    package let operations: [LanguageServerWorkspaceOperation]
    package let changeAnnotations: [String: LanguageServerChangeAnnotation]

    package init(operations: [LanguageServerWorkspaceOperation] = [],
                 changeAnnotations: [String: LanguageServerChangeAnnotation] = [:]) {
        self.operations = operations
        self.changeAnnotations = changeAnnotations
    }
}

package struct LanguageServerChangeAnnotation: Codable, Equatable, Sendable {
    package let label: String
    package let needsConfirmation: Bool?
    package let description: String?

    package init(label: String, needsConfirmation: Bool? = nil, description: String? = nil) {
        self.label = label
        self.needsConfirmation = needsConfirmation
        self.description = description
    }
}

package struct LanguageServerTextDocumentEdit: Codable, Equatable, Sendable {
    package let uri: String
    /// nil represents both absent and null. Zero remains a real server version.
    package let version: Int?
    package let edits: [LanguageServerTextEdit]

    package init(uri: String, version: Int? = nil, edits: [LanguageServerTextEdit]) {
        self.uri = uri
        self.version = version
        self.edits = edits
    }

    private enum CodingKeys: String, CodingKey { case uri, version, edits }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uri, forKey: .uri)
        try container.encode(version, forKey: .version)
        try container.encode(edits, forKey: .edits)
    }
}

package struct LanguageServerCreateFileOptions: Codable, Equatable, Sendable {
    package let overwrite: Bool?
    package let ignoreIfExists: Bool?
    package init(overwrite: Bool? = nil, ignoreIfExists: Bool? = nil) {
        self.overwrite = overwrite
        self.ignoreIfExists = ignoreIfExists
    }
}

package struct LanguageServerDeleteFileOptions: Codable, Equatable, Sendable {
    package let recursive: Bool?
    package let ignoreIfNotExists: Bool?
    package init(recursive: Bool? = nil, ignoreIfNotExists: Bool? = nil) {
        self.recursive = recursive
        self.ignoreIfNotExists = ignoreIfNotExists
    }
}

package struct LanguageServerCreateFile: Codable, Equatable, Sendable {
    package let uri: String
    package let options: LanguageServerCreateFileOptions?
    package let annotationID: String?
    package init(uri: String, options: LanguageServerCreateFileOptions? = nil, annotationID: String? = nil) {
        self.uri = uri
        self.options = options
        self.annotationID = annotationID
    }
    private enum CodingKeys: String, CodingKey {
        case uri, options
        case annotationID = "annotationId"
    }
}

package struct LanguageServerRenameFile: Codable, Equatable, Sendable {
    package let oldURI: String
    package let newURI: String
    package let options: LanguageServerCreateFileOptions?
    package let annotationID: String?
    package init(oldURI: String, newURI: String, options: LanguageServerCreateFileOptions? = nil,
                 annotationID: String? = nil) {
        self.oldURI = oldURI
        self.newURI = newURI
        self.options = options
        self.annotationID = annotationID
    }
    private enum CodingKeys: String, CodingKey {
        case oldURI = "oldUri"
        case newURI = "newUri"
        case options
        case annotationID = "annotationId"
    }
}

package struct LanguageServerDeleteFile: Codable, Equatable, Sendable {
    package let uri: String
    package let options: LanguageServerDeleteFileOptions?
    package let annotationID: String?
    package init(uri: String, options: LanguageServerDeleteFileOptions? = nil, annotationID: String? = nil) {
        self.uri = uri
        self.options = options
        self.annotationID = annotationID
    }
    private enum CodingKeys: String, CodingKey {
        case uri, options
        case annotationID = "annotationId"
    }
}

package enum LanguageServerWorkspaceOperation: Codable, Equatable, Sendable {
    case edit(LanguageServerTextDocumentEdit)
    case createFile(LanguageServerCreateFile)
    case renameFile(LanguageServerRenameFile)
    case deleteFile(LanguageServerDeleteFile)

    private enum CodingKeys: String, CodingKey { case kind }
    private enum Kind: String, Codable { case edit, create, rename, delete }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .edit: self = .edit(try LanguageServerTextDocumentEdit(from: decoder))
        case .create: self = .createFile(try LanguageServerCreateFile(from: decoder))
        case .rename: self = .renameFile(try LanguageServerRenameFile(from: decoder))
        case .delete: self = .deleteFile(try LanguageServerDeleteFile(from: decoder))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .edit(let edit):
            try container.encode(Kind.edit, forKey: .kind)
            try edit.encode(to: encoder)
        case .createFile(let resource):
            try container.encode(Kind.create, forKey: .kind)
            try resource.encode(to: encoder)
        case .renameFile(let resource):
            try container.encode(Kind.rename, forKey: .kind)
            try resource.encode(to: encoder)
        case .deleteFile(let resource):
            try container.encode(Kind.delete, forKey: .kind)
            try resource.encode(to: encoder)
        }
    }
}

/// LSP-facing encoding for codeAction/resolve. The normalized Core format must
/// never be sent back verbatim: LSP uses textDocument and character fields.
package struct LanguageServerWorkspaceEditWire: Encodable, Sendable {
    package let edit: LanguageServerWorkspaceEdit
    package init(_ edit: LanguageServerWorkspaceEdit) { self.edit = edit }

    private enum CodingKeys: String, CodingKey { case documentChanges, changeAnnotations }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(edit.operations.map(Operation.init), forKey: .documentChanges)
        try container.encode(edit.changeAnnotations, forKey: .changeAnnotations)
    }

    private struct Operation: Encodable {
        let operation: LanguageServerWorkspaceOperation
        init(_ operation: LanguageServerWorkspaceOperation) { self.operation = operation }
        private enum CodingKeys: String, CodingKey { case textDocument, edits }
        private struct Document: Encodable {
            let uri: String
            let version: Int?
            private enum CodingKeys: String, CodingKey { case uri, version }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(uri, forKey: .uri)
                try container.encode(version, forKey: .version)
            }
        }
        func encode(to encoder: Encoder) throws {
            if case .edit(let edit) = operation {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(Document(uri: edit.uri, version: edit.version), forKey: .textDocument)
                try container.encode(edit.edits.map(LanguageServerTextEditWire.init), forKey: .edits)
            } else {
                try operation.encode(to: encoder)
            }
        }
    }
}

package struct LanguageServerTextEditWire: Encodable, Sendable {
    package let edit: LanguageServerTextEdit
    package init(_ edit: LanguageServerTextEdit) { self.edit = edit }
    private enum CodingKeys: String, CodingKey { case range, newText, annotationId }
    private struct Position: Encodable { let line: Int; let character: Int }
    private struct Range: Encodable { let start: Position; let end: Position }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Range(start: Position(line: edit.range.start.line, character: edit.range.start.utf16Column),
                                   end: Position(line: edit.range.end.line, character: edit.range.end.utf16Column)), forKey: .range)
        try container.encode(edit.newText, forKey: .newText)
        try container.encodeIfPresent(edit.annotationID, forKey: .annotationId)
    }
}
