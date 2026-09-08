import Foundation
import LitheCoreContracts

/// Owns one undo entry per successful workspace edit transaction. The entry
/// delegates execution back to the same coordinator, so undo never writes an
/// unvalidated stale snapshot directly.
@MainActor
final class WorkspaceTextEditUndoController {
    private let undoManager: UndoManager
    private let coordinator: WorkspaceTextEditCoordinator
    private let operations: any WorkspaceTextEditFileOperations

    init(undoManager: UndoManager, coordinator: WorkspaceTextEditCoordinator,
         operations: any WorkspaceTextEditFileOperations) {
        self.undoManager = undoManager
        self.coordinator = coordinator
        self.operations = operations
    }

    func register(edits: [WorkspaceTextEdit], workspaceURL: URL, transactionID: UUID) {
        guard !edits.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                await target.applyInverse(edits, workspaceURL: workspaceURL, transactionID: transactionID)
            }
        }
        undoManager.setActionName("Replace Text")
    }

    func registerOpenDocuments(_ edits: [(document: EditorDocument, before: String, after: String)]) {
        guard !edits.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { target in
            for edit in edits { edit.document.text = edit.before }
            target.undoManager.registerUndo(withTarget: target) { _ in
                for edit in edits { edit.document.text = edit.after }
            }
            target.undoManager.setActionName("Redo Replace Text")
        }
        undoManager.setActionName("Replace Text")
    }

    func registerTransaction(
        edits: [WorkspaceTextEdit],
        openDocuments: [(document: EditorDocument, before: String, after: String)],
        workspaceURL: URL,
        transactionID: UUID
    ) {
        guard !edits.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                let inverse = edits.map {
                    WorkspaceTextEdit(path: $0.path, sourceText: $0.replacementText,
                                      replacementText: $0.sourceText, sourceIdentity: "")
                }
                _ = await target.coordinator.apply(inverse, at: workspaceURL,
                                                   operations: target.operations,
                                                   transactionID: transactionID)
                for edit in openDocuments { edit.document.text = edit.before }
                target.undoManager.registerUndo(withTarget: target) { _ in
                    Task { @MainActor in
                        _ = await target.coordinator.apply(edits, at: workspaceURL,
                                                           operations: target.operations,
                                                           transactionID: transactionID)
                        for edit in openDocuments { edit.document.text = edit.after }
                    }
                }
                target.undoManager.setActionName("Redo Replace Text")
            }
        }
        undoManager.setActionName("Replace Text")
    }

    private func applyInverse(_ edits: [WorkspaceTextEdit], workspaceURL: URL, transactionID: UUID) async {
        let inverse = edits.map {
            WorkspaceTextEdit(path: $0.path, sourceText: $0.replacementText,
                              replacementText: $0.sourceText, sourceIdentity: "")
        }
        _ = await coordinator.apply(inverse, at: workspaceURL, operations: operations,
                                    transactionID: transactionID)
    }
}
