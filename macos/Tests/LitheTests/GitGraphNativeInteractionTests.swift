import AppKit
import LitheGitModule
import Testing
@testable import Lithe

@Suite("Native Git graph navigation", .serialized)
@MainActor
struct GitGraphNativeInteractionTests {
    @Test("Native diagonal arrow tips route through the real hit hierarchy", arguments: [CGFloat(0), CGFloat(0.5)])
    func diagonalTipsSelectAndRevealEndpoints(_ inset: CGFloat) throws {
        let layout = fixture()
        var selections: [String] = []
        let callbacks = actions { selections.append($0.hash) }
        let (window, scroll, document) = try surface(layout, actions: callbacks)
        defer { window.orderOut(nil); window.close() }

        for direction in [GitGraphPrintElement.Direction.down, .up] {
            let row = try #require(layout.rows.enumerated().first { row in
                row.element.printElements.contains { $0.hasArrow && $0.direction == direction && abs($0.position - $0.adjacentPosition) >= 2 }
            })
            let edge = try #require(row.element.printElements.first {
                $0.hasArrow && $0.direction == direction && abs($0.position - $0.adjacentPosition) >= 2
            })
            let target = try #require(edge.targetHash)
            let targetIndex = try #require(layout.rows.firstIndex { $0.commit.hash == target })
            let tip = GitGraphGeometry.line(for: edge, rowHeight: GitGraphGeometry.rowHeight).end
            let point = CGPoint(x: tip.x, y: CGFloat(row.offset) * GitGraphGeometry.rowHeight + tip.y + (direction == .up ? inset : -inset))
            // The second activation has the same focused hash, after the user
            // scrolls away. Native navigation must still bring it into view.
            for _ in 0..<2 {
                reveal(point, in: scroll, document: document)
                let hit = scroll.hitTest(document.convert(point, to: scroll.superview))
                #expect(hit is GitGraphNSView, "The graph must intercept diagonal tips before adjacent text rows")
                try click(point, in: document, window: window)
                #expect(selections.last == target)
                #expect(scroll.contentView.bounds.intersects(CGRect(x: 0, y: CGFloat(targetIndex) * GitGraphGeometry.rowHeight,
                    width: 1, height: GitGraphGeometry.rowHeight)))
                document.update(locale: Locale(identifier: "en"), presentation: presentation(layout), selectedHash: target, showCommitDecorations: true,
                    canLoadMore: false, isLoadingMore: false, actions: callbacks, onLoadMore: {}, selectedHashes: [target])
            }
        }
        #expect(selections.count == 4)
    }

    @Test("Native text and gutter clicks retain range and additive selection")
    func ordinaryClicksKeepModifiers() throws {
        let layout = fixture()
        var selections: [(String, NSEvent.ModifierFlags)] = []
        var callbacks = actions { _ in Issue.record("The native surface lost selection modifiers") }
        callbacks.onSelectWithModifiers = { selections.append(($0.hash, $1)) }
        let (window, scroll, document) = try surface(layout, actions: callbacks)
        defer { window.orderOut(nil); window.close() }
        let row = 10
        let y = CGFloat(row) * GitGraphGeometry.rowHeight + GitGraphGeometry.rowHeight / 2
        for modifiers in [NSEvent.ModifierFlags.shift, .command] {
            for x: CGFloat in [2, 400] {
                let point = CGPoint(x: x, y: y)
                reveal(point, in: scroll, document: document)
                try click(point, in: document, window: window, modifiers: modifiers)
            }
        }
        #expect(selections.map(\.0) == Array(repeating: layout.rows[row].commit.hash, count: 4))
        #expect(selections.map(\.1) == [.shift, .shift, .command, .command])
    }

    @Test("Native arrow accessibility shares navigation without duplicate drawing views")
    func accessibleArrowsTrackTheViewportAndKeepStableElements() throws {
        let layout = fixture()
        var selection: String?
        let callbacks = actions { selection = $0.hash }
        let (window, scroll, document) = try surface(layout, actions: callbacks)
        defer { window.orderOut(nil); window.close() }
        let graph = try #require(document.subviews.compactMap { $0 as? GitGraphNSView }.first)
        let elements = try #require(graph.accessibilityChildren() as? [NSAccessibilityElement])
        let first = try #require(elements.first)
        #expect(elements.count == layout.rows.flatMap(\.printElements).filter { $0.hasArrow && $0.targetHash != nil }.count)
        #expect(first.accessibilityRole() == .button)
        #expect(first.accessibilityLabel()?.contains("commit") == true)
        #expect(graph.subviews.isEmpty, "Accessibility must not introduce a second row-rendering hierarchy")
        let originalFrame = first.accessibilityFrame()
        scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(first.accessibilityFrame().origin != originalFrame.origin)
        #expect(first.accessibilityPerformPress())
        #expect(selection != nil)

        let origin = scroll.contentView.bounds.origin
        let focusChanged = document.update(locale: Locale(identifier: "en"), presentation: presentation(layout), selectedHash: nil,
            showCommitDecorations: true, canLoadMore: false, isLoadingMore: false,
            actions: callbacks, onLoadMore: {}, selectedHashes: [layout.rows[1].commit.hash])
        #expect(!focusChanged, "Changing only the selected set must not request viewport movement")
        #expect(scroll.contentView.bounds.origin == origin)
        let refreshed = try #require(graph.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(refreshed.first === first)

        let referencePainter = GitGraphNSView()
        referencePainter.update(snapshot: GitGraphLayoutService.routingSnapshot(for: layout), width: 400,
            rowHeight: GitGraphGeometry.rowHeight)
        #expect(referencePainter.accessibilityChildren()?.isEmpty ?? true,
            "The SwiftUI reference surface supplies its own accessible arrow buttons")
    }

    @Test("Identical native graph updates preserve cached actions without extra redraw requests")
    func repeatedUpdatesDoNotInvalidateNativeSurfaces() throws {
        let layout = fixture()
        let prepared = presentation(layout)
        let callbacks = actions { _ in }
        let (window, scroll, document) = try surface(layout, actions: callbacks)
        defer { window.orderOut(nil); window.close() }
        let graph = try #require(document.subviews.compactMap { $0 as? GitGraphNSView }.first)
        let initialElements = try #require(graph.accessibilityChildren() as? [NSAccessibilityElement])
        let first = try #require(initialElements.first)
        window.displayIfNeeded()
        document.needsDisplay = false
        graph.needsDisplay = false

        for _ in 0..<3 {
            #expect(!document.update(locale: Locale(identifier: "en"), presentation: prepared, selectedHash: nil,
                showCommitDecorations: true, canLoadMore: false, isLoadingMore: false,
                actions: callbacks, onLoadMore: {}))
            document.updateLayout(width: scroll.contentView.bounds.width, viewportHeight: scroll.contentView.bounds.height)
            _ = first.accessibilityFrame()
        }

        #expect(!document.needsDisplay)
        #expect(!graph.needsDisplay)
        let finalElements = try #require(graph.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(finalElements.first === first)
    }

    private func surface(_ layout: GitGraphLayout, actions: GitGraphRowActions) throws -> (NSWindow, NSScrollView, GitGraphScrollDocumentView) {
        let scroll = GitGraphScrollView.makeScrollView(presentation: presentation(layout), selectedHash: nil,
            showCommitDecorations: true, canLoadMore: false, isLoadingMore: false, actions: actions, onLoadMore: {})
        let document = try #require(scroll.documentView as? GitGraphScrollDocumentView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        document.update(locale: Locale(identifier: "en"), presentation: presentation(layout), selectedHash: nil,
            showCommitDecorations: true, canLoadMore: false, isLoadingMore: false, actions: actions, onLoadMore: {})
        document.updateLayout(width: scroll.contentView.bounds.width, viewportHeight: scroll.contentView.bounds.height)
        return (window, scroll, document)
    }

    private func reveal(_ point: CGPoint, in scroll: NSScrollView, document: NSView) {
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: min(maximum, max(0, point.y - 40))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func click(_ point: CGPoint, in document: NSView, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws {
        let location = document.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    private func fixture() -> GitGraphLayout {
        let commits = (0...40).map { row -> GitCommit in
            let parents: [String]
            if row == 0 { parents = ["1", "40"] }
            else if row == 1 { parents = (2...6).map(String.init) }
            else if (2...6).contains(row) { parents = ["39"] }
            else if row >= 39 { parents = [] }
            else { parents = [String(row + 1)] }
            return GitCommit(hash: String(row), shortHash: String(row), parentHashes: parents,
                authorName: "Fixture", authorEmail: "fixture@example.invalid", date: "2026-01-01",
                subject: "Commit \(row)", decorations: row == 0 ? "HEAD -> main" : "")
        }
        return GitGraphLayoutService.layout(commits: commits, options: .expanded)
    }

    private func presentation(_ layout: GitGraphLayout) -> GitGraphPresentation {
        GitGraphPresentation(rows: layout.rows, routingSnapshot: GitGraphLayoutService.routingSnapshot(for: layout),
            hasMissingParents: layout.hasMissingParents)
    }

    private func actions(_ select: @escaping (GitCommit) -> Void) -> GitGraphRowActions {
        GitGraphRowActions(onSelect: select, onCherryPick: { _ in }, onRevert: { _ in }, onReset: { _ in }, onCreateTag: { _ in })
    }
}
