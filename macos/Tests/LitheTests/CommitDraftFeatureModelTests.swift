import Foundation
import Testing
@testable import Lithe

@Suite("Git undo commit draft")
@MainActor
struct GitUndoCommitDraftTests {
    @Test(arguments: ["", " \n "])
    func undoRestoresTheFullMessageOnlyIntoAnEmptyDraft(_ initial: String) async {
        let store = GitUndoDraftTestStore()
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode
        ).services)
        model.commitMessage = initial
        model.amendCommit = true
        model.prepareForUndoneGitCommit(message: "Title\n\nOriginal description\n")
        #expect(model.commitMessage == "Title\n\nOriginal description\n")
        #expect(!model.amendCommit)
        #expect(model.commitEditorRequestVersion == 1)
        model.commitMessage = "An existing draft"
        model.amendCommit = true
        model.prepareForUndoneGitCommit(message: "Another undone message")
        #expect(model.commitMessage == "An existing draft")
        #expect(!model.amendCommit)
        #expect(model.commitEditorRequestVersion == 2)
        await model.shutdownProjectSession()
    }
}

private final class GitUndoDraftTestStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func object(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}
