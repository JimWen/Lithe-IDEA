import AppKit
import LitheGitModule
import Testing
@testable import Lithe

@Suite("Native Worktree document layout")
@MainActor
struct GitWorktreeNativeLayoutTests {
    @Test("Loading and filtering worktrees resizes the document without a window resize")
    func listHeightFollowsRowsAtUnchangedWidth() {
        let view = GitWorktreeListNSView()
        let first = item("main")
        let second = item("feature")
        // A first render can precede the detached list projection. Growing and
        // shrinking that projection must expose every row at the same width.
        let steps: [(items: [GitWorktreeListItem], height: CGFloat)] = [
            ([], 20), ([first], 104), ([first, second], 195), ([second], 104), ([], 20)
        ]
        for step in steps {
            view.update(items: step.items, selectedWorktreeID: nil, onSelect: { _ in })
            view.updateLayout(width: 360)
            #expect(view.frame.size == CGSize(width: 360, height: step.height))
            #expect(!view.updateLayout(width: 360))
        }
    }

    @Test("Worktree detail documents resize when same-width snapshots gain or lose rows")
    func detailHeightFollowsSnapshotAtUnchangedWidth() {
        let view = GitWorktreeRowsNSView()
        let first = GitWorktreeRowsSnapshot.Row.commit(subject: "First", author: "Fixture", date: "2026-01-01")
        let second = GitWorktreeRowsSnapshot.Row.commit(subject: "Second", author: "Fixture", date: "2026-01-02")
        let steps: [(rows: [GitWorktreeRowsSnapshot.Row], height: CGFloat)] = [
            ([], 0), ([first], 35), ([first, second], 70), ([second], 35), ([], 0)
        ]
        for (version, step) in steps.enumerated() {
            view.update(
                snapshot: GitWorktreeRowsSnapshot(identity: .history(inspectionVersion: version, query: ""), rows: step.rows),
                rowHeight: 35
            )
            view.updateLayout(width: 640)
            #expect(view.frame.size == CGSize(width: 640, height: step.height))
            #expect(!view.updateLayout(width: 640))
        }
    }

    @Test("Initial window layout reveals preloaded history without another data update")
    func detailInitialHostLayoutSizesPreloadedRows() throws {
        let rows = ["First", "Second", "Third"].map {
            GitWorktreeRowsSnapshot.Row.commit(subject: $0, author: "Fixture", date: "2026-01-01")
        }
        // The production factory receives data while its native viewport is
        // still zero-sized. Only the subsequent host layout supplies a width;
        // no search or second snapshot should be needed to reveal these rows.
        let scroll = GitWorktreeRowsScrollView.makeScrollView(snapshot:
            GitWorktreeRowsSnapshot(identity: .history(inspectionVersion: 1, query: ""), rows: rows))
        let document = try #require(scroll.documentView as? GitWorktreeRowsNSView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        window.contentView = scroll
        window.setContentSize(NSSize(width: 720, height: 320))
        scroll.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        #expect(scroll.contentView.bounds.width > 0)
        #expect(document.frame.width == scroll.contentView.bounds.width)
        #expect(document.frame.height == 105)
    }

    private func item(_ name: String) -> GitWorktreeListItem {
        GitWorktreeListItem(worktree: GitWorktree(
            path: "/fixture/worktrees/\(name)", head: "abcdef", branch: "refs/heads/\(name)",
            isCurrent: false, isPrimary: false, isBare: false, isDetached: false,
            isLocked: false, lockReason: nil, isPrunable: false, pruneReason: nil
        ), status: .available)
    }
}
