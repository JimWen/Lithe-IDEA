import LitheAIAgentModule
import LitheCoreContracts
import SwiftUI

struct AIAgentToolWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let feature = model.aiAgentFeatureIfActive {
                AIAgentPanelView(feature: feature)
            } else {
                VStack(spacing: 0) {
                    LitheToolWindowHeader(
                        title: "AI Agent",
                        systemImage: "sparkles",
                        onMinimize: { model.isAIAgentVisible = false }
                    ) {
                        Button {
                            model.showSettings(category: .ai)
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .litheIconButton()
                        .help("AI Agent Settings")
                    }
                    Spacer()
                    if model.isAIAgentActivating {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Starting AI Agent…")
                                .font(LitheTheme.smallFont)
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                    } else if let error = model.aiAgentActivationError {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 22))
                                .foregroundStyle(LitheTheme.warning)
                            Text(error)
                                .font(LitheTheme.smallFont)
                                .foregroundStyle(LitheTheme.secondaryText)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                            Button("Retry") {
                                Task { await model.activateAIAgentModule() }
                            }
                            .buttonStyle(LitheSecondaryButtonStyle())
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .task { await model.activateAIAgentModule() }
                    }
                    Spacer()
                }
            }
        }
        .litheWorkbenchSurface(LitheTheme.sidebar)
        .accessibilityIdentifier("ai-agent-tool-window")
    }
}

private struct AIAgentPanelView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: AIAgentFeatureModel
    @State private var isThreadDrawerPresented = false
    @State private var isNewWorktreeSheetPresented = false
    @State private var newWorktreeBranchDraft = ""
    @State private var renamingThreadID: UUID?
    @State private var renameDraft = ""

    private var activeThread: AIAgentThread? { feature.selectedThread }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            contextStrip
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if let banner = feature.statusBannerMessage {
                statusBanner(banner)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }

            if feature.isDiffPanelVisible {
                AIAgentDiffReviewPanel(feature: feature)
            } else {
                AIAgentTimelineView(feature: feature)
            }

            if let queued = activeThread?.queuedPrompts, !queued.isEmpty {
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                queuedPromptsBar(queued)
            }

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            AIAgentComposerView(feature: feature)
        }
        .sheet(isPresented: $isNewWorktreeSheetPresented) {
            newWorktreeDialog
        }
        .task(id: model.workspaceURL?.standardizedFileURL.path) {
            if let path = model.workspaceURL?.standardizedFileURL.path {
                feature.loadWorkspace(at: path)
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Button {
                isThreadDrawerPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    statusDot(for: activeThread)
                    Text(activeThread?.title ?? "AI Agent")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(LitheTheme.raised.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .lithePointer()
            .help("Switch or manage AI Agent threads")
            .popover(isPresented: $isThreadDrawerPresented, arrowEdge: .bottom) {
                threadDrawerPopover
            }

            Spacer(minLength: 4)

            Button {
                _ = feature.createThread()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .litheIconButton()
            .help("New Thread")

            diffToggleButton

            Button {
                model.showSettings(category: .ai)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .litheIconButton()
            .help("AI Agent Settings")

            Button {
                model.isAIAgentVisible = false
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .litheIconButton()
            .help("Hide AI Agent")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(LitheTheme.toolHeader)
    }

    private var diffToggleButton: some View {
        let count = feature.workingTreeDiff.files.count
        let adds = feature.workingTreeDiff.totalAdditions
        let dels = feature.workingTreeDiff.totalDeletions
        return Button {
            feature.isDiffPanelVisible.toggle()
            if feature.isDiffPanelVisible {
                Task { await feature.refreshWorkingTreeDiff() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    if adds > 0 {
                        Text("+\(adds)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LitheTheme.success)
                    }
                    if dels > 0 {
                        Text("-\(dels)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LitheTheme.error)
                    }
                }
            }
            .foregroundStyle(feature.isDiffPanelVisible ? LitheTheme.accent : LitheTheme.secondaryText)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(
                feature.isDiffPanelVisible
                    ? LitheTheme.accent.opacity(0.14)
                    : LitheTheme.raised.opacity(0.55)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .lithePointer()
        .help("Toggle Diff Review & Commit")
    }

    private var contextStrip: some View {
        HStack(spacing: 6) {
            Menu {
                if let branch = activeThread?.worktreeBranch {
                    Text("Isolated worktree: \(branch)")
                    Button("Open Worktree in New Tab/Window") {
                        if let path = activeThread?.worktreePath {
                            model.openProject(URL(fileURLWithPath: path, isDirectory: true))
                        }
                    }
                    Button("Remove Worktree & Return to Workspace", role: .destructive) {
                        if let id = activeThread?.id {
                            Task { await feature.removeWorktree(for: id) }
                        }
                    }
                } else {
                    Button("Isolate Thread in New Git Worktree…") {
                        newWorktreeBranchDraft = ""
                        isNewWorktreeSheetPresented = true
                    }
                    Button("New Isolated Worktree Thread") {
                        Task { await feature.createIsolatedWorktreeThread() }
                    }
                }
                Divider()
                Button("Refresh Git Diff") {
                    Task { await feature.refreshWorkingTreeDiff() }
                }
                Button("Clear Thread History") {
                    Task { await feature.clearSelectedThreadHistory() }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: activeThread?.worktreeBranch != nil ? "arrow.triangle.branch" : "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(activeThread?.worktreeBranch != nil ? LitheTheme.accent : LitheTheme.secondaryText)
                    Text(activeThread?.worktreeBranch ?? (feature.workingTreeDiff.branchName.isEmpty ? model.projectName : feature.workingTreeDiff.branchName))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    if activeThread?.worktreeBranch != nil {
                        Text("WT")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(LitheTheme.accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(LitheTheme.accent.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .lithePointer()

            Spacer(minLength: 4)

            if let usage = activeThread?.totalUsage, usage.totalTokens > 0 {
                HStack(spacing: 4) {
                    Text(Self.formatTokenCount(usage.totalTokens))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LitheTheme.tertiaryText)
                    if let cost = usage.costUSD, cost > 0 {
                        Text(String(format: "$%.3f", cost))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                }
            }

            if let sessionID = activeThread?.providerSessionID, !sessionID.isEmpty {
                Text("#\(sessionID.prefix(6))")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .help("Provider session: \(sessionID)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(LitheTheme.sidebar)
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.accent)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(2)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(LitheTheme.accent.opacity(0.08))
    }

    private func queuedPromptsBar(_ queued: [AIAgentQueuedPrompt]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 10))
                    .foregroundStyle(LitheTheme.warning)
                Text("Queued follow-ups (\(queued.count))")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
            }
            ForEach(queued) { item in
                HStack(spacing: 6) {
                    Text(item.prompt)
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Button("Steer") {
                        feature.steerWithQueuedPrompt(id: item.id)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(LitheTheme.accent)
                    .lithePointer()
                    .help("Interrupt current turn and run this prompt immediately")

                    Button {
                        feature.removeQueuedPrompt(id: item.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(LitheTheme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(LitheTheme.raised.opacity(0.45))
    }

    // MARK: - Thread Drawer Popover

    private var threadDrawerPopover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.tertiaryText)
                TextField("Search threads…", text: $feature.threadSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !feature.threadSearchQuery.isEmpty {
                    Button {
                        feature.threadSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(LitheTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.inputBorder, lineWidth: 1))
            .padding(10)

            HStack(spacing: 6) {
                Button {
                    _ = feature.createThread()
                    isThreadDrawerPresented = false
                } label: {
                    Label("New Thread", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LitheSecondaryButtonStyle())

                Button {
                    isThreadDrawerPresented = false
                    Task { await feature.createIsolatedWorktreeThread() }
                } label: {
                    Label("Worktree", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LitheSecondaryButtonStyle())
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(feature.filteredThreads) { thread in
                        threadRow(thread)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 300)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            HStack {
                Toggle("Show archived", isOn: $feature.showArchivedThreads)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                Text("\(feature.threads.count) threads")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
        .frame(width: 310)
        .background(LitheTheme.raised)
    }

    private func threadRow(_ thread: AIAgentThread) -> some View {
        let isSelected = thread.id == feature.selectedThreadID
        return HStack(spacing: 7) {
            statusDot(for: thread)
            VStack(alignment: .leading, spacing: 2) {
                if renamingThreadID == thread.id {
                    TextField("Thread title", text: $renameDraft, onCommit: {
                        feature.renameThread(thread.id, to: renameDraft)
                        renamingThreadID = nil
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                } else {
                    HStack(spacing: 4) {
                        if thread.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(LitheTheme.accent)
                        }
                        Text(thread.title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(LitheTheme.primaryText)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text(thread.backend.shortTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LitheTheme.secondaryText)
                    if let wt = thread.worktreeBranch {
                        Label(wt, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LitheTheme.accent)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("\(thread.turns.count) turns")
                        .font(.system(size: 10))
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? LitheTheme.subtleSelection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            feature.selectThread(thread.id)
            isThreadDrawerPresented = false
        }
        .contextMenu {
            Button(thread.isPinned ? "Unpin" : "Pin") {
                feature.togglePinThread(thread.id)
            }
            Button("Rename…") {
                renameDraft = thread.title
                renamingThreadID = thread.id
            }
            Button(thread.isArchived ? "Unarchive" : "Archive") {
                feature.toggleArchiveThread(thread.id)
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await feature.deleteThread(thread.id) }
            }
        }
    }

    private var newWorktreeDialog: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Isolate Thread in Git Worktree")
                .font(.system(size: 14, weight: .semibold))
            Text("Create a sibling Git worktree branch so the agent can edit and run tests without touching your current checkout.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("Branch name (optional, e.g. agent/fix-auth)", text: $newWorktreeBranchDraft)
                .litheSettingsTextField()
            HStack {
                Spacer()
                Button("Cancel") {
                    isNewWorktreeSheetPresented = false
                }
                .buttonStyle(LitheSecondaryButtonStyle())
                Button("Create Worktree") {
                    let branch = newWorktreeBranchDraft
                    isNewWorktreeSheetPresented = false
                    Task { await feature.attachWorktreeToSelectedThread(branchName: branch) }
                }
                .buttonStyle(LithePrimaryButtonStyle(
                    backgroundColor: LitheTheme.settingsPrimaryAction,
                    restingOpacity: 1
                ))
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(LitheTheme.settingsSurface)
    }

    @ViewBuilder
    private func statusDot(for thread: AIAgentThread?) -> some View {
        let color: Color = {
            guard let thread else { return LitheTheme.tertiaryText }
            if thread.hasPendingApproval { return LitheTheme.warning }
            if thread.isRunning { return LitheTheme.accent }
            if thread.turns.last?.status == .failed { return LitheTheme.error }
            if !thread.turns.isEmpty { return LitheTheme.success }
            return LitheTheme.tertiaryText
        }()
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    private static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM tok", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fk tok", Double(count) / 1_000.0)
        }
        return "\(count) tok"
    }
}
