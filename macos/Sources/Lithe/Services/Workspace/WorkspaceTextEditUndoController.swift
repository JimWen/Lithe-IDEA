import Combine
import Foundation
import LitheCoreContracts

/// Coordinates disk and open-buffer edits, including every Undo/Redo cycle.
/// Buffer-only history commits synchronously. Mixed disk history uses an owned
/// task and retains compensation until the final buffer commit succeeds.
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
        !isApplying && !documents().contains(where: \.hasMutationLease)
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

    /// Keep the owned task joinable until compensation and lease cleanup finish.
    func cancelCurrentOperation() { operationTask?.cancel() }

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

    struct SelectionRestoration {
        let before: NSRange
        let after: NSRange
        let restore: @MainActor (NSRange) -> Void
        var inverse: Self { Self(before: after, after: before, restore: restore) }
    }

    func apply(_ edits: [WorkspaceTextEdit], at workspaceURL: URL,
               expectedBuffers: [URL: WorkspaceTextEditBufferSnapshot]? = nil,
               validate: @escaping @MainActor () -> Bool = { true },
               didCommit: @escaping @MainActor ([URL: WorkspaceTextEditBufferSnapshot]) -> Void = { _ in }) async -> WorkspaceTextEditTransactionResult {
        guard !isApplying else { return rejected(edits) }
        breakNativeEditCoalescing()
        isApplying = true
        let task = Task { @MainActor in
            let result = await self.perform(edits, at: workspaceURL, expectedBuffers: expectedBuffers,
                                            validate: validate) {
                self.registerTransition(self.inverse(edits), at: workspaceURL)
                didCommit(Dictionary(uniqueKeysWithValues: self.documents().map {
                    ($0.url.standardizedFileURL, WorkspaceTextEditBufferSnapshot($0))
                }))
            }
            self.isApplying = false
            return result
        }
        operationTask = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Completion commits during NSTextView's callback and performs no file I/O.
    func applyOpenDocumentEdits(_ edits: [WorkspaceTextEdit], at workspaceURL: URL,
                                expectedBuffers: [URL: WorkspaceTextEditBufferSnapshot],
                                selection: SelectionRestoration? = nil) -> WorkspaceTextEditTransactionResult {
        guard !isApplying else { return rejected(edits) }
        breakNativeEditCoalescing()
        isApplying = true
        defer { isApplying = false }
        guard let batch = prepare(edits, at: workspaceURL, expectedBuffers: expectedBuffers, requireOpen: true) else {
            return rejected(edits)
        }
        defer { release(batch) }
        let changed = batch.buffers.filter { $0.edit.changesText }
        willMutate(batch.buffers.map(\.document))
        changed.forEach { $0.document.commitMutationText($0.edit.replacementText, lease: $0.lease) }
        if let selection { selection.restore(selection.after) }
        let history = Dictionary(uniqueKeysWithValues: changed.map {
            ($0.document.url.standardizedFileURL, WorkspaceTextEditBufferSnapshot($0.document))
        })
        registerTransition(inverse(edits), at: workspaceURL, selection: selection?.inverse, history: history)
        return WorkspaceTextEditTransactionResult(transactionID: UUID(), state: .applied, changedPaths: edits.filter(\.changesText).map(\.path))
    }

    private func registerTransition(_ edits: [WorkspaceTextEdit], at workspaceURL: URL,
                                    selection: SelectionRestoration? = nil,
                                    history: [URL: WorkspaceTextEditBufferSnapshot]? = nil) {
        guard !edits.isEmpty else { return }
        // Separate the workspace operation from the current native typing group.
        // During undo/redo AppKit owns this group and the inverse must join it.
        let ownsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if ownsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                guard !target.isApplying else { return }
                guard target.matchesHistory(history) else {
                    target.undoManager.removeAllActions(withTarget: target)
                    target.notifyFailure("Could not undo or redo because the original document was closed or reloaded.")
                    return
                }
                if history != nil {
                    let current = Dictionary(uniqueKeysWithValues: target.documents().map {
                        ($0.url.standardizedFileURL, WorkspaceTextEditBufferSnapshot($0))
                    })
                    let result = target.applyOpenDocumentEdits(edits, at: workspaceURL,
                        expectedBuffers: current, selection: selection)
                    if result.state != .applied {
                        target.undoManager.removeAllActions(withTarget: target)
                        target.notifyFailure("Could not undo or redo the replacement because files changed. Review the current files.")
                    }
                    return
                }
                target.registerTransition(target.inverse(edits), at: workspaceURL, selection: selection?.inverse, history: history)
                target.isApplying = true
                target.operationTask = Task { @MainActor in
                    let result = await target.perform(edits, at: workspaceURL, validate: { target.matchesHistory(history) }, onCommit: {
                        if let selection { selection.restore(selection.after) }
                    })
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
        }
        undoManager.setActionName("Replace Text")
        if ownsGroup { undoManager.endUndoGrouping() }
    }

    private func matchesHistory(_ history: [URL: WorkspaceTextEditBufferSnapshot]?) -> Bool {
        guard let history else { return true }
        let current = documents()
        return history.allSatisfy { url, expected in
            current.first(where: { $0.url.standardizedFileURL == url }).map(expected.matchesHistory) == true
        }
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

    private struct BufferMutation {
        let document: EditorDocument
        let edit: WorkspaceTextEdit
        let lease: EditorDocument.MutationLease
    }

    private struct PreparedBatch {
        let buffers: [BufferMutation]
        let disk: [WorkspaceTextEdit]
    }

    private func prepare(_ edits: [WorkspaceTextEdit], at workspaceURL: URL,
                         expectedBuffers: [URL: WorkspaceTextEditBufferSnapshot]?,
                         requireOpen: Bool = false) -> PreparedBatch? {
        guard Set(edits.map(\.path)).count == edits.count,
              edits.allSatisfy(WorkspaceTextEditCoordinator.isValidPath) else { return nil }
        let openDocuments = documents()
        var buffers: [BufferMutation] = []
        var disk: [WorkspaceTextEdit] = []
        var prepared = false
        defer {
            if !prepared { buffers.forEach { $0.document.releaseMutationLease($0.lease) } }
        }
        for edit in edits {
            let url = workspaceURL.appendingPathComponent(edit.path).standardizedFileURL
            guard let document = openDocuments.first(where: { $0.url.standardizedFileURL == url }) else {
                guard !requireOpen, expectedBuffers?[url] == nil else { return nil }
                disk.append(edit)
                continue
            }
            if let expectedBuffers {
                guard let expected = expectedBuffers[url], expected.matches(document) else { return nil }
            }
            guard !document.isReadOnly, !document.hasExternalConflict,
                  document.text.utf8.elementsEqual(edit.sourceText.utf8) else { return nil }
            // Only this no-I/O path holds leases without yielding. A save's
            // captured snapshot remains independent of synchronous live edits.
            let lease = requireOpen ? document.acquireSynchronousBufferMutationLease() : document.acquireMutationLease()
            guard let lease else { return nil }
            buffers.append(BufferMutation(document: document, edit: edit, lease: lease))
        }
        prepared = true
        return PreparedBatch(buffers: buffers, disk: disk)
    }

    private func release(_ batch: PreparedBatch) {
        batch.buffers.forEach { $0.document.releaseMutationLease($0.lease) }
        // Even unchanged leased buffers may have deferred watcher events or
        // suspended autosave. End the lifecycle for every lease we acquired.
        didMutate(batch.buffers.map(\.document))
    }

    private func perform(_ edits: [WorkspaceTextEdit], at workspaceURL: URL,
                         expectedBuffers: [URL: WorkspaceTextEditBufferSnapshot]? = nil,
                         validate: @escaping @MainActor () -> Bool = { true },
                         onCommit: @escaping @MainActor () -> Void = {}) async -> WorkspaceTextEditTransactionResult {
        guard !Task.isCancelled, validate() else {
            return WorkspaceTextEditTransactionResult(transactionID: UUID(), state: .cancelled)
        }
        guard let batch = prepare(edits, at: workspaceURL, expectedBuffers: expectedBuffers) else { return rejected(edits) }
        defer { release(batch) }
        willMutate(batch.buffers.map(\.document))
        let result = await coordinator.apply(batch.disk, at: workspaceURL, operations: operations,
            validate: { await MainActor.run { validate() } }, commit: { @MainActor in
                guard !Task.isCancelled, validate() else { throw CancellationError() }
                let current = self.documents()
                for buffer in batch.buffers {
                    guard current.contains(where: { $0 === buffer.document }),
                          buffer.document.url.standardizedFileURL == workspaceURL.appendingPathComponent(buffer.edit.path).standardizedFileURL,
                          buffer.document.hasMutationLease,
                          buffer.document.text.utf8.elementsEqual(buffer.edit.sourceText.utf8),
                          !buffer.document.isReadOnly, !buffer.document.hasExternalConflict else { throw CancellationError() }
                }
                for edit in batch.disk {
                    guard !current.contains(where: { $0.url.standardizedFileURL == workspaceURL.appendingPathComponent(edit.path).standardizedFileURL }) else {
                        throw CancellationError()
                    }
                }
                batch.buffers.filter { $0.edit.changesText }.forEach { $0.document.commitMutationText($0.edit.replacementText, lease: $0.lease) }
                onCommit()
            })
        guard result.state == .applied else { return result }
        return WorkspaceTextEditTransactionResult(transactionID: result.transactionID,
                                                  state: .applied, changedPaths: edits.filter(\.changesText).map(\.path))
    }

    private func inverse(_ edits: [WorkspaceTextEdit]) -> [WorkspaceTextEdit] {
        edits.filter(\.changesText).map { WorkspaceTextEdit(path: $0.path, sourceText: $0.replacementText,
                                     replacementText: $0.sourceText, sourceIdentity: "") }
    }

    private func rejected(_ edits: [WorkspaceTextEdit]) -> WorkspaceTextEditTransactionResult {
        WorkspaceTextEditTransactionResult(transactionID: UUID(), state: .failed, failedPaths: edits.map(\.path))
    }

    deinit { operationTask?.cancel() }
}
