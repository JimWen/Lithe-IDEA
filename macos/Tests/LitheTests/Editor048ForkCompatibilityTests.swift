import AppKit
import Foundation
import ObjectiveC
import Testing
@testable import Lithe

@MainActor
@Suite("Native editor fork compatibility")
struct Editor048ForkCompatibilityTests {
    @Test(arguments: ["😀", "🧑🏽‍💻"])
    func nativeInsertionBesideSurrogatesPreservesTextSelectionAndUndo(emoji: String) throws {
        let source = "<h1>HTML BLUE</h1>"
        try withEditor(source: source) { model, document, coordinator, view, _ in
            let undo = model.services.workspaceTextEditUndoController.sharedUndoManager
            view.externalUndoManager = undo
            view.allowsUndo = true
            view.isLanguageNavigationEnabled = true
            view.delegate = coordinator
            defer { view.delegate = nil; undo.removeAllActions() }
            let selection = (source as NSString).range(of: "HTML BLUE")
            view.setSelectedRange(selection)
            let replacement = "HTML LIVE 中文 " + emoji

            // Selection notifications run caret decoration while the preceding
            // UTF-16 code unit is a low surrogate, reproducing native typing.
            undo.beginUndoGrouping()
            view.insertText(replacement, replacementRange: selection)
            undo.endUndoGrouping()
            #expect(document.text == "<h1>" + replacement + "</h1>")
            #expect(view.string == document.text)
            #expect(view.selectedRange() == NSRange(location: 4 + replacement.utf16.count, length: 0))
            view.updateCaretDecorations()
            view.updateEditorDecorations()
            #expect(undo.canUndo)
            undo.undo()
            #expect(view.string == source)
            #expect(document.text == source)
        }
    }

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

            let undoEvent = try event(character: "z", keyCode: 6, flags: .command)
            #expect(view.performKeyEquivalent(with: undoEvent))
            #expect(view.string == "one")
            #expect(document.text == "one")
        }
    }

    @Test
    func sharedNativeUndoSurvivesEditorReleaseAndPreservesCrossDocumentOrder() async throws {
        let store = Editor048TestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
        ).services
        let model = AppModel(settings: settings, services: services)
        let undo = model.services.workspaceTextEditUndoController.sharedUndoManager
        undo.groupsByEvent = false
        defer { undo.removeAllActions() }
        let viewportStore = EditorViewportStore()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            _ = window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }

        let sourceA = "fn main() {\n}\n"
        let sourceB = "package main\n"
        let insertedA = "// alpha one\n// alpha two\n"
        let insertedB = "// beta one\n// beta two\n"
        let editedA = sourceA + insertedA
        let editedB = sourceB + insertedB
        let documentA = EditorDocument(
            url: URL(fileURLWithPath: "/fixture/main.rs"),
            text: sourceA,
            modificationDate: nil
        )
        let documentB = EditorDocument(
            url: URL(fileURLWithPath: "/fixture/main.go"),
            text: sourceB,
            modificationDate: nil
        )

        let releasedA = TestGate()
        let releasedACoordinatorGate = TestGate()
        let releasedAStorageGate = TestGate()
        weak var releasedAView: CodeTextView?
        weak var releasedACoordinator: CodeEditorView.Coordinator?
        weak var releasedATextStorage: NSTextStorage?
        try autoreleasepool {
            let editor = try makeMountedEditor(
                document: documentA, model: model, viewportStore: viewportStore, window: window
            )
            defer { dismantleMountedEditor(editor, window: window) }
            observeNativeRelease(editor.view, gate: releasedA)
            observeNativeRelease(editor.coordinator, gate: releasedACoordinatorGate)
            observeNativeRelease(try #require(editor.view.textStorage), gate: releasedAStorageGate)
            releasedAView = editor.view
            releasedACoordinator = editor.coordinator
            releasedATextStorage = editor.view.textStorage
            insertNativeText(insertedA, in: editor.view, using: undo)
            #expect(editor.view.string == editedA)
            #expect(documentA.text == editedA)
            #expect(editor.view.selectedRange() == NSRange(location: editedA.utf16.count, length: 0))
            editor.view.breakUndoCoalescing()
            model.services.workspaceTextEditUndoController.breakNativeEditCoalescing(for: documentA)
            try #require(!editor.view.isCoalescingUndo)
            try #require(undo.groupingLevel == 0)
            try #require(undo.canUndo)
            documentA.markSavedWithoutWriting()
            #expect(!documentA.isDirty)
        }
        await drainNativeReleaseEvents(
            until: [releasedA, releasedACoordinatorGate, releasedAStorageGate], timeout: .seconds(2)
        )
        #expect(releasedA.isOpen, "Old editor release did not complete")
        #expect(releasedACoordinatorGate.isOpen, "Old coordinator release did not complete")
        #expect(releasedAStorageGate.isOpen, "Old text storage release did not complete")
        #expect(releasedACoordinator == nil)
        #expect(releasedATextStorage == nil)
        try #require(releasedAView == nil, "Switching documents must release the old native editor")
        try #require(releasedACoordinator == nil, "Switching documents must release the old editor coordinator")
        try #require(releasedATextStorage == nil, "Switching documents must release the old text storage")

        let releasedB = TestGate()
        let releasedBCoordinatorGate = TestGate()
        let releasedBStorageGate = TestGate()
        weak var releasedBView: CodeTextView?
        weak var releasedBCoordinator: CodeEditorView.Coordinator?
        weak var releasedBTextStorage: NSTextStorage?
        try autoreleasepool {
            let editor = try makeMountedEditor(
                document: documentB, model: model, viewportStore: viewportStore, window: window
            )
            defer { dismantleMountedEditor(editor, window: window) }
            observeNativeRelease(editor.view, gate: releasedB)
            observeNativeRelease(editor.coordinator, gate: releasedBCoordinatorGate)
            observeNativeRelease(try #require(editor.view.textStorage), gate: releasedBStorageGate)
            releasedBView = editor.view
            releasedBCoordinator = editor.coordinator
            releasedBTextStorage = editor.view.textStorage
            insertNativeText(insertedB, in: editor.view, using: undo)
            #expect(editor.view.string == editedB)
            #expect(documentB.text == editedB)
            editor.view.breakUndoCoalescing()
            model.services.workspaceTextEditUndoController.breakNativeEditCoalescing(for: documentB)
            try #require(!editor.view.isCoalescingUndo)
            try #require(undo.groupingLevel == 0)
            try #require(undo.canUndo)
            documentB.markSavedWithoutWriting()
            #expect(!documentB.isDirty)

            let undoEvent = try event(
                character: "z",
                keyCode: 6,
                flags: .command
            )
            #expect(editor.view.performKeyEquivalent(with: undoEvent))
            #expect(editor.view.string == sourceB)
            #expect(documentB.text == sourceB)
            #expect(documentB.isDirty)
            #expect(editor.view.selectedRange() == NSRange(location: sourceB.utf16.count, length: 0))
            #expect(documentA.text == editedA, "The newest shared action must undo document B first")
        }
        await drainNativeReleaseEvents(
            until: [releasedB, releasedBCoordinatorGate, releasedBStorageGate], timeout: .seconds(2)
        )
        #expect(releasedB.isOpen, "Old editor release did not complete")
        #expect(releasedBCoordinatorGate.isOpen, "Old coordinator release did not complete")
        #expect(releasedBStorageGate.isOpen, "Old text storage release did not complete")
        #expect(releasedBCoordinator == nil)
        #expect(releasedBTextStorage == nil)
        try #require(releasedBView == nil, "Returning to document A must release document B's native editor")
        try #require(releasedBCoordinator == nil, "Returning to document A must release document B's coordinator")
        try #require(releasedBTextStorage == nil, "Returning to document A must release document B's text storage")

        try autoreleasepool {
            let editor = try makeMountedEditor(
                document: documentA, model: model, viewportStore: viewportStore, window: window
            )
            defer { dismantleMountedEditor(editor, window: window) }
            let undoEvent = try event(
                character: "z",
                keyCode: 6,
                flags: .command
            )
            #expect(editor.view.performKeyEquivalent(with: undoEvent))
            #expect(editor.view.string == sourceA)
            #expect(documentA.text == sourceA)
            #expect(documentA.isDirty)
            #expect(editor.view.selectedRange() == NSRange(location: sourceA.utf16.count, length: 0))
            #expect(documentB.text == sourceB)
        }

        try autoreleasepool {
            let editor = try makeMountedEditor(
                document: documentA, model: model, viewportStore: viewportStore, window: window
            )
            defer { dismantleMountedEditor(editor, window: window) }
            let redoEvent = try event(
                character: "z",
                keyCode: 6,
                flags: [.command, .shift]
            )
            #expect(editor.view.performKeyEquivalent(with: redoEvent))
            #expect(editor.view.string == editedA)
            #expect(documentA.text == editedA)
            #expect(!documentA.isDirty)
            #expect(editor.view.selectedRange() == NSRange(location: editedA.utf16.count, length: 0))
            #expect(documentB.text == sourceB, "Shared redo must restore document A before document B")
        }

        try autoreleasepool {
            let editor = try makeMountedEditor(
                document: documentB, model: model, viewportStore: viewportStore, window: window
            )
            defer { dismantleMountedEditor(editor, window: window) }
            let redoEvent = try event(
                character: "z",
                keyCode: 6,
                flags: [.command, .shift]
            )
            #expect(editor.view.performKeyEquivalent(with: redoEvent))
            #expect(editor.view.string == editedB)
            #expect(documentB.text == editedB)
            #expect(!documentB.isDirty)
            #expect(editor.view.selectedRange() == NSRange(location: editedB.utf16.count, length: 0))
            #expect(!undo.canRedo)
        }
    }

    @Test
    func stableBridgeCoalescesTypingAndBreaksAtCaretMovement() throws {
        try withStableEditor(source: "") { _, document, _, view, undo in
            view.keyDown(with: try event(character: "a", keyCode: 0, flags: []))
            view.keyDown(with: try event(character: "b", keyCode: 11, flags: []))
            view.keyDown(with: try event(character: "c", keyCode: 8, flags: []))
            #expect(document.text == "abc")
            #expect(view.selectedRange() == NSRange(location: 3, length: 0))

            let undoEvent = try event(character: "z", keyCode: 6, flags: .command)
            let redoEvent = try event(character: "z", keyCode: 6, flags: [.command, .shift])
            #expect(view.performKeyEquivalent(with: undoEvent))
            #expect(document.text.isEmpty)
            #expect(view.selectedRange() == NSRange(location: 0, length: 0))
            #expect(view.performKeyEquivalent(with: redoEvent))
            #expect(document.text == "abc")

            view.keyDown(with: try event(character: "d", keyCode: 2, flags: []))
            view.keyDown(with: try event(character: "e", keyCode: 14, flags: []))
            view.keyDown(with: try event(character: "\u{F702}", keyCode: 123, flags: .function))
            #expect(view.selectedRange() == NSRange(location: 4, length: 0))
            view.keyDown(with: try event(character: "X", keyCode: 7, flags: .shift))
            #expect(document.text == "abcdXe")

            #expect(view.performKeyEquivalent(with: undoEvent))
            #expect(document.text == "abcde")
            #expect(view.selectedRange() == NSRange(location: 4, length: 0))
            #expect(view.performKeyEquivalent(with: undoEvent))
            #expect(document.text == "abc")
            #expect(view.performKeyEquivalent(with: undoEvent))
            #expect(document.text.isEmpty)
            #expect(!undo.canUndo)
        }
    }

    @Test
    func stableBridgeKeyDownUndoKeepsRedoHistory() throws {
        try withStableEditor(source: "") { _, document, _, view, undo in
            view.keyDown(with: try event(character: "a", keyCode: 0, flags: []))
            view.keyDown(with: try event(character: "z", keyCode: 6, flags: .command))
            #expect(document.text.isEmpty)
            #expect(!undo.canUndo)
            #expect(undo.canRedo)
            view.keyDown(with: try event(character: "z", keyCode: 6, flags: [.command, .shift]))
            #expect(document.text == "a")
            #expect(!undo.canRedo)
        }
    }

    @Test
    func stableBridgeUndoPreservesUnicodeBytesAndCoordinates() throws {
        try withStableEditor(source: "e\u{301}") { _, document, _, view, _ in
            view.setSelectedRange(NSRange(location: 0, length: 2))
            view.insertText("é", replacementRange: view.selectedRange())
            #expect(Array(document.text.utf8) == [0xC3, 0xA9])
            let undoEvent = try event(character: "z", keyCode: 6, flags: .command)
            #expect(view.performKeyEquivalent(with: undoEvent))
            #expect(Array(document.text.utf8) == [0x65, 0xCC, 0x81])
            #expect(Array(view.string.utf8) == [0x65, 0xCC, 0x81])
            #expect(view.selectedRange() == NSRange(location: 0, length: 2))
            let redoEvent = try event(character: "z", keyCode: 6, flags: [.command, .shift])
            #expect(view.performKeyEquivalent(with: redoEvent))
            #expect(Array(view.string.utf8) == [0xC3, 0xA9])
            #expect(view.selectedRange() == NSRange(location: 1, length: 0))
        }
    }

    @Test
    func stableBridgeFindReplacementRestoresMatchesAndFinalSelection() throws {
        try withStableEditor(source: "foo foo") { _, document, coordinator, view, _ in
            coordinator.lastFindVisible = true
            coordinator.lastFindQuery = "foo"
            view.syncFindState(isVisible: true, query: "foo", options: .default)
            view.replaceNextFindMatch(replacement: "bar")
            #expect(document.text == "bar foo")
            #expect(view.findMatchLocationsForTesting == [4])
            #expect(view.selectedRange() == NSRange(location: 4, length: 3))
            let undoEvent = try event(character: "z", keyCode: 6, flags: .command)
            #expect(view.performKeyEquivalent(with: undoEvent))
            #expect(document.text == "foo foo")
            #expect(view.findMatchLocationsForTesting == [0, 4])
            let redoEvent = try event(character: "z", keyCode: 6, flags: [.command, .shift])
            #expect(view.performKeyEquivalent(with: redoEvent))
            #expect(document.text == "bar foo")
            #expect(view.findMatchLocationsForTesting == [4])
            #expect(view.selectedRange() == NSRange(location: 4, length: 3))
        }
    }

    @Test
    func stableBridgeIMECommitInsideNativeInputScopeIsOneAction() throws {
        try withStableEditor(source: "tail") { _, document, _, view, undo in
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: 0, length: 0))
            // Paste owns the same outer native input scope as keyDown. Deliver
            // an IME commit inside it without depending on the system input source.
            view.onPasteImage = { [weak view] in
                view?.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
                return true
            }
            defer { view.onPasteImage = nil }
            view.paste(nil)
            try #require(!view.hasMarkedText())
            try #require(document.text == "你tail")
            let undoEvent = try event(character: "z", keyCode: 6, flags: .command)
            #expect(view.performKeyEquivalent(with: undoEvent))
            #expect(document.text == "tail")
            #expect(!undo.canUndo)
            let redoEvent = try event(character: "z", keyCode: 6, flags: [.command, .shift])
            #expect(view.performKeyEquivalent(with: redoEvent))
            #expect(document.text == "你tail")
        }
    }

    @Test
    func stableBridgeLineEditRestoresFinalSelectionOnRedo() throws {
        try withStableEditor(source: "one") { _, document, _, view, _ in
            view.onLineEditingAction = { _ in
                EditorLineEditResult(
                    text: "one\none",
                    replacedRange: NSRange(location: 0, length: 3),
                    selection: NSRange(location: 4, length: 3)
                )
            }
            let duplicate = try event(character: "d", keyCode: 2, flags: .command)
            #expect(view.performKeyEquivalent(with: duplicate))
            #expect(document.text == "one\none")
            #expect(view.selectedRange() == NSRange(location: 4, length: 3))

            let undoEvent = try event(character: "z", keyCode: 6, flags: .command)
            let redoEvent = try event(character: "z", keyCode: 6, flags: [.command, .shift])
            #expect(view.performKeyEquivalent(with: undoEvent))
            #expect(document.text == "one")
            #expect(view.selectedRange() == NSRange(location: 3, length: 0))
            #expect(view.performKeyEquivalent(with: redoEvent))
            #expect(document.text == "one\none")
            #expect(view.selectedRange() == NSRange(location: 4, length: 3))
        }
    }

    @Test
    func stableBridgeRecordsIMECommitAsOneAction() throws {
        try withStableEditor(source: "tail") { _, document, _, view, undo in
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.setMarkedText(
                "n",
                selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: 0, length: 0)
            )
            view.setMarkedText(
                "ni",
                selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            view.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(document.text == "你tail")
            #expect(view.selectedRange() == NSRange(location: 1, length: 0))

            let undoEvent = try event(character: "z", keyCode: 6, flags: .command)
            let redoEvent = try event(character: "z", keyCode: 6, flags: [.command, .shift])
            #expect(view.performKeyEquivalent(with: undoEvent))
            #expect(document.text == "tail")
            #expect(view.selectedRange() == NSRange(location: 0, length: 0))
            #expect(!undo.canUndo)
            #expect(view.performKeyEquivalent(with: redoEvent))
            #expect(document.text == "你tail")
            #expect(view.selectedRange() == NSRange(location: 1, length: 0))
        }
    }

    @Test
    func stableBridgeDoesNotRecordCancelledIMEComposition() throws {
        try withStableEditor(source: "tail") { _, document, _, view, undo in
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.setMarkedText(
                "ni",
                selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: 0, length: 0)
            )
            view.setMarkedText(
                "",
                selectedRange: NSRange(location: 0, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            view.unmarkText()
            #expect(view.string == "tail")
            #expect(document.text == "tail")
            #expect(!undo.canUndo)
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

    private func withStableEditor(
        source: String,
        body: (
            AppModel,
            EditorDocument,
            CodeEditorView.Coordinator,
            CodeTextView,
            UndoManager
        ) throws -> Void
    ) throws {
        let store = Editor048TestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
        ).services
        let model = AppModel(settings: settings, services: services)
        let document = EditorDocument(
            url: URL(fileURLWithPath: "/fixture/stable.swift"),
            text: source,
            modificationDate: nil
        )
        let undo = model.services.workspaceTextEditUndoController.sharedUndoManager
        undo.groupsByEvent = false
        defer { undo.removeAllActions() }
        let viewportStore = EditorViewportStore()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            _ = window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        try autoreleasepool {
            let editor = try makeMountedEditor(
                document: document,
                model: model,
                viewportStore: viewportStore,
                window: window
            )
            defer { dismantleMountedEditor(editor, window: window) }
            try body(model, document, editor.coordinator, editor.view, undo)
        }
    }

    private func makeMountedEditor(
        document: EditorDocument,
        model: AppModel,
        viewportStore: EditorViewportStore,
        window: NSWindow
    ) throws -> (coordinator: CodeEditorView.Coordinator, view: CodeTextView, scroll: NSScrollView) {
        let coordinator = CodeEditorView.Coordinator(
            document: document,
            model: model,
            markdownScrollPosition: nil,
            viewportStore: viewportStore
        )
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        view.externalUndoManager = model.services.workspaceTextEditUndoController.sharedUndoManager
        coordinator.textView = view
        coordinator.attachStableNativeUndo(to: view)
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.string = document.text
        view.rebuildLineIndex()
        view.isEditable = true
        let viewportState = viewportStore.state(for: document.id)
        let selection = viewportState.selectionRestorationRevision > 0
            ? NSRange(location: viewportState.selectionLocation, length: viewportState.selectionLength)
            : NSRange(location: document.text.utf16.count, length: 0)
        view.setSelectedRange(selection)
        view.delegate = coordinator
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.appliedSelectionRestorationRevision = viewportState.selectionRestorationRevision
        window.contentView?.addSubview(scroll)
        try #require(window.makeFirstResponder(view))
        return (coordinator, view, scroll)
    }

    private func dismantleMountedEditor(
        _ editor: (coordinator: CodeEditorView.Coordinator, view: CodeTextView, scroll: NSScrollView),
        window: NSWindow
    ) {
        #expect(window.makeFirstResponder(nil))
        #expect(window.firstResponder !== editor.view)
        editor.coordinator.detachStableNativeUndo()
        editor.coordinator.persistViewport()
        editor.view.delegate = nil
        editor.coordinator.textView = nil
        editor.scroll.documentView = nil
        editor.scroll.removeFromSuperview()
    }

    private func insertNativeText(_ text: String, in view: CodeTextView, using undo: UndoManager) {
        #expect(undo.groupingLevel == 0)
        let insertion = view.selectedRange()
        view.insertText(text, replacementRange: insertion)
        #expect(undo.groupingLevel == 0)
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

// Observe actual AppKit release after its queued work finishes. The sentinel
// does not retain the editor and never detaches the TextKit object graph.
@MainActor
private func observeNativeRelease(_ object: AnyObject, gate: TestGate) {
    objc_setAssociatedObject(object, &editorReleaseObservationKey,
                             EditorReleaseObservation(gate: gate), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@MainActor private var editorReleaseObservationKey: UInt8 = 0

private final class EditorReleaseObservation: NSObject {
    let gate: TestGate
    init(gate: TestGate) { self.gate = gate }
    deinit { gate.open() }
}

// SwiftPM drives a CFRunLoop without NSApplication's per-event autorelease
// pools. Run AppKit's delayed release callbacks inside a pool owned by each
// event turn, so the lifetime assertion measures owners rather than the host's
// outer pool. Schedule outside a main-queue task before entering the native
// loop: nesting while that queue is draining would starve queued callbacks.
@MainActor
private func drainNativeReleaseEvents(until gates: [TestGate], timeout: Duration) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    let maximumEventTurnSeconds = 0.02
    await withCheckedContinuation { continuation in
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            precondition(Thread.isMainThread)
            while !gates.allSatisfy(\.isOpen), clock.now < deadline {
                let remaining = clock.now.duration(to: deadline).components
                let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
                // Timer callbacks do not make returnAfterSourceHandled return.
                // Bound each event turn so their autoreleases drain promptly;
                // the overall deadline never moves and no sleep is involved.
                let result = autoreleasepool {
                    CFRunLoopRunInMode(.defaultMode, min(maximumEventTurnSeconds, max(0, seconds)), true)
                }
                if result == .finished { break }
            }
            continuation.resume()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
