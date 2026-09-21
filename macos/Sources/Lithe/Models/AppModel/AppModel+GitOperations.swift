import Foundation
import LitheGitModule

extension AppModel {
    func selectGitRepository(_ root: URL) async {
        guard let feature = await activateGitModule() else { return }
        await feature.selectRepository(root)
    }

    func showGitDirectoryDiff(for directoryURL: URL) async {
        activeDocumentID = nil
        guard let feature = await activateGitModule() else { return }
        await feature.showDirectoryDiff(at: directoryURL)
    }

    func loadGitLineChanges(for fileURL: URL) async {
        guard let feature = await activateGitModule() else { return }
        await feature.loadLineChanges(for: fileURL)
    }

    func showGitLineChange(_ marker: GitLineChangeMarker, for fileURL: URL) async {
        guard let feature = await activateGitModule() else { return }
        await feature.showLineChange(marker, for: fileURL)
    }

    func stageGitLineChange(_ marker: GitLineChangeMarker, for fileURL: URL) async {
        guard let feature = await activateGitModule() else { return }
        await feature.stageLineChange(marker, for: fileURL)
    }

    func unstageGitLineChange(_ marker: GitLineChangeMarker, for fileURL: URL) async {
        guard let feature = await activateGitModule() else { return }
        await feature.unstageLineChange(marker, for: fileURL)
    }

    func requestDiscardGitLineChange(_ marker: GitLineChangeMarker, for fileURL: URL) async {
        guard let feature = await activateGitModule() else { return }
        feature.requestDiscardLineChange(marker, for: fileURL)
    }

    func stashWorkingTree(message: String, includeUntracked: Bool) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.stashWorkingTree(message: message, includeUntracked: includeUntracked)
    }

    func shelveWorkingTree(message: String) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.shelveWorkingTree(message: message)
    }

    func applyStash(_ stash: GitStash, pop: Bool = false) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.applyStash(stash, pop: pop)
    }

    func requestConflictRollback(path: String, resume: GitConflictResume) {
        gitFeatureIfActive?.requestConflictRollback(path: path, resume: resume)
    }

    func confirmConflictRollback(_ request: GitConflictRollbackRequest) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.confirmConflictRollback(request)
    }

    func cancelConflictRollback() {
        gitFeatureIfActive?.cancelConflictRollback()
    }

    func showGitConflictDiff(path: String) {
        selectedSidebar = .changes
        gitFeatureIfActive?.clearGitConflictFilter()
        Task { [weak self] in
            guard let gitFeature = await self?.activateGitModule() else { return }
            await gitFeature.selectConflictPath(path)
        }
    }

    func showGitConflictFiles(_ paths: [String]) {
        selectedSidebar = .changes
        gitFeatureIfActive?.setGitConflictFilter(paths)
        if let first = paths.first {
            Task { [weak self] in
                guard let gitFeature = await self?.activateGitModule() else { return }
                await gitFeature.selectConflictPath(first)
            }
        }
    }

    func clearGitConflictFilter() {
        gitFeatureIfActive?.clearGitConflictFilter()
    }

    func showStashRestoreConflictFiles() {
        selectedSidebar = .changes
        gitFeatureIfActive?.showStashRestoreConflictFiles()
    }

    func showStashRestoreConflictStash() {
        selectedSidebar = .changes
        gitFeatureIfActive?.showStashRestoreConflictStash()
    }

    func dismissStashRestoreConflictNotice() {
        gitFeatureIfActive?.dismissStashRestoreConflictNotice()
    }

    func showStashRestoreConflictNotice() {
        gitFeatureIfActive?.showStashRestoreConflictNotice()
    }

    func dropStash(_ stash: GitStash) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.dropStash(stash)
    }

    func applyShelf(_ shelf: GitShelfEntry) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.applyShelf(shelf)
    }

    func dropShelf(_ shelf: GitShelfEntry) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.dropShelf(shelf)
    }

    func selectChange(_ change: GitChange) {
        activeDocumentID = nil
        Task { [weak self] in
            guard let gitFeature = await self?.activateGitModule() else { return }
            await gitFeature.selectChange(change)
        }
    }

    func reloadSelectedChangeDiff(whitespace: GitDiffWhitespaceMode) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.reloadSelectedChangeDiff(whitespace: whitespace)
    }

    func refreshGit() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.refreshGit()
    }

    func refreshGitWorktrees() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.refreshWorktrees()
    }

    func inspectGitWorktree(_ worktree: GitWorktree) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.inspectWorktree(worktree)
    }

    func loadMoreGitWorktreeHistory(_ worktree: GitWorktree) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.loadMoreWorktreeHistory(for: worktree)
    }

    func createGitWorktree(
        named name: String,
        from reference: GitReference,
        revision: String? = nil,
        at destination: URL
    ) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.createWorktree(named: name, from: reference, revision: revision, at: destination)
    }

    func removeGitWorktree(_ worktree: GitWorktree, force: Bool) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.removeWorktree(worktree, force: force)
    }

    func setGitWorktreeLocked(_ worktree: GitWorktree, locked: Bool) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.setWorktreeLocked(worktree, locked: locked)
    }

    func pruneGitWorktrees() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.pruneWorktrees()
    }

    func repairGitWorktrees() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.repairWorktrees()
    }

    func chooseGitWorktreeParentDirectory() -> URL? {
        platformUI.chooseDirectory(title: "Choose Worktree Parent", prompt: "Choose")
    }

    func stageSelectedChange() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.stageSelectedChange()
    }

    func unstageSelectedChange() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.unstageSelectedChange()
    }

    func stageDiffHunk(_ hunk: DiffHunk, in change: GitChange) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.stageDiffHunk(hunk, in: change)
    }

    func unstageDiffHunk(_ hunk: DiffHunk, in change: GitChange) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.unstageDiffHunk(hunk, in: change)
    }

    func requestDiscardHunk(_ hunk: DiffHunk, in change: GitChange) {
        gitFeatureIfActive?.requestDiscardHunk(hunk, in: change)
    }

    func confirmDiscardHunk(_ request: DiffHunkRequest) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.confirmDiscardHunk(request)
    }

    func cancelDiscardHunk() {
        gitFeatureIfActive?.cancelDiscardHunk()
    }

    func requestDiscardSelectedChange() {
        gitFeatureIfActive?.requestDiscardSelectedChange()
    }

    func requestDiscardChange(_ change: GitChange) {
        gitFeatureIfActive?.requestDiscardChange(change)
    }

    func confirmDiscardChange(_ change: GitChange) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.confirmDiscardChange(change)
    }

    func cancelDiscardChange() {
        gitFeatureIfActive?.cancelDiscardChange()
    }

    func checkoutReference(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.checkoutReference(reference)
    }

    func resolveCheckoutConflict(
        _ request: GitCheckoutConflictRequest,
        strategy: GitCheckoutConflictStrategy
    ) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.resolveCheckoutConflict(request, strategy: strategy)
    }

    func checkoutRevision(_ rawRevision: String) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.checkoutRevision(rawRevision)
    }

    func cherryPick(_ commit: GitCommit) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.cherryPick(commit)
    }

    func revert(_ commit: GitCommit) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.revert(commit)
    }

    func resetCurrentBranch(to commit: GitCommit) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.resetCurrentBranch(to: commit)
    }

    func pushBranch(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.pushBranch(reference)
    }

    func toggleStaging(_ change: GitChange) {
        guard let gitFeature = gitFeatureIfActive else { return }
        guard let staged = gitFeature.beginToggleStaging(change) else { return }
        Task { await gitFeature.finishToggleStaging(change, staged: staged) }
    }

    func setStaging(_ changes: [GitChange], staged: Bool) {
        guard let gitFeature = gitFeatureIfActive else { return }
        let pendingChanges = gitFeature.beginSetStaging(changes, staged: staged)
        Task { await gitFeature.finishSetStaging(pendingChanges, staged: staged) }
    }

    func stageAllChanges() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.stageAllChanges()
    }

    func toggleGitLog() async {
        isGitLogVisible.toggle()
        if isGitLogVisible {
            isTestsVisible = false
            isTerminalVisible = false
            isReferencesVisible = false
            isProblemsVisible = false
            isRunVisible = false
            isDebugVisible = false
        }
        if isGitLogVisible && gitCommits.isEmpty {
            if selectedGitReference == nil {
                await showAllGitReferences()
            } else {
                await refreshGitHistory()
            }
        } else if !isGitLogVisible {
            gitFeatureIfActive?.cancelGitHistoryLoading()
        }
    }

    func closeGitLog() {
        isGitLogVisible = false
        gitFeatureIfActive?.cancelGitHistoryLoading()
    }

    func selectGitReference(_ reference: GitReference?) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.selectGitReference(reference)
    }

    func showAllGitReferences() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.showAllGitReferences()
    }

    func refreshGitHistory() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.refreshGitHistory()
    }

    func loadMoreGitHistory() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.loadMoreGitHistory()
    }

    func selectGitCommit(_ commit: GitCommit) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.selectGitCommit(commit)
    }

    func applyGitLogFilter(_ query: String) async {
        await applyGitLogFilter(GitLogQuery.parse(query))
    }

    func applyGitLogFilter(_ query: GitLogQuery) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.applyGitLogFilter(query)
    }

    func showGitCommitDiff(for file: GitCommitFile) {
        activeDocumentID = nil
        Task { [weak self] in
            guard let gitFeature = await self?.activateGitModule() else { return }
            await gitFeature.showGitCommitDiff(for: file)
        }
    }

    func closeGitCommitDiff() {
        gitFeatureIfActive?.closeGitCommitDiff()
    }

    func showGitCommit(_ hash: String) async {
        guard let gitFeature = await activateGitModule(),
              gitFeature.gitRepositoryRoot != nil,
              !hash.allSatisfy({ $0 == "0" }) else { return }
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isRunVisible = false
        isDebugVisible = false
        isTestsVisible = false
        isGitLogVisible = true
        await gitFeature.showGitCommit(hash)
    }

    func showComparisonWithWorkingTree(for reference: GitReference) async {
        activeDocumentID = nil
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.showComparisonWithWorkingTree(for: reference)
    }

    func showComparison(from reference: GitReference, to target: GitReference) async {
        activeDocumentID = nil
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.showComparison(from: reference, to: target)
    }

    func selectBranchComparisonFile(_ file: GitBranchComparisonFile) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.selectBranchComparisonFile(file)
    }

    func closeBranchComparison() {
        gitFeatureIfActive?.closeBranchComparison()
    }

    func createBranch(
        named rawName: String,
        from reference: GitReference,
        checkout: Bool
    ) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.createBranch(named: rawName, from: reference, checkout: checkout)
    }

    func renameBranch(_ reference: GitReference, to rawName: String) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.renameBranch(reference, to: rawName)
    }

    func deleteBranch(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.deleteBranch(reference)
    }

    func restoreRecentlyDeletedBranch() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.restoreRecentlyDeletedBranch()
    }

    func dismissDeletedBranchBanner() {
        gitFeatureIfActive?.dismissDeletedBranchBanner()
    }

    /// Returns nil on success, otherwise the error message a tag dialog
    /// should show where the user typed.
    @discardableResult
    func createTag(at commit: GitCommit, name: String, message: String) async -> String? {
        guard let gitFeature = await activateGitModule() else { return "No Git repository is open" }
        return await gitFeature.createTag(at: commit, name: name, message: message)
    }

    func deleteTag(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.deleteTag(reference)
    }

    func restoreRecentlyDeletedTag() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.restoreRecentlyDeletedTag()
    }

    func dismissDeletedTagBanner() {
        gitFeatureIfActive?.dismissDeletedTagBanner()
    }

    func mergeBranch(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.mergeBranch(reference)
    }

    func continueGitOperation() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.continueGitOperation()
    }

    func resolvePullStrategy(_ strategy: GitPullStrategy) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.resolvePullStrategy(strategy)
    }

    func cancelPullStrategy() {
        gitFeatureIfActive?.cancelPullStrategy()
    }

    func resolveIntegrationConflict(_ request: GitIntegrationConflictRequest) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.resolveIntegrationConflict(request)
    }

    func cancelIntegrationConflict() {
        gitFeatureIfActive?.cancelIntegrationConflict()
    }

    func abortGitOperation() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.abortGitOperation()
    }

    func skipGitOperationStep() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.skipGitOperationStep()
    }

    func rebaseCurrentBranch(onto reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.rebaseCurrentBranch(onto: reference)
    }

    func checkoutAndRebase(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.checkoutAndRebase(reference)
    }

    func pullRemoteReference(_ reference: GitReference, strategy: GitPullStrategy) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.pullRemoteReference(reference, strategy: strategy)
    }

    func updateCurrentBranch(_ reference: GitReference) async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.updateCurrentBranch(reference)
    }

    func fetchGit() async {
        guard let gitFeature = await activateGitModule() else { return }
        await gitFeature.fetchGit()
    }
}
