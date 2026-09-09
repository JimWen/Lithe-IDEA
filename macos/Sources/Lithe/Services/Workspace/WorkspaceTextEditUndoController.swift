import Combine
import Foundation
import LitheCoreContracts

/// Coordinates disk and open-buffer edits, including every Undo/Redo cycle.
/// Native UndoManager callbacks register their inverse synchronously; the owned
/// task validates and commits the transition before publishing buffer changes.
@MainActor
final class WorkspaceTextEditUndoController: ObservableObject {
    private let undoManager: UndoManager
    private let coordinator: WorkspaceTextEditCoordinator
    private let operations: any WorkspaceTextEditFileOperations
    private var documents: () -> [EditorDocument] = { [] }
    private var willMutate: ([EditorDocument]) -> Void = { _ in }
    private var didMutate: ([EditorDocument]) -> Void = { _ in }
    private var notifyFailure: (String) -> Void = { _ in }
    private var operationTask: Task<WorkspaceTextEditTransactionResult, Never>?
    @Published private(set) var isApplying = false

    var sharedUndoManager: UndoManager { undoManager }
    var canUndo: Bool { !isApplying && undoManager.canUndo }
    var canRedo: Bool { !isApplying && undoManager.canRedo }

    init(undoManager: UndoManager, coordinator: WorkspaceTextEditCoordinator,
         operations: any WorkspaceTextEditFileOperations) {
        self.undoManager = undoManager
        self.coordinator = coordinator
        self.operations = operations
    }

    func configure(documents: @escaping () -> [EditorDocument],
                   willMutate: @escaping ([EditorDocument]) -> Void,
                   didMutate: @escaping ([EditorDocument]) -> Void,
                   notifyFailure: @escaping (String) -> Void) {
        self.documents = documents
        self.willMutate = willMutate
        self.didMutate = didMutate
        self.notifyFailure = notifyFailure
    }

    func reset() {
        operationTask?.cancel()
        undoManager.removeAllActions()
    }

    func waitForCurrentOperation() async -> WorkspaceTextEditTransactionResult? {
        await operationTask?.value
    }

    func apply(_ edits: [WorkspaceTextEdit], at workspaceURL: URL) async -> WorkspaceTextEditTransactionResult {
        guard !isApplying else { return rejected(edits) }
        isApplying = true
        let task = Task { @MainActor in
            let result = await self.perform(edits, at: workspaceURL)
            if result.state == .applied, !Task.isCancelled {
                self.registerTransition(self.inverse(edits), at: workspaceURL)
            }
            self.isApplying = false
            return result
        }
        operationTask = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func registerTransition(_ edits: [WorkspaceTextEdit], at workspaceURL: URL) {
        guard !edits.isEmpty else { return }
        // Separate the workspace operation from the current native typing group.
        // During undo/redo AppKit owns this group and the inverse must join it.
        let ownsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if ownsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in
            guard !target.isApplying else { return }
            target.registerTransition(target.inverse(edits), at: workspaceURL)
            target.isApplying = true
            target.operationTask = Task { @MainActor in
                let result = await target.perform(edits, at: workspaceURL)
                if result.state != .applied {
                    // Neither the failed transition nor its optimistic inverse
                    // may overwrite a later external/user edit on the next click.
                    target.undoManager.removeAllActions(withTarget: target)
                    target.notifyFailure("Could not undo or redo the replacement because files changed. Review the current files.")
                }
                target.isApplying = false
                return result
            }
        }
        undoManager.setActionName("Replace Text")
        if ownsGroup { undoManager.endUndoGrouping() }
    }

    private func perform(_ edits: [WorkspaceTextEdit], at workspaceURL: URL) async -> WorkspaceTextEditTransactionResult {
        guard !Task.isCancelled else {
            return WorkspaceTextEditTransactionResult(transactionID: UUID(), state: .cancelled)
        }
        guard Set(edits.map(\.path)).count == edits.count,
              edits.allSatisfy(WorkspaceTextEditCoordinator.isValidPath) else { return rejected(edits) }
        let openDocuments = documents()
        var leased: [(document: EditorDocument, lease: EditorDocument.MutationLease)] = []
        var buffers: [(document: EditorDocument, edit: WorkspaceTextEdit, lease: EditorDocument.MutationLease)] = []
        var disk: [WorkspaceTextEdit] = []
        defer {
            leased.forEach { $0.document.releaseMutationLease($0.lease) }
            didMutate(leased.map(\.document))
        }
        for edit in edits {
            let url = workspaceURL.appendingPathComponent(edit.path).standardizedFileURL
            guard let document = openDocuments.first(where: { $0.url.standardizedFileURL == url }) else {
                disk.append(edit)
                continue
            }
            guard !document.isReadOnly, !document.hasExternalConflict,
                  document.text.utf8.elementsEqual(edit.sourceText.utf8),
                  let lease = document.acquireMutationLease() else { return rejected(edits) }
            leased.append((document, lease))
            buffers.append((document, edit, lease))
        }
        willMutate(leased.map(\.document))
        let result = await coordinator.apply(disk, at: workspaceURL, operations: operations)
        guard result.state == .applied else { return result }
        // Even an already-dirty document must publish a programmatic change so
        // its NSTextView replaces the visible buffer and refreshes LSP state.
        for buffer in buffers { buffer.document.commitMutationText(buffer.edit.replacementText, lease: buffer.lease) }
        return WorkspaceTextEditTransactionResult(transactionID: result.transactionID,
                                                  state: .applied, changedPaths: edits.map(\.path))
    }

    private func inverse(_ edits: [WorkspaceTextEdit]) -> [WorkspaceTextEdit] {
        edits.map { WorkspaceTextEdit(path: $0.path, sourceText: $0.replacementText,
                                     replacementText: $0.sourceText, sourceIdentity: "") }
    }

    private func rejected(_ edits: [WorkspaceTextEdit]) -> WorkspaceTextEditTransactionResult {
        WorkspaceTextEditTransactionResult(transactionID: UUID(), state: .failed, failedPaths: edits.map(\.path))
    }

    deinit { operationTask?.cancel() }
}
