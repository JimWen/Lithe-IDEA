import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Workspace text edit transaction")
struct WorkspaceTextEditCoordinatorTests {
    actor FakeFileOperations: WorkspaceTextEditFileOperations {
        var texts: [String: String]
        var identities: [String: String]
        var failingPath: String?
        private(set) var writes: [String] = []

        init(texts: [String: String], failingPath: String? = nil) {
            self.texts = texts
            self.identities = texts.mapValues { _ in UUID().uuidString }
            self.failingPath = failingPath
        }

        func capture(_ paths: [String], at workspaceURL: URL) async throws -> [WorkspaceTextEditSnapshot] {
            paths.map { WorkspaceTextEditSnapshot(path: $0, text: texts[$0] ?? "", identity: identities[$0] ?? "missing") }
        }

        func replace(_ edit: WorkspaceTextEdit, expected snapshot: WorkspaceTextEditSnapshot, at workspaceURL: URL) async throws {
            if edit.path == failingPath { throw NSError(domain: "test", code: 1) }
            guard texts[edit.path]?.utf8.elementsEqual(edit.sourceText.utf8) == true else {
                throw NSError(domain: "test", code: 2)
            }
            texts[edit.path] = edit.replacementText
            writes.append(edit.path)
        }

        func restore(_ snapshot: WorkspaceTextEditSnapshot, at workspaceURL: URL) async throws {
            texts[snapshot.path] = snapshot.text
            writes.append("restore:\(snapshot.path)")
        }

        func currentTexts() -> [String: String] { texts }
        func recordedWrites() -> [String] { writes }
    }

    @Test
    func staleSourceRejectsTheWholeBatchBeforeWriting() async {
        let files = FakeFileOperations(texts: ["a.txt": "changed", "b.txt": "old"])
        let coordinator = WorkspaceTextEditCoordinator()
        let result = await coordinator.apply([
            WorkspaceTextEdit(path: "a.txt", sourceText: "old", replacementText: "new", sourceIdentity: "stale"),
            WorkspaceTextEdit(path: "b.txt", sourceText: "old", replacementText: "new", sourceIdentity: "missing")
        ], at: URL(fileURLWithPath: "/workspace"), operations: files)

        #expect(result.state == .failed)
        #expect(result.changedPaths.isEmpty)
        #expect(await files.recordedWrites().isEmpty)
    }

    @Test
    func failedCommitCompensatesEarlierFiles() async {
        let files = FakeFileOperations(texts: ["a.txt": "old", "b.txt": "old"], failingPath: "b.txt")
        let identities = await files.identities
        let coordinator = WorkspaceTextEditCoordinator()
        let result = await coordinator.apply([
            WorkspaceTextEdit(path: "a.txt", sourceText: "old", replacementText: "new", sourceIdentity: identities["a.txt"]!),
            WorkspaceTextEdit(path: "b.txt", sourceText: "old", replacementText: "new", sourceIdentity: identities["b.txt"]!)
        ], at: URL(fileURLWithPath: "/workspace"), operations: files)

        #expect(result.state == .failed)
        #expect(await files.currentTexts() == ["a.txt": "old", "b.txt": "old"])
        #expect(await files.recordedWrites() == ["a.txt", "restore:a.txt"])
    }

    @Test
    func duplicateOrEscapingPathsAreRejectedBeforeCapture() async {
        let files = FakeFileOperations(texts: ["a.txt": "old"])
        let coordinator = WorkspaceTextEditCoordinator()
        let result = await coordinator.apply([
            WorkspaceTextEdit(path: "../a.txt", sourceText: "old", replacementText: "new", sourceIdentity: "x"),
            WorkspaceTextEdit(path: "../a.txt", sourceText: "old", replacementText: "new", sourceIdentity: "x")
        ], at: URL(fileURLWithPath: "/workspace"), operations: files)

        #expect(result.state == .failed)
        #expect(await files.recordedWrites().isEmpty)
    }
}
