import AppKit
import SwiftTerm
import Testing
@testable import Lithe

@Suite("Terminal typography", .serialized)
@MainActor
struct TerminalTypographyTests {
    enum Update: CaseIterable, Sendable { case font, spacing, batch }

    @Test(arguments: Update.allCases)
    func typographyPreservesProtocolRepliesAndLiveAttributes(_ update: Update) throws {
        let view = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        let delegate = TypographyDelegate()
        view.terminalDelegate = delegate
        let terminal = view.getTerminal()
        // Query replies protect modes that cannot be restored through public
        // properties, including keypad, origin, insert and disabled wrapping.
        terminal.feed(text: "\u{1b}[?1h\u{1b}=\u{1b}[?6h\u{1b}[?7l\u{1b}[4h\u{1b}[?2004h\u{1b}[>3u")
        let before = protocolReplies(view, delegate)
        #expect(before == "\u{1b}[?1;1$y\u{1b}[?66;1$y\u{1b}[?6;1$y\u{1b}[?7;2$y\u{1b}[4;1$y\u{1b}[?2004;1$y\u{1b}[?3u")
        terminal.feed(text: "\u{1b}[31;44;1m\u{1b}]8;;https://example.invalid/typography\u{1b}\\A")
        let attribute = terminal.currentAttribute
        switch update {
        case .font: view.font = .monospacedSystemFont(ofSize: 19, weight: .regular)
        case .spacing: view.lineSpacing = 1.4
        case .batch: view.updateTypography(font: .monospacedSystemFont(ofSize: 18, weight: .regular), lineSpacing: 1.3)
        }
        #expect(view.getTerminal() === terminal)
        #expect(protocolReplies(view, delegate) == before)
        #expect(terminal.currentAttribute == attribute)
        // A character written after the change must still join the live OSC 8
        // link, not merely retain the payload of a cell written beforehand.
        let cursor = terminal.getCursorLocation()
        terminal.feed(text: "B\u{1b}]8;;\u{1b}\\")
        #expect(terminal.link(at: .screen(Position(col: cursor.x, row: cursor.y)), mode: .explicitOnly) == "https://example.invalid/typography")
        #expect(delegate.sizes.count == 1)
        let size = try #require(delegate.sizes.last)
        #expect(size == [terminal.cols, terminal.rows])
    }

    @Test
    func sameGridFontChangePreservesSavedCursorCharsetAndBuffer() {
        let view = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        let delegate = TypographyDelegate()
        view.terminalDelegate = delegate
        let terminal = view.getTerminal()
        terminal.feed(text: "NORMAL\u{1b}[?1049hALTERNATE\u{1b}[3;4H\u{1b}[32m\u{1b}(0\u{1b}7\u{1b}[7;8H")
        let contents = terminal.getBufferAsData()
        let attribute = terminal.currentAttribute
        let beforeSize = [terminal.cols, terminal.rows]
        // An equal-sized descriptor with a different cascade exercises the path
        // for which name/size-based Metal cache keys alone are insufficient.
        let descriptor = view.font.fontDescriptor.addingAttributes([
            .cascadeList: [NSFontDescriptor(fontAttributes: [.family: "Apple Color Emoji"])]
        ])
        let font = NSFont(descriptor: descriptor, size: view.font.pointSize)!
        view.updateTypography(font: font, lineSpacing: view.lineSpacing)
        #expect(view.getTerminal() === terminal)
        #expect(terminal.isCurrentBufferAlternate)
        #expect(terminal.getBufferAsData() == contents)
        #expect([terminal.cols, terminal.rows] == beforeSize)
        #expect(delegate.sizes.isEmpty)
        terminal.feed(text: "\u{1b}8")
        #expect(terminal.getCursorLocation().x == 3)
        #expect(terminal.getCursorLocation().y == 2)
        #expect(terminal.currentAttribute == attribute)
        terminal.feed(text: "q")
        #expect(terminal.getCharacter(col: 3, row: 2) == "─")
        terminal.feed(text: "\u{1b}[?1049l")
        #expect(!terminal.isCurrentBufferAlternate)
        #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self).contains("NORMAL"))
    }

    @Test(arguments: [false, true])
    func synchronizedFrameDefersTypographyAndCaretUntilCommit(originallyNeverRedraw: Bool) async throws {
        let view = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        let delegate = TypographyDelegate()
        view.terminalDelegate = delegate
        let applied = TestGate()
        defer { applied.open() }
        let terminal = view.getTerminal()
        terminal.feed(text: "COMMITTED\u{1b}[2;3H")
        view.font = view.font
        let caret = view.caretFrame
        let size = [terminal.cols, terminal.rows]
        let oldFont = view.font
        let oldSpacing = view.lineSpacing
        let originalPolicy: NSView.LayerContentsRedrawPolicy = originallyNeverRedraw ? .never : .beforeViewResize
        view.layerContentsRedrawPolicy = originalPolicy
        terminal.feed(text: "\u{1b}[?2026h\u{1b}[7;8HUNCOMMITTED")
        defer { terminal.feed(text: "\u{1b}[?2026l") }
        view.updateTypography(font: .monospacedSystemFont(ofSize: 20, weight: .regular), lineSpacing: 1.4)
        #expect(terminal.synchronizedOutputActive)
        #expect(view.caretFrame == caret)
        #expect([terminal.cols, terminal.rows] == size)
        #expect(view.font == oldFont)
        #expect(view.lineSpacing == oldSpacing)
        #expect(view.layerContentsRedrawPolicy == .never)
        delegate.onResize = { applied.open() }
        terminal.feed(text: "\u{1b}[?2026l")
        try #require(await applied.waitUntilOpen())
        #expect(!terminal.synchronizedOutputActive)
        #expect(view.caretFrame != caret)
        #expect([terminal.cols, terminal.rows] != size)
        #expect(view.layerContentsRedrawPolicy == originalPolicy)
    }

    @Test
    func deferredSettersMergeLatestValuesInEitherOrder() async throws {
        for fontFirst in [true, false] {
            let view = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
            let delegate = TypographyDelegate()
            view.terminalDelegate = delegate
            let applied = TestGate()
            delegate.onResize = { applied.open() }
            defer { applied.open() }
            let terminal = view.getTerminal()
            let font = NSFont.monospacedSystemFont(ofSize: 21, weight: .regular)
            terminal.feed(text: "\u{1b}[?2026h")
            defer { terminal.feed(text: "\u{1b}[?2026l") }
            if fontFirst { view.font = font; view.lineSpacing = 1.4 }
            else { view.lineSpacing = 1.4; view.font = font }
            // A new synchronized frame arrives before the queued commit flush.
            terminal.feed(text: "\u{1b}[?2026l\u{1b}[?2026h")
            view.lineSpacing = 1.5
            terminal.feed(text: "\u{1b}[?2026l")
            try #require(await applied.waitUntilOpen())
            #expect(view.font == font)
            #expect(view.lineSpacing == 1.5)
            #expect(delegate.sizes.count == 1)
        }
    }

    @Test
    func redrawThatEndsSynchronizationDoesNotLeakNeverPolicy() {
        let view = TypographyRedrawView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        let terminal = view.getTerminal()
        view.layerContentsRedrawPolicy = .beforeViewResize
        // Native drawing/layout can resize while the begin callback drains a
        // previous dirty frame. That nested end must win over the outer begin.
        view.onDisplay = { view.setFrameSize(CGSize(width: 960, height: 570)) }
        defer { view.onDisplay = nil; terminal.feed(text: "\u{1b}[?2026l") }
        terminal.feed(text: "\u{1b}[?2026h")
        #expect(!terminal.synchronizedOutputActive)
        #expect(view.layerContentsRedrawPolicy == .beforeViewResize)
    }

    @Test
    func newerImmediateTypographySupersedesQueuedCommit() async throws {
        let view = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        let delegate = TypographyDelegate()
        view.terminalDelegate = delegate
        let terminal = view.getTerminal()
        terminal.feed(text: "\u{1b}[?2026h")
        defer { terminal.feed(text: "\u{1b}[?2026l") }
        view.updateTypography(font: .monospacedSystemFont(ofSize: 18, weight: .regular), lineSpacing: 1.4)
        terminal.feed(text: "\u{1b}[?2026l")
        let latest = NSFont.monospacedSystemFont(ofSize: 24, weight: .regular)
        view.updateTypography(font: latest, lineSpacing: 1.2)
        // A queued marker observes the earlier native commit block's completion;
        // no real-time wait or executor-yield assumption is needed.
        let queueDrained = TestGate()
        defer { queueDrained.open() }
        DispatchQueue.main.async { queueDrained.open() }
        try #require(await queueDrained.waitUntilOpen())
        #expect(view.font == latest)
        #expect(view.lineSpacing == 1.2)
        #expect(delegate.sizes.count == 1)
    }

    @Test
    func windowResizeCommitsPendingTypographyAfterOuterResizeCompletes() async throws {
        let view = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        let delegate = TypographyDelegate()
        view.terminalDelegate = delegate
        let applied = TestGate()
        defer { applied.open() }
        let terminal = view.getTerminal()
        let font = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        let targetSize = CGSize(width: 960, height: 570)
        let reference = SwiftTerm.TerminalView(frame: CGRect(origin: .zero, size: targetSize))
        reference.updateTypography(font: font, lineSpacing: 1.4)
        let expected = [reference.getTerminal().cols, reference.getTerminal().rows]
        delegate.onResize = {
            if delegate.sizes.last == expected { applied.open() }
        }
        defer { delegate.onResize = nil }
        terminal.feed(text: "\u{1b}[?2026h\u{1b}[?1h")
        defer { terminal.feed(text: "\u{1b}[?2026l") }
        view.updateTypography(font: font, lineSpacing: 1.4)
        // Native resize ends synchronized output from inside emulator.resize.
        // A nested font resize must not be overwritten by that outer call.
        view.setFrameSize(targetSize)
        try #require(await applied.waitUntilOpen())
        #expect([terminal.cols, terminal.rows] == expected)
        #expect(delegate.sizes.last == expected)
        #expect(!terminal.synchronizedOutputActive)
        #expect(terminal.applicationCursor)
    }

    @Test
    func zeroAndTinySurfacesPreserveModesAndUseActualPTYDimensions() {
        let transport = MacTerminalTransport()
        let view = transport.view
        let terminal = view.getTerminal()
        terminal.feed(text: "\u{1b}[?1h")
        let initial = [terminal.cols, terminal.rows]
        view.updateTypography(font: .monospacedSystemFont(ofSize: 22, weight: .regular), lineSpacing: 1.5)
        #expect([terminal.cols, terminal.rows] == initial)
        view.setFrameSize(CGSize(width: 1, height: 1))
        view.updateTypography(font: .monospacedSystemFont(ofSize: 24, weight: .regular), lineSpacing: 1.2)
        let size = view.terminalWindowSize()
        #expect(size.ws_col == terminal.cols)
        #expect(size.ws_row == terminal.rows)
        #expect(size.ws_col > 0 && size.ws_row > 0)
        #expect(terminal.applicationCursor)
        view.setFrameSize(CGSize(width: 800, height: 480))
        #expect(terminal.cols > 2 && terminal.rows > 1)
        #expect(terminal.applicationCursor)
    }

    private func protocolReplies(_ view: SwiftTerm.TerminalView, _ delegate: TypographyDelegate) -> String {
        delegate.output = []
        view.getTerminal().feed(text: "\u{1b}[?1$p\u{1b}[?66$p\u{1b}[?6$p\u{1b}[?7$p\u{1b}[4$p\u{1b}[?2004$p\u{1b}[?u")
        return String(decoding: delegate.output, as: UTF8.self)
    }
}

@MainActor
private final class TypographyRedrawView: SwiftTerm.TerminalView {
    var onDisplay: (() -> Void)?
    override func displayIfNeeded() {
        let action = onDisplay
        onDisplay = nil
        action?()
        super.displayIfNeeded()
    }
}

@MainActor
private final class TypographyDelegate: @preconcurrency TerminalViewDelegate {
    var output: [UInt8] = []
    var sizes: [[Int]] = []
    var onResize: (() -> Void)?
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { output.append(contentsOf: data) }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        sizes.append([newCols, newRows])
        onResize?()
    }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}
