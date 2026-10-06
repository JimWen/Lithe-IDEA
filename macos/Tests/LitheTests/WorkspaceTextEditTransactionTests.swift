import Combine
import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
struct WorkspaceTextEditTransactionTests {
    @Test
    func mixedDirtyBufferAndDiskTransactionSupportsRepeatedUndoRedoAndRejectsConflicts() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let document = EditorDocument(url: root.appendingPathComponent("open.txt"), text: "saved", modificationDate: nil)
        document.text = "dirty"
        let files = TransactionMemoryFiles(["open.txt": "saved", "closed.txt": "old"])
        let undo = UndoManager()
        undo.groupsByEvent = false
        let controller = WorkspaceTextEditUndoController(undoManager: undo,
            coordinator: WorkspaceTextEditCoordinator(), operations: files)
        defer { controller.reset() }
        var failures: [String] = []
        var publications = 0
        let observation = document.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        controller.configure(documents: { [document] }, willMutate: { _ in }, didMutate: { _ in },
                             notifyFailure: { failures.append($0) })
        let edits = [edit("open.txt", "dirty", "new"), edit("closed.txt", "old", "new")]
        #expect(await controller.apply(edits, at: root).state == .applied)
        #expect(document.text == "new")
        #expect(document.isDirty)
        #expect(await files.text("open.txt") == "saved")
        #expect(await files.text("closed.txt") == "new")
        for _ in 0..<3 {
            #expect(controller.canUndo)
            undo.undo()
            #expect(await controller.waitForCurrentOperation()?.state == .applied)
            #expect(document.text == "dirty")
            #expect(await files.text("closed.txt") == "old")
            #expect(controller.canRedo)
            undo.redo()
            #expect(await controller.waitForCurrentOperation()?.state == .applied)
            #expect(document.text == "new")
            #expect(await files.text("closed.txt") == "new")
        }
        #expect(publications >= 7, "Programmatic edits must notify an already-dirty native editor")
        #expect(!document.hasMutationLease)
        await files.set("external", for: "closed.txt")
        undo.undo()
        #expect(await controller.waitForCurrentOperation()?.state == .failed)
        #expect(document.text == "new", "Failed disk validation must not modify any open buffer")
        #expect(await files.text("closed.txt") == "external")
        #expect(!controller.canRedo && !controller.canUndo)
        #expect(failures.count == 1)
    }

    @Test
    func cancellationReleasesOpenBufferLeaseWithoutCommittingEitherSurface() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let document = EditorDocument(url: root.appendingPathComponent("open.txt"), text: "old", modificationDate: nil)
        let files = TransactionMemoryFiles(["closed.txt": "old"], gatesCapture: true)
        let controller = WorkspaceTextEditUndoController(undoManager: UndoManager(),
            coordinator: WorkspaceTextEditCoordinator(), operations: files)
        controller.configure(documents: { [document] }, willMutate: { _ in }, didMutate: { _ in }, notifyFailure: { _ in })
        let task = Task { await controller.apply([edit("open.txt", "old", "new"), edit("closed.txt", "old", "new")], at: root) }
        defer { task.cancel(); controller.reset(); files.release.open() }
        #expect(await files.entered.waitUntilOpen(timeout: .seconds(2)))
        #expect(document.hasMutationLease)
        #expect(!document.applyLiveEditorEdit(replacedRange: NSRange(location: 0, length: 0), replacement: "typing"))
        document.text = "unowned programmatic edit"
        #expect(document.text == "old")
        controller.reset()
        files.release.open()
        #expect(await task.value.state == .cancelled)
        #expect(document.text == "old" && !document.hasMutationLease)
        #expect(await files.text("closed.txt") == "old")
        #expect(!controller.canUndo)
    }

    @Test
    func reentrantCoordinatorRejectsOverlappingBatches() async {
        let root = URL(fileURLWithPath: "/workspace")
        let files = TransactionMemoryFiles(["file.txt": "old"], gatesCapture: true)
        let coordinator = WorkspaceTextEditCoordinator()
        let edits = [edit("file.txt", "old", "new")]
        let first = Task { await coordinator.apply(edits, at: root, operations: files) }
        defer { first.cancel(); files.release.open() }
        #expect(await files.entered.waitUntilOpen(timeout: .seconds(2)))
        #expect(await coordinator.apply(edits, at: root, operations: files).state == .failed)
        files.release.open()
        #expect(await first.value.state == .applied)
    }

    @Test
    func finalHostCommitFailureCompensatesDiskAfterTheLastWrite() async {
        let files = TransactionMemoryFiles(["file.txt": "old"])
        let result = await WorkspaceTextEditCoordinator().apply(
            [edit("file.txt", "old", "new")], at: URL(fileURLWithPath: "/workspace"), operations: files,
            commit: { throw CancellationError() })
        #expect(result.state == .cancelled)
        #expect(result.recoveryPaths.isEmpty)
        #expect(await files.text("file.txt") == "old")
    }

    @Test(arguments: ["unchanged", "bytes", "identity"])
    func finalUnchangedTargetValidationCompensatesOnlyActualWrites(change: String) async {
        let root = URL(fileURLWithPath: "/workspace")
        let files = TransactionMemoryFiles(["changed.txt": "old", "noop.txt": "old"], gatesWrite: true)
        let task = Task { await WorkspaceTextEditCoordinator().apply(
            [edit("changed.txt", "old", "new"), edit("noop.txt", "old", "old")], at: root, operations: files) }
        defer { task.cancel(); files.release.open() }
        #expect(await files.entered.waitUntilOpen(timeout: .seconds(2)))
        if change != "unchanged" { await files.set("external", for: "noop.txt") }
        if change == "identity" { await files.set("old", for: "noop.txt") }
        files.release.open()
        let result = await task.value
        #expect(result.state == (change == "unchanged" ? .applied : .failed))
        #expect(await files.text("changed.txt") == (change == "unchanged" ? "new" : "old"))
        #expect(await files.text("noop.txt") == (change == "bytes" ? "external" : "old"))
        #expect(result.changedPaths == (change == "unchanged" ? ["changed.txt"] : []))
        #expect(result.recoveryPaths.isEmpty)
    }

    @Test
    func changedContextDuringDiskCaptureDoesNotCommitBuffersOrRegisterUndo() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let document = EditorDocument(url: root.appendingPathComponent("open.txt"), text: "old", modificationDate: nil)
        let files = TransactionMemoryFiles(["closed.txt": "old"], gatesCapture: true)
        let controller = WorkspaceTextEditUndoController(undoManager: UndoManager(), coordinator: WorkspaceTextEditCoordinator(), operations: files)
        controller.configure(documents: { [document] }, willMutate: { _ in }, didMutate: { _ in }, notifyFailure: { _ in })
        var current = true
        let task = Task { await controller.apply([edit("open.txt", "old", "new"), edit("closed.txt", "old", "new")], at: root,
            expectedBuffers: [document.url: WorkspaceTextEditBufferSnapshot(document)], validate: { current }) }
        defer { task.cancel(); controller.reset(); files.release.open() }
        #expect(await files.entered.waitUntilOpen(timeout: .seconds(2)))
        current = false
        files.release.open()
        #expect(await task.value.state == .cancelled)
        #expect(document.text == "old")
        #expect(!document.hasMutationLease)
        #expect(!controller.canUndo)
        #expect(await files.text("closed.txt") == "old")
    }

    @Test(arguments: [false, true])
    func completionHistoryCannotChangeAReopenedOrReloadedDocument(reopen: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let url = root.appendingPathComponent("open.txt")
        var document = EditorDocument(url: url, text: "old", modificationDate: nil)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let controller = WorkspaceTextEditUndoController(undoManager: undo, coordinator: WorkspaceTextEditCoordinator(),
            operations: TransactionMemoryFiles([:]))
        var failures: [String] = []
        controller.configure(documents: { [document] }, willMutate: { _ in }, didMutate: { _ in }, notifyFailure: { failures.append($0) })
        defer { controller.reset() }
        #expect(controller.applyOpenDocumentEdits([edit("open.txt", "old", "new")], at: root,
            expectedBuffers: [url: WorkspaceTextEditBufferSnapshot(document)]).state == .applied)
        if reopen {
            controller.handleDocumentClosed(document)
            document = EditorDocument(url: url, text: "new", modificationDate: nil)
        } else {
            document.replaceWithDiskContent("new")
        }
        _ = controller.undo()
        _ = await controller.waitForCurrentOperation()
        #expect(document.text == "new")
        #expect(!controller.canRedo)
        #expect(failures.count == 1)
    }

    @Test(arguments: [false, true])
    func nativeRollbackUsesWrittenIdentityAndPreservesExternalWriter(externalChange: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-transaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "old".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "old".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let result = await WorkspaceTextEditCoordinator().apply(
            [edit("a.txt", "old", "new"), edit("b.txt", "old", "new")], at: root,
            operations: FailingSecondNativeWrite(externalChange: externalChange))
        #expect(result.state == (externalChange ? .recoveryRequired : .failed))
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == (externalChange ? "external" : "old"))
        #expect(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8) == "old")
        #expect(result.recoveryPaths == (externalChange ? ["a.txt"] : []))
    }

    private func edit(_ path: String, _ before: String, _ after: String) -> WorkspaceTextEdit {
        WorkspaceTextEdit(path: path, sourceText: before, replacementText: after, sourceIdentity: "")
    }
}

private actor TransactionMemoryFiles: WorkspaceTextEditFileOperations {
    nonisolated let entered = TestGate()
    nonisolated let release = TestGate()
    private var values: [String: String]
    private var generations: [String: Int] = [:]
    private let gatesCapture: Bool
    private let gatesWrite: Bool
    init(_ values: [String: String], gatesCapture: Bool = false, gatesWrite: Bool = false) {
        self.values = values
        self.gatesCapture = gatesCapture
        self.gatesWrite = gatesWrite
    }
    func text(_ path: String) -> String? { values[path] }
    func set(_ text: String, for path: String) { values[path] = text; generations[path, default: 0] += 1 }
    func capture(_ paths: [String], at workspaceURL: URL) async throws -> [WorkspaceTextEditSnapshot] {
        if gatesCapture {
            entered.open()
            guard await release.waitUntilOpen(timeout: .seconds(2)) else { throw CancellationError() }
        }
        return try paths.map { path in
            guard let text = values[path] else { throw CocoaError(.fileNoSuchFile) }
            return WorkspaceTextEditSnapshot(path: path, text: text, identity: String(generations[path, default: 0]))
        }
    }
    func replace(_ edit: WorkspaceTextEdit, expected snapshot: WorkspaceTextEditSnapshot,
                 at workspaceURL: URL) async throws -> WorkspaceTextEditSnapshot {
        guard values[edit.path] == snapshot.text else { throw CocoaError(.fileWriteUnknown) }
        set(edit.replacementText, for: edit.path)
        let written = WorkspaceTextEditSnapshot(path: edit.path, text: edit.replacementText, identity: String(generations[edit.path, default: 0]))
        if gatesWrite {
            entered.open()
            let released = await release.waitUntilOpen(timeout: .seconds(2))
            if !released, !Task.isCancelled { Issue.record("Write gate did not release before its deadline") }
        }
        return written
    }
    func restore(_ snapshot: WorkspaceTextEditSnapshot, expected writtenSnapshot: WorkspaceTextEditSnapshot,
                 at workspaceURL: URL) throws {
        guard values[snapshot.path] == writtenSnapshot.text else { throw CocoaError(.fileWriteUnknown) }
        set(snapshot.text, for: snapshot.path)
    }
}

private struct FailingSecondNativeWrite: WorkspaceTextEditFileOperations {
    let externalChange: Bool
    let native = MacWorkspaceTextEditFileOperations()
    func capture(_ paths: [String], at workspaceURL: URL) async throws -> [WorkspaceTextEditSnapshot] {
        try await native.capture(paths, at: workspaceURL)
    }
    func replace(_ edit: WorkspaceTextEdit, expected snapshot: WorkspaceTextEditSnapshot,
                 at workspaceURL: URL) async throws -> WorkspaceTextEditSnapshot {
        if edit.path == "b.txt" {
            if externalChange {
                try "external".write(to: workspaceURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            }
            throw CocoaError(.fileWriteUnknown)
        }
        return try await native.replace(edit, expected: snapshot, at: workspaceURL)
    }
    func restore(_ snapshot: WorkspaceTextEditSnapshot, expected writtenSnapshot: WorkspaceTextEditSnapshot,
                 at workspaceURL: URL) async throws {
        try await native.restore(snapshot, expected: writtenSnapshot, at: workspaceURL)
    }
}
