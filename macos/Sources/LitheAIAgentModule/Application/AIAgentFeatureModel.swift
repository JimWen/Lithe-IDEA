import Combine
import Foundation
import LitheCoreContracts

/// T3-Code-inspired multi-thread AI Agent feature model.
///
/// Owns per-workspace conversation threads, live streaming turns, prompt queueing
/// and steering, supervised approvals, pre-turn file checkpoints/revert, isolated
/// Git worktree threads, and inline working-tree diff review + commit/push.
@MainActor
public final class AIAgentFeatureModel: ObservableObject {
    @Published public private(set) var threads: [AIAgentThread] = []
    @Published public var selectedThreadID: UUID?
    @Published public var threadSearchQuery = ""
    @Published public var showArchivedThreads = false
    @Published public var isDiffPanelVisible = false
    @Published public private(set) var detectedCLIs: [AIAgentCLIDetection] = []
    @Published public private(set) var isDetectingCLIs = false
    @Published public private(set) var workingTreeDiff = AIAgentWorkingTreeDiff(rootPath: "")
    @Published public private(set) var isLoadingDiff = false
    @Published public private(set) var isPerformingGitAction = false
    @Published public private(set) var isGeneratingCommitMessage = false
    @Published public var composerDraft = ""
    @Published public var attachedContexts: [AIAgentContextAttachment] = []
    @Published public private(set) var statusBannerMessage: String?

    private let runner: AIAgentTurnRunner
    private let cliResolver: any AIAgentCLIResolving
    private let threadStore: any AIAgentThreadStoring
    private weak var host: (any AIAgentWorkspaceHost)?
    private var onBeginActiveRun: (@MainActor (UUID, @escaping @MainActor () async -> Void) -> (() -> Void))?

    private struct DeltaBufferKey: Hashable {
        let threadID: UUID
        let turnID: UUID
        let itemID: String
        let isReasoning: Bool
    }

    private struct BufferedDelta {
        var text: String
        var isReplacement: Bool
    }

    private var activeWorkspacePath: String?
    private var diffRefreshGeneration: UInt64 = 0
    private var runningTasksByThread: [UUID: Task<Void, Never>] = [:]
    private var activeProcessesByThread: [UUID: any AIAgentProcessSession] = [:]
    private var pendingApprovals: [UUID: CheckedContinuation<AIAgentApprovalDecision, Never>] = [:]
    private var alwaysAllowedKindsByThread: [UUID: Set<AIAgentApprovalKind>] = [:]
    private var activeCleanupHandlersByThread: [UUID: () -> Void] = [:]
    private var pendingTextDeltas: [DeltaBufferKey: BufferedDelta] = [:]
    private var pendingDeltaOrder: [DeltaBufferKey] = []
    private var deltaFlushTask: Task<Void, Never>?
    private var lastDeltaFlushUptime: TimeInterval = 0
    private static let deltaCoalesceInterval: TimeInterval = 0.04

    public init(
        runner: AIAgentTurnRunner,
        cliResolver: any AIAgentCLIResolving,
        threadStore: any AIAgentThreadStoring
    ) {
        self.runner = runner
        self.cliResolver = cliResolver
        self.threadStore = threadStore
    }

    public func configure(
        host: any AIAgentWorkspaceHost,
        onBeginActiveRun: (@MainActor (UUID, @escaping @MainActor () async -> Void) -> (() -> Void))? = nil
    ) {
        self.host = host
        self.onBeginActiveRun = onBeginActiveRun
        if let workspacePath = host.workspacePath, activeWorkspacePath != workspacePath {
            loadWorkspace(at: workspacePath)
        }
    }

    public var selectedThread: AIAgentThread? {
        guard let selectedThreadID else { return nil }
        return threads.first { $0.id == selectedThreadID }
    }

    public var filteredThreads: [AIAgentThread] {
        let query = threadSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return threads
            .filter { showArchivedThreads ? true : !$0.isArchived }
            .filter { thread in
                guard !query.isEmpty else { return true }
                return thread.title.lowercased().contains(query)
                    || (thread.worktreeBranch?.lowercased().contains(query) ?? false)
                    || thread.turns.contains { $0.prompt.lowercased().contains(query) }
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    public var isSelectedThreadRunning: Bool {
        selectedThread?.isRunning ?? false
    }

    public var hasAnyRunningTurn: Bool {
        !runningTasksByThread.isEmpty
    }

    public func detection(for backend: AIAgentBackendKind) -> AIAgentCLIDetection? {
        detectedCLIs.first { $0.backend == backend }
    }

    public func loadWorkspace(at workspacePath: String) {
        let normalized = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        if activeWorkspacePath == normalized, !threads.isEmpty {
            return
        }
        cancelAllActiveTurnsSnapshot()
        activeWorkspacePath = normalized
        let loaded = threadStore.loadThreads(for: normalized)
        if loaded.isEmpty {
            let initial = makeDefaultThread(workspacePath: normalized)
            threads = [initial]
            selectedThreadID = initial.id
            persistThreads()
        } else {
            threads = loaded.map(Self.sanitizingInterruptedTurns)
            selectedThreadID = threads.first(where: { !$0.isArchived })?.id ?? threads.first?.id
        }
        attachedContexts = []
        isDiffPanelVisible = false
        Task {
            await refreshCLIDetection()
            await refreshWorkingTreeDiff()
        }
    }

    public func resetWorkspace() {
        cancelAllActiveTurnsSnapshot()
        activeWorkspacePath = nil
        threads = []
        selectedThreadID = nil
        attachedContexts = []
        workingTreeDiff = AIAgentWorkingTreeDiff(rootPath: "")
        isDiffPanelVisible = false
        statusBannerMessage = nil
    }

    public func refreshCLIDetection() async {
        guard !isDetectingCLIs else { return }
        isDetectingCLIs = true
        defer { isDetectingCLIs = false }
        let settings = host?.agentSettings ?? .default
        detectedCLIs = await cliResolver.detectCLIs(settings: settings)
    }

    // MARK: - Thread Management

    @discardableResult
    public func createThread(
        backend: AIAgentBackendKind? = nil,
        model: String? = nil,
        permissionMode: AIAgentPermissionMode? = nil,
        worktree: AIAgentWorktreeInfo? = nil
    ) -> AIAgentThread? {
        guard let workspacePath = activeWorkspacePath ?? host?.workspacePath else { return nil }
        let settings = host?.agentSettings ?? .default
        let resolvedBackend = backend ?? settings.defaultBackend
        let normalized = AIAgentModelCatalog.normalize(
            model: model ?? settings.defaultModel(for: resolvedBackend),
            effort: settings.defaultReasoningEffort,
            backend: resolvedBackend
        )
        let thread = AIAgentThread(
            title: worktree.map { "Worktree · \($0.branchName)" } ?? "New Thread",
            workspacePath: workspacePath,
            worktreePath: worktree?.path,
            worktreeBranch: worktree?.branchName,
            backend: resolvedBackend,
            model: normalized.model,
            reasoningEffort: normalized.effort,
            permissionMode: permissionMode ?? settings.defaultPermissionMode
        )
        threads.insert(thread, at: 0)
        selectedThreadID = thread.id
        isDiffPanelVisible = false
        persistThreads()
        Task { await refreshWorkingTreeDiff() }
        return thread
    }

    public func createIsolatedWorktreeThread(branchName: String? = nil) async {
        guard let host, let workspacePath = activeWorkspacePath ?? host.workspacePath else { return }
        let cleanBranch: String
        if let branchName, !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cleanBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let stamp = Self.shortTimestamp()
            cleanBranch = "agent/\(stamp)"
        }
        isPerformingGitAction = true
        defer { isPerformingGitAction = false }
        do {
            let info = try await host.createIsolatedWorktree(branchName: cleanBranch, from: workspacePath)
            _ = createThread(worktree: info)
            statusBannerMessage = "Created isolated worktree on branch \(info.branchName)"
        } catch {
            host.notify(error.localizedDescription)
            statusBannerMessage = error.localizedDescription
        }
    }

    public func attachWorktreeToSelectedThread(branchName: String? = nil) async {
        guard let threadID = selectedThreadID else { return }
        await attachWorktree(to: threadID, branchName: branchName)
    }

    @discardableResult
    public func attachWorktree(to threadID: UUID, branchName: String? = nil) async -> Bool {
        guard let host,
              let expectedWorkspace = activeWorkspacePath,
              let initialThread = threads.first(where: { $0.id == threadID }) else { return false }
        guard initialThread.worktreePath == nil else {
            statusBannerMessage = "Thread is already isolated in \(initialThread.worktreeBranch ?? "worktree")."
            return true
        }
        let cleanBranch = (branchName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "agent/\(Self.shortTimestamp())"
        isPerformingGitAction = true
        defer { isPerformingGitAction = false }
        do {
            let info = try await host.createIsolatedWorktree(branchName: cleanBranch, from: initialThread.workspacePath)
            guard activeWorkspacePath == expectedWorkspace,
                  let resolvedIndex = threads.firstIndex(where: { $0.id == threadID }) else {
                // Workspace changed or thread was deleted while Git created the worktree.
                try? await host.removeIsolatedWorktree(path: info.path, from: initialThread.workspacePath)
                return false
            }
            threads[resolvedIndex].worktreePath = info.path
            threads[resolvedIndex].worktreeBranch = info.branchName
            threads[resolvedIndex].providerSessionID = nil
            threads[resolvedIndex].updatedAt = Date()
            persistThreads()
            statusBannerMessage = "Switched thread to isolated worktree \(info.branchName)"
            await refreshWorkingTreeDiff()
            return true
        } catch {
            host.notify(error.localizedDescription)
            return false
        }
    }

    public func removeWorktree(for threadID: UUID) async {
        guard let host,
              let expectedWorkspace = activeWorkspacePath,
              let initialThread = threads.first(where: { $0.id == threadID }),
              let worktreePath = initialThread.worktreePath else { return }

        let sharingThreads = threads.filter { $0.worktreePath == worktreePath }
        if let activeRunner = sharingThreads.first(where: { $0.isRunning || runningTasksByThread[$0.id] != nil }) {
            let message = "Cannot remove worktree while thread '\(activeRunner.title)' is still running in it."
            host.notify(message)
            statusBannerMessage = message
            return
        }

        isPerformingGitAction = true
        defer { isPerformingGitAction = false }
        do {
            try await host.removeIsolatedWorktree(path: worktreePath, from: initialThread.workspacePath)
            guard activeWorkspacePath == expectedWorkspace else { return }
            let now = Date()
            for idx in threads.indices where threads[idx].worktreePath == worktreePath {
                threads[idx].worktreePath = nil
                threads[idx].worktreeBranch = nil
                threads[idx].providerSessionID = nil
                threads[idx].updatedAt = now
            }
            persistThreads()
            statusBannerMessage = "Removed isolated worktree"
            await refreshWorkingTreeDiff()
        } catch {
            host.notify(error.localizedDescription)
        }
    }

    public func selectThread(_ id: UUID) {
        guard threads.contains(where: { $0.id == id }) else { return }
        selectedThreadID = id
        Task { await refreshWorkingTreeDiff() }
    }

    public func renameThread(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].title = trimmed
        threads[index].updatedAt = Date()
        persistThreads()
    }

    public func togglePinThread(_ id: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].isPinned.toggle()
        persistThreads()
    }

    public func toggleArchiveThread(_ id: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].isArchived.toggle()
        if threads[index].isArchived, selectedThreadID == id {
            selectedThreadID = threads.first(where: { !$0.isArchived && $0.id != id })?.id
        }
        persistThreads()
    }

    public func deleteThread(_ id: UUID) async {
        await stopTurn(for: id)
        threads.removeAll { $0.id == id }
        alwaysAllowedKindsByThread[id] = nil
        if selectedThreadID == id {
            selectedThreadID = threads.first(where: { !$0.isArchived })?.id ?? threads.first?.id
        }
        if threads.isEmpty, let workspacePath = activeWorkspacePath {
            let fresh = makeDefaultThread(workspacePath: workspacePath)
            threads = [fresh]
            selectedThreadID = fresh.id
        }
        persistThreads()
    }

    public func clearSelectedThreadHistory() async {
        guard let threadID = selectedThreadID,
              let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        await stopTurn(for: threadID)
        threads[index].turns.removeAll()
        threads[index].queuedPrompts.removeAll()
        threads[index].providerSessionID = nil
        threads[index].totalUsage = AIAgentTokenUsage()
        threads[index].title = threads[index].worktreeBranch.map { "Worktree · \($0)" } ?? "New Thread"
        threads[index].updatedAt = Date()
        persistThreads()
    }

    @discardableResult
    public func forkThread(_ id: UUID) -> AIAgentThread? {
        guard let source = threads.first(where: { $0.id == id }) else { return nil }
        let completedTurns = source.turns.filter { !$0.isInFlight }
        let baseTitle = source.title.hasSuffix(" (Fork)") ? source.title : "\(source.title) (Fork)"
        let forked = AIAgentThread(
            title: baseTitle,
            workspacePath: source.workspacePath,
            worktreePath: source.worktreePath,
            worktreeBranch: source.worktreeBranch,
            backend: source.backend,
            model: source.model,
            reasoningEffort: source.reasoningEffort,
            permissionMode: source.permissionMode,
            providerSessionID: nil,
            turns: completedTurns,
            totalUsage: source.totalUsage
        )
        threads.insert(forked, at: 0)
        selectedThreadID = forked.id
        isDiffPanelVisible = false
        statusBannerMessage = "Forked thread '\(source.title)'."
        persistThreads()
        return forked
    }

    public func exportThreadMarkdown(_ id: UUID) -> String {
        guard let thread = threads.first(where: { $0.id == id }) else { return "" }
        var lines: [String] = [
            "# \(thread.title)",
            "",
            "- Provider: \(thread.backend.title)\(thread.model.isEmpty ? "" : " (\(thread.model))")",
            "- Mode: \(thread.permissionMode.title)",
            "- Workspace: `\(thread.effectiveRootPath)`"
        ]
        if let branch = thread.worktreeBranch {
            lines.append("- Worktree Branch: `\(branch)`")
        }
        lines.append("")
        for (idx, turn) in thread.turns.enumerated() {
            lines.append("---")
            lines.append("")
            lines.append("## Turn \(idx + 1) · \(turn.permissionMode.title)")
            lines.append("")
            lines.append("### Prompt")
            lines.append("")
            lines.append(turn.prompt)
            lines.append("")
            let reply = turn.assistantResponseText
            if !reply.isEmpty {
                lines.append("### Response")
                lines.append("")
                lines.append(reply)
                lines.append("")
            }
            if !turn.changedFiles.isEmpty {
                lines.append("### Modified Files")
                lines.append("")
                for file in turn.changedFiles {
                    lines.append("- `[\(file.kind.badge)] \(file.path)` (+\(file.additions)/-\(file.deletions))")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    public func implementPlan(from turn: AIAgentTurn, inNewWorktree: Bool = false) {
        guard let threadID = selectedThreadID,
              let index = threads.firstIndex(where: { $0.id == threadID }),
              !threads[index].isRunning else { return }
        let planExcerpt = turn.assistantResponseText
        guard !planExcerpt.isEmpty else { return }

        updateSelectedThreadPermissionMode(.autoEdit)
        let clippedPlan = String(planExcerpt.prefix(16_000))
        let followUpPrompt = """
        Implement the approved plan below step by step, keeping changes minimal and verified with relevant builds or tests.

        <approved_plan>
        \(clippedPlan)
        </approved_plan>
        """
        if inNewWorktree && threads[index].worktreePath == nil {
            let expectedWorkspace = activeWorkspacePath
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isolated = await self.attachWorktree(to: threadID)
                guard self.activeWorkspacePath == expectedWorkspace,
                      self.runningTasksByThread[threadID] == nil,
                      self.threads.contains(where: { $0.id == threadID && !$0.isRunning }) else { return }
                if !isolated {
                    self.statusBannerMessage = "Continuing plan implementation in current workspace because worktree creation was unavailable."
                }
                self.startTurn(in: threadID, prompt: followUpPrompt, attachments: [])
            }
            return
        }
        startTurn(in: threadID, prompt: followUpPrompt, attachments: [])
    }

    public func retryTurn(_ turn: AIAgentTurn) {
        sendPrompt(turn.prompt, attachments: turn.attachments)
    }

    public func loadTurnIntoComposer(_ turn: AIAgentTurn) {
        composerDraft = turn.prompt
        attachedContexts = turn.attachments
    }

    // MARK: - Per-Thread Configuration

    public func updateSelectedThreadBackend(_ backend: AIAgentBackendKind) {
        guard let threadID = selectedThreadID,
              let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        guard threads[index].backend != backend else { return }
        threads[index].backend = backend
        threads[index].providerSessionID = nil
        let rawModel = host?.agentSettings.defaultModel(for: backend) ?? ""
        let normalized = AIAgentModelCatalog.normalize(
            model: rawModel,
            effort: threads[index].reasoningEffort,
            backend: backend
        )
        threads[index].model = normalized.model
        threads[index].reasoningEffort = normalized.effort
        threads[index].updatedAt = Date()
        persistThreads()
    }

    public func updateSelectedThreadModel(_ model: String) {
        guard let threadID = selectedThreadID,
              let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        let normalized = AIAgentModelCatalog.normalize(
            model: model,
            effort: threads[index].reasoningEffort,
            backend: threads[index].backend
        )
        threads[index].model = normalized.model
        threads[index].reasoningEffort = normalized.effort
        threads[index].updatedAt = Date()
        persistThreads()
    }

    public func updateSelectedThreadEffort(_ effort: AIAgentReasoningEffort) {
        guard let threadID = selectedThreadID,
              let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        let supported = AIAgentModelCatalog.supportedEfforts(
            for: threads[index].model,
            backend: threads[index].backend
        )
        threads[index].reasoningEffort = AIAgentModelCatalog.clampEffort(effort, supported: supported)
        threads[index].updatedAt = Date()
        persistThreads()
    }

    public func updateSelectedThreadPermissionMode(_ mode: AIAgentPermissionMode) {
        guard let threadID = selectedThreadID,
              let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].permissionMode = mode
        threads[index].updatedAt = Date()
        persistThreads()
    }

    // MARK: - Context Attachments

    public func addAttachment(_ attachment: AIAgentContextAttachment) {
        if !attachedContexts.contains(where: { $0.kind == attachment.kind }) {
            attachedContexts.append(attachment)
        }
    }

    public func removeAttachment(id: UUID) {
        attachedContexts.removeAll { $0.id == id }
    }

    // MARK: - Prompt Submission, Slash Commands, Queue & Steer

    public func submitComposerPrompt() {
        let prompt = composerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let attachments = attachedContexts
        composerDraft = ""
        attachedContexts = []
        sendPrompt(prompt, attachments: attachments)
    }

    public func sendPrompt(
        _ rawPrompt: String,
        attachments: [AIAgentContextAttachment] = []
    ) {
        let trimmed = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.hasPrefix("/") && handleSlashCommand(trimmed) {
            return
        }

        if selectedThreadID == nil, let created = createThread() {
            selectedThreadID = created.id
        }
        guard let threadID = selectedThreadID,
              let index = threads.firstIndex(where: { $0.id == threadID }) else { return }

        if threads[index].isRunning {
            threads[index].queuedPrompts.append(AIAgentQueuedPrompt(
                prompt: trimmed,
                attachments: attachments
            ))
            threads[index].updatedAt = Date()
            persistThreads()
            return
        }

        if let host,
           host.agentSettings.preferIsolatedWorktree,
           threads[index].worktreePath == nil,
           threads[index].turns.isEmpty,
           threads[index].permissionMode != .plan {
            let expectedWorkspace = activeWorkspacePath
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isolated = await self.attachWorktree(to: threadID)
                guard self.activeWorkspacePath == expectedWorkspace,
                      self.runningTasksByThread[threadID] == nil,
                      self.threads.contains(where: { $0.id == threadID && !$0.isRunning }) else { return }
                if !isolated {
                    self.statusBannerMessage = "Continuing in current workspace because isolated worktree creation was unavailable."
                }
                self.startTurn(in: threadID, prompt: trimmed, attachments: attachments)
            }
            return
        }

        startTurn(in: threadID, prompt: trimmed, attachments: attachments)
    }

    public func steerWithQueuedPrompt(id: UUID) {
        guard let threadID = selectedThreadID,
              let index = threads.firstIndex(where: { $0.id == threadID }),
              let qIndex = threads[index].queuedPrompts.firstIndex(where: { $0.id == id }) else {
            return
        }
        let queued = threads[index].queuedPrompts.remove(at: qIndex)
        persistThreads()
        Task {
            await stopTurn(for: threadID)
            startTurn(in: threadID, prompt: queued.prompt, attachments: queued.attachments)
        }
    }

    public func removeQueuedPrompt(id: UUID) {
        guard let threadID = selectedThreadID,
              let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].queuedPrompts.removeAll { $0.id == id }
        persistThreads()
    }

    public func stopActiveTurn() {
        guard let threadID = selectedThreadID else { return }
        Task { await stopTurn(for: threadID) }
    }

    public func stopTurn(for threadID: UUID) async {
        // Deny any approval waiting on this thread so the task unblocks immediately.
        if let index = threads.firstIndex(where: { $0.id == threadID }) {
            for tIdx in threads[index].turns.indices {
                for iIdx in threads[index].turns[tIdx].items.indices {
                    if let approval = threads[index].turns[tIdx].items[iIdx].approval,
                       approval.decision == nil {
                        threads[index].turns[tIdx].items[iIdx].approval?.decision = .deny
                        threads[index].turns[tIdx].items[iIdx].status = .denied
                        if let continuation = pendingApprovals.removeValue(forKey: approval.id) {
                            continuation.resume(returning: .deny)
                        }
                    }
                }
            }
        }

        flushPendingTextDeltas()
        runningTasksByThread[threadID]?.cancel()
        if let process = activeProcessesByThread.removeValue(forKey: threadID) {
            _ = await process.stopAndWait()
        }
        if let task = runningTasksByThread.removeValue(forKey: threadID) {
            await task.value
        }
        if let cleanup = activeCleanupHandlersByThread.removeValue(forKey: threadID) {
            cleanup()
        }
        if let index = threads.firstIndex(where: { $0.id == threadID }) {
            for tIdx in threads[index].turns.indices where threads[index].turns[tIdx].isInFlight {
                threads[index].turns[tIdx].status = .cancelled
                threads[index].turns[tIdx].completedAt = Date()
            }
            persistThreads()
        }
    }

    public func stopAllActiveTurns() async {
        let ids = Array(Set(runningTasksByThread.keys).union(activeProcessesByThread.keys))
        for id in ids {
            await stopTurn(for: id)
        }
        for (_, continuation) in pendingApprovals {
            continuation.resume(returning: .deny)
        }
        pendingApprovals.removeAll()
    }

    /// Synchronously detaches and cancels only the turns currently running,
    /// so a new turn started immediately after `loadWorkspace` is never killed
    /// by a deferred teardown task from the previous workspace.
    private func cancelAllActiveTurnsSnapshot() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        pendingTextDeltas.removeAll()
        pendingDeltaOrder.removeAll()
        let oldTasks = runningTasksByThread
        let oldProcesses = activeProcessesByThread
        let oldApprovals = pendingApprovals
        let oldCleanups = activeCleanupHandlersByThread

        runningTasksByThread.removeAll()
        activeProcessesByThread.removeAll()
        pendingApprovals.removeAll()
        activeCleanupHandlersByThread.removeAll()

        for (_, continuation) in oldApprovals {
            continuation.resume(returning: .deny)
        }
        for (_, task) in oldTasks {
            task.cancel()
        }
        for (_, cleanup) in oldCleanups {
            cleanup()
        }
        if !oldProcesses.isEmpty {
            let processesToStop = Array(oldProcesses.values)
            Task {
                for process in processesToStop {
                    _ = await process.stopAndWait()
                }
            }
        }
    }

    // MARK: - Approvals

    public func respondToApproval(requestID: UUID, decision: AIAgentApprovalDecision) {
        for tIndex in threads.indices {
            for turnIndex in threads[tIndex].turns.indices {
                for itemIndex in threads[tIndex].turns[turnIndex].items.indices {
                    if let approval = threads[tIndex].turns[turnIndex].items[itemIndex].approval,
                       approval.id == requestID {
                        threads[tIndex].turns[turnIndex].items[itemIndex].approval?.decision = decision
                        threads[tIndex].turns[turnIndex].items[itemIndex].status = decision == .deny ? .denied : .completed
                        if decision == .allowAlways && approval.cacheAlwaysAllowByKind {
                            alwaysAllowedKindsByThread[threads[tIndex].id, default: []].insert(approval.kind)
                        }
                        if threads[tIndex].turns[turnIndex].status == .waitingApproval {
                            threads[tIndex].turns[turnIndex].status = .running
                        }
                    }
                }
            }
        }
        if let continuation = pendingApprovals.removeValue(forKey: requestID) {
            continuation.resume(returning: decision)
        }
        persistThreads()
    }

    // MARK: - Checkpoints & Revert

    public func revertToCheckpoint(_ checkpoint: AIAgentCheckpoint) async {
        guard let host else { return }
        var restoredCount = 0
        var gitRestoreSucceeded = false
        var pathsTouchedByGitRestore: Set<String> = []

        if let gitTreeHash = checkpoint.gitTreeHash, !gitTreeHash.isEmpty {
            isPerformingGitAction = true
            let preRevertTree = await host.captureGitCheckpointTree(in: checkpoint.workingDirectoryPath)
            if let preRevertTree, preRevertTree != gitTreeHash {
                let pendingDiff = await host.diffGitTrees(
                    from: gitTreeHash,
                    to: preRevertTree,
                    in: checkpoint.workingDirectoryPath
                )
                pathsTouchedByGitRestore = Set(pendingDiff.map(\.path))
            }
            do {
                let gitCount = try await host.restoreGitCheckpointTree(
                    gitTreeHash,
                    in: checkpoint.workingDirectoryPath
                )
                restoredCount += gitCount
                gitRestoreSucceeded = true
            } catch {
                if checkpoint.fileSnapshots.isEmpty {
                    isPerformingGitAction = false
                    host.notify("Failed to revert checkpoint: \(error.localizedDescription)")
                    statusBannerMessage = error.localizedDescription
                    return
                }
            }
            isPerformingGitAction = false
        }

        // Always reconcile Direct API fileSnapshots even after a Git tree restore so
        // .gitignore'd edits and pre-existing unsaved editor buffer states are preserved.
        if !checkpoint.fileSnapshots.isEmpty {
            var snapshotReconciled = 0
            for snapshot in checkpoint.fileSnapshots {
                do {
                    if let previousContent = snapshot.previousContent {
                        let exists = host.fileExists(
                            relativePath: snapshot.relativePath,
                            rootPath: checkpoint.workingDirectoryPath
                        )
                        let currentContent = exists
                            ? (try? await host.readFile(
                                relativePath: snapshot.relativePath,
                                rootPath: checkpoint.workingDirectoryPath
                            ))
                            : nil
                        if currentContent != previousContent {
                            try await host.writeFile(
                                relativePath: snapshot.relativePath,
                                content: previousContent,
                                expectedSourceText: currentContent,
                                rootPath: checkpoint.workingDirectoryPath
                            )
                            snapshotReconciled += 1
                        }
                    } else if host.fileExists(relativePath: snapshot.relativePath, rootPath: checkpoint.workingDirectoryPath) {
                        try await host.deleteFile(
                            relativePath: snapshot.relativePath,
                            rootPath: checkpoint.workingDirectoryPath
                        )
                        snapshotReconciled += 1
                    }
                } catch {
                    host.notify("Failed to restore \(snapshot.relativePath): \(error.localizedDescription)")
                }
            }
            if !gitRestoreSucceeded {
                restoredCount += snapshotReconciled
            } else if restoredCount == 0 {
                restoredCount = snapshotReconciled
            }
        } else if !gitRestoreSucceeded {
            statusBannerMessage = "No file edits recorded in this checkpoint."
            return
        }

        // Reconcile pre-turn unsaved dirty buffers for any file whose disk state was
        // restored by Git so reverting a CLI turn restores disk to the pre-turn tree
        // while keeping the user's pre-existing unsaved editor edits intact in the buffer.
        if gitRestoreSucceeded && !checkpoint.preTurnDirtyBufferSnapshots.isEmpty {
            for dirtySnapshot in checkpoint.preTurnDirtyBufferSnapshots {
                guard pathsTouchedByGitRestore.contains(dirtySnapshot.relativePath),
                      let preTurnBufferText = dirtySnapshot.previousContent else {
                    continue
                }
                do {
                    let currentContent = try? await host.readFile(
                        relativePath: dirtySnapshot.relativePath,
                        rootPath: checkpoint.workingDirectoryPath
                    )
                    if currentContent != preTurnBufferText {
                        try await host.writeFile(
                            relativePath: dirtySnapshot.relativePath,
                            content: preTurnBufferText,
                            expectedSourceText: currentContent,
                            rootPath: checkpoint.workingDirectoryPath
                        )
                    }
                } catch {
                    host.notify("Failed to restore unsaved buffer \(dirtySnapshot.relativePath): \(error.localizedDescription)")
                }
            }
        }

        await host.refreshWorkspaceAndGit()
        await refreshWorkingTreeDiff()
        statusBannerMessage = restoredCount == 0
            ? "Workspace already matches this checkpoint."
            : "Reverted \(restoredCount) file\(restoredCount == 1 ? "" : "s") to checkpoint."
    }

    // MARK: - Diff Review & Git Actions

    public func discardWorkingTreeFile(_ relativePath: String) async {
        guard let host,
              let rootPath = selectedThread?.effectiveRootPath ?? activeWorkspacePath else { return }
        isPerformingGitAction = true
        defer { isPerformingGitAction = false }
        do {
            try await host.discardFileChange(relativePath: relativePath, in: rootPath)
            statusBannerMessage = "Discarded changes in \(relativePath)."
            await host.refreshWorkspaceAndGit()
            await refreshWorkingTreeDiff()
        } catch {
            host.notify(error.localizedDescription)
            statusBannerMessage = error.localizedDescription
        }
    }

    public func generateCommitMessageForWorkingTree() async -> String? {
        guard let host,
              let rootPath = selectedThread?.effectiveRootPath ?? activeWorkspacePath,
              !isGeneratingCommitMessage else { return nil }
        isGeneratingCommitMessage = true
        defer { isGeneratingCommitMessage = false }
        do {
            let message = try await host.generateCommitMessage(in: rootPath)
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            statusBannerMessage = "Generated commit message."
            return trimmed
        } catch {
            host.notify(error.localizedDescription)
            statusBannerMessage = error.localizedDescription
            return nil
        }
    }

    public func commitAndPushWorkingTreeChanges(message: String) async -> Bool {
        // Bind both commit and push to the same root captured at invocation time so
        // switching to another worktree thread mid-commit never pushes the wrong branch.
        guard let targetRoot = selectedThread?.effectiveRootPath ?? activeWorkspacePath else { return false }
        let committed = await commitWorkingTreeChanges(message: message, in: targetRoot)
        guard committed else { return false }
        await pushWorkingTreeBranch(in: targetRoot)
        return true
    }

    public func refreshWorkingTreeDiff() async {
        guard let host,
              let rootPath = selectedThread?.effectiveRootPath ?? activeWorkspacePath else { return }
        diffRefreshGeneration &+= 1
        let generation = diffRefreshGeneration
        let expectedWorkspace = activeWorkspacePath
        let expectedThreadID = selectedThreadID
        isLoadingDiff = true
        let diff = await host.workingTreeDiff(in: rootPath)
        guard diffRefreshGeneration == generation,
              activeWorkspacePath == expectedWorkspace,
              selectedThreadID == expectedThreadID,
              (selectedThread?.effectiveRootPath ?? activeWorkspacePath) == rootPath else {
            return
        }
        workingTreeDiff = diff
        isLoadingDiff = false
    }

    public func commitWorkingTreeChanges(message: String) async -> Bool {
        guard let rootPath = selectedThread?.effectiveRootPath ?? activeWorkspacePath else { return false }
        return await commitWorkingTreeChanges(message: message, in: rootPath)
    }

    private func commitWorkingTreeChanges(message: String, in rootPath: String) async -> Bool {
        guard let host else { return false }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        isPerformingGitAction = true
        defer { isPerformingGitAction = false }
        do {
            let result = try await host.commitChanges(message: trimmed, in: rootPath)
            statusBannerMessage = result
            await host.refreshWorkspaceAndGit()
            await refreshWorkingTreeDiff()
            return true
        } catch {
            host.notify(error.localizedDescription)
            statusBannerMessage = error.localizedDescription
            return false
        }
    }

    public func pushWorkingTreeBranch() async {
        guard let rootPath = selectedThread?.effectiveRootPath ?? activeWorkspacePath else { return }
        await pushWorkingTreeBranch(in: rootPath)
    }

    private func pushWorkingTreeBranch(in rootPath: String) async {
        guard let host else { return }
        isPerformingGitAction = true
        defer { isPerformingGitAction = false }
        do {
            let result = try await host.pushCurrentBranch(in: rootPath)
            statusBannerMessage = result
            await host.refreshWorkspaceAndGit()
            await refreshWorkingTreeDiff()
        } catch {
            host.notify(error.localizedDescription)
            statusBannerMessage = error.localizedDescription
        }
    }

    public func openFileFromTimeline(_ relativePath: String) {
        guard let host,
              let rootPath = selectedThread?.effectiveRootPath ?? activeWorkspacePath else { return }
        host.openFile(relativePath: relativePath, rootPath: rootPath)
    }

    public func openDiffFromTimeline(_ relativePath: String) {
        guard let host,
              let rootPath = selectedThread?.effectiveRootPath ?? activeWorkspacePath else { return }
        host.openDiff(relativePath: relativePath, rootPath: rootPath)
    }

    public func toggleItemCollapsed(turnID: UUID, itemID: String) {
        guard let threadID = selectedThreadID,
              let tIndex = threads.firstIndex(where: { $0.id == threadID }),
              let turnIndex = threads[tIndex].turns.firstIndex(where: { $0.id == turnID }),
              let itemIndex = threads[tIndex].turns[turnIndex].items.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        threads[tIndex].turns[turnIndex].items[itemIndex].isCollapsed.toggle()
    }

    // MARK: - Internal Turn Execution

    private func startTurn(
        in threadID: UUID,
        prompt: String,
        attachments: [AIAgentContextAttachment]
    ) {
        guard let host,
              let threadIndex = threads.firstIndex(where: { $0.id == threadID }) else { return }

        if threads[threadIndex].turns.isEmpty && threads[threadIndex].title == "New Thread" {
            threads[threadIndex].title = Self.deriveThreadTitle(from: prompt)
        }

        let turnID = UUID()
        let rootPath = threads[threadIndex].effectiveRootPath
        let preTurnDirtyBuffers = host.openDirtyFileSnapshots(in: rootPath)
        let checkpoint = AIAgentCheckpoint(
            turnID: turnID,
            label: "Before: \(Self.deriveThreadTitle(from: prompt))",
            workingDirectoryPath: rootPath,
            preTurnDirtyBufferSnapshots: preTurnDirtyBuffers
        )
        let turn = AIAgentTurn(
            id: turnID,
            prompt: prompt,
            attachments: attachments,
            permissionMode: threads[threadIndex].permissionMode,
            status: .running,
            checkpoint: checkpoint
        )
        threads[threadIndex].turns.append(turn)
        threads[threadIndex].updatedAt = Date()
        statusBannerMessage = nil
        persistThreads()

        let threadSnapshot = threads[threadIndex]
        if let onBeginActiveRun {
            activeCleanupHandlersByThread[threadID] = onBeginActiveRun(threadID) { [weak self] in
                await self?.stopTurn(for: threadID)
            }
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let preTurnDiff = await host.workingTreeDiff(in: rootPath)
            let preTurnSnapshotPaths = Set(preTurnDiff.files.map(\.path))
            let preTurnTreeHash = await host.captureGitCheckpointTree(in: rootPath)
            self.updateCheckpointPreTurnState(
                threadID: threadID,
                turnID: turnID,
                headHash: preTurnDiff.headHash,
                treeHash: preTurnTreeHash
            )

            let hooks = AIAgentTurnExecutionHooks(
                onEvent: { [weak self] event in
                    self?.applyStreamEvent(event, threadID: threadID, turnID: turnID)
                },
                onRequestApproval: { [weak self] request in
                    guard let self else { return .deny }
                    return await self.awaitApproval(request, threadID: threadID, turnID: turnID)
                },
                onRecordFileSnapshot: { [weak self] relativePath in
                    guard let self else { throw CancellationError() }
                    try await self.captureFileSnapshotIfNeeded(
                        relativePath: relativePath,
                        rootPath: rootPath,
                        threadID: threadID,
                        turnID: turnID
                    )
                },
                onRegisterProcess: { [weak self] process in
                    guard let self else { return }
                    if let process {
                        self.activeProcessesByThread[threadID] = process
                    } else {
                        self.activeProcessesByThread.removeValue(forKey: threadID)
                    }
                }
            )

            do {
                try await self.runner.runTurn(
                    thread: threadSnapshot,
                    prompt: prompt,
                    attachments: attachments,
                    host: host,
                    hooks: hooks
                )
                self.finishTurn(
                    threadID: threadID,
                    turnID: turnID,
                    status: .completed,
                    errorMessage: nil,
                    preTurnChangedPaths: preTurnSnapshotPaths,
                    preTurnTreeHash: preTurnTreeHash
                )
            } catch is CancellationError {
                self.finishTurn(
                    threadID: threadID,
                    turnID: turnID,
                    status: .cancelled,
                    errorMessage: nil,
                    preTurnChangedPaths: preTurnSnapshotPaths,
                    preTurnTreeHash: preTurnTreeHash
                )
            } catch {
                self.finishTurn(
                    threadID: threadID,
                    turnID: turnID,
                    status: .failed,
                    errorMessage: error.localizedDescription,
                    preTurnChangedPaths: preTurnSnapshotPaths,
                    preTurnTreeHash: preTurnTreeHash
                )
            }
        }

        runningTasksByThread[threadID] = task
    }

    private func finishTurn(
        threadID: UUID,
        turnID: UUID,
        status: AIAgentTurnStatus,
        errorMessage: String?,
        preTurnChangedPaths: Set<String>,
        preTurnTreeHash: String?
    ) {
        flushPendingTextDeltas()
        runningTasksByThread.removeValue(forKey: threadID)
        activeProcessesByThread.removeValue(forKey: threadID)
        if let cleanup = activeCleanupHandlersByThread.removeValue(forKey: threadID) {
            cleanup()
        }

        guard let tIndex = threads.firstIndex(where: { $0.id == threadID }),
              let turnIndex = threads[tIndex].turns.firstIndex(where: { $0.id == turnID }) else {
            return
        }

        var finalStatus = status
        if finalStatus == .completed,
           threads[tIndex].turns[turnIndex].items.contains(where: { $0.kind == .error }) {
            finalStatus = .failed
        }
        threads[tIndex].turns[turnIndex].status = finalStatus
        threads[tIndex].turns[turnIndex].completedAt = Date()
        if let errorMessage, !errorMessage.isEmpty {
            threads[tIndex].turns[turnIndex].errorMessage = errorMessage
            let alreadyReported = threads[tIndex].turns[turnIndex].items.last.map {
                $0.kind == .error && $0.content == errorMessage
            } ?? false
            if !alreadyReported {
                threads[tIndex].turns[turnIndex].items.append(AIAgentTimelineItem(
                    kind: .error,
                    title: "Error",
                    content: errorMessage,
                    status: .failed
                ))
            }
        }
        for iIdx in threads[tIndex].turns[turnIndex].items.indices {
            if threads[tIndex].turns[turnIndex].items[iIdx].status == .running {
                threads[tIndex].turns[turnIndex].items[iIdx].status = finalStatus == .completed ? .completed : .failed
            }
        }
        threads[tIndex].updatedAt = Date()
        persistThreads()

        let rootPath = threads[tIndex].effectiveRootPath
        let expectedWorkspace = activeWorkspacePath
        Task { @MainActor [weak self] in
            guard let self, let host = self.host else { return }
            await host.refreshWorkspaceAndGit()
            guard self.activeWorkspacePath == expectedWorkspace else { return }
            let postDiff = await host.workingTreeDiff(in: rootPath)
            let postTurnTreeHash = await host.captureGitCheckpointTree(in: rootPath)
            guard self.activeWorkspacePath == expectedWorkspace else { return }
            if self.selectedThreadID == threadID,
               self.selectedThread?.effectiveRootPath == rootPath {
                self.workingTreeDiff = postDiff
            }

            var exactTreeChanges: [AIAgentFileChangeSummary] = []
            if let preTurnTreeHash, let postTurnTreeHash, preTurnTreeHash != postTurnTreeHash {
                exactTreeChanges = await host.diffGitTrees(from: preTurnTreeHash, to: postTurnTreeHash, in: rootPath)
            }

            if let ti = self.threads.firstIndex(where: { $0.id == threadID }),
               let turnIdx = self.threads[ti].turns.firstIndex(where: { $0.id == turnID }) {
                self.threads[ti].turns[turnIdx].checkpoint?.gitPostTurnTreeHash = postTurnTreeHash
                let touchedFiles: [AIAgentFileChangeSummary]
                if !exactTreeChanges.isEmpty {
                    touchedFiles = exactTreeChanges
                } else {
                    touchedFiles = postDiff.files.filter { file in
                        !preTurnChangedPaths.contains(file.path)
                            || self.threads[ti].turns[turnIdx].changedFiles.contains(where: { $0.path == file.path })
                            || (self.threads[ti].turns[turnIdx].checkpoint?.fileSnapshots.contains(where: { $0.relativePath == file.path }) ?? false)
                    }
                }
                if !touchedFiles.isEmpty {
                    self.threads[ti].turns[turnIdx].changedFiles = touchedFiles
                    if host.agentSettings.autoOpenDiffOnChanges && self.selectedThreadID == threadID {
                        self.isDiffPanelVisible = true
                    }
                }
                self.persistThreads()
            }
            // Automatically dispatch next queued prompt ONLY if no newer turn started during refresh.
            if finalStatus == .completed,
               self.runningTasksByThread[threadID] == nil,
               let ti = self.threads.firstIndex(where: { $0.id == threadID }),
               !self.threads[ti].isRunning,
               !self.threads[ti].queuedPrompts.isEmpty {
                let next = self.threads[ti].queuedPrompts.removeFirst()
                self.persistThreads()
                self.startTurn(in: threadID, prompt: next.prompt, attachments: next.attachments)
            }
        }
    }

    private func applyStreamEvent(
        _ event: AIAgentStreamEvent,
        threadID: UUID,
        turnID: UUID
    ) {
        guard let tIndex = threads.firstIndex(where: { $0.id == threadID }),
              let turnIndex = threads[tIndex].turns.firstIndex(where: { $0.id == turnID }) else {
            return
        }

        switch event {
        case .assistantTextDelta(let itemID, let text, let isReplacement):
            enqueueTextDelta(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                text: text,
                isReplacement: isReplacement,
                isReasoning: false
            )
            return

        case .reasoningDelta(let itemID, let text, let isReplacement):
            enqueueTextDelta(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                text: text,
                isReplacement: isReplacement,
                isReasoning: true
            )
            return

        case .sessionEstablished(let sessionID):
            flushPendingTextDeltas()
            threads[tIndex].providerSessionID = sessionID

        case .commandUpdated(let itemID, let command, let output, let exitCode, let status):
            flushPendingTextDeltas()
            let boundedOutput = Self.clampOutput(output)
            if let existing = threads[tIndex].turns[turnIndex].items.firstIndex(where: { $0.id == itemID }) {
                if !command.isEmpty { threads[tIndex].turns[turnIndex].items[existing].title = command }
                threads[tIndex].turns[turnIndex].items[existing].output = boundedOutput
                threads[tIndex].turns[turnIndex].items[existing].exitCode = exitCode
                threads[tIndex].turns[turnIndex].items[existing].status = status
            } else {
                threads[tIndex].turns[turnIndex].items.append(AIAgentTimelineItem(
                    id: itemID,
                    kind: .commandExecution,
                    title: command,
                    output: boundedOutput,
                    status: status,
                    exitCode: exitCode,
                    isCollapsed: true
                ))
            }

        case .toolCallUpdated(let itemID, let name, let inputSummary, let output, let status):
            flushPendingTextDeltas()
            let boundedOutput = Self.clampOutput(output)
            if let existing = threads[tIndex].turns[turnIndex].items.firstIndex(where: { $0.id == itemID }) {
                threads[tIndex].turns[turnIndex].items[existing].title = name
                if !inputSummary.isEmpty { threads[tIndex].turns[turnIndex].items[existing].content = inputSummary }
                if !boundedOutput.isEmpty { threads[tIndex].turns[turnIndex].items[existing].output = boundedOutput }
                threads[tIndex].turns[turnIndex].items[existing].status = status
            } else {
                threads[tIndex].turns[turnIndex].items.append(AIAgentTimelineItem(
                    id: itemID,
                    kind: .toolCall,
                    title: name,
                    content: inputSummary,
                    output: boundedOutput,
                    status: status,
                    isCollapsed: true
                ))
            }

        case .fileChangesUpdated(let itemID, let changes, let status):
            flushPendingTextDeltas()
            if let existing = threads[tIndex].turns[turnIndex].items.firstIndex(where: { $0.id == itemID }) {
                threads[tIndex].turns[turnIndex].items[existing].fileChanges = changes
                threads[tIndex].turns[turnIndex].items[existing].status = status
            } else {
                threads[tIndex].turns[turnIndex].items.append(AIAgentTimelineItem(
                    id: itemID,
                    kind: .fileChanges,
                    title: "Changed Files",
                    status: status,
                    fileChanges: changes
                ))
            }
            for change in changes where !threads[tIndex].turns[turnIndex].changedFiles.contains(where: { $0.path == change.path }) {
                threads[tIndex].turns[turnIndex].changedFiles.append(change)
            }

        case .systemNotice(let notice):
            flushPendingTextDeltas()
            threads[tIndex].turns[turnIndex].items.append(AIAgentTimelineItem(
                kind: .systemNotice,
                title: "Notice",
                content: notice,
                status: .completed
            ))

        case .usage(let usage):
            flushPendingTextDeltas()
            threads[tIndex].turns[turnIndex].usage = usage
            threads[tIndex].totalUsage.add(usage)

        case .failed(let message):
            flushPendingTextDeltas()
            threads[tIndex].turns[turnIndex].errorMessage = message
            let alreadyReported = threads[tIndex].turns[turnIndex].items.last.map {
                $0.kind == .error && $0.content == message
            } ?? false
            if !alreadyReported {
                threads[tIndex].turns[turnIndex].items.append(AIAgentTimelineItem(
                    kind: .error,
                    title: "Error",
                    content: message,
                    status: .failed
                ))
            }
        }
    }

    private func enqueueTextDelta(
        threadID: UUID,
        turnID: UUID,
        itemID: String,
        text: String,
        isReplacement: Bool,
        isReasoning: Bool
    ) {
        let key = DeltaBufferKey(
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            isReasoning: isReasoning
        )
        if var existing = pendingTextDeltas[key] {
            if isReplacement {
                existing.text = text
                existing.isReplacement = true
            } else {
                existing.text.append(text)
            }
            pendingTextDeltas[key] = existing
        } else {
            pendingTextDeltas[key] = BufferedDelta(text: text, isReplacement: isReplacement)
            pendingDeltaOrder.append(key)
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDeltaFlushUptime >= Self.deltaCoalesceInterval {
            flushPendingTextDeltas()
            return
        }
        guard deltaFlushTask == nil else { return }
        let delayNanos = UInt64(Self.deltaCoalesceInterval * 1_000_000_000)
        deltaFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled else { return }
            self?.flushPendingTextDeltas()
        }
    }

    private func flushPendingTextDeltas() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        guard !pendingDeltaOrder.isEmpty else { return }
        let order = pendingDeltaOrder
        let buffered = pendingTextDeltas
        pendingDeltaOrder.removeAll(keepingCapacity: true)
        pendingTextDeltas.removeAll(keepingCapacity: true)
        lastDeltaFlushUptime = ProcessInfo.processInfo.systemUptime

        for key in order {
            guard let delta = buffered[key],
                  let tIndex = threads.firstIndex(where: { $0.id == key.threadID }),
                  let turnIndex = threads[tIndex].turns.firstIndex(where: { $0.id == key.turnID }) else {
                continue
            }
            if let existing = threads[tIndex].turns[turnIndex].items.firstIndex(where: { $0.id == key.itemID }) {
                if delta.isReplacement {
                    threads[tIndex].turns[turnIndex].items[existing].content = delta.text
                } else {
                    threads[tIndex].turns[turnIndex].items[existing].content.append(delta.text)
                }
            } else if key.isReasoning {
                threads[tIndex].turns[turnIndex].items.append(AIAgentTimelineItem(
                    id: key.itemID,
                    kind: .reasoning,
                    title: "Thinking",
                    content: delta.text,
                    status: .running,
                    isCollapsed: true
                ))
            } else {
                threads[tIndex].turns[turnIndex].items.append(AIAgentTimelineItem(
                    id: key.itemID,
                    kind: .assistantText,
                    content: delta.text,
                    status: .running
                ))
            }
        }
    }

    private func awaitApproval(
        _ request: AIAgentApprovalRequest,
        threadID: UUID,
        turnID: UUID
    ) async -> AIAgentApprovalDecision {
        flushPendingTextDeltas()
        if request.cacheAlwaysAllowByKind,
           alwaysAllowedKindsByThread[threadID]?.contains(request.kind) == true {
            return .allowAlways
        }
        guard let tIndex = threads.firstIndex(where: { $0.id == threadID }),
              let turnIndex = threads[tIndex].turns.firstIndex(where: { $0.id == turnID }) else {
            return .deny
        }

        threads[tIndex].turns[turnIndex].status = .waitingApproval
        threads[tIndex].turns[turnIndex].items.append(AIAgentTimelineItem(
            id: "approval-\(request.id.uuidString)",
            kind: .approval,
            title: request.title,
            content: request.detail,
            status: .waitingApproval,
            approval: request
        ))

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingApprovals[request.id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let pending = self.pendingApprovals.removeValue(forKey: request.id) else {
                    return
                }
                pending.resume(returning: .deny)
            }
        }
    }

    private func captureFileSnapshotIfNeeded(
        relativePath: String,
        rootPath: String,
        threadID: UUID,
        turnID: UUID
    ) async throws {
        guard let host,
              let tIndex = threads.firstIndex(where: { $0.id == threadID }),
              let turnIndex = threads[tIndex].turns.firstIndex(where: { $0.id == turnID }),
              let checkpoint = threads[tIndex].turns[turnIndex].checkpoint else {
            return
        }
        if checkpoint.fileSnapshots.contains(where: { $0.relativePath == relativePath }) {
            return
        }
        let existingContent: String?
        if host.fileExists(relativePath: relativePath, rootPath: rootPath) {
            // Propagate read errors rather than misclassifying an unreadable existing file as absent.
            existingContent = try await host.readFile(relativePath: relativePath, rootPath: rootPath)
        } else {
            existingContent = nil
        }
        guard let reIdx = threads.firstIndex(where: { $0.id == threadID }),
              let reTurnIdx = threads[reIdx].turns.firstIndex(where: { $0.id == turnID }),
              var latestCheckpoint = threads[reIdx].turns[reTurnIdx].checkpoint else {
            return
        }
        if !latestCheckpoint.fileSnapshots.contains(where: { $0.relativePath == relativePath }) {
            latestCheckpoint.fileSnapshots.append(AIAgentFileSnapshot(
                relativePath: relativePath,
                previousContent: existingContent
            ))
            threads[reIdx].turns[reTurnIdx].checkpoint = latestCheckpoint
        }
    }

    private func updateCheckpointPreTurnState(
        threadID: UUID,
        turnID: UUID,
        headHash: String?,
        treeHash: String?
    ) {
        guard let tIndex = threads.firstIndex(where: { $0.id == threadID }),
              let turnIndex = threads[tIndex].turns.firstIndex(where: { $0.id == turnID }) else { return }
        threads[tIndex].turns[turnIndex].checkpoint?.gitHeadHash = headHash
        threads[tIndex].turns[turnIndex].checkpoint?.gitTreeHash = treeHash
    }

    // MARK: - Slash Commands

    private func handleSlashCommand(_ raw: String) -> Bool {
        let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return false }
        let command = String(first).lowercased()
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        switch command {
        case "/plan":
            updateSelectedThreadPermissionMode(.plan)
            statusBannerMessage = "Switched to Plan mode (read-only)."
            return true
        case "/supervised":
            updateSelectedThreadPermissionMode(.supervised)
            statusBannerMessage = "Switched to Supervised mode."
            return true
        case "/auto":
            updateSelectedThreadPermissionMode(.autoEdit)
            statusBannerMessage = "Switched to Auto-Edit mode."
            return true
        case "/diff":
            isDiffPanelVisible.toggle()
            if isDiffPanelVisible { Task { await refreshWorkingTreeDiff() } }
            return true
        case "/fork":
            if let threadID = selectedThreadID {
                _ = forkThread(threadID)
            }
            return true
        case "/new":
            _ = createThread()
            return true
        case "/clear":
            Task { await clearSelectedThreadHistory() }
            return true
        case "/model":
            if !argument.isEmpty {
                updateSelectedThreadModel(argument)
                statusBannerMessage = "Thread model set to \(argument)."
            } else {
                updateSelectedThreadModel("")
                statusBannerMessage = "Reset thread model to backend default."
            }
            return true
        case "/worktree":
            Task { await attachWorktreeToSelectedThread(branchName: argument.isEmpty ? nil : argument) }
            return true
        case "/revert":
            if let latestCheckpoint = selectedThread?.turns.reversed().first(where: { $0.canRevertCheckpoint })?.checkpoint {
                Task { await revertToCheckpoint(latestCheckpoint) }
            } else {
                statusBannerMessage = "No revertible file checkpoint in this thread."
            }
            return true
        case "/review":
            let reviewPrompt = argument.isEmpty
                ? "Review the current uncommitted Git changes in this repository. Focus on correctness, edge cases, concurrency, and missing tests."
                : "Review the current uncommitted Git changes focusing on: \(argument)"
            sendPrompt(reviewPrompt, attachments: attachedContexts)
            return true
        default:
            return false
        }
    }

    // MARK: - Helpers

    private func makeDefaultThread(workspacePath: String) -> AIAgentThread {
        let settings = host?.agentSettings ?? .default
        let normalized = AIAgentModelCatalog.normalize(
            model: settings.defaultModel(for: settings.defaultBackend),
            effort: settings.defaultReasoningEffort,
            backend: settings.defaultBackend
        )
        return AIAgentThread(
            title: "New Thread",
            workspacePath: workspacePath,
            backend: settings.defaultBackend,
            model: normalized.model,
            reasoningEffort: normalized.effort,
            permissionMode: settings.defaultPermissionMode
        )
    }

    private func persistThreads() {
        guard let activeWorkspacePath else { return }
        // Bound persisted history to 50 most recently updated threads.
        let bounded = Array(threads.sorted { $0.updatedAt > $1.updatedAt }.prefix(50))
        threadStore.saveThreads(bounded, for: activeWorkspacePath)
    }

    private static func sanitizingInterruptedTurns(_ thread: AIAgentThread) -> AIAgentThread {
        var copy = thread
        let normalized = AIAgentModelCatalog.normalize(
            model: copy.model,
            effort: copy.reasoningEffort,
            backend: copy.backend
        )
        copy.model = normalized.model
        copy.reasoningEffort = normalized.effort
        for index in copy.turns.indices where copy.turns[index].isInFlight {
            copy.turns[index].status = .cancelled
            copy.turns[index].completedAt = copy.turns[index].completedAt ?? Date()
        }
        return copy
    }

    private static func deriveThreadTitle(from prompt: String) -> String {
        let collapsed = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 48 { return collapsed }
        return String(collapsed.prefix(47)) + "…"
    }

    private static func shortTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmm"
        return formatter.string(from: Date())
    }

    private static let maxTimelineOutputCharacters = 65_536

    private static func clampOutput(_ output: String) -> String {
        guard output.count > maxTimelineOutputCharacters else { return output }
        return String(output.prefix(maxTimelineOutputCharacters)) + "\n… [output truncated]"
    }
}
