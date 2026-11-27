import AppKit
import LitheAIAgentModule
import LitheCoreContracts
import SwiftUI

struct AIAgentTimelineView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: AIAgentFeatureModel
    @State private var pendingRevertCheckpoint: AIAgentCheckpoint?

    private var turns: [AIAgentTurn] {
        feature.selectedThread?.turns ?? []
    }

    var body: some View {
        Group {
            if turns.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(turns) { turn in
                                AIAgentTurnCardView(
                                    turn: turn,
                                    feature: feature,
                                    onRequestRevert: { checkpoint in
                                        pendingRevertCheckpoint = checkpoint
                                    }
                                )
                                .id(turn.id)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("timeline-bottom")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                    }
                    .litheScrollViewChrome(alwaysShowVertical: false, usesCompactScrollers: true)
                    .onChange(of: turns.count) { _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("timeline-bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: turns.last?.items.count) { _ in
                        proxy.scrollTo("timeline-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "Revert files to this checkpoint?",
            isPresented: Binding(
                get: { pendingRevertCheckpoint != nil },
                set: { if !$0 { pendingRevertCheckpoint = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revert Files", role: .destructive) {
                guard let checkpoint = pendingRevertCheckpoint else { return }
                pendingRevertCheckpoint = nil
                Task { await feature.revertToCheckpoint(checkpoint) }
            }
            Button("Cancel", role: .cancel) {
                pendingRevertCheckpoint = nil
            }
        } message: {
            Text(pendingRevertCheckpoint?.label ?? "")
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(LitheTheme.accent)
                            .frame(width: 28, height: 28)
                            .background(LitheTheme.accent.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 7))

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Lithe AI Agent")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(LitheTheme.primaryText)
                            Text("Multi-provider coding agent with diff review & worktrees")
                                .font(.system(size: 11))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                    }
                }

                // Backend readiness strip (Codex / Claude / Direct API)
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROVIDERS")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(LitheTheme.tertiaryText)
                    ForEach(AIAgentBackendKind.allCases) { backend in
                        let detection = feature.detection(for: backend)
                        let isSelected = feature.selectedThread?.backend == backend
                        Button {
                            feature.updateSelectedThreadBackend(backend)
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(detection?.isAvailable == true ? LitheTheme.success : LitheTheme.warning)
                                    .frame(width: 7, height: 7)
                                Text(backend.title)
                                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                                    .foregroundStyle(LitheTheme.primaryText)
                                Spacer(minLength: 4)
                                Text(detection?.statusDetail ?? "Checking…")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(LitheTheme.accent)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(isSelected ? LitheTheme.subtleSelection : LitheTheme.raised.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isSelected ? LitheTheme.accent.opacity(0.5) : LitheTheme.divider, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .lithePointer()
                    }
                }

                // Starter prompts
                VStack(alignment: .leading, spacing: 6) {
                    Text("QUICK START")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(LitheTheme.tertiaryText)

                    starterChip(
                        title: "Explain project architecture",
                        prompt: "Summarize the architecture, key modules, and entry points of this project.",
                        icon: "map"
                    )
                    starterChip(
                        title: "Review local Git changes",
                        prompt: "/review",
                        icon: "eye"
                    )
                    starterChip(
                        title: "Run tests and diagnose failures",
                        prompt: "Run the project's test suite and diagnose any failing tests or warnings.",
                        icon: "checkmark.seal"
                    )
                    starterChip(
                        title: "Switch to Plan mode & design a feature",
                        prompt: "/plan",
                        icon: "list.bullet.rectangle"
                    )
                }
            }
            .padding(14)
        }
    }

    private func starterChip(title: String, prompt: String, icon: String) -> some View {
        Button {
            feature.sendPrompt(prompt, attachments: feature.attachedContexts)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.accent)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(LitheTheme.raised.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .lithePointer()
    }
}

private struct AIAgentTurnCardView: View {
    let turn: AIAgentTurn
    @ObservedObject var feature: AIAgentFeatureModel
    let onRequestRevert: (AIAgentCheckpoint) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // User prompt bubble
            VStack(alignment: .leading, spacing: 5) {
                if !turn.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(turn.attachments) { attachment in
                                HStack(spacing: 3) {
                                    Image(systemName: attachment.imageFilePath != nil ? "photo" : "doc.text")
                                        .font(.system(size: 9))
                                    Text(attachment.displayLabel)
                                        .font(.system(size: 10, design: .monospaced))
                                }
                                .foregroundStyle(LitheTheme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(LitheTheme.accent.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(turn.prompt)
                        .font(.system(size: 12.5))
                        .foregroundStyle(LitheTheme.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if turn.permissionMode == .plan {
                        Text("PLAN")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(LitheTheme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(LitheTheme.accent.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .padding(10)
            .background(LitheTheme.raised.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(LitheTheme.panelBorder, lineWidth: 1))

            // Agent timeline items
            ForEach(turn.items) { item in
                timelineItemView(item)
            }

            // Live running indicator with elapsed timer
            if turn.status == .running {
                TimelineView(.periodic(from: turn.startedAt, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(turn.startedAt)))
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Working…")
                            .font(.system(size: 11))
                            .foregroundStyle(LitheTheme.secondaryText)
                        Text(Self.formatElapsed(elapsed))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                    .padding(.leading, 4)
                }
            }

            // T3-Code Plan Proposal action bar on completed Plan turns
            if turn.isCompletedPlanProposal && !feature.isSelectedThreadRunning {
                planProposalActionBar
            }

            // Changed files summary bar
            if !turn.changedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.system(size: 10))
                            .foregroundStyle(LitheTheme.secondaryText)
                        Text("Modified files (\(turn.changedFiles.count))")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(LitheTheme.secondaryText)
                        Spacer()
                        Button("Review Diff") {
                            feature.isDiffPanelVisible = true
                            Task { await feature.refreshWorkingTreeDiff() }
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(LitheTheme.accent)
                        .lithePointer()
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(turn.changedFiles) { file in
                                Button {
                                    feature.openFileFromTimeline(file.path)
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(file.kind.badge)
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundStyle(badgeColor(file.kind))
                                        Text((file.path as NSString).lastPathComponent)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(LitheTheme.primaryText)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(LitheTheme.inputBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(LitheTheme.divider, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .lithePointer()
                                .help(file.path)
                            }
                        }
                    }
                }
                .padding(8)
                .background(LitheTheme.raised.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Turn footer: status, usage, checkpoint revert, copy
            if !turn.isInFlight {
                turnFooter
            }
        }
    }

    @ViewBuilder
    private func timelineItemView(_ item: AIAgentTimelineItem) -> some View {
        switch item.kind {
        case .assistantText:
            AIAgentMarkdownBlockView(text: item.content)

        case .reasoning:
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    feature.toggleItemCollapsed(turnID: turn.id, itemID: item.id)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Image(systemName: "brain")
                            .font(.system(size: 10.5))
                        Text("Thinking")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(LitheTheme.tertiaryText)
                }
                .buttonStyle(.plain)
                .lithePointer()

                if !item.isCollapsed {
                    Text(item.content)
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LitheTheme.inputBackground.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

        case .commandExecution:
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    feature.toggleItemCollapsed(turnID: turn.id, itemID: item.id)
                } label: {
                    HStack(spacing: 6) {
                        statusIcon(item.status)
                        Text("$ \(item.title)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LitheTheme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let code = item.exitCode {
                            Text("exit \(code)")
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(code == 0 ? LitheTheme.success : LitheTheme.error)
                        }
                        Image(systemName: item.isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .lithePointer()

                if !item.isCollapsed && !item.output.isEmpty {
                    Rectangle().fill(LitheTheme.divider).frame(height: 1)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(item.output)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            }
            .background(LitheTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.divider, lineWidth: 1))

        case .toolCall:
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    feature.toggleItemCollapsed(turnID: turn.id, itemID: item.id)
                } label: {
                    HStack(spacing: 6) {
                        statusIcon(item.status)
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(LitheTheme.primaryText)
                        if !item.content.isEmpty {
                            Text(item.content)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        if !item.output.isEmpty {
                            Image(systemName: item.isCollapsed ? "chevron.right" : "chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(LitheTheme.tertiaryText)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .lithePointer()

                if !item.isCollapsed && !item.output.isEmpty {
                    Rectangle().fill(LitheTheme.divider).frame(height: 1)
                    Text(String(item.output.prefix(2000)))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(LitheTheme.raised.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.divider, lineWidth: 1))

        case .fileChanges:
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.accent)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(item.fileChanges) { change in
                            Button {
                                feature.openFileFromTimeline(change.path)
                            } label: {
                                HStack(spacing: 3) {
                                    Text(change.kind.badge)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(badgeColor(change.kind))
                                    Text((change.path as NSString).lastPathComponent)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(LitheTheme.primaryText)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(LitheTheme.inputBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .lithePointer()
                            .help(change.path)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(LitheTheme.raised.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .approval:
            if let approval = item.approval {
                approvalCard(approval)
            }

        case .error:
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.error)
                Text(item.content)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.primaryText)
                    .textSelection(.enabled)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LitheTheme.error.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.error.opacity(0.35), lineWidth: 1))

        case .systemNotice:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(item.content)
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
    }

    private func approvalCard(_ request: AIAgentApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.warning)
                Text(request.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
                if let decision = request.decision {
                    Text(decision == .deny ? "Denied" : "Approved")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(decision == .deny ? LitheTheme.error : LitheTheme.success)
                }
            }
            Text(request.detail)
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)

            if let command = request.command, !command.isEmpty {
                Text("$ \(command)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LitheTheme.primaryText)
                    .textSelection(.enabled)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LitheTheme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            if let preview = request.diffPreview, !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(8)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LitheTheme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            if request.decision == nil {
                HStack(spacing: 6) {
                    if request.allowsAllowOnce {
                        Button("Allow Once") {
                            feature.respondToApproval(requestID: request.id, decision: .allowOnce)
                        }
                        .buttonStyle(LithePrimaryButtonStyle(
                            backgroundColor: LitheTheme.settingsPrimaryAction,
                            restingOpacity: 1
                        ))
                    }

                    if request.allowsAllowAlways {
                        Button("Allow Always") {
                            feature.respondToApproval(requestID: request.id, decision: .allowAlways)
                        }
                        .buttonStyle(LitheSecondaryButtonStyle())
                    }

                    Spacer()

                    Button("Deny") {
                        feature.respondToApproval(requestID: request.id, decision: .deny)
                    }
                    .buttonStyle(LitheSecondaryButtonStyle())
                }
            }
        }
        .padding(10)
        .background(LitheTheme.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(LitheTheme.warning.opacity(0.45), lineWidth: 1))
    }

    private var planProposalActionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "map.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.accent)
                Text("Plan ready to implement")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
            }
            HStack(spacing: 6) {
                Button {
                    feature.implementPlan(from: turn, inNewWorktree: false)
                } label: {
                    Label("Implement Plan", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(LithePrimaryButtonStyle(
                    backgroundColor: LitheTheme.settingsPrimaryAction,
                    restingOpacity: 1
                ))

                if feature.selectedThread?.worktreePath == nil {
                    Button {
                        feature.implementPlan(from: turn, inNewWorktree: true)
                    } label: {
                        Label("In Worktree", systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(LitheSecondaryButtonStyle())
                    .help("Create an isolated Git worktree and implement this plan there")
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(turn.assistantResponseText, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.secondaryText)
                .lithePointer()
            }
        }
        .padding(9)
        .background(LitheTheme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(LitheTheme.accent.opacity(0.35), lineWidth: 1))
    }

    private var turnFooter: some View {
        HStack(spacing: 8) {
            Text(turn.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10))
                .foregroundStyle(LitheTheme.tertiaryText)

            if let duration = turn.durationSeconds, duration >= 0.2 {
                Text(Self.formatDuration(duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LitheTheme.tertiaryText)
            }

            if turn.status == .cancelled {
                Text("Cancelled")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LitheTheme.warning)
            } else if let usage = turn.usage, usage.totalTokens > 0 {
                Text("\(usage.inputTokens) in · \(usage.outputTokens) out")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LitheTheme.tertiaryText)
            }

            Spacer()

            if turn.canRevertCheckpoint, let checkpoint = turn.checkpoint {
                Button {
                    onRequestRevert(checkpoint)
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.warning)
                .lithePointer()
                .help("Restore workspace files to the pre-turn checkpoint")
            }

            if turn.status == .failed || turn.status == .cancelled {
                Button {
                    feature.retryTurn(turn)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.accent)
                .lithePointer()
                .help("Retry this prompt")
            }

            Button {
                feature.loadTurnIntoComposer(turn)
            } label: {
                Image(systemName: "arrow.uturn.left")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LitheTheme.tertiaryText)
            .lithePointer()
            .help("Edit prompt in composer")

            let replyText = turn.assistantResponseText
            if !replyText.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(replyText, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.tertiaryText)
                .lithePointer()
                .help("Copy response")
            }
        }
        .padding(.horizontal, 2)
    }

    private static func formatElapsed(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        return formatElapsed(Int(seconds.rounded()))
    }

    @ViewBuilder
    private func statusIcon(_ status: AIAgentToolCallStatus) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini)
        case .waitingApproval:
            Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(LitheTheme.warning)
        case .completed:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 10.5)).foregroundStyle(LitheTheme.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 10.5)).foregroundStyle(LitheTheme.error)
        case .denied:
            Image(systemName: "slash.circle.fill").font(.system(size: 10.5)).foregroundStyle(LitheTheme.warning)
        }
    }

    private func badgeColor(_ kind: AIAgentFileChangeKind) -> Color {
        switch kind {
        case .added: LitheTheme.success
        case .modified: LitheTheme.warning
        case .deleted: LitheTheme.error
        case .renamed: LitheTheme.accent
        }
    }
}

/// Lightweight, high-craft markdown renderer for streaming agent responses with fenced code blocks & copy action.
struct AIAgentMarkdownBlockView: View {
    let text: String

    private enum Segment: Identifiable {
        case prose(id: Int, text: String)
        case code(id: Int, language: String, code: String)

        var id: Int {
            switch self {
            case .prose(let id, _): id
            case .code(let id, _, _): id
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.parseSegments(text)) { segment in
                switch segment {
                case .prose(_, let content):
                    proseText(content)
                case .code(_, let language, let code):
                    codeBlock(language: language, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func proseText(_ content: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.system(size: 12.5))
                .foregroundStyle(LitheTheme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(content)
                .font(.system(size: 12.5))
                .foregroundStyle(LitheTheme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func codeBlock(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.secondaryText)
                .lithePointer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(LitheTheme.raised.opacity(0.75))

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.primaryText)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(LitheTheme.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.divider, lineWidth: 1))
    }

    private static func parseSegments(_ input: String) -> [Segment] {
        var segments: [Segment] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var inCode = false
        var codeLanguage = ""
        var nextID = 0

        func flushProse() {
            let joined = proseLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty {
                segments.append(.prose(id: nextID, text: joined))
                nextID += 1
            }
            proseLines.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            let joined = codeLines.joined(separator: "\n")
            segments.append(.code(id: nextID, language: codeLanguage, code: joined))
            nextID += 1
            codeLines.removeAll(keepingCapacity: true)
            codeLanguage = ""
        }

        for rawLine in input.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushProse()
                    inCode = true
                    codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else if inCode {
                codeLines.append(line)
            } else {
                proseLines.append(line)
            }
        }

        if inCode {
            flushCode()
        } else {
            flushProse()
        }
        return segments
    }
}
