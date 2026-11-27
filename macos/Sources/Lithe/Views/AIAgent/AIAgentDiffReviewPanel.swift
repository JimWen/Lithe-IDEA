import LitheAIAgentModule
import LitheCoreContracts
import SwiftUI

/// T3-Code-inspired inline Diff Review + Commit/Push panel inside the AI Agent sidebar.
struct AIAgentDiffReviewPanel: View {
    @ObservedObject var feature: AIAgentFeatureModel
    @State private var expandedFilePaths: Set<String> = []
    @State private var commitMessageDraft = ""
    @State private var fileFilterQuery = ""
    @State private var pendingDiscardPath: String?

    private var diff: AIAgentWorkingTreeDiff { feature.workingTreeDiff }

    private var filteredFiles: [AIAgentFileChangeSummary] {
        let query = fileFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return diff.files }
        return diff.files.filter { $0.path.lowercased().contains(query) }
    }

    private var areAllExpanded: Bool {
        !filteredFiles.isEmpty && filteredFiles.allSatisfy { expandedFilePaths.contains($0.path) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    feature.isDiffPanelVisible = false
                } label: {
                    Label("Back to Chat", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.accent)
                .lithePointer()

                Spacer()

                if !diff.files.isEmpty {
                    Text("\(diff.files.count) files")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text("+\(diff.totalAdditions)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LitheTheme.success)
                    Text("-\(diff.totalDeletions)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LitheTheme.error)

                    Button {
                        if areAllExpanded {
                            expandedFilePaths.removeAll()
                        } else {
                            expandedFilePaths = Set(filteredFiles.map(\.path))
                        }
                    } label: {
                        Image(systemName: areAllExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                            .font(.system(size: 10.5))
                    }
                    .litheIconButton()
                    .help(areAllExpanded ? "Collapse all diffs" : "Expand all diffs")
                }

                Button {
                    Task { await feature.refreshWorkingTreeDiff() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .litheIconButton()
                .disabled(feature.isLoadingDiff)
                .help("Refresh Diff")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(LitheTheme.raised.opacity(0.5))

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if diff.files.count > 3 || !fileFilterQuery.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.tertiaryText)
                    TextField("Filter changed files…", text: $fileFilterQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                    if !fileFilterQuery.isEmpty {
                        Button {
                            fileFilterQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(LitheTheme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(LitheTheme.inputBackground.opacity(0.6))
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }

            if feature.isLoadingDiff && diff.files.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading working-tree diff…")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diff.files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(LitheTheme.success)
                    Text("Working tree is clean")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text("Changes made by the agent will appear here for review, commit, or revert.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !diff.branchName.isEmpty {
                    Rectangle().fill(LitheTheme.divider).frame(height: 1)
                    cleanBranchPushBar
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredFiles) { file in
                            diffFileCard(file)
                        }
                    }
                    .padding(10)
                }
                .litheScrollViewChrome(alwaysShowVertical: false, usesCompactScrollers: true)

                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                commitAndPushBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if expandedFilePaths.isEmpty, let first = diff.files.first?.path {
                expandedFilePaths.insert(first)
            }
        }
        .confirmationDialog(
            "Discard changes in this file?",
            isPresented: Binding(
                get: { pendingDiscardPath != nil },
                set: { if !$0 { pendingDiscardPath = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                guard let path = pendingDiscardPath else { return }
                pendingDiscardPath = nil
                Task { await feature.discardWorkingTreeFile(path) }
            }
            Button("Cancel", role: .cancel) {
                pendingDiscardPath = nil
            }
        } message: {
            Text(pendingDiscardPath ?? "")
        }
    }

    private func diffFileCard(_ file: AIAgentFileChangeSummary) -> some View {
        let isExpanded = expandedFilePaths.contains(file.path)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    if isExpanded {
                        expandedFilePaths.remove(file.path)
                    } else {
                        expandedFilePaths.insert(file.path)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LitheTheme.tertiaryText)
                        Text(file.kind.badge)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(badgeColor(file.kind))
                            .frame(width: 14)
                        Text(file.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LitheTheme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if file.additions > 0 {
                            Text("+\(file.additions)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(LitheTheme.success)
                        }
                        if file.deletions > 0 {
                            Text("-\(file.deletions)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(LitheTheme.error)
                        }
                    }
                }
                .buttonStyle(.plain)
                .lithePointer()

                Button {
                    feature.openDiffFromTimeline(file.path)
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 10.5))
                }
                .litheIconButton()
                .help("Open full diff in editor")

                Button {
                    pendingDiscardPath = file.path
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10))
                }
                .litheIconButton()
                .disabled(feature.isPerformingGitAction)
                .help("Discard changes in this file")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if isExpanded {
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                if file.diffText.isEmpty {
                    Text(file.kind == .added ? "New untracked file — click the split icon to open in editor." : "Binary or empty textual diff.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .padding(8)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 1) {
                            let lines = file.diffText.split(separator: "\n", omittingEmptySubsequences: false).prefix(160)
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, rawLine in
                                let line = String(rawLine)
                                Text(line)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(diffLineForeground(line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .background(diffLineBackground(line))
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .background(LitheTheme.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.divider, lineWidth: 1))
    }

    private var cleanBranchPushBar: some View {
        HStack(spacing: 8) {
            Label(diff.branchName, systemImage: "arrow.triangle.branch")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
            if diff.aheadCount > 0 || diff.behindCount > 0 {
                Text("↑\(diff.aheadCount) ↓\(diff.behindCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(diff.aheadCount > 0 ? LitheTheme.accent : LitheTheme.tertiaryText)
            }
            Spacer()
            Button {
                Task { await feature.pushWorkingTreeBranch() }
            } label: {
                Label("Push", systemImage: "arrow.up.circle")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(LitheSecondaryButtonStyle())
            .disabled(feature.isPerformingGitAction)
        }
        .padding(10)
        .background(LitheTheme.raised.opacity(0.4))
    }

    private var commitAndPushBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Commit message for \(diff.branchName.isEmpty ? "changes" : diff.branchName)…", text: $commitMessageDraft)
                    .litheSettingsTextField()

                Button {
                    Task {
                        if let generated = await feature.generateCommitMessageForWorkingTree() {
                            commitMessageDraft = generated
                        }
                    }
                } label: {
                    if feature.isGeneratingCommitMessage {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11.5))
                    }
                }
                .litheIconButton()
                .disabled(feature.isGeneratingCommitMessage || feature.isPerformingGitAction)
                .help("Generate commit message")
            }

            let isMessageEmpty = commitMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            HStack(spacing: 6) {
                Button {
                    let message = commitMessageDraft
                    Task {
                        if await feature.commitWorkingTreeChanges(message: message) {
                            commitMessageDraft = ""
                        }
                    }
                } label: {
                    Label("Commit", systemImage: "checkmark.circle")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(LithePrimaryButtonStyle(
                    backgroundColor: LitheTheme.settingsPrimaryAction,
                    restingOpacity: 1
                ))
                .disabled(feature.isPerformingGitAction || isMessageEmpty)

                Button {
                    let message = commitMessageDraft
                    Task {
                        if await feature.commitAndPushWorkingTreeChanges(message: message) {
                            commitMessageDraft = ""
                        }
                    }
                } label: {
                    Label("Commit & Push", systemImage: "arrow.up.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(feature.isPerformingGitAction || isMessageEmpty)

                Button {
                    Task { await feature.pushWorkingTreeBranch() }
                } label: {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 12))
                }
                .litheIconButton()
                .disabled(feature.isPerformingGitAction)
                .help("Push current branch")

                Spacer()
            }
        }
        .padding(10)
        .background(LitheTheme.raised.opacity(0.4))
    }

    private func badgeColor(_ kind: AIAgentFileChangeKind) -> Color {
        switch kind {
        case .added: LitheTheme.success
        case .modified: LitheTheme.warning
        case .deleted: LitheTheme.error
        case .renamed: LitheTheme.accent
        }
    }

    private func diffLineForeground(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return LitheTheme.tertiaryText
        }
        if line.hasPrefix("@@") { return LitheTheme.accent }
        if line.hasPrefix("+") { return LitheTheme.success }
        if line.hasPrefix("-") { return LitheTheme.error }
        return LitheTheme.secondaryText
    }

    private func diffLineBackground(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return LitheTheme.success.opacity(0.12)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return LitheTheme.error.opacity(0.12)
        }
        if line.hasPrefix("@@") {
            return LitheTheme.accent.opacity(0.08)
        }
        return Color.clear
    }
}
