import AppKit
import SwiftTerm
import Testing

@Suite("Terminal pointer routing", .serialized)
@MainActor
struct TerminalPointerRoutingTests {
    @Test
    func sharedWindowTrackingRestoresTheHostsOriginalChoice() throws {
        for original in [false, true] {
            let window = makeWindow()
            window.acceptsMouseMovedEvents = original
            let first = makeTerminal()
            let second = makeTerminal()
            defer { first.removeFromSuperview(); second.removeFromSuperview(); window.close() }
            let content = try #require(window.contentView)
            content.addSubview(first)
            content.addSubview(second)
            for _ in 0..<3 { first.linkHighlightMode = .hover; second.linkHighlightMode = .hover }
            #expect(window.acceptsMouseMovedEvents)
            first.linkReporting = .none
            #expect(window.acceptsMouseMovedEvents)
            second.linkReporting = .none
            #expect(window.acceptsMouseMovedEvents == original)
            // A TUI can still request motion when URL discovery is disabled.
            first.feed(text: "\u{1b}[?1003h")
            #expect(window.acceptsMouseMovedEvents)
            first.feed(text: "\u{1b}[?1003l")
            #expect(window.acceptsMouseMovedEvents == original)
            first.linkReporting = .explicit
            #expect(window.acceptsMouseMovedEvents)
            first.removeFromSuperview()
            #expect(window.acceptsMouseMovedEvents == original)
        }
    }

    @Test
    func movingAndReleasingViewsCleansUpBothWindows() async throws {
        let old = makeWindow()
        let next = makeWindow()
        old.acceptsMouseMovedEvents = false
        next.acceptsMouseMovedEvents = false
        let released = TestGate()
        var terminal: SwiftTerm.TerminalView? = ReleasingTerminal(frame: .zero, released: released)
        terminal?.linkHighlightMode = .hover
        terminal?.setFrameSize(CGSize(width: 350, height: 400))
        weak let releasedView = terminal
        defer { terminal?.removeFromSuperview(); old.close(); next.close() }
        try #require(old.contentView).addSubview(try #require(terminal))
        #expect(old.acceptsMouseMovedEvents && !next.acceptsMouseMovedEvents)
        try #require(next.contentView).addSubview(try #require(terminal))
        #expect(!old.acceptsMouseMovedEvents && next.acceptsMouseMovedEvents)
        terminal?.removeFromSuperview()
        terminal = nil
        // SwiftTerm can own the view until its already-queued native redraw
        // completes. Observe deinit with a bounded gate, not a fixed delay.
        #expect(await released.waitUntilOpen())
        #expect(releasedView == nil)
        #expect(!old.acceptsMouseMovedEvents && !next.acceptsMouseMovedEvents)
    }

    @Test
    func applicationDispatchDeliversOnePacketToOnlyTheVisibleHoveredTerminal() throws {
        let window = makeWindow()
        let first = makeTerminal()
        let second = makeTerminal()
        second.setFrameOrigin(CGPoint(x: 400, y: 0))
        let firstOutput = PointerOutput()
        let secondOutput = PointerOutput()
        first.terminalDelegate = firstOutput
        second.terminalDelegate = secondOutput
        let editor = PointerResponder(frame: CGRect(x: 0, y: 500, width: 800, height: 100))
        let content = try #require(window.contentView)
        content.addSubview(first)
        content.addSubview(second)
        content.addSubview(editor)
        defer { first.removeFromSuperview(); second.removeFromSuperview(); window.close() }
        first.linkReporting = .none
        second.linkReporting = .none
        first.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")
        second.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")
        #expect(window.makeFirstResponder(editor))
        // NSApplication dispatch invokes the real local monitor as well as
        // normal responder delivery. Calling TerminalView directly cannot
        // catch lost hover with editor focus or duplicate TUI motion packets.
        let firstMove = try move(in: first, window: window)
        NSApplication.shared.sendEvent(firstMove)
        #expect(firstOutput.text == "\u{1b}[<35;5;1M")
        #expect(secondOutput.text.isEmpty)
        #expect(editor.moves == 1) // The terminal's monitor must not consume it.
        firstOutput.bytes = []
        #expect(window.makeFirstResponder(first))
        NSApplication.shared.sendEvent(firstMove)
        #expect(firstOutput.text == "\u{1b}[<35;5;1M")
        firstOutput.bytes = []
        NSApplication.shared.sendEvent(try move(in: second, window: window))
        #expect(firstOutput.text.isEmpty && secondOutput.text == "\u{1b}[<35;5;1M")
        secondOutput.bytes = []
        NSApplication.shared.sendEvent(try mouseMove(window: window, point: CGPoint(x: 390, y: 450)))
        #expect(firstOutput.text.isEmpty && secondOutput.text.isEmpty)
        first.isHidden = true
        NSApplication.shared.sendEvent(firstMove)
        #expect(firstOutput.text.isEmpty)
        first.isHidden = false
        // Clip the terminal while keeping its original bounds and window.
        let clip = NSClipView(frame: CGRect(x: 0, y: 0, width: 350, height: 100))
        content.addSubview(clip)
        clip.documentView = first
        NSApplication.shared.sendEvent(try move(in: first, window: window))
        #expect(firstOutput.text.isEmpty)
        clip.isHidden = true
        NSApplication.shared.sendEvent(try mouseMove(window: window, point: CGPoint(x: 20, y: 20)))
        #expect(firstOutput.text.isEmpty)
        first.removeFromSuperview()
        NSApplication.shared.sendEvent(firstMove)
        #expect(firstOutput.text.isEmpty)
    }

    @Test
    func commandHoverWorksWithEditorFocusWithoutSendingBackgroundKeyboardInput() throws {
        let window = makeWindow()
        let terminal = makeTerminal()
        terminal.linkHighlightMode = .hoverWithModifier
        let output = PointerOutput()
        terminal.terminalDelegate = output
        let editor = PointerResponder(frame: CGRect(x: 0, y: 500, width: 800, height: 100))
        let content = try #require(window.contentView)
        content.addSubview(terminal)
        content.addSubview(editor)
        defer { terminal.removeFromSuperview(); window.close() }
        terminal.feed(text: "\u{1b}]8;;https://example.invalid/hover\u{1b}\\hover\u{1b}]8;;\u{1b}\\\u{1b}[>10u")
        #expect(window.makeFirstResponder(editor))
        let move = try move(in: terminal, window: window)
        window.pointerLocation = move.locationInWindow
        NSApplication.shared.sendEvent(try mouseMove(window: window, point: move.locationInWindow, flags: [.command]))
        #expect(hasPreview(terminal))
        #expect(output.text.isEmpty)
        // No intervening move: key release must immediately clear the preview.
        // Its deliberately bogus event coordinates must not override the window pointer.
        sendModifier(try modifier(window: window, flags: []), to: window)
        #expect(!hasPreview(terminal) && output.text.isEmpty && editor.modifiers == 1)
        sendModifier(try modifier(window: window, flags: [.command]), to: window)
        #expect(hasPreview(terminal) && output.text.isEmpty && editor.modifiers == 2)
        terminal.isHidden = true
        sendModifier(try modifier(window: window, flags: []), to: window)
        #expect(!hasPreview(terminal))
        terminal.isHidden = false
        terminal.linkHighlightMode = .hover
        sendModifier(try modifier(window: window, flags: [.command]), to: window)
        sendModifier(try modifier(window: window, flags: []), to: window)
        #expect(hasPreview(terminal) && output.text.isEmpty)
        #expect(window.makeFirstResponder(terminal))
        sendModifier(try modifier(window: window, flags: [.command]), to: window)
        #expect(output.text == "\u{1b}[57444;9u")
        output.bytes = []
        sendModifier(try modifier(window: window, flags: []), to: window)
        #expect(output.text == "\u{1b}[57444;1:3u")
    }

    private func sendModifier(_ event: NSEvent, to window: NSWindow) {
        // The command-line test host has no AppKit key window. Still exercise
        // its real local monitor, then complete normal window/responder delivery
        // explicitly when NSApplication cannot choose this fixture as key window.
        let application = NSApplication.shared
        guard application.keyWindow == nil || application.keyWindow === window else {
            Issue.record("Another key window would receive this fixture's keyboard event")
            return
        }
        application.sendEvent(event)
        if application.keyWindow == nil { window.sendEvent(event) }
    }

    private func hasPreview(_ view: SwiftTerm.TerminalView) -> Bool {
        view.subviews.contains { ($0 as? NSTextField)?.stringValue == "https://example.invalid/hover" }
    }

    private func modifier(window: NSWindow, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .flagsChanged, location: CGPoint(x: -1_000, y: -1_000),
            modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
    }

    private func makeWindow() -> PointerWindow {
        let window = PointerWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeTerminal() -> SwiftTerm.TerminalView {
        // Hover may be enabled before the hosting layout gives the view a size.
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.linkHighlightMode = .hover
        view.setFrameSize(CGSize(width: 350, height: 400))
        return view
    }

    private func move(in view: SwiftTerm.TerminalView, window: NSWindow) throws -> NSEvent {
        let cell = view.caretFrame.size
        try #require(cell.width > 0 && cell.height > 0)
        let point = CGPoint(x: cell.width * 4.5, y: view.bounds.height - cell.height * 0.5)
        return try mouseMove(window: window, point: view.convert(point, to: nil))
    }

    private func mouseMove(window: NSWindow, point: CGPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0))
    }
}

@MainActor
private final class PointerWindow: NSWindow {
    var pointerLocation = CGPoint.zero
    override var mouseLocationOutsideOfEventStream: NSPoint { pointerLocation }
}

@MainActor
private final class ReleasingTerminal: SwiftTerm.TerminalView {
    private let released: TestGate
    init(frame: CGRect, released: TestGate) {
        self.released = released
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("Not used by this fixture") }
    deinit { released.open() }
}

@MainActor
private final class PointerResponder: NSView {
    var moves = 0
    var modifiers = 0
    override var acceptsFirstResponder: Bool { true }
    override func mouseMoved(with event: NSEvent) { moves += 1 }
    override func flagsChanged(with event: NSEvent) { modifiers += 1 }
}

@MainActor
private final class PointerOutput: @preconcurrency TerminalViewDelegate {
    var bytes: [UInt8] = []
    var text: String { String(decoding: bytes, as: UTF8.self) }
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}
