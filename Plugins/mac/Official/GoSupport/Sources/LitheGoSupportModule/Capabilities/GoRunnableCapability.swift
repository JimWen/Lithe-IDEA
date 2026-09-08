import Foundation
import LitheCoreContracts

/// Deterministic first-stage Go runnable discovery. The provider is deliberately
/// syntax-only until the document-symbol session is available; it never runs
/// package init or test code.
@MainActor
public final class GoRunnableCapability: NSObject, DocumentRunnableProviding {
    public override init() {}

    public func runnables(documentURL: URL, text: String, revision: Int,
                           completion: @escaping (Result<DocumentRunnableSet, Error>) -> Void) {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
        let isTestFile = documentURL.lastPathComponent.hasSuffix("_test.go")
        let packageMain = lines.contains { String($0).trimmingCharacters(in: .whitespaces).hasPrefix("package main") }
        var values: [DocumentRunnable] = []
        for (index, line) in lines.enumerated() {
            let value = String(line).trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("func ") else { continue }
            let suffix = String(value.dropFirst(5))
            let namePart = suffix.components(separatedBy: CharacterSet(charactersIn: "({")).first ?? ""
            let name = namePart.trimmingCharacters(in: CharacterSet.whitespaces)
            let kind: DocumentRunnable.Kind?
            if name == "main" && packageMain { kind = .application }
            else if isTestFile && name.hasPrefix("Test") { kind = .test }
            else if isTestFile && name.hasPrefix("Benchmark") { kind = .benchmark }
            else if isTestFile && name.hasPrefix("Example") { kind = .example }
            else { kind = nil }
            guard let kind else { continue }
            let position = LanguageServerPosition(line: index, utf16Column: 0)
            values.append(DocumentRunnable(id: "go:\(kind.rawValue):\(name):\(index + 1)", configurationID: nil,
                                           displayName: name, kind: kind, line: index + 1,
                                           symbolRange: LanguageServerRange(start: position, end: position)))
        }
        completion(.success(DocumentRunnableSet(documentID: documentURL.standardizedFileURL.path,
                                                documentRevision: revision, runnables: values)))
    }
}
