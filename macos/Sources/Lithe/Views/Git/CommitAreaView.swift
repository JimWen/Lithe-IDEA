import SwiftUI
import LitheGitModule

struct CommitAreaView: View {
    @ObservedObject var feature: GitFeatureModel
    @EnvironmentObject private var model: AppModel
    @State private var commitMessageFocused = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Toggle(isOn: $model.amendCommit) {
                    Text("Amend") + Text(" last commit").foregroundColor(LitheTheme.accent)
                }
                    .toggleStyle(.checkbox)
                    .lithePointer()
                    .font(.system(size: LitheTheme.Commit.amendFontSize))
                LitheSystemIcon(systemImage: "clock", size: LitheTheme.Commit.actionIconSize)
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                Button {
                    Task { await model.generateCommitMessage() }
                } label: {
                    HStack(spacing: 4) {
                        if model.isGeneratingCommitMessage {
                            ProgressView().controlSize(.mini)
                        } else {
                            LitheSystemIcon(systemImage: "wand.and.stars", size: LitheTheme.Commit.actionIconSize)
                        }
                        Text("AI")
                    }
                }
                .buttonStyle(
                    LitheSecondaryButtonStyle(
                        horizontalPadding: LitheTheme.Commit.compactButtonPadding,
                        height: LitheTheme.Commit.compactButtonHeight,
                        fontSize: LitheTheme.Commit.compactButtonFontSize
                    )
                )
                .disabled(
                    stagedChanges.isEmpty ||
                        feature.isLoadingDiff ||
                        model.isGeneratingCommitMessage
                )
                .help("Generate a commit message from staged diffs")
                Text("\(stagedChanges.count) staged")
                    .font(.system(size: LitheTheme.Commit.metadataFontSize))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            CommitMessageEditor(text: $model.commitMessage, focused: $commitMessageFocused)
            .frame(maxWidth: .infinity, minHeight: 50, maxHeight: .infinity, alignment: .topLeading)
            .litheRoundedControlBackground(LitheTheme.editor)
            .overlay {
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .strokeBorder(
                        commitMessageFocused ? LitheTheme.selection : LitheTheme.divider,
                        lineWidth: commitMessageFocused ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await model.commitStagedChanges() }
                } label: {
                    HStack(spacing: 6) {
                        if feature.isCommitting {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Commit")
                    }
                }
                .buttonStyle(LithePrimaryButtonStyle())
                .disabled(!canCommit)

                Button("Commit and Push…") {
                    Task { await model.commitAndPushStagedChanges() }
                }
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(!canCommit)

                Spacer(minLength: 0)
                Button {
                    model.showSettings(category: .ai)
                } label: {
                    LitheSystemIcon(systemImage: "gearshape")
                }
                .litheIconButton()
                .help("Open AI & Commit settings")
            }
        }
        .padding(LitheTheme.Commit.panelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.toolHeader)
        .confirmationDialog(
            "Replace current commit message?",
            isPresented: Binding(
                get: { model.pendingGeneratedCommitMessage != nil },
                set: { if !$0 { model.discardPendingGeneratedCommitMessage() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Replace") {
                model.applyPendingGeneratedCommitMessage()
            }
            .lithePointer()
            Button("Keep Current", role: .cancel) {
                model.discardPendingGeneratedCommitMessage()
            }
            .lithePointer()
        } message: {
            Text("The generated message will replace the text currently in the editor.")
        }
    }

    private var stagedChanges: [GitChange] {
        feature.activeRepositoryChanges.filter(\.isStaged)
    }

    private var canCommit: Bool {
        !stagedChanges.isEmpty &&
            !model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !feature.isCommitting
    }

}
