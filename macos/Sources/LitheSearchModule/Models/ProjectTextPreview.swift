import Foundation

/// All paths remain relative to the captured workspace root, including directory scopes.
public enum ProjectTextScope: Hashable, Sendable, Encodable {
    case project
    case directory(String)
    case files([String])

    private enum CodingKeys: String, CodingKey { case kind, path, paths }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .project:
            try values.encode("project", forKey: .kind)
        case .directory(let path):
            try values.encode("directory", forKey: .kind)
            try values.encode(path, forKey: .path)
        case .files(let paths):
            try values.encode("files", forKey: .kind)
            try values.encode(paths, forKey: .paths)
        }
    }

    public var isEmpty: Bool {
        if case .files(let paths) = self { return paths.isEmpty }
        return false
    }
}

public enum ProjectTextPreviewPurpose: String, Sendable, Encodable { case search, replace }

public struct ProjectTextPreviewRequest: Sendable {
    public let operationID = UUID().uuidString
    public let rootURL: URL
    public let scope: ProjectTextScope
    public let purpose: ProjectTextPreviewPurpose
    public let query: String
    public let replacement: String
    public let options: ProjectSearchOptions
    public let textOverrides: [String: String]
    public let visibilityRules: SearchVisibilityRules

    public init(rootURL: URL, scope: ProjectTextScope, purpose: ProjectTextPreviewPurpose,
                query: String, replacement: String = "", options: ProjectSearchOptions,
                textOverrides: [String: String], visibilityRules: SearchVisibilityRules) {
        self.rootURL = rootURL
        self.scope = scope
        self.purpose = purpose
        self.query = query
        self.replacement = replacement
        self.options = options
        self.textOverrides = textOverrides
        self.visibilityRules = visibilityRules
    }
}

public struct ProjectTextPreviewIssue: Decodable, Hashable, Sendable {
    public let path: String?
    public let code: String
    public let message: String

    public init(path: String?, code: String, message: String) {
        self.path = path
        self.code = code
        self.message = message
    }
}

public struct ProjectTextPreview: Sendable {
    public enum Status: String, Decodable, Sendable { case complete, incomplete }
    public let files: [ProjectReplacementFile]
    public let status: Status
    public let issues: [ProjectTextPreviewIssue]

    public init(files: [ProjectReplacementFile], status: Status, issues: [ProjectTextPreviewIssue] = []) {
        self.files = files
        self.status = status
        self.issues = issues
    }
}

public struct ProjectSearchFailure: Error, LocalizedError, Hashable, Sendable {
    public let code: String
    public let message: String
    public let details: String?

    public init(code: String, message: String, details: String? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    public var errorDescription: String? {
        guard let details, !details.isEmpty else { return message }
        return message + ": " + details
    }
}

/// An occurrence refers to the unchanged source snapshot using UTF-16 offsets.
public struct ProjectReplacementEdit: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let line: Int
    public let utf16Start: Int
    public let utf16Length: Int
    public let newText: String

    public init(id: String, line: Int, utf16Start: Int, utf16Length: Int, newText: String) {
        self.id = id
        self.line = line
        self.utf16Start = utf16Start
        self.utf16Length = utf16Length
        self.newText = newText
    }
}
