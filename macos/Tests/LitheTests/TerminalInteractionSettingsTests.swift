import AppKit
import LitheTerminalModule
import SwiftTerm
import Testing
@testable import Lithe

@Suite("Terminal interaction settings", .serialized)
@MainActor
struct TerminalInteractionSettingsTests {
    @Test
    func oldPayloadDefaultsAndAllInteractionFieldsRoundTrip() throws {
        let old = try JSONDecoder().decode(TerminalDisplayConfiguration.self, from: Data(#"{"fontSize":18}"#.utf8))
        #expect(old.scrollback == 2_000 && old.cursorShape == .block && old.cursorBlink)
        #expect(old.optionAsMeta && old.keepSelectionOnCopy && !old.copyOnSelect)
        #expect(old.linkDetection == .automatic && old.linkModifier == .command)
        let store = TerminalConfigurationTestStore()
        let settings = AppSettings(store: store)
        var configuration = old
        configuration.scrollback = 0; configuration.cursorShape = .bar; configuration.cursorBlink = false
        configuration.optionAsMeta = false; configuration.scrollSensitivity = 0.25
        configuration.copyOnSelect = true; configuration.keepSelectionOnCopy = false
        configuration.linkDetection = .explicit; configuration.linkModifier = .none
        settings.terminalDisplayConfiguration = configuration
        #expect(AppSettings(store: store).terminalDisplayConfiguration == configuration)
        for history in [-1, 100_001] {
            configuration.scrollback = history
            #expect(configuration.scrollbackValidationMessage != nil)
        }
        for sensitivity in [Double.nan, .infinity, -.infinity, 0.04, 10.01] {
            configuration.scrollSensitivity = sensitivity
            #expect(configuration.scrollSensitivityValidationMessage != nil)
        }
    }

    @Test
    func independentGroupsPreserveFontSelectionAndApplicationCursor() throws {
        let transport = fixture()
        defer { transport.stop() }
        let view = transport.view
        var configuration = TerminalDisplayConfiguration()
        #expect(transport.applyDisplayConfiguration(configuration).isEmpty)
        view.feed(text: "first second\r\nthird fourth")
        view.feed(text: "\u{1b}[6 q") // Application chooses a steady bar.
        view.selectAll()
        let selection = try #require(view.selectionRange)
        let font = view.font
        configuration.linkDetection = .disabled; configuration.optionAsMeta = false
        configuration.scrollSensitivity = 2
        #expect(transport.applyDisplayConfiguration(configuration).isEmpty)
        #expect(view.font == font && view.selectionRange == selection)
        #expect(view.getTerminal().options.cursorStyle == .steadyBar)
        #expect(!view.optionAsMetaKey && view.scrollSensitivity == 2)
        configuration.fontName = "LitheFixtureMissing-Interaction"
        configuration.fontSize = 30; configuration.scrollback = 4_000
        configuration.cursorShape = .underline; configuration.cursorBlink = false
        #expect(!transport.applyDisplayConfiguration(configuration).isEmpty)
        #expect(view.font == font)
        #expect(view.getTerminal().options.scrollback == 4_000)
        #expect(view.getTerminal().options.cursorStyle == .steadyUnderline)
        #expect(view.selectionRange == selection)
        configuration.scrollSensitivity = .infinity
        configuration.optionAsMeta = true
        #expect(transport.applyDisplayConfiguration(configuration).count == 2)
        #expect(view.scrollSensitivity == 2 && view.optionAsMetaKey)
        configuration.scrollback = 0
        _ = transport.applyDisplayConfiguration(configuration)
        #expect(view.selectionRange == nil)
        #expect(view.getTerminal().options.scrollback == 0)
        view.feed(text: String(repeating: "line\r\n", count: 60))
        #expect(!view.canScroll)
    }

    @Test
    func linksHonorDiscoveryModifierPreviewAndSelectionGestures() throws {
        let scheduler = ManualCommandScheduler()
        let transport = MacTerminalTransport(linkActivation: MacTerminalLinkActivation(schedule: { delay, action in
            scheduler.schedule(after: delay, action)
        }))
        transport.view.setFrameSize(CGSize(width: 800, height: 480))
        defer { transport.stop() }
        let view = transport.view
        var configuration = TerminalDisplayConfiguration()
        configuration.linkModifier = .none
        _ = transport.applyDisplayConfiguration(configuration)
        view.feed(text: "https://example.invalid/plain\r\n\u{1b}]8;id=fixture;https://example.invalid/a;b\u{1b}\\explicit\u{1b}]8;;\u{1b}\\")
        var opened: [String] = []
        transport.onLink = { link, _ in opened.append(link) }
        try click(view, row: 0, col: 4)
        #expect(opened.isEmpty)
        scheduler.drain(includingDeadlines: true)
        #expect(opened == ["https://example.invalid/plain"])
        opened = []
        // A real double click includes the first complete single click.
        try click(view, row: 0, col: 4)
        try click(view, row: 0, col: 4, count: 2)
        scheduler.drain(includingDeadlines: true)
        #expect(opened.isEmpty && view.selectionRange != nil)
        try drag(view, row: 0, from: 1, to: 8)
        #expect(opened.isEmpty)
        try click(view, row: 0, col: 4, flags: [.shift])
        #expect(opened.isEmpty)
        configuration.linkDetection = .explicit
        _ = transport.applyDisplayConfiguration(configuration)
        try click(view, row: 0, col: 4)
        #expect(opened.isEmpty)
        try click(view, row: 1, col: 3)
        scheduler.drain(includingDeadlines: true)
        #expect(opened == ["https://example.invalid/a;b"])
        view.mouseMoved(with: try event(view, .mouseMoved, row: 1, col: 3))
        #expect(view.subviews.contains { ($0 as? NSTextField)?.stringValue == "https://example.invalid/a;b" })
        configuration.linkDetection = .disabled
        _ = transport.applyDisplayConfiguration(configuration)
        #expect(!view.subviews.contains { $0 is NSTextField })
        opened = []
        try click(view, row: 1, col: 3, flags: [.command])
        view.flagsChanged(with: try modifierEvent(view, row: 1, col: 3))
        view.mouseMoved(with: try event(view, .mouseMoved, row: 1, col: 3, flags: [.command]))
        #expect(opened.isEmpty && !view.subviews.contains { $0 is NSTextField })
        configuration.linkDetection = .automatic; configuration.linkModifier = .command
        _ = transport.applyDisplayConfiguration(configuration)
        try click(view, row: 0, col: 4)
        #expect(opened.isEmpty)
        try click(view, row: 0, col: 4, flags: [.command])
        #expect(opened == ["https://example.invalid/plain"])
    }

    @Test
    func reportingKeepsMousePacketsWhenLinksAreDisabledOrClickable() throws {
        let view = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        let delegate = InteractionDelegate()
        view.terminalDelegate = delegate
        view.linkHighlightMode = .hover
        view.feed(text: "https://example.invalid/plain\u{1b}[?1003h\u{1b}[?1006h")
        try click(view, row: 0, col: 4)
        #expect(delegate.links.isEmpty)
        let clicks = String(decoding: delegate.output, as: UTF8.self)
        #expect(clicks.contains("\u{1b}[<0;5;1M") && clicks.contains("\u{1b}[<0;5;1m"))
        delegate.output = []
        view.mouseDown(with: try event(view, .leftMouseDown, row: 0, col: 4))
        view.feed(text: "\u{1b}[?1003l")
        view.mouseUp(with: try event(view, .leftMouseUp, row: 0, col: 4))
        #expect(delegate.links.isEmpty)
        view.feed(text: "\u{1b}[?1003h")
        delegate.output = []
        view.mouseDown(with: try event(view, .leftMouseDown, row: 0, col: 4))
        view.mouseUp(with: try event(view, .leftMouseUp, row: 0, col: 4, flags: [.shift]))
        #expect(delegate.links.isEmpty)
        #expect(String(decoding: delegate.output, as: UTF8.self).contains("m"))
        delegate.output = []
        view.linkReporting = .none
        view.mouseMoved(with: try event(view, .mouseMoved, row: 0, col: 4))
        #expect(String(decoding: delegate.output, as: UTF8.self).contains("\u{1b}[<35;5;1M"))
        #expect(!view.subviews.contains { $0 is NSTextField })
    }

    @Test
    func copyUsesActualRangeAndPreservesAutomaticSelection() throws {
        let clipboard = ClipboardFixture()
        defer { clipboard.restore() }
        let transport = fixture()
        defer { transport.stop() }
        let view = transport.view
        var configuration = TerminalDisplayConfiguration()
        configuration.copyOnSelect = true; configuration.keepSelectionOnCopy = false
        _ = transport.applyDisplayConfiguration(configuration)
        view.feed(text: "same one\r\nsame two\r\nthird word")
        try click(view, row: 0, col: 1)
        try click(view, row: 0, col: 1, count: 2)
        clipboard.recordWrite()
        #expect(NSPasteboard.general.string(forType: .string) == "same")
        #expect(view.selectionRange != nil)
        let firstCount = NSPasteboard.general.changeCount
        try click(view, row: 0, col: 1, count: 2)
        #expect(NSPasteboard.general.changeCount == firstCount)
        try click(view, row: 1, col: 1, count: 2)
        clipboard.recordWrite()
        #expect(NSPasteboard.general.changeCount > firstCount)
        #expect(NSPasteboard.general.string(forType: .string) == "same")
        #expect(view.selectionRange != nil)
        view.copy(view)
        clipboard.recordWrite()
        #expect(view.selectionRange == nil)
        configuration.keepSelectionOnCopy = true
        _ = transport.applyDisplayConfiguration(configuration)
        try click(view, row: 2, col: 1, count: 3)
        clipboard.recordWrite()
        #expect(NSPasteboard.general.string(forType: .string)?.contains("third word") == true)
        let range = view.selectionRange
        view.copy(view); clipboard.recordWrite()
        #expect(view.selectionRange == range)
        let count = NSPasteboard.general.changeCount
        view.mouseDown(with: try event(view, .leftMouseDown, row: 2, col: 1, count: 2))
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1049l")
        view.mouseUp(with: try event(view, .leftMouseUp, row: 2, col: 1, count: 2))
        #expect(NSPasteboard.general.changeCount == count)
        view.mouseDown(with: try event(view, .leftMouseDown, row: 1, col: 1))
        view.mouseDragged(with: try event(view, .leftMouseDragged, row: 0, col: 5))
        view.cancelMouseInteraction()
        let cancelledRange = view.selectionRange
        view.mouseDragged(with: try event(view, .leftMouseDragged, row: 0, col: 15))
        view.mouseUp(with: try event(view, .leftMouseUp, row: 0, col: 15))
        #expect(view.selectionRange == cancelledRange)
        #expect(NSPasteboard.general.changeCount == count)
    }

    @Test
    func nativeContentClickTakesKeyboardFocusFromTheEditor() throws {
        let clipboard = ClipboardFixture()
        let transport = fixture()
        let view = transport.view
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { transport.stop(); window.close(); clipboard.restore() }
        let editor = NSTextView(frame: CGRect(x: 0, y: 500, width: 800, height: 100))
        let content = try #require(window.contentView)
        content.addSubview(view)
        content.addSubview(editor)
        view.feed(text: "terminal word")
        view.keepSelectionOnCopy = false
        #expect(window.makeFirstResponder(editor))
        let point = try location(view, row: 0, col: 2)
        // Exercise the actual window hierarchy, including its Metal drawing
        // child when available, instead of calling TerminalView directly.
        let receiver = try #require(content.hitTest(view.convert(point, to: content)))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 2, pressure: 0))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp,
            location: down.locationInWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2,
            clickCount: 2, pressure: 0))
        receiver.mouseDown(with: down)
        receiver.mouseUp(with: up)
        #expect(window.firstResponder === view)
        #expect(view.getSelection() == "terminal")
        #expect(window.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil) == true)
        clipboard.recordWrite()
        #expect(NSPasteboard.general.string(forType: .string) == "terminal")
        #expect(view.selectionRange == nil)
    }

    @Test
    func delayedLinkIgnoresCancelledAndDestroyedCallbacks() {
        var callbacks: [@MainActor @Sendable () -> Void] = []
        var delays: [TimeInterval] = []
        var cancellations = 0
        var opened = 0
        var activation: MacTerminalLinkActivation? = MacTerminalLinkActivation(schedule: { delay, action in
            delays.append(delay)
            callbacks.append(action)
            // Keep cancelled callbacks to emulate delivery already in flight.
            return { cancellations += 1 }
        })
        activation?.submit { opened += 1 }
        activation?.cancel()
        callbacks[0]()
        #expect(opened == 0 && cancellations == 1)
        activation?.submit { opened += 10 }
        activation?.submit { opened += 100 }
        callbacks[1](); callbacks[2]()
        #expect(opened == 100 && cancellations == 2)
        callbacks[2]()
        #expect(opened == 100)
        activation?.submit { opened += 1000 }
        activation = nil
        callbacks[3]()
        #expect(opened == 100 && cancellations == 3)
        #expect(delays.allSatisfy { $0 == NSEvent.doubleClickInterval })
    }

    private func fixture() -> MacTerminalTransport {
        let transport = MacTerminalTransport()
        transport.view.setFrameSize(CGSize(width: 800, height: 480))
        return transport
    }

    private func location(_ view: SwiftTerm.TerminalView, row: Int, col: Int) throws -> CGPoint {
        let cell = view.caretFrame.size
        try #require(cell.width > 0 && cell.height > 0)
        return CGPoint(x: (CGFloat(col) + 0.5) * cell.width,
                       y: view.frame.height - (CGFloat(row) + 0.5) * cell.height)
    }

    private func event(_ view: SwiftTerm.TerminalView, _ type: NSEvent.EventType,
                       row: Int, col: Int, count: Int = 1, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: location(view, row: row, col: col), modifierFlags: flags,
                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                                       clickCount: count, pressure: 0))
    }

    private func modifierEvent(_ view: SwiftTerm.TerminalView, row: Int, col: Int) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .flagsChanged, location: location(view, row: row, col: col), modifierFlags: [.command],
                                     timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: 55))
    }

    private func click(_ view: SwiftTerm.TerminalView, row: Int, col: Int,
                       count: Int = 1, flags: NSEvent.ModifierFlags = []) throws {
        view.mouseDown(with: try event(view, .leftMouseDown, row: row, col: col, count: count, flags: flags))
        view.mouseUp(with: try event(view, .leftMouseUp, row: row, col: col, count: count, flags: flags))
    }

    private func drag(_ view: SwiftTerm.TerminalView, row: Int, from: Int, to: Int) throws {
        view.mouseDown(with: try event(view, .leftMouseDown, row: row, col: from))
        for col in from...to { view.mouseDragged(with: try event(view, .leftMouseDragged, row: row, col: col)) }
        view.mouseUp(with: try event(view, .leftMouseUp, row: row, col: to))
    }
}

@MainActor
private final class InteractionDelegate: @preconcurrency TerminalViewDelegate {
    var output: [UInt8] = []
    var links: [String] = []
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { output.append(contentsOf: data) }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) { links.append(link) }
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

/// Preserve opaque pasteboard data without logging or inspecting its contents.
@MainActor
private final class ClipboardFixture {
    private let original: [[NSPasteboard.PasteboardType: Data]]
    private var ownedChangeCount: Int
    init() {
        let board = NSPasteboard.general
        original = (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        ownedChangeCount = board.changeCount
    }
    func recordWrite() { ownedChangeCount = NSPasteboard.general.changeCount }
    func restore() {
        let board = NSPasteboard.general
        guard board.changeCount == ownedChangeCount else { return }
        let items = original.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        board.clearContents()
        board.writeObjects(items)
    }
}
