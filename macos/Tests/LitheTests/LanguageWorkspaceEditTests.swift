import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Language workspace edits")
struct LanguageWorkspaceEditTests {
    @Test
    func bridgeDecodesEveryOrderedWorkspaceEditFixture() throws {
        for example in try WorkspaceEditFixture.validCases() {
            let data = try JSONSerialization.data(withJSONObject: example.normalized)
            do {
                let model = try JSONDecoder().decode(RustCoreBridge.LspWorkspaceEditPayload.self, from: data)
                let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? NSDictionary
                #expect(roundTrip == example.normalized as NSDictionary, "\(example.name) must retain every normalized field")
            } catch {
                Issue.record("\(example.name) failed normalized bridge decoding: \(error)")
            }
        }
    }

    @Test
    func resolveEncodingUsesOriginalFileURIsOrderedOperationsAndLSPPositions() throws {
        let example = try #require(WorkspaceEditFixture.validCases().first)
        let model = try JSONDecoder().decode(LanguageServerWorkspaceEdit.self,
                                            from: JSONSerialization.data(withJSONObject: example.normalized))
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            LanguageServerWorkspaceEditWire(model))) as? [String: Any])
        let original = try #require(example.wire)
        #expect(wire["changes"] == nil)
        #expect(wire["documentChanges"] as? NSArray == original["documentChanges"] as? NSArray)
        #expect(wire["changeAnnotations"] as? NSDictionary == original["changeAnnotations"] as? NSDictionary)
    }

    @Test(arguments: [false, true])
    @MainActor
    func completionCommitsSynchronouslyAndRegistersOneSharedUndoAction(duringSave: Bool) async throws {
        try await withLanguageEditProject(source: "tail foo") { model, document in
            let controller = model.services.workspaceTextEditUndoController
            controller.sharedUndoManager.groupsByEvent = false
            let item = LanguageServerCompletionItem(
                label: "food", detail: nil, documentation: nil, insertText: "food",
                sortText: nil, filterText: nil, kind: nil, textEdit: nil,
                additionalTextEdits: [LanguageServerTextEdit(
                    range: .init(start: .init(line: 0, utf16Column: 0), end: .init(line: 0, utf16Column: 0)),
                    newText: "prefix ")], data: nil
            )
            var restored: [NSRange] = []
            model.applyLanguageCompletion(item, fallbackRange: .init(
                start: .init(line: 0, utf16Column: 5), end: .init(line: 0, utf16Column: 8)),
                beforeSelection: NSRange(location: 8, length: 0), restoreSelection: { restored.append($0) })
            #expect(document.text == "prefix tail food", "Completion must commit before returning to NSTextView")
            #expect(restored.last == NSRange(location: 16, length: 0))
            #expect(document.isDirty)
            let lease = try #require(document.acquireMutationLease())
            #expect(!controller.undo(), "A held lease must reject Undo before consuming its history")
            document.releaseMutationLease(lease)
            let capturedText = document.text
            let capturedRevision = document.lifecycleState.revision
            if duringSave {
                document.applyLifecycleState(.init(status: .saving, revision: capturedRevision,
                    savedRevision: document.lifecycleState.savedRevision, saveRevision: capturedRevision, operationId: "save"))
            }
            #expect(controller.undo(), "Completion must join the same Undo owner as native typing")
            #expect(document.text == "tail foo", "Buffer-only Undo must finish before another native key event")
            #expect(restored.last == NSRange(location: 8, length: 0))
            #expect(!document.hasMutationLease && !controller.isApplying)
            _ = await controller.waitForCurrentOperation()
            #expect(document.text == "tail foo")
            #expect(restored.last == NSRange(location: 8, length: 0))
            #expect(!controller.canUndo)
            if duringSave {
                #expect(document.lifecycleState.status == .saving)
                document.markSavedWithoutWriting(state: .init(status: .dirty, revision: document.lifecycleState.revision,
                    savedRevision: capturedRevision, saveRevision: nil, operationId: nil), savedContent: capturedText)
                #expect(document.text == "tail foo")
                #expect(document.savedText == capturedText)
            }
            #expect(controller.redo())
            #expect(document.text == "prefix tail food", "Buffer-only Redo must also finish synchronously")
            #expect(restored.last == NSRange(location: 16, length: 0))
            #expect(!document.hasMutationLease && !controller.isApplying)
            _ = await controller.waitForCurrentOperation()
            #expect(document.text == "prefix tail food")
            #expect(restored.last == NSRange(location: 16, length: 0))
            let diskText = try String(contentsOf: document.url, encoding: .utf8)
            #expect(diskText == "tail foo")
        }
    }

    @Test
    @MainActor
    func actionWithoutItsProducingSessionCannotApplyVersionedEdits() async throws {
        try await withLanguageEditProject(source: "old") { model, document in
            let edit = LanguageServerTextEdit(
                range: .init(start: .init(line: 0, utf16Column: 0), end: .init(line: 0, utf16Column: 3)), newText: "wrong")
            model.applyLanguageCodeAction(.init(
                title: "Unbound stale action", kind: "quickfix", isPreferred: false,
                edit: .init(operations: [.edit(.init(uri: document.url.absoluteString, version: 999, edits: [edit]))]),
                command: nil, data: nil))
            #expect(document.text == "old", "An action must retain its original request/session context")
            #expect(!document.isDirty)
            #expect(!model.services.workspaceTextEditUndoController.canUndo)
        }
    }

    @Test
    func plannerAppliesRepeatedURIsSequentiallyWithoutInventingVersions() throws {
        let root = URL(fileURLWithPath: "/workspace")
        let url = root.appendingPathComponent("naïve space.go")
        func makeEdit(_ end: Int, _ text: String) -> LanguageServerTextEdit {
            .init(range: .init(start: .init(line: 0, utf16Column: 0), end: .init(line: 0, utf16Column: end)), newText: text)
        }
        let sources: [URL: LanguageWorkspaceEditPlanner.Source] = [url: .init(
            path: "naïve space.go", text: "old", diskIdentity: "", isOpen: true,
            synchronized: .init(sessionIdentity: "original", version: 7, sourceText: "old"))]
        let edit = LanguageServerWorkspaceEdit(operations: [
            .edit(.init(uri: url.absoluteString, version: 7, edits: [makeEdit(3, "first")])),
            .edit(.init(uri: url.absoluteString, version: 7, edits: [makeEdit(5, "final")]))])
        let plan = try LanguageWorkspaceEditPlanner.plan(edit, rootURL: root, sources: sources, sessionIdentity: "original")
        #expect(plan.count == 1)
        #expect(plan.first?.sourceText == "old")
        #expect(plan.first?.replacementText == "final")
        #expect(plan.first?.path == "naïve space.go")
    }

    @Test(arguments: ["version", "session", "accepted-bytes", "unsynced-zero", "closed-positive"])
    func plannerRejectsStaleVersionAndSource(scenario: String) {
        let root = URL(fileURLWithPath: "/workspace")
        let url = root.appendingPathComponent("main.go")
        let synchronized: LanguageServerSynchronizedDocumentSnapshot? = scenario == "unsynced-zero" || scenario == "closed-positive" ? nil :
            .init(sessionIdentity: scenario == "session" ? "old-session" : "current", version: 7,
                  sourceText: scenario == "accepted-bytes" ? "other" : "old")
        let source = LanguageWorkspaceEditPlanner.Source(path: "main.go", text: "old", diskIdentity: "disk-identity",
            isOpen: scenario != "closed-positive", synchronized: synchronized)
        let edit = LanguageServerWorkspaceEdit(operations: [.edit(.init(uri: url.absoluteString,
            version: scenario == "unsynced-zero" ? 0 : scenario == "version" ? 8 : 7, edits: []))])
        #expect(throws: LanguageWorkspaceEditPlanner.Failure.self) {
            try LanguageWorkspaceEditPlanner.plan(edit, rootURL: root, sources: [url: source], sessionIdentity: "current")
        }
    }

    @Test
    func plannerRetainsGuardedUnopenedZeroVersionAndRejectsLateUnsupportedOperations() throws {
        let root = URL(fileURLWithPath: "/workspace")
        let url = root.appendingPathComponent("closed.go")
        let text = LanguageServerTextEdit(range: .init(start: .init(line: 0, utf16Column: 0), end: .init(line: 0, utf16Column: 3)), newText: "new")
        let operation = LanguageServerWorkspaceOperation.edit(.init(uri: url.absoluteString, version: 0, edits: [text]))
        let sources: [URL: LanguageWorkspaceEditPlanner.Source] = [url: .init(path: "closed.go", text: "old",
            diskIdentity: "inode-generation", isOpen: false, synchronized: nil)]
        let plan = try LanguageWorkspaceEditPlanner.plan(.init(operations: [operation]), rootURL: root, sources: sources, sessionIdentity: "session")
        #expect(plan.first?.sourceIdentity == "inode-generation")
        #expect(plan.first?.replacementText == "new")
        #expect(throws: LanguageWorkspaceEditPlanner.Failure.self) {
            try LanguageWorkspaceEditPlanner.plan(.init(operations: [operation, .deleteFile(.init(uri: url.absoluteString))]),
                rootURL: root, sources: sources, sessionIdentity: "session")
        }
        #expect(throws: LanguageWorkspaceEditPlanner.Failure.self) {
            try LanguageWorkspaceEditPlanner.plan(.init(operations: [operation], changeAnnotations: ["confirm": .init(label: "Confirm", needsConfirmation: true)]),
                rootURL: root, sources: sources, sessionIdentity: "session")
        }
    }

    @Test
    func textEditsRejectSplitSurrogatesAndKeepEqualPositionInsertOrder() throws {
        func insertion(_ column: Int, _ text: String) -> LanguageServerTextEdit {
            let position = LanguageServerPosition(line: 0, utf16Column: column)
            return .init(range: .init(start: position, end: position), newText: text)
        }
        #expect(throws: LanguageServerTextEditApplicator.Error.self) {
            try LanguageServerTextEditApplicator.apply([insertion(1, "split")], to: "😀")
        }
        #expect(throws: LanguageServerTextEditApplicator.Error.self) {
            try LanguageServerTextEditApplicator.apply([insertion(3, "past end")], to: "😀")
        }
        let result = try LanguageServerTextEditApplicator.apply([insertion(0, "first"), insertion(0, "second")], to: "😀")
        #expect(result == "firstsecond😀")
    }

    @Test(arguments: ["edited-back", "reopened", "relocated-back", "unicode-bytes"])
    @MainActor
    func bufferSnapshotRejectsReusedTextWithDifferentIdentity(scenario: String) {
        let url = URL(fileURLWithPath: "/workspace/main.go")
        var document = EditorDocument(url: url, text: "é", modificationDate: nil)
        let snapshot = WorkspaceTextEditBufferSnapshot(document)
        #expect(snapshot.matches(document))
        switch scenario {
        case "edited-back": document.text = "other"; document.text = "é"
        case "reopened": document = EditorDocument(url: url, text: "é", modificationDate: nil)
        case "relocated-back": document.relocate(to: url.appendingPathExtension("moved")); document.relocate(to: url)
        default: document.text = "e\u{301}"
        }
        #expect(!snapshot.matches(document))
    }
}

@MainActor
private func withLanguageEditProject(
    source: String,
    body: @MainActor (AppModel, EditorDocument) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-language-edit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("main.go")
    try source.write(to: url, atomically: true, encoding: .utf8)
    let store = LanguageEditTestStore()
    let settings = AppSettings(store: store)
    settings.autoSave = false
    let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode,
                                       workspaceOperations: LanguageEditFixtureWorkspaceOperations()).services
    let model = AppModel(settings: settings, services: services)
    func cleanup() async {
        model.workspaceFeature.reset()
        model.documentFeature.reset()
        await model.shutdownProjectSession()
    }
    do {
        model.openProjectDirectly(root)
        await model.documentFeature.openFileAsync(url, isReadOnly: false, displayPath: nil, activateWhenReady: true)
        try await body(model, #require(model.activeDocument))
        await cleanup()
    } catch {
        await cleanup()
        throw error
    }
}

/// Host edit tests must also exercise the Swift-only lane. Fixture loading uses
/// the native filesystem; Rust file decoding is covered by the Core bridge lane.
struct LanguageEditFixtureWorkspaceOperations: WorkspaceOperations {
    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? {
        FileSystemWorkspaceSnapshotBuilder().snapshot(at: rootURL, visibilityRules: visibilityRules)
    }

    func readFile(at rootURL: URL, relativePath: String) -> String? {
        try? String(contentsOf: rootURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private final class LanguageEditTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

extension LanguageServerWorkspaceOperation {
    var textEditsForTest: [LanguageServerTextEdit] {
        if case .edit(let edit) = self { return edit.edits }
        return []
    }
}

enum WorkspaceEditFixture {
    struct Example {
        let name: String
        let normalized: [String: Any]
        let wire: [String: Any]?
    }

    static func validCases() throws -> [Example] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/lsp/workspace-edit-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(fixture["valid"] as? [[String: Any]]).map { example in
            Example(name: try #require(example["name"] as? String),
                    normalized: try #require(example["normalized"] as? [String: Any]),
                    wire: example["wire"] as? [String: Any])
        }
    }
}
