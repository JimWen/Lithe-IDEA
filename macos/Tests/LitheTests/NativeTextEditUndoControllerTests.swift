import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
struct NativeTextEditUndoControllerTests {
    @Test
    func eventGroupedTypingCompletionTypingUndoRemainsSynchronous() async throws {
        let document = document("f", named: "completion.swift")
        let harness = NativeUndoHarness(documents: [document])
        harness.undoManager.groupsByEvent = true
        defer { harness.controller.reset() }

        for step in 0..<3 {
            let closed = TestGate()
            let observer = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidCloseUndoGroup,
                object: harness.undoManager, queue: nil) { _ in
                MainActor.assumeIsolated {
                    if harness.undoManager.groupingLevel == 0 { closed.open() }
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            if step == 1 {
                let result = harness.controller.applyOpenDocumentEdits(
                    [workspaceEdit("completion.swift", from: "fu", to: "func")],
                    at: document.url.deletingLastPathComponent(),
                    expectedBuffers: [document.url: WorkspaceTextEditBufferSnapshot(document)],
                    selection: .init(before: NSRange(location: 2, length: 0), after: NSRange(location: 4, length: 0),
                        restore: { [observations = harness.observations, id = document.id] in observations.record($0, for: id) }))
                #expect(result.state == .applied)
            } else {
                let offset = step == 0 ? 1 : 4
                applyNativeEdit(to: document, range: NSRange(location: offset, length: 0),
                    replacement: step == 0 ? "u" : " ", beforeSelection: NSRange(location: offset, length: 0),
                    afterSelection: NSRange(location: offset + 1, length: 0), kind: .typing, harness: harness)
            }
            // Observe actual event-group closure rather than manually closing it.
            try #require(await closed.waitUntilOpen(timeout: .seconds(2)))
        }
        for (text, caret) in [("func", 4), ("fu", 2), ("f", 1)] {
            #expect(harness.controller.undo())
            #expect(document.text == text)
            #expect(harness.observations.selection(for: document) == NSRange(location: caret, length: 0))
            #expect(!document.hasMutationLease && !harness.controller.isApplying)
        }
        #expect(!harness.controller.canUndo)
        for (text, caret) in [("fu", 2), ("func", 4), ("func ", 5)] {
            #expect(harness.controller.redo())
            #expect(document.text == text)
            #expect(harness.observations.selection(for: document) == NSRange(location: caret, length: 0))
            #expect(!document.hasMutationLease && !harness.controller.isApplying)
        }
        #expect(harness.observations.failures.isEmpty)
        #expect(!harness.controller.canRedo)
    }

    @Test
    func defaultEventGroupingKeepsSeparateDocumentActionsInOrder() async throws {
        let documentA = document("A", named: "event-A.swift")
        let documentB = document("B", named: "event-B.swift")
        let harness = NativeUndoHarness(documents: [documentA, documentB])
        harness.undoManager.groupsByEvent = true
        defer { harness.controller.reset() }

        for document in [documentA, documentB] {
            let groupClosed = TestGate()
            let observer = NotificationCenter.default.addObserver(
                forName: .NSUndoManagerDidCloseUndoGroup,
                object: harness.undoManager,
                queue: nil
            ) { _ in
                MainActor.assumeIsolated {
                    if harness.undoManager.groupingLevel == 0 { groupClosed.open() }
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            applyNativeEdit(
                to: document, range: NSRange(location: 1, length: 0), replacement: "+",
                beforeSelection: NSRange(location: 1, length: 0),
                afterSelection: NSRange(location: 2, length: 0), kind: .atomic, harness: harness
            )
            // Real event-loop closure separates events, as in the application's
            // default UndoManager; no manual grouping or fixed delay substitutes it.
            try #require(await groupClosed.waitUntilOpen(timeout: .seconds(2)))
        }
        #expect(harness.controller.undo())
        #expect(documentA.text == "A+")
        #expect(documentB.text == "B")
        #expect(harness.controller.undo())
        #expect(documentA.text == "A")
        #expect(harness.controller.redo())
        #expect(documentA.text == "A+")
        #expect(documentB.text == "B")
        #expect(harness.controller.redo())
        #expect(documentB.text == "B+")
    }

    @Test
    func sharedHistoryTraversesDocumentsInOrderAndRecomputesDirtyState() {
        let documentA = document("A", named: "A.swift")
        let documentB = document("B", named: "B.swift")
        let harness = NativeUndoHarness(documents: [documentA, documentB])
        defer { harness.controller.reset() }

        applyNativeEdit(
            to: documentA,
            range: NSRange(location: 1, length: 0),
            replacement: "+",
            beforeSelection: NSRange(location: 1, length: 0),
            afterSelection: NSRange(location: 2, length: 0),
            kind: .atomic,
            harness: harness
        )
        documentA.markSavedWithoutWriting()
        applyNativeEdit(
            to: documentB,
            range: NSRange(location: 1, length: 0),
            replacement: "+",
            beforeSelection: NSRange(location: 1, length: 0),
            afterSelection: NSRange(location: 2, length: 0),
            kind: .atomic,
            harness: harness
        )
        documentB.markSavedWithoutWriting()

        #expect(harness.controller.undo())
        #expect(documentA.text == "A+")
        #expect(!documentA.isDirty)
        #expect(documentB.text == "B")
        #expect(documentB.isDirty)
        #expect(harness.observations.selection(for: documentB) == NSRange(location: 1, length: 0))

        #expect(harness.controller.undo())
        #expect(documentA.text == "A")
        #expect(documentA.isDirty)
        #expect(documentB.text == "B")
        #expect(harness.observations.selection(for: documentA) == NSRange(location: 1, length: 0))

        #expect(harness.controller.redo())
        #expect(documentA.text == "A+")
        #expect(!documentA.isDirty)
        #expect(documentB.text == "B")
        #expect(harness.observations.selection(for: documentA) == NSRange(location: 2, length: 0))

        #expect(harness.controller.redo())
        #expect(documentB.text == "B+")
        #expect(!documentB.isDirty)
        #expect(harness.observations.selection(for: documentB) == NSRange(location: 2, length: 0))
        #expect(!harness.controller.canRedo)
    }

    @Test
    func continuousTypingAndBackwardDeleteCoalesceWhileExplicitBreakSeparatesTyping() {
        let document = document("", named: "typing.swift")
        let harness = NativeUndoHarness(documents: [document])
        defer { harness.controller.reset() }

        applyNativeEdit(
            to: document,
            range: NSRange(location: 0, length: 0),
            replacement: "a",
            beforeSelection: NSRange(location: 0, length: 0),
            afterSelection: NSRange(location: 1, length: 0),
            kind: .typing,
            harness: harness
        )
        applyNativeEdit(
            to: document,
            range: NSRange(location: 1, length: 0),
            replacement: "b",
            beforeSelection: NSRange(location: 1, length: 0),
            afterSelection: NSRange(location: 2, length: 0),
            kind: .typing,
            harness: harness
        )
        harness.controller.breakNativeEditCoalescing(for: document)
        applyNativeEdit(
            to: document,
            range: NSRange(location: 2, length: 0),
            replacement: "c",
            beforeSelection: NSRange(location: 2, length: 0),
            afterSelection: NSRange(location: 3, length: 0),
            kind: .typing,
            harness: harness
        )
        applyNativeEdit(
            to: document,
            range: NSRange(location: 3, length: 0),
            replacement: "d",
            beforeSelection: NSRange(location: 3, length: 0),
            afterSelection: NSRange(location: 4, length: 0),
            kind: .typing,
            harness: harness
        )

        #expect(document.text == "abcd")
        #expect(harness.controller.undo())
        #expect(document.text == "ab")
        #expect(harness.observations.selection(for: document) == NSRange(location: 2, length: 0))
        #expect(harness.controller.undo())
        #expect(document.text.isEmpty)
        #expect(!document.isDirty)
        #expect(harness.controller.redo())
        #expect(document.text == "ab")
        #expect(harness.controller.redo())
        #expect(document.text == "abcd")

        applyNativeEdit(
            to: document,
            range: NSRange(location: 3, length: 1),
            replacement: "",
            beforeSelection: NSRange(location: 4, length: 0),
            afterSelection: NSRange(location: 3, length: 0),
            kind: .backwardDelete,
            harness: harness
        )
        applyNativeEdit(
            to: document,
            range: NSRange(location: 2, length: 1),
            replacement: "",
            beforeSelection: NSRange(location: 3, length: 0),
            afterSelection: NSRange(location: 2, length: 0),
            kind: .backwardDelete,
            harness: harness
        )
        #expect(document.text == "ab")
        #expect(harness.controller.undo())
        #expect(document.text == "abcd")
        #expect(harness.observations.selection(for: document) == NSRange(location: 4, length: 0))
        #expect(harness.controller.redo())
        #expect(document.text == "ab")
        #expect(harness.observations.selection(for: document) == NSRange(location: 2, length: 0))
    }

    @Test
    func nativeAndMixedWorkspaceEditsShareOneUndoRedoOrder() async {
        let root = URL(fileURLWithPath: "/workspace")
        let documentA = EditorDocument(
            url: root.appendingPathComponent("A.swift"),
            text: "A",
            modificationDate: nil
        )
        let openDocument = EditorDocument(
            url: root.appendingPathComponent("open.txt"),
            text: "open",
            modificationDate: nil
        )
        let documentB = EditorDocument(
            url: root.appendingPathComponent("B.swift"),
            text: "B",
            modificationDate: nil
        )
        let files = NativeUndoMemoryFiles(["closed.txt": "closed"])
        let harness = NativeUndoHarness(
            documents: [documentA, openDocument, documentB],
            operations: files
        )
        defer { harness.controller.reset() }

        applyNativeEdit(
            to: documentA,
            range: NSRange(location: 1, length: 0),
            replacement: "+",
            beforeSelection: NSRange(location: 1, length: 0),
            afterSelection: NSRange(location: 2, length: 0),
            kind: .atomic,
            harness: harness
        )
        let workspaceEdits = [
            workspaceEdit("open.txt", from: "open", to: "replaced open"),
            workspaceEdit("closed.txt", from: "closed", to: "replaced closed")
        ]
        #expect(await harness.controller.apply(workspaceEdits, at: root).state == .applied)
        applyNativeEdit(
            to: documentB,
            range: NSRange(location: 1, length: 0),
            replacement: "+",
            beforeSelection: NSRange(location: 1, length: 0),
            afterSelection: NSRange(location: 2, length: 0),
            kind: .atomic,
            harness: harness
        )

        #expect(harness.controller.undo())
        #expect(documentB.text == "B")
        #expect(openDocument.text == "replaced open")
        #expect(await files.text(for: "closed.txt") == "replaced closed")

        #expect(harness.controller.undo())
        #expect(await harness.controller.waitForCurrentOperation()?.state == .applied)
        #expect(openDocument.text == "open")
        #expect(!openDocument.isDirty)
        #expect(await files.text(for: "closed.txt") == "closed")
        #expect(documentA.text == "A+")

        #expect(harness.controller.undo())
        #expect(documentA.text == "A")
        #expect(!documentA.isDirty)

        #expect(harness.controller.redo())
        #expect(documentA.text == "A+")
        #expect(harness.controller.redo())
        #expect(await harness.controller.waitForCurrentOperation()?.state == .applied)
        #expect(openDocument.text == "replaced open")
        #expect(await files.text(for: "closed.txt") == "replaced closed")
        #expect(harness.controller.redo())
        #expect(documentB.text == "B+")
        #expect(!harness.controller.canRedo)
    }

    @Test
    func closingOneDocumentPreservesOtherDocumentAndWorkspaceHistory() async {
        let root = URL(fileURLWithPath: "/workspace")
        let documentA = EditorDocument(
            url: root.appendingPathComponent("A.swift"),
            text: "A",
            modificationDate: nil
        )
        let documentB = EditorDocument(
            url: root.appendingPathComponent("B.swift"),
            text: "B",
            modificationDate: nil
        )
        let files = NativeUndoMemoryFiles(["closed.txt": "closed"])
        let harness = NativeUndoHarness(documents: [documentA, documentB], operations: files)
        defer { harness.controller.reset() }

        applyNativeEdit(
            to: documentA,
            range: NSRange(location: 1, length: 0),
            replacement: "+",
            beforeSelection: NSRange(location: 1, length: 0),
            afterSelection: NSRange(location: 2, length: 0),
            kind: .atomic,
            harness: harness
        )
        let workspaceEdits = [workspaceEdit("closed.txt", from: "closed", to: "workspace")]
        #expect(await harness.controller.apply(workspaceEdits, at: root).state == .applied)
        applyNativeEdit(
            to: documentB,
            range: NSRange(location: 1, length: 0),
            replacement: "+",
            beforeSelection: NSRange(location: 1, length: 0),
            afterSelection: NSRange(location: 2, length: 0),
            kind: .atomic,
            harness: harness
        )

        harness.controller.handleDocumentClosed(documentA)
        #expect(harness.controller.undo())
        #expect(documentB.text == "B")
        #expect(documentA.text == "A+")
        #expect(harness.controller.undo())
        #expect(await harness.controller.waitForCurrentOperation()?.state == .applied)
        #expect(await files.text(for: "closed.txt") == "closed")
        #expect(!harness.controller.canUndo)

        #expect(harness.controller.redo())
        #expect(await harness.controller.waitForCurrentOperation()?.state == .applied)
        #expect(await files.text(for: "closed.txt") == "workspace")
        #expect(harness.controller.redo())
        #expect(documentB.text == "B+")
        #expect(documentA.text == "A+", "Closing A must remove its action from both traversal directions")
        #expect(!harness.controller.canRedo)
    }

    @Test
    func leaseDoesNotPopHistoryAndExternalRebaseOnlyInvalidatesItsDocument() throws {
        let documentA = document("A", named: "A.swift")
        let documentB = document("B", named: "B.swift")
        let harness = NativeUndoHarness(documents: [documentA, documentB])
        defer { harness.controller.reset() }

        applyNativeEdit(
            to: documentA,
            range: NSRange(location: 1, length: 0),
            replacement: "+",
            beforeSelection: NSRange(location: 1, length: 0),
            afterSelection: NSRange(location: 2, length: 0),
            kind: .atomic,
            harness: harness
        )
        applyNativeEdit(
            to: documentB,
            range: NSRange(location: 1, length: 0),
            replacement: "+",
            beforeSelection: NSRange(location: 1, length: 0),
            afterSelection: NSRange(location: 2, length: 0),
            kind: .atomic,
            harness: harness
        )

        let undoLease = try #require(documentB.acquireMutationLease())
        #expect(!harness.controller.undo())
        #expect(documentB.text == "B+")
        documentB.releaseMutationLease(undoLease)
        #expect(harness.controller.undo())
        #expect(documentB.text == "B")

        let redoLease = try #require(documentB.acquireMutationLease())
        #expect(!harness.controller.redo())
        #expect(documentB.text == "B")
        documentB.releaseMutationLease(redoLease)
        #expect(harness.controller.redo())
        #expect(documentB.text == "B+")

        documentB.replaceWithDiskContent("external")
        #expect(harness.controller.undo())
        #expect(documentB.text == "external")
        #expect(harness.observations.failures.count == 1)
        #expect(harness.controller.canUndo, "Rejecting B's stale action must retain A's older history")
        #expect(harness.controller.undo())
        #expect(documentA.text == "A")
        #expect(documentB.text == "external")
    }

    @Test
    func undoDuringSaveAcknowledgesCapturedBytesWithoutReplacingCurrentText() {
        let document = document("baseline", named: "saving.swift")
        let harness = NativeUndoHarness(documents: [document])
        defer { harness.controller.reset() }

        applyNativeEdit(
            to: document,
            range: NSRange(location: 8, length: 0),
            replacement: " edit",
            beforeSelection: NSRange(location: 8, length: 0),
            afterSelection: NSRange(location: 13, length: 0),
            kind: .atomic,
            harness: harness
        )
        let capturedText = document.text
        let capturedRevision = document.lifecycleState.revision
        document.applyLifecycleState(DocumentLifecycleState(
            status: .saving,
            revision: capturedRevision,
            savedRevision: document.lifecycleState.savedRevision,
            saveRevision: capturedRevision,
            operationId: "save"
        ))

        #expect(harness.controller.undo())
        #expect(document.text == "baseline")
        #expect(document.lifecycleState.status == .saving)

        document.markSavedWithoutWriting(
            state: DocumentLifecycleState(
                status: .dirty,
                revision: document.lifecycleState.revision,
                savedRevision: capturedRevision,
                saveRevision: nil,
                operationId: nil
            ),
            savedContent: capturedText
        )
        #expect(document.text == "baseline", "Save completion must not restore its earlier buffer snapshot")
        #expect(document.savedText == "baseline edit")
        #expect(document.isDirty)

        #expect(harness.controller.redo())
        #expect(document.text == "baseline edit")
        #expect(!document.isDirty)
    }

    private func document(_ text: String, named name: String) -> EditorDocument {
        EditorDocument(
            url: URL(fileURLWithPath: "/workspace").appendingPathComponent(name),
            text: text,
            modificationDate: nil
        )
    }

    private func workspaceEdit(_ path: String, from source: String, to replacement: String) -> WorkspaceTextEdit {
        WorkspaceTextEdit(
            path: path,
            sourceText: source,
            replacementText: replacement,
            sourceIdentity: ""
        )
    }

    private func applyNativeEdit(
        to document: EditorDocument,
        range: NSRange,
        replacement: String,
        beforeSelection: NSRange,
        afterSelection: NSRange,
        kind: WorkspaceTextEditUndoController.NativeTextEditKind,
        harness: NativeUndoHarness
    ) {
        let source = document.text as NSString
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              range.location <= source.length,
              range.length <= source.length - range.location else {
            Issue.record("Test edit has an invalid UTF-16 range: \(range)")
            return
        }
        let removedText = source.substring(with: range)
        let generation = document.nativeHistoryGeneration
        guard document.applyLiveEditorEdit(replacedRange: range, replacement: replacement) else {
            Issue.record("Document rejected the test edit")
            return
        }
        harness.controller.recordNativeEdit(
            WorkspaceTextEditUndoController.NativeTextEdit(
                replacedRange: range,
                removedText: removedText,
                insertedText: replacement,
                beforeSelection: beforeSelection,
                afterSelection: afterSelection,
                kind: kind,
                generation: generation,
                restoreSelection: { [observations = harness.observations, documentID = document.id] selection in
                    observations.record(selection, for: documentID)
                }
            ),
            in: document
        )
    }
}

@MainActor
private struct NativeUndoHarness {
    let undoManager: UndoManager
    let controller: WorkspaceTextEditUndoController
    let observations = NativeUndoObservations()

    init(
        documents: [EditorDocument],
        operations: any WorkspaceTextEditFileOperations = NativeUndoMemoryFiles([:])
    ) {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        self.undoManager = undoManager
        controller = WorkspaceTextEditUndoController(
            undoManager: undoManager,
            coordinator: WorkspaceTextEditCoordinator(),
            operations: operations
        )
        controller.configure(
            documents: { documents },
            willMutate: { _ in },
            didMutate: { _ in },
            notifyFailure: { [observations] message in observations.failures.append(message) }
        )
    }
}

@MainActor
private final class NativeUndoObservations {
    var failures: [String] = []
    private var selections: [UUID: NSRange] = [:]

    func record(_ selection: NSRange, for documentID: UUID) {
        selections[documentID] = selection
    }

    func selection(for document: EditorDocument) -> NSRange? {
        selections[document.id]
    }
}

private actor NativeUndoMemoryFiles: WorkspaceTextEditFileOperations {
    private struct Value {
        var text: String
        var generation: Int
    }

    private var values: [String: Value]

    init(_ contents: [String: String]) {
        values = contents.mapValues { Value(text: $0, generation: 0) }
    }

    func text(for path: String) -> String? {
        values[path]?.text
    }

    func capture(
        _ paths: [String],
        at workspaceURL: URL
    ) async throws -> [WorkspaceTextEditSnapshot] {
        try paths.map { path in
            guard let value = values[path] else { throw CocoaError(.fileNoSuchFile) }
            return WorkspaceTextEditSnapshot(
                path: path,
                text: value.text,
                identity: String(value.generation)
            )
        }
    }

    func replace(
        _ edit: WorkspaceTextEdit,
        expected snapshot: WorkspaceTextEditSnapshot,
        at workspaceURL: URL
    ) async throws -> WorkspaceTextEditSnapshot {
        guard let value = values[edit.path],
              value.text.utf8.elementsEqual(snapshot.text.utf8),
              String(value.generation) == snapshot.identity else {
            throw CocoaError(.fileWriteUnknown)
        }
        let next = Value(text: edit.replacementText, generation: value.generation + 1)
        values[edit.path] = next
        return WorkspaceTextEditSnapshot(
            path: edit.path,
            text: next.text,
            identity: String(next.generation)
        )
    }

    func restore(
        _ snapshot: WorkspaceTextEditSnapshot,
        expected writtenSnapshot: WorkspaceTextEditSnapshot,
        at workspaceURL: URL
    ) async throws {
        guard let value = values[snapshot.path],
              value.text.utf8.elementsEqual(writtenSnapshot.text.utf8),
              String(value.generation) == writtenSnapshot.identity else {
            throw CocoaError(.fileWriteUnknown)
        }
        values[snapshot.path] = Value(text: snapshot.text, generation: value.generation + 1)
    }
}
