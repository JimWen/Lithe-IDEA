import AppKit
import Testing
@testable import Lithe

@MainActor
struct MacSearchKeyboardTests {
    @Test
    func nativeEditingKeysAreNotPopupNavigation() {
        for key: UInt16 in [123, 124] {
            #expect(MacSearchKeyboardAction.resolve(keyCode: key, modifiers: []) == nil)
            #expect(MacSearchKeyboardAction.resolve(keyCode: key, modifiers: [.shift]) == nil)
        }
        for key: UInt16 in [125, 126, 36, 76, 53] {
            for modifier: NSEvent.ModifierFlags in [.shift, .command, .option, .control] {
                #expect(MacSearchKeyboardAction.resolve(keyCode: key, modifiers: modifier) == nil)
            }
        }
        #expect(MacSearchKeyboardAction.resolve(keyCode: 48, modifiers: []) == .category(1))
        #expect(MacSearchKeyboardAction.resolve(keyCode: 48, modifiers: [.shift]) == .category(-1))
        #expect(MacSearchKeyboardAction.resolve(keyCode: 48, modifiers: [.command]) == nil)
    }

    @Test
    func monitorRespectsWindowCompositionSheetsAndDismantling() throws {
        let window = SearchTestWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let other = SearchTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        let view = MacSearchKeyView()
        let editor = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 100))
        defer { view.removeMonitor(); window.close(); other.close() }
        window.contentView?.addSubview(view)
        window.contentView?.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        var enabled = true
        view.isEnabled = { enabled }
        var actions: [MacSearchKeyboardAction] = []
        view.handle = { actions.append($0); return true }
        func event(_ owner: NSWindow) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: owner.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        }
        let ownEvent = try event(window)
        #expect(view.consume(ownEvent))
        #expect(actions == [.move(1)])
        enabled = false
        #expect(!view.consume(ownEvent))
        enabled = true
        #expect(!view.consume(try event(other)))
        window.testKey = false
        #expect(!view.consume(ownEvent))
        window.testKey = true
        editor.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(!view.consume(ownEvent))
        editor.unmarkText()
        window.testAttachedSheet = other
        #expect(!view.consume(ownEvent))
        window.testAttachedSheet = nil
        // A sheet's parent may have an attached sheet; only this owning window
        // controls whether another modal surface blocks its navigation.
        other.testAttachedSheet = window
        #expect(view.consume(ownEvent))
        other.testAttachedSheet = nil
        window.close()
        #expect(!view.consume(ownEvent))
        view.removeMonitor()
        #expect(!view.consume(ownEvent))
        #expect(actions == [.move(1), .move(1)])
    }
}

private final class SearchTestWindow: NSWindow {
    var testKey = true
    var testAttachedSheet: NSWindow?
    override var isKeyWindow: Bool { testKey }
    override var attachedSheet: NSWindow? { testAttachedSheet }
}
