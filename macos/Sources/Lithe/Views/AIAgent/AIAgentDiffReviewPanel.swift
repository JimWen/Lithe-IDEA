import LitheAIAgentModule
import LitheCoreContracts
import SwiftUI

/// T3-Code-inspired inline Diff Review + Commit/Push panel inside the AI Agent sidebar.
struct AIAgentDiffReviewPanel: View {
    @ObservedObject var feature: AIAgentFeatureModel
    @State private var expandedFilePaths: Set<String> = []
    @State private var commitMessageDraft = ""

    private var diff: AIAgentWorkingTreeDiff { feature.workingTreeDiff }

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
                        ForEach(diff.files) { file in
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
            TextField("Commit message for \(diff.branchName.isEmpty ? "changes" : diff.branchName)…", text: $commitMessageDraft)
                .litheSettingsTextField()

            HStack(spacing: 6) {
                Button {
                    let message = commitMessageDraft
                    Task {
                        if await feature.commitWorkingTreeChanges(message: message) {
                            commitMessageDraft = ""
                        }
                    }
                } label: {
                    Label("Commit All", systemImage: "checkmark.circle")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(LithePrimaryButtonStyle(
                    backgroundColor: LitheTheme.settingsPrimaryAction,
                    restingOpacity: 1
                ))
                .disabled(
                    feature.isPerformingGitAction
                        || commitMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                Button {
                    Task { await feature.pushWorkingTreeBranch() }
                } label: {
                    Label("Push", systemImage: "arrow.up.circle")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(feature.isPerformingGitAction)

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
