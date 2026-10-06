import Foundation
import Testing
@testable import Lithe

@MainActor
struct EditorDocumentPersistenceBoundaryTests {
    @Test func acceptedSnapshotAcknowledgmentRequiresExactBytesAndPreservesDocumentIdentity() {
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/main.go"), text: "é", modificationDate: nil)
        #expect(document.applyLiveEditorEdit(replacedRange: NSRange(location: 0, length: 1), replacement: "e\u{301}"))
        document.acknowledgeLanguageServerSnapshot("é")
        #expect(document.takePendingLanguageServerChanges().count == 1)
        #expect(document.applyLiveEditorEdit(replacedRange: NSRange(location: 2, length: 0), replacement: "!"))
        let revision = document.lifecycleState.revision
        let generation = document.nativeHistoryGeneration
        document.acknowledgeLanguageServerSnapshot(document.text)
        #expect(document.takePendingLanguageServerChanges().isEmpty)
        #expect(document.lifecycleState.revision == revision)
        #expect(document.nativeHistoryGeneration == generation)
        #expect(document.isDirty)
    }

    @Test(arguments: ["\n", "\r", "\r\n"])
    func nativeIncrementalLSPChangesCountLineTerminators(separator: String) throws {
        let text = "first" + separator + "a😀b"
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/main.rs"), text: text, modificationDate: nil)
        let offset = ("first" + separator + "a").utf16.count
        #expect(document.applyLiveEditorEdit(replacedRange: NSRange(location: offset, length: 2), replacement: "😎"))
        let change = try #require(document.takePendingLanguageServerChanges().first)
        #expect(change.start == LanguageServerDocumentPosition(line: 1, utf16Column: 1))
        #expect(change.end == LanguageServerDocumentPosition(line: 1, utf16Column: 3))
        #expect(change.text == "😎")
    }

    @Test func filesystemPermissionsCannotUnlockAProductReadOnlyDocument() {
        let url = URL(fileURLWithPath: "/fixture/main.py")
        let file = EditorDocument(url: url, text: "text", modificationDate: nil, isFileWritable: false)
        #expect(file.isReadOnly)
        file.updateFileSystemWritable(true)
        #expect(!file.isReadOnly)
        let preview = EditorDocument(url: url, text: "text", modificationDate: nil, isReadOnly: true)
        preview.updateFileSystemWritable(true)
        #expect(preview.isReadOnly)
    }

    @Test func relocationBackToTheSamePathStillInvalidatesAnEarlierRead() {
        let original = URL(fileURLWithPath: "/fixture/main.py")
        let document = EditorDocument(url: original, text: "text", modificationDate: nil)
        let initial = document.locationRevision
        document.relocate(to: URL(fileURLWithPath: "/fixture/renamed.py"))
        document.relocate(to: original)
        #expect(document.url == original)
        #expect(document.locationRevision == initial + 2)
    }
}
