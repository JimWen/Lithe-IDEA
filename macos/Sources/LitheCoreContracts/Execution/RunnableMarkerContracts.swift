import Foundation

/// A runnable entry point discovered inside one open document.
package struct DocumentRunnable: Equatable, Identifiable, Sendable {
    package enum Kind: String, Sendable { case application, test, benchmark, example }
    package let id: String
    package let configurationID: String?
    package let displayName: String
    package let kind: Kind
    package let line: Int
    package let symbolRange: LanguageServerRange

    package init(id: String, configurationID: String?, displayName: String, kind: Kind, line: Int, symbolRange: LanguageServerRange) {
        self.id = id; self.configurationID = configurationID; self.displayName = displayName
        self.kind = kind; self.line = line; self.symbolRange = symbolRange
    }
}

package struct DocumentRunnableSet: Equatable, Sendable {
    package let documentID: String
    package let documentRevision: Int
    package let runnables: [DocumentRunnable]

    package init(documentID: String, documentRevision: Int, runnables: [DocumentRunnable]) {
        self.documentID = documentID; self.documentRevision = documentRevision
        self.runnables = runnables.sorted { $0.line == $1.line ? $0.id < $1.id : $0.line < $1.line }
    }
}

@MainActor
package protocol DocumentRunnableProviding: AnyObject {
    func runnables(documentURL: URL, text: String, revision: Int,
                   completion: @escaping (Result<DocumentRunnableSet, Error>) -> Void)
}

package struct EphemeralRunPlan: Equatable, Sendable {
    package let displayName: String
    package let languageID: String
    package let workingDirectory: URL
    package let arguments: [String]
    package let environment: [String: String]

    package init(displayName: String, languageID: String, workingDirectory: URL, arguments: [String], environment: [String: String]) {
        self.displayName = displayName; self.languageID = languageID; self.workingDirectory = workingDirectory
        self.arguments = arguments; self.environment = environment
    }
}
