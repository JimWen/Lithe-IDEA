import Foundation
import LitheCoreContracts

/// Complete preflight over immutable sources. Repeated document operations
/// consume the previous virtual result, then become one transaction per path.
enum LanguageWorkspaceEditPlanner {
    struct Source: Sendable {
        let path: String
        let text: String
        let diskIdentity: String
        let isOpen: Bool
        let synchronized: LanguageServerSynchronizedDocumentSnapshot?
    }

    enum Failure: LocalizedError {
        case unsupportedOperation, confirmationRequired, invalidTarget, staleSource
        var errorDescription: String? {
            switch self {
            case .unsupportedOperation: "This language action contains a file operation that is not yet supported."
            case .confirmationRequired: "This language action requires confirmation that is not yet supported."
            case .invalidTarget: "The language action targets an invalid or unavailable workspace file."
            case .staleSource: "The document or language server changed. Request the action again."
            }
        }
    }

    static func textOperations(_ edit: LanguageServerWorkspaceEdit, rootURL: URL) throws -> [(URL, LanguageServerTextDocumentEdit)] {
        guard edit.changeAnnotations.values.allSatisfy({ $0.needsConfirmation != true }) else {
            throw Failure.confirmationRequired
        }
        let root = rootURL.standardizedFileURL.path + "/"
        return try edit.operations.map { operation in
            guard case .edit(let documentEdit) = operation else { throw Failure.unsupportedOperation }
            guard let url = URL(string: documentEdit.uri), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil else { throw Failure.invalidTarget }
            let target = url.standardizedFileURL
            guard target.path.hasPrefix(root), target.path.count > root.count,
                  !target.path.contains("\\"), !target.path.contains("\0") else { throw Failure.invalidTarget }
            for textEdit in documentEdit.edits {
                if let annotation = textEdit.annotationID, edit.changeAnnotations[annotation] == nil {
                    throw Failure.invalidTarget
                }
            }
            return (target, documentEdit)
        }
    }

    static func plan(_ edit: LanguageServerWorkspaceEdit, rootURL: URL,
                     sources: [URL: Source], sessionIdentity: String?) throws -> [WorkspaceTextEdit] {
        let operations = try textOperations(edit, rootURL: rootURL)
        var replacements: [URL: String] = [:]
        var order: [URL] = []
        for (url, operation) in operations {
            guard let source = sources[url] else { throw Failure.invalidTarget }
            if let synchronized = source.synchronized {
                guard synchronized.sessionIdentity == sessionIdentity,
                      synchronized.sourceText.utf8.elementsEqual(source.text.utf8),
                      operation.version == nil || operation.version == synchronized.version else { throw Failure.staleSource }
            } else if source.isOpen {
                // Local completions are unversioned and have no LSP session.
                guard sessionIdentity == nil, operation.version == nil else { throw Failure.staleSource }
            } else {
                // gopls uses zero for unopened files. The disk transaction must
                // still validate both captured identity and exact source bytes.
                guard operation.version == nil || operation.version == 0,
                      !source.diskIdentity.isEmpty else { throw Failure.staleSource }
            }
            if replacements[url] == nil { order.append(url) }
            replacements[url] = try LanguageServerTextEditApplicator.apply(operation.edits, to: replacements[url] ?? source.text)
        }
        return order.compactMap { url in
            guard let source = sources[url], let replacement = replacements[url] else { return nil }
            // No-op targets still constrain the complete action and its command.
            return WorkspaceTextEdit(path: source.path, sourceText: source.text, replacementText: replacement,
                                     sourceIdentity: source.diskIdentity)
        }
    }
}
