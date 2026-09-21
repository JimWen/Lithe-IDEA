import AppKit
import Testing
@testable import Lithe

@MainActor
@Suite("Generic editor viewport refresh")
struct EditorViewportRefreshTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    @Test(arguments: ["go", "rs", "py", "swift", "json", "md"])
    func programmaticReplacementRepaintsPreviouslyCachedText(fileExtension: String) throws {
        try withCoordinator(source: "value", fileExtension: fileExtension) { coordinator, document in
            let (view, _) = makeTextView("value")
            coordinator.textView = view
            coordinator.highlight()
            let storage = try #require(view.textStorage)
            view.string = "class"
            let recorder = GenericViewportAttributeRecorder()
            storage.delegate = recorder
            defer { storage.delegate = nil }

            // A programmatic edit has no shouldChangeText callback; the new
            // buffer must not inherit the old buffer's viewport cache.
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))

            #expect(document.text == "class")
            #expect(recorder.attributeEdits > 0)
            let reference = NSTextStorage(string: "class")
            SyntaxHighlighter.apply(to: reference, font: font, fileExtension: fileExtension, isDark: true)
            for location in 0..<storage.length {
                #expect(storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
                    == reference.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor)
            }
        }
    }

    @Test
    func repeatedEmptyFoldUpdatesPreserveDecorationsWithoutFullLayout() throws {
        let (view, layout) = makeTextView("func main() {}")
        let range = NSRange(location: 0, length: 4)
        layout.addTemporaryAttribute(.foregroundColor, value: NSColor.magenta, forCharacterRange: range)
        layout.containerLayoutRequests = 0

        // The Go/Rust runnable refresh enters this common renderer even though
        // no fold provider supplied any ranges. It must not erase other overlays.
        for _ in 0..<3 {
            view.updateFolds(regions: [], collapsedIDs: [], onToggle: { _ in })
        }

        #expect(layout.containerLayoutRequests == 0)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0,
                                         effectiveRange: nil) as? NSColor == .magenta)
    }

    @Test
    func removingAnExistingFoldStillRestoresVisibleText() {
        let (view, layout) = makeTextView("start\nhidden\nend")
        // JavaFoldRegion is the pre-existing renderer input; this fixture does
        // not run a Java parser or introduce a new language folding provider.
        let fold = JavaFoldRegion(kind: .block, startLine: 0, endLine: 2,
                                  hiddenRange: NSRange(location: 6, length: 7))
        view.updateFolds(regions: [fold], collapsedIDs: [fold.id], onToggle: { _ in })
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 6,
                                         effectiveRange: nil) as? NSColor == .clear)
        layout.containerLayoutRequests = 0

        view.updateFolds(regions: [], collapsedIDs: [], onToggle: { _ in })

        #expect(layout.containerLayoutRequests > 0)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 6,
                                         effectiveRange: nil) == nil)
    }

    @Test(arguments: ["go", "rs", "py", "swift", "json", "md"])
    func nonJavaFoldRefreshPreservesTheViewportCache(fileExtension: String) throws {
        try withCoordinator(source: "name\nsecond\n", fileExtension: fileExtension) { coordinator, _ in
            let (view, _) = makeTextView("name\nsecond\n")
            coordinator.textView = view
            coordinator.highlight()
            let storage = try #require(view.textStorage)
            let recorder = GenericViewportAttributeRecorder()
            storage.delegate = recorder
            defer { storage.delegate = nil }

            coordinator.scheduleFoldRefresh()
            coordinator.highlight()

            #expect(recorder.attributeEdits == 0)
        }
    }

    private func makeTextView(_ source: String) -> (CodeTextView, GenericViewportLayoutRecorder) {
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        let layout = GenericViewportLayoutRecorder()
        view.textContainer?.replaceLayoutManager(layout)
        layout.delegate = view
        view.font = font
        view.string = source
        view.rebuildLineIndex()
        return (view, layout)
    }

    private func withCoordinator(
        source: String,
        fileExtension: String,
        body: (CodeEditorView.Coordinator, EditorDocument) throws -> Void
    ) rethrows {
        let store = GenericViewportTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/Viewport.\(fileExtension)"),
                                      text: source, modificationDate: nil)
        let coordinator = CodeEditorView.Coordinator(
            document: document, model: model,
            markdownScrollPosition: nil, viewportStore: EditorViewportStore()
        )
        // All assertions finish synchronously. Releasing the coordinator cancels
        // its owned debounce tasks; no run loop or wall-clock wait is required.
        try withExtendedLifetime((model, document)) { try body(coordinator, document) }
    }
}

private final class GenericViewportAttributeRecorder: NSObject, NSTextStorageDelegate {
    var attributeEdits = 0

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedAttributes) { attributeEdits += 1 }
    }
}

private final class GenericViewportLayoutRecorder: NSLayoutManager {
    var containerLayoutRequests = 0

    override func ensureLayout(for container: NSTextContainer) {
        containerLayoutRequests += 1
        super.ensureLayout(for: container)
    }
}

private final class GenericViewportTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
