import Foundation
import Testing
@testable import Lithe

@MainActor
struct EditorDocumentPersistenceBoundaryTests {
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
