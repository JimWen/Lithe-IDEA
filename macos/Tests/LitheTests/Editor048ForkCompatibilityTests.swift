import AppKit
import Foundation
import Testing
@testable import Lithe

@MainActor
@Suite("Native editor fork compatibility")
struct Editor048ForkCompatibilityTests {
    @Test(arguments: ["\n", "\r", "\r\n"])
    func emptyLogicalLineKeepsCaretGeometryOnItsOwnFragment(separator: String) throws {
        let source = "first" + separator + separator + "last"
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.string = source
        let manager = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        manager.ensureLayout(for: container)
        let location = ("first" + separator).utf16.count
        let rect = EditorCaretGeometry.rect(
            at: location, sourceLength: source.utf16.count, layoutManager: manager,
            textContainer: container, fallbackLineHeight: manager.defaultLineHeight(for: view.font!)
        )
        let glyph = manager.glyphIndexForCharacter(at: location)
        let expected = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let preceding = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        #expect(rect.minY == expected.minY)
        #expect(rect.minY > preceding.minY)
    }

    @Test
    func transactionSuspensionBlocksBothLineEditingEventPaths() throws {
        let view = CodeTextView(frame: .zero)
        view.string = "original"
        view.isEditable = true
        view.isExternalEditSuspended = { true }
        var transforms = 0
        view.onLineEditingAction = { _ in
            transforms += 1
            return EditorLineEditResult(text: "changed", replacedRange: NSRange(location: 0, length: 8),
                                        selection: NSRange(location: 0, length: 0))
        }
        let duplicate = try event(character: "d", keyCode: 2, flags: .command)
        #expect(view.performKeyEquivalent(with: duplicate))
        view.keyDown(with: try event(character: "\u{F700}", keyCode: 126, flags: [.option, .shift, .function]))
        #expect(transforms == 0)
        #expect(view.string == "original")
    }

    @Test
    func lineEditingSharesNativeUndoAndKeepsDocumentBufferInSync() throws {
        try withEditor(source: "one") { model, document, coordinator, view, _ in
            let undo = model.services.workspaceTextEditUndoController.sharedUndoManager
            view.externalUndoManager = undo
            view.allowsUndo = true
            view.onLineEditingAction = { _ in
                EditorLineEditResult(text: "one\none", replacedRange: NSRange(location: 0, length: 3),
                                     selection: NSRange(location: 4, length: 3))
            }
            view.delegate = coordinator
            defer { view.delegate = nil; undo.removeAllActions() }
            let duplicate = try event(character: "d", keyCode: 2, flags: .command)
            // One explicit group models a single native keyboard event without
            // waiting for the AppKit run loop to close an event-based group.
            undo.beginUndoGrouping()
            let handled = view.performKeyEquivalent(with: duplicate)
            undo.endUndoGrouping()
            #expect(handled)
            #expect(view.string == "one\none")
            #expect(document.text == view.string)
            #expect(view.selectedRange() == NSRange(location: 4, length: 3))
            #expect(undo.canUndo)

            #expect(view.performKeyEquivalent(with: try event(character: "z", keyCode: 6, flags: .command)))
            #expect(view.string == "one")
            #expect(document.text == "one")
        }
    }

    @Test
    func alreadyDirtyNativeEditsReevaluateSoftWrapThreshold() throws {
        let maximum = LitheTextViewportLayout.softWrapMaximumLineCount
        let source = String(repeating: "x\n", count: maximum - 1) + "last"
        try withEditor(source: source) { model, document, coordinator, view, scroll in
            model.settings.editorSoftWrapEnabled = true
            document.applyLiveEditorText(source + "!")
            view.string = document.text
            view.rebuildLineIndex()
            #expect(document.isDirty)
            coordinator.applySoftWrapIfNeeded(enabled: true)
            #expect(view.isSoftWrapEnabled)
            // No model objectWillChange is needed for an already-dirty edit.
            view.string += "\nextra"
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
            #expect(!view.isSoftWrapAvailable)
            #expect(!view.isSoftWrapEnabled)
            #expect(scroll.hasHorizontalScroller)
            #expect(document.text == view.string)

            view.string = "small again"
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
            #expect(view.isSoftWrapAvailable)
            #expect(view.isSoftWrapEnabled)
            #expect(!scroll.hasHorizontalScroller)
        }
    }

    private func event(character: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: character, charactersIgnoringModifiers: character,
                                     isARepeat: false, keyCode: keyCode))
    }

    private func withEditor(
        source: String,
        body: (AppModel, EditorDocument, CodeEditorView.Coordinator, CodeTextView, NSScrollView) throws -> Void
    ) rethrows {
        let store = Editor048TestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/main.go"), text: source, modificationDate: nil)
        let coordinator = CodeEditorView.Coordinator(document: document, model: model,
            markdownScrollPosition: nil, viewportStore: EditorViewportStore())
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.string = source
        view.rebuildLineIndex()
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        defer { scroll.documentView = nil }
        try withExtendedLifetime((model, document)) { try body(model, document, coordinator, view, scroll) }
    }
}

private final class Editor048TestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
