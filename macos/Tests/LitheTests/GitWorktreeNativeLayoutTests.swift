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

    private func item(_ name: String) -> GitWorktreeListItem {
        GitWorktreeListItem(worktree: GitWorktree(
            path: "/fixture/worktrees/\(name)", head: "abcdef", branch: "refs/heads/\(name)",
            isCurrent: false, isPrimary: false, isBare: false, isDetached: false,
            isLocked: false, lockReason: nil, isPrunable: false, pruneReason: nil
        ), status: .available)
    }
}
