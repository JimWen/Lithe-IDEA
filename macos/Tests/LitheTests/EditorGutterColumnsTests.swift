import AppKit
import SwiftUI
import Testing
import LitheCoreContracts
@testable import LitheGitModule
@testable import Lithe

@MainActor
@Suite("Editor gutter available columns")
struct EditorGutterColumnsTests {
    @Test(arguments: ["rs", "go", "txt"])
    func mountedEditorDoesNotReserveUnavailableMarkerColumns(fileExtension: String) throws {
        let store = GutterColumnsTestStore()
        let settings = AppSettings(store: store)
        settings.editorFontSize = 13
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        let source = fileExtension == "rs" ? "fn main() {}" : "package main\nfunc main() {}"
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/src/main.\(fileExtension)"),
                                      text: source, modificationDate: nil)
        let hosting = NSHostingView(rootView:
            CodeEditorView(document: document, shouldFocus: false, viewportStore: EditorViewportStore())
                .environmentObject(model).environmentObject(model.editorChrome)
                .environmentObject(settings).environmentObject(model.editorDiagnosticsStore))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); model.documentFeature.reset() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func gutter(in view: NSView) -> LineNumberGutterView? {
            if let gutter = view as? LineNumberGutterView { return gutter }
            return view.subviews.lazy.compactMap { gutter(in: $0) }.first
        }
        let mountedGutter = try #require(gutter(in: hosting))
        // The native Rust/Go editor has a runnable column but no Java-only
        // breakpoint/fold columns. A text file needs only numbers and Git.
        #expect(mountedGutter.frame.width == (fileExtension == "txt" ? 31 : 51))
    }

    @Test
    func markerRefreshCompactsTheGutterAndMovesGitHitTestingWithIt() throws {
        let text = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textContainerInset = .zero
        text.string = "fn main() {}"
        text.rebuildLineIndex()
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        let gutter = LineNumberGutterView(frame: NSRect(x: 0, y: 0, width: 80, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { scroll.documentView = nil; window.contentView = nil; window.close() }
        window.contentView?.addSubview(scroll)
        window.contentView?.addSubview(gutter)
        var widthUpdates: [CGFloat] = []
        gutter.onStandardWidthChange = { [weak gutter] width in
            widthUpdates.append(width)
            gutter?.setFrameSize(NSSize(width: width, height: 200))
        }
        gutter.attach(textView: text, scrollView: scroll)
        #expect(gutter.frame.width == 31)
        let runnable = DocumentRunnable(id: "rust:main", configurationID: nil, displayName: "fixture",
            kind: .application, line: 1,
            symbolRange: .init(start: .init(line: 0, utf16Column: 0), end: .init(line: 0, utf16Column: 0)))
        gutter.updateRunnableMarkers([runnable], onRun: { _ in }, onDebug: { _ in }, onModify: { _ in })
        #expect(gutter.frame.width == 51)
        gutter.updateRunnableMarkers([runnable], onRun: { _ in }, onDebug: { _ in }, onModify: { _ in })
        #expect(widthUpdates == [31, 51], "Unchanged markers must not repeatedly resize the editor")

        let marker = GitLineChangeMarker(line: 0, kind: .modified, hunkID: "main")
        var shown: [GitLineChangeMarker] = []
        gutter.updateGitLineChanges([marker], onShow: { shown.append($0) })
        let manager = try #require(text.layoutManager)
        manager.ensureLayout(for: try #require(text.textContainer))
        let y = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).midY
        func clickGitColumn(at x: CGFloat) throws {
            let location = gutter.convert(NSPoint(x: x, y: y), to: nil)
            gutter.mouseDown(with: try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        try clickGitColumn(at: 50)
        gutter.updateRunnableMarkers([], onRun: { _ in }, onDebug: { _ in }, onModify: { _ in })
        #expect(gutter.frame.width == 31)
        try clickGitColumn(at: 30)
        #expect(shown == [marker, marker])

        // Existing debugger locations remain visible even when adding a new
        // breakpoint is unsupported for this language.
        gutter.updateDebugBreakpointLines([1: .init(enabled: true, verified: true)],
            supportsBreakpoints: false, onToggle: { _ in })
        #expect(gutter.frame.width == 45)
        gutter.updateDebugBreakpointLines([:], supportsBreakpoints: false, onToggle: { _ in })
        #expect(gutter.frame.width == 31)
        gutter.updateCurrentExecutionLine(1)
        #expect(gutter.frame.width == 45)
        gutter.updateCurrentExecutionLine(nil)
        #expect(gutter.frame.width == 31)

        let fold = JavaFoldRegion(kind: .method, startLine: 0, endLine: 1,
                                  hiddenRange: NSRange(location: 10, length: 1))
        gutter.updateFoldRegions([fold], collapsedIDs: [], onToggle: { _ in })
        #expect(gutter.frame.width == 46)
        gutter.updateFoldRegions([], collapsedIDs: [], onToggle: { _ in })
        #expect(gutter.frame.width == 31)
    }

    @Test
    func compactColumnsDoNotKeepInvisibleBreakpointOrFoldHitTargets() {
        let layout = EditorGutterLayout(lineNumberTextWidth: 14,
            showsBreakpoints: false, showsNavigationMarkers: true, showsFolds: false)
        #expect(layout.breakpointInteractionRange.isEmpty)
        #expect(layout.hitTarget(at: 14, hasGitChange: true) == .lineNumber)
        #expect(layout.hitTarget(at: 30, hasGitChange: true) == .implementation)
        #expect(layout.hitTarget(at: 49, hasGitChange: true) == .gitChange)
        #expect(layout.hitTarget(at: 49, hasGitChange: false) == nil)
        #expect(layout.hitTarget(at: 60, hasGitChange: true) == nil)
    }
}

private final class GutterColumnsTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
