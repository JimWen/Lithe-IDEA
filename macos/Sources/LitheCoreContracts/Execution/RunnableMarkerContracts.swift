import Foundation

/// A runnable entry point discovered inside one open document.
public struct DocumentRunnable: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case application, test, benchmark, example }
    public let id: String
    public let configurationID: String?
    public let displayName: String
    public let kind: Kind
    public let line: Int
    public let symbolRange: LanguageServerRange

    public init(id: String, configurationID: String?, displayName: String, kind: Kind, line: Int, symbolRange: LanguageServerRange) {
        self.id = id; self.configurationID = configurationID; self.displayName = displayName
        self.kind = kind; self.line = line; self.symbolRange = symbolRange
    }
}

public struct DocumentRunnableSet: Equatable, Sendable {
    public let documentID: String
    public let documentRevision: Int
    public let runnables: [DocumentRunnable]

    public init(documentID: String, documentRevision: Int, runnables: [DocumentRunnable]) {
        self.documentID = documentID; self.documentRevision = documentRevision
        self.runnables = runnables.sorted { $0.line == $1.line ? $0.id < $1.id : $0.line < $1.line }
    }
}

@MainActor
public protocol DocumentRunnableProviding: AnyObject {
    func runnables(documentURL: URL, text: String, revision: Int,
                   completion: @escaping (Result<DocumentRunnableSet, Error>) -> Void)
}

public struct EphemeralRunPlan: Equatable, Sendable {
    public let displayName: String
    public let languageID: String
    public let workingDirectory: URL
    public let arguments: [String]
    public let environment: [String: String]

    public init(displayName: String, languageID: String, workingDirectory: URL, arguments: [String], environment: [String: String]) {
        self.displayName = displayName; self.languageID = languageID; self.workingDirectory = workingDirectory
        self.arguments = arguments; self.environment = environment
    }
}
