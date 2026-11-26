import LitheCoreContracts
import SwiftUI

/// T3-Code-aligned AI Agent configuration section inside Settings → AI & Commit.
struct AIAgentSettingsSectionView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionGroup("AI Agent Harness") {
                Text("Run Codex CLI, Claude Code CLI, or a Direct HTTP API provider directly in Lithe's right sidebar with multi-thread history, diff review, checkpoints, and isolated Git worktrees.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)

                settingsRow("Default backend") {
                    LitheSettingsSelect(
                        selection: $settings.aiAgent.defaultBackend,
                        options: AIAgentBackendKind.allCases,
                        width: 220,
                        accessibilityLabel: "Default backend",
                        title: \AIAgentBackendKind.title
                    )
                }

                settingsRow("Permission mode") {
                    LitheSettingsSelect(
                        selection: $settings.aiAgent.defaultPermissionMode,
                        options: AIAgentPermissionMode.allCases,
                        width: 220,
                        accessibilityLabel: "Permission mode",
                        title: \AIAgentPermissionMode.title
                    )
                }

                Text(settings.aiAgent.defaultPermissionMode.summary)
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(
                        settings.aiAgent.defaultPermissionMode == .fullAuto
                            ? LitheTheme.warning
                            : LitheTheme.secondaryText
                    )
                    .padding(.leading, 182)

                settingsRow("Reasoning effort") {
                    LitheSettingsSelect(
                        selection: $settings.aiAgent.defaultReasoningEffort,
                        options: AIAgentReasoningEffort.allCases,
                        width: 220,
                        accessibilityLabel: "Agent reasoning effort",
                        title: \AIAgentReasoningEffort.title
                    )
                }

                settingsRow("Codex CLI path") {
                    HStack(spacing: 6) {
                        TextField("Auto-detect (`codex` on PATH)", text: $settings.aiAgent.codexCLIPath)
                            .litheSettingsTextField()
                        Button("Choose…") {
                            if let url = model.platformUI.chooseFile(title: "Choose Codex CLI", prompt: "Choose") {
                                settings.aiAgent.codexCLIPath = url.path
                            }
                        }
                        .buttonStyle(LitheSecondaryButtonStyle())
                    }
                }

                settingsRow("Default Codex model") {
                    TextField("Leave blank to use ~/.codex/config.toml default", text: $settings.aiAgent.defaultCodexModel)
                        .litheSettingsTextField()
                }

                settingsRow("Claude CLI path") {
                    HStack(spacing: 6) {
                        TextField("Auto-detect (`claude` on PATH)", text: $settings.aiAgent.claudeCLIPath)
                            .litheSettingsTextField()
                        Button("Choose…") {
                            if let url = model.platformUI.chooseFile(title: "Choose Claude CLI", prompt: "Choose") {
                                settings.aiAgent.claudeCLIPath = url.path
                            }
                        }
                        .buttonStyle(LitheSecondaryButtonStyle())
                    }
                }

                settingsRow("Default Claude model") {
                    TextField("e.g. sonnet, opus (blank uses Claude default)", text: $settings.aiAgent.defaultClaudeModel)
                        .litheSettingsTextField()
                }

                if let feature = model.aiAgentFeatureIfActive, !feature.detectedCLIs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(feature.detectedCLIs) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(item.isAvailable ? LitheTheme.success : LitheTheme.warning)
                                Text(item.backend.title)
                                    .font(.system(size: 12, weight: .medium))
                                Text(item.statusDetail)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(1)
                                Spacer()
                                if let path = item.executablePath {
                                    Text(path)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(LitheTheme.tertiaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(LitheTheme.inputBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        Task {
                            if let feature = await model.activateAIAgentModule() {
                                await feature.refreshCLIDetection()
                            }
                        }
                    } label: {
                        Label("Detect Agent CLIs", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(LitheSecondaryButtonStyle())

                    if model.isAIAgentAvailable {
                        Button("Open AI Agent Panel") {
                            if !model.isAIAgentVisible {
                                model.toggleAIAgent()
                            }
                        }
                        .buttonStyle(LitheSecondaryButtonStyle())
                    }
                }

                Divider().padding(.vertical, 2)

                LitheSettingsCheckbox(
                    isOn: $settings.aiAgent.preferIsolatedWorktree,
                    title: "Prefer isolated Git worktrees for new agent tasks"
                )
                LitheSettingsCheckbox(
                    isOn: $settings.aiAgent.autoOpenDiffOnChanges,
                    title: "Automatically open Diff Review when a turn modifies files"
                )
                LitheSettingsCheckbox(
                    isOn: $settings.aiAgent.includeActiveFileContextByDefault,
                    title: "Suggest attaching active editor file/selection in composer"
                )

                Text("Custom agent instructions")
                    .font(.system(size: 11.5, weight: .medium))
                TextEditor(text: $settings.aiAgent.customSystemInstructions)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 68)
                    .padding(5)
                    .litheRoundedControlBackground(LitheTheme.inputBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                            .stroke(LitheTheme.inputBorder, lineWidth: 1)
                    }
            }
        }
    }

    private func sectionGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 13, weight: .medium))
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }
            content()
        }
        .font(.system(size: 13))
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(title))
                .frame(width: 170, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
    }
}
