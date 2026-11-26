import Foundation
import Testing
@testable import LitheGitModule

@MainActor
@Suite("Git log backend filtered history")
struct GitLogBackendFilterTests {
    @Test
    func filteredHistoryFindsDeepCommitsBeyondFirstPageAndSupportsPagination() async {
        let root = URL(fileURLWithPath: "/tmp/lithe-git-filter-fixture", isDirectory: true)
        let firstPageCommit = GitCommit(
            hash: "1111111111111111111111111111111111111111",
            shortHash: "11111111",
            parentHashes: ["2222222222222222222222222222222222222222"],
            authorName: "Alice",
            authorEmail: "alice@example.com",
            date: "2026-11-20T10:00:00Z",
            subject: "Recent head commit",
            decorations: "HEAD -> main"
        )
        let deepCommitOne = GitCommit(
            hash: "df520e31aaaa1111111111111111111111111111",
            shortHash: "df520e31",
            parentHashes: [],
            authorName: "Bob",
            authorEmail: "bob@example.com",
            date: "2025-05-01T12:00:00Z",
            subject: "Deep commit #501",
            decorations: ""
        )
        let deepCommitTwo = GitCommit(
            hash: "df520e32bbbb2222222222222222222222222222",
            shortHash: "df520e32",
            parentHashes: [],
            authorName: "Bob",
            authorEmail: "bob@example.com",
            date: "2025-04-01T12:00:00Z",
            subject: "Deep commit #700",
            decorations: ""
        )

        let ops = FilteredHistoryMockOperations(
            repositoryRoot: root,
            unfilteredFirstPage: GitHistoryPage(commits: [firstPageCommit], nextCursor: "u-2", hasMore: true),
            filteredPages: [
                nil: GitHistoryPage(commits: [deepCommitOne], nextCursor: "f-2", hasMore: true),
                "f-2": GitHistoryPage(commits: [deepCommitTwo], nextCursor: nil, hasMore: false)
            ]
        )
        let service = GitService(operations: ops)
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { true },
            notify: { _ in },
            onStateRefreshed: {}
        )
        await feature.refreshGit()
        await feature.refreshGitHistory()

        #expect(feature.gitCommits.map(\.shortHash) == ["11111111"])
        #expect(feature.displayedGitCommits.map(\.shortHash) == ["11111111"])

        await feature.applyGitLogFilter("df520e3")
        #expect(feature.displayedGitCommits.map(\.shortHash) == ["df520e31"])
        #expect(feature.gitLogMatchedCommitHashes == [deepCommitOne.hash])
        #expect(feature.canLoadMoreDisplayedGitHistory)
        #expect(ops.lastRecordedFilter()?.textTerms == ["df520e3"])

        await feature.loadMoreGitHistory()
        #expect(feature.displayedGitCommits.map(\.shortHash) == ["df520e31", "df520e32"])
        #expect(!feature.canLoadMoreDisplayedGitHistory)

        await feature.applyGitLogFilter("")
        #expect(feature.gitFilteredCommits == nil)
        #expect(feature.displayedGitCommits.map(\.shortHash) == ["11111111"])
        #expect(feature.canLoadMoreDisplayedGitHistory)
    }
}

private final class FilteredHistoryMockOperations: GitOperations, @unchecked Sendable {
    let repositoryRoot: URL
    let unfilteredFirstPage: GitHistoryPage
    let filteredPages: [String?: GitHistoryPage]
    private let lock = NSLock()
    private var recordedFilter: GitHistoryFilter?

    init(
        repositoryRoot: URL,
        unfilteredFirstPage: GitHistoryPage,
        filteredPages: [String?: GitHistoryPage]
    ) {
        self.repositoryRoot = repositoryRoot
        self.unfilteredFirstPage = unfilteredFirstPage
        self.filteredPages = filteredPages
    }

    func lastRecordedFilter() -> GitHistoryFilter? {
        lock.lock()
        defer { lock.unlock() }
        return recordedFilter
    }

    var supportsFilteredHistoryPage: Bool { true }

    func run(arguments: [String], workingDirectory: String, input: String?) -> GitProcessResult {
        GitProcessResult(output: "", exitCode: 0)
    }

    func snapshot(at rootURL: URL) -> GitSnapshot? {
        GitSnapshot(repositoryRoot: repositoryRoot, branch: "main", changes: [])
    }

    func watchContext(at rootURL: URL) -> GitWatchContext? { nil }
    func worktrees(at rootURL: URL) -> [GitWorktree]? { [] }
    func diffDocument(at rootURL: URL, pathspecs: [String], staged: Bool, untracked: Bool, whitespace: GitDiffWhitespaceMode) -> DiffDocument? { nil }
    func diffPatch(at rootURL: URL, pathspecs: [String], staged: Bool, untracked: Bool, whitespace: GitDiffWhitespaceMode) -> String? { nil }
    func commitDiffDocument(at rootURL: URL, commit: String, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { nil }
    func comparisonDiffDocument(at rootURL: URL, reference: String, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { nil }
    func comparisonDiffDocument(at rootURL: URL, reference: GitReference, targetReference: GitReference?, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { nil }
    func applyPatch(_ patch: String, at rootURL: URL, mode: String) -> GitProcessResult? { nil }

    func history(at rootURL: URL, reference: GitReference?, limit: Int) -> GitHistorySnapshot? {
        GitHistorySnapshot(
            references: [GitReference(fullName: "refs/heads/main", shortName: "main", kind: .local, isCurrent: true, upstreamShortName: nil)],
            commits: unfilteredFirstPage.commits,
            hasMore: unfilteredFirstPage.hasMore
        )
    }

    func historyPage(
        at rootURL: URL,
        reference: GitReference?,
        cursor: String?,
        limit: Int,
        operationID: String
    ) -> GitHistoryPage? {
        unfilteredFirstPage
    }

    func historyPage(
        at rootURL: URL,
        reference: GitReference?,
        cursor: String?,
        limit: Int,
        filter: GitHistoryFilter?,
        operationID: String
    ) -> GitHistoryPage? {
        lock.lock()
        recordedFilter = filter
        lock.unlock()
        if let filter, !filter.isEmpty {
            return filteredPages[cursor]
        }
        return unfilteredFirstPage
    }

    func files(in commit: GitCommit, at rootURL: URL) -> [GitCommitFile]? { [] }
    func commit(at rootURL: URL, hash: String) -> GitCommit? { nil }
    func comparison(for reference: GitReference, at rootURL: URL) -> GitBranchComparison? { nil }
    func comparison(from reference: GitReference, to target: GitReference, at rootURL: URL) -> GitBranchComparison? { nil }
    func stashes(at rootURL: URL) -> [GitStash]? { [] }
    func blame(at rootURL: URL, relativePath: String) -> [GitBlameLine]? { [] }
    func stage(_ change: GitChange) -> GitProcessResult? { nil }
    func unstage(_ change: GitChange) -> GitProcessResult? { nil }
    func discard(_ change: GitChange) -> GitProcessResult? { nil }
    func discardAll(_ change: GitChange) -> GitProcessResult? { nil }
    func commit(at rootURL: URL, message: String, amend: Bool) -> GitProcessResult? { nil }
    func cherryPick(_ hash: String, at rootURL: URL) -> GitProcessResult? { nil }
    func revert(_ hash: String, at rootURL: URL) -> GitProcessResult? { nil }
    func resetCurrentBranch(to hash: String, mode: String, at rootURL: URL) -> GitProcessResult? { nil }
    func createBranch(named name: String, from reference: GitReference, checkout: Bool, at rootURL: URL) -> GitProcessResult? { nil }
    func createWorktree(named name: String, from reference: GitReference, revision: String?, at destination: URL, repositoryRoot: URL) -> GitProcessResult? { nil }
    func removeWorktree(_ worktree: GitWorktree, force: Bool, at rootURL: URL) -> GitProcessResult? { nil }
    func lockWorktree(_ worktree: GitWorktree, at rootURL: URL) -> GitProcessResult? { nil }
    func unlockWorktree(_ worktree: GitWorktree, at rootURL: URL) -> GitProcessResult? { nil }
    func repairWorktrees(at rootURL: URL) -> GitProcessResult? { nil }
    func pruneWorktrees(at rootURL: URL) -> GitProcessResult? { nil }
    func renameBranch(_ reference: GitReference, to name: String, at rootURL: URL) -> GitProcessResult? { nil }
    func deleteBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func mergeBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func rebaseCurrentBranch(onto reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func checkoutAndRebase(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func updateCurrentBranch(at rootURL: URL, strategy: GitPullStrategy) -> GitProcessResult? { nil }
    func pullRemoteReference(_ reference: GitReference, strategy: GitPullStrategy, at rootURL: URL) -> GitProcessResult? { nil }
    func pullPreflight(at rootURL: URL) -> GitPullPreflightState? { nil }
    func conflictMarkerPaths(at rootURL: URL) -> [String] { [] }
    func integrationPreflight(for target: GitIntegrationTarget, operation: GitIntegrationOperation, at rootURL: URL) -> GitIntegrationPreflightState? { nil }
    func fetch(at rootURL: URL) -> GitProcessResult? { nil }
    func checkout(_ reference: GitReference, at rootURL: URL, force: Bool, autoStash: Bool) -> GitProcessResult? { nil }
    func checkoutBlockingPaths(for reference: GitReference, at rootURL: URL) -> [String] { [] }
    func operationState(at rootURL: URL) -> GitOperationState? { nil }
    func continueOperation(at rootURL: URL) -> GitProcessResult? { nil }
    func abortOperation(at rootURL: URL) -> GitProcessResult? { nil }
    func skipOperationStep(at rootURL: URL) -> GitProcessResult? { nil }
    func checkoutRevision(_ revision: String, at rootURL: URL) -> GitProcessResult? { nil }
    func push(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func cloneRepository(from remote: String, to destination: URL) -> GitProcessResult? { nil }
    func stash(message: String, includeUntracked: Bool, at rootURL: URL) -> GitProcessResult? { nil }
    func applyStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func popStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func dropStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func stageAll(at rootURL: URL) -> GitProcessResult? { nil }
    func createTag(named name: String, at revision: String, message: String?, rootURL: URL) -> GitProcessResult? { nil }
    func deleteTag(named name: String, rootURL: URL) -> GitProcessResult? { nil }
}
