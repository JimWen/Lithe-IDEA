import Combine
import Foundation
import LitheCoreContracts

/// Coordinates disk and open-buffer edits, including every Undo/Redo cycle.
/// Native UndoManager callbacks register their inverse synchronously; the owned
/// task validates and commits the transition before publishing buffer changes.
@MainActor
final class WorkspaceTextEditUndoController: ObservableObject {
    enum NativeTextEditKind: Sendable {
        case typing
        case backwardDelete
        case forwardDelete
        case atomic
    }

    struct NativeTextEdit: @unchecked Sendable {
        let replacedRange: NSRange
        let removedText: String
        let insertedText: String
        let beforeSelection: NSRange
        let afterSelection: NSRange
        let kind: NativeTextEditKind
        let generation: UInt64
        let restoreSelection: @MainActor @Sendable (NSRange) -> Void
    }

    private final class NativeTextEntry: @unchecked Sendable {
        var replacedRange: NSRange
        var removedText: String
        var insertedText: String
        let beforeSelection: NSRange
        var afterSelection: NSRange
        let kind: NativeTextEditKind
        let generation: UInt64
        let restoreSelection: @MainActor @Sendable (NSRange) -> Void
        weak var document: EditorDocument?

        init(document: EditorDocument, edit: NativeTextEdit) {
            self.document = document
            replacedRange = edit.replacedRange
            removedText = edit.removedText
            insertedText = edit.insertedText
            beforeSelection = edit.beforeSelection
            afterSelection = edit.afterSelection
            kind = edit.kind
            generation = edit.generation
            restoreSelection = edit.restoreSelection
        }
    }

    private struct NativeTextTransition: @unchecked Sendable {
        let range: NSRange
        let expectedText: String
        let replacementText: String
        let resultingSelection: NSRange
        let inverseSelection: NSRange
        let generation: UInt64
        let restoreSelection: @MainActor @Sendable (NSRange) -> Void

        var inverse: NativeTextTransition {
            NativeTextTransition(
                range: NSRange(location: range.location, length: replacementText.utf16.count),
                expectedText: replacementText,
                replacementText: expectedText,
                resultingSelection: inverseSelection,
                inverseSelection: resultingSelection,
                generation: generation,
                restoreSelection: restoreSelection
            )
        }
    }

    private let undoManager: UndoManager
    private let coordinator: WorkspaceTextEditCoordinator
    private let operations: any WorkspaceTextEditFileOperations
    private var documents: () -> [EditorDocument] = { [] }
    private var willMutate: ([EditorDocument]) -> Void = { _ in }
    private var didMutate: ([EditorDocument]) -> Void = { _ in }
    private var notifyFailure: (String) -> Void = { _ in }
    private var operationTask: Task<WorkspaceTextEditTransactionResult, Never>?
    private var coalescingNativeEntry: NativeTextEntry?
    private var nativeDocuments: [ObjectIdentifier: EditorDocument] = [:]
    @Published private(set) var isApplying = false

    var sharedUndoManager: UndoManager { undoManager }
    var canUndo: Bool { canTraverseNativeHistory && undoManager.canUndo }
    var canRedo: Bool { canTraverseNativeHistory && undoManager.canRedo }

    private var canTraverseNativeHistory: Bool {
        !isApplying && !nativeDocuments.values.contains(where: \.hasMutationLease)
    }

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
        coalescingNativeEntry = nil
        undoManager.removeAllActions()
        nativeDocuments.removeAll()
    }

    func recordNativeEdit(_ edit: NativeTextEdit, in document: EditorDocument) {
        guard !isApplying,
              !undoManager.isUndoing,
              !undoManager.isRedoing,
              edit.generation == document.nativeHistoryGeneration,
              !edit.removedText.utf8.elementsEqual(edit.insertedText.utf8) else { return }
        if merge(edit, into: coalescingNativeEntry, document: document) { return }
        nativeDocuments[ObjectIdentifier(document)] = document
        let entry = NativeTextEntry(document: document, edit: edit)
        coalescingNativeEntry = edit.kind == .atomic ? nil : entry
        registerNativeEntry(entry, document: document)
    }

    func breakNativeEditCoalescing(for document: EditorDocument? = nil) {
        guard document == nil || coalescingNativeEntry?.document === document else { return }
        coalescingNativeEntry = nil
    }

    func handleDocumentClosed(_ document: EditorDocument) {
        breakNativeEditCoalescing(for: document)
        undoManager.removeAllActions(withTarget: document)
        nativeDocuments[ObjectIdentifier(document)] = nil
    }

    func waitForCurrentOperation() async -> WorkspaceTextEditTransactionResult? {
        await operationTask?.value
    }

    @discardableResult
    func undo() -> Bool {
        guard canUndo else { return false }
        breakNativeEditCoalescing()
        undoManager.undo()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard canRedo else { return false }
        breakNativeEditCoalescing()
        undoManager.redo()
        return true
    }

    func apply(_ edits: [WorkspaceTextEdit], at workspaceURL: URL) async -> WorkspaceTextEditTransactionResult {
        guard !isApplying else { return rejected(edits) }
        breakNativeEditCoalescing()
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

    private func registerNativeTransition(_ transition: NativeTextTransition, document: EditorDocument) {
        let ownsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if ownsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: document) { [weak self] target in
            self?.replayNativeTransition(transition, document: target)
        }
        undoManager.setActionName("Edit Text")
        if ownsGroup { undoManager.endUndoGrouping() }
    }

    private func registerNativeEntry(_ entry: NativeTextEntry, document: EditorDocument) {
        let ownsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if ownsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: document) { [weak self, entry] target in
            self?.replayNativeTransition(
                NativeTextTransition(
                    range: NSRange(
                        location: entry.replacedRange.location,
                        length: entry.insertedText.utf16.count
                    ),
                    expectedText: entry.insertedText,
                    replacementText: entry.removedText,
                    resultingSelection: entry.beforeSelection,
                    inverseSelection: entry.afterSelection,
                    generation: entry.generation,
                    restoreSelection: entry.restoreSelection
                ),
                document: target
            )
        }
        undoManager.setActionName("Edit Text")
        if ownsGroup { undoManager.endUndoGrouping() }
    }

    private func replayNativeTransition(_ transition: NativeTextTransition, document: EditorDocument) {
        breakNativeEditCoalescing()
        guard !isApplying,
              nativeDocuments[ObjectIdentifier(document)] === document,
              !document.isReadOnly,
              !document.hasExternalConflict,
              !document.hasMutationLease,
              transition.generation == document.nativeHistoryGeneration,
              let replacementRange = validatedRange(
                  transition.range,
                  expectedText: transition.expectedText,
                  in: document.text
              ) else {
            rejectNativeHistory(for: document)
            return
        }
        let source = document.text as NSString
        let nextText = source.replacingCharacters(in: replacementRange, with: transition.replacementText)
        willMutate([document])
        registerNativeTransition(transition.inverse, document: document)
        transition.restoreSelection(transition.resultingSelection)
        guard document.applyNativeHistoryText(nextText) else { return }
        didMutate([document])
    }

    private func validatedRange(
        _ range: NSRange,
        expectedText: String,
        in source: String
    ) -> NSRange? {
        let text = source as NSString
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              range.location <= text.length,
              range.length <= text.length - range.location,
              Range(range, in: source) != nil,
              text.substring(with: range).utf8.elementsEqual(expectedText.utf8) else { return nil }
        return range
    }

    private func rejectNativeHistory(for document: EditorDocument) {
        undoManager.removeAllActions(withTarget: document)
        notifyFailure("Could not undo or redo this edit because the document changed. Review the current text.")
    }

    private func merge(
        _ edit: NativeTextEdit,
        into entry: NativeTextEntry?,
        document: EditorDocument
    ) -> Bool {
        guard let entry,
              entry.document === document,
              entry.generation == edit.generation,
              entry.kind == edit.kind,
              entry.afterSelection == edit.beforeSelection else { return false }
        switch edit.kind {
        case .typing:
            guard entry.removedText.isEmpty,
                  edit.removedText.isEmpty,
                  edit.replacedRange.location == entry.replacedRange.location + entry.insertedText.utf16.count else {
                return false
            }
            entry.insertedText += edit.insertedText
        case .backwardDelete:
            guard entry.insertedText.isEmpty,
                  edit.insertedText.isEmpty,
                  NSMaxRange(edit.replacedRange) == entry.replacedRange.location else { return false }
            entry.replacedRange.location = edit.replacedRange.location
            entry.replacedRange.length += edit.replacedRange.length
            entry.removedText = edit.removedText + entry.removedText
        case .forwardDelete:
            guard entry.insertedText.isEmpty,
                  edit.insertedText.isEmpty,
                  edit.replacedRange.location == entry.replacedRange.location else { return false }
            entry.replacedRange.length += edit.replacedRange.length
            entry.removedText += edit.removedText
        case .atomic:
            return false
        }
        entry.afterSelection = edit.afterSelection
        return true
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
