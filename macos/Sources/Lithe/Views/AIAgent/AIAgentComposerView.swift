import LitheAIAgentModule
import LitheCoreContracts
import SwiftUI

struct AIAgentComposerView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: AIAgentFeatureModel
    @State private var isCustomModelPopoverPresented = false
    @State private var customModelDraft = ""

    private var activeThread: AIAgentThread? { feature.selectedThread }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let suggestions = activeSlashSuggestions, !suggestions.isEmpty {
                slashAutocompleteCard(suggestions)
            } else if let fileSuggestions = activeAtFileSuggestions, !fileSuggestions.isEmpty {
                fileMentionAutocompleteCard(fileSuggestions)
            }

            contextChipsRow

            ZStack(alignment: .topLeading) {
                if feature.composerDraft.isEmpty {
                    Text(feature.isSelectedThreadRunning
                        ? "Queue a follow-up prompt… (⌘↩ to queue)"
                        : "Ask AI Agent… (@file, /plan, /diff, ⌘↩ to send)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $feature.composerDraft)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LitheTheme.primaryText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 54, maxHeight: 132)
                    .padding(4)
            }
            .background(LitheTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(LitheTheme.inputBorder, lineWidth: 1))

            bottomControlsRow
        }
        .padding(10)
        .background(LitheTheme.sidebar)
    }

    private var contextChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                if let document = model.activeDocument {
                    let hasSelection = !model.editorSelectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button {
                        model.attachActiveEditorContextToAgent()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                            Text(hasSelection ? "Selection" : document.url.lastPathComponent)
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(LitheTheme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(LitheTheme.raised.opacity(0.65))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(LitheTheme.divider, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                    .help("Attach active editor file or selection as context")
                }

                ForEach(feature.attachedContexts) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 9.5))
                            .foregroundStyle(LitheTheme.accent)
                        Text(attachment.displayLabel)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.primaryText)
                        Button {
                            feature.removeAttachment(id: attachment.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(LitheTheme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .lithePointer()
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(LitheTheme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }

    private var bottomControlsRow: some View {
        HStack(spacing: 5) {
            backendPill
            modelPill
            effortPill
            modePill

            Spacer(minLength: 4)

            if feature.isSelectedThreadRunning {
                Button {
                    feature.stopActiveTurn()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 24, height: 24)
                        .background(LitheTheme.error)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .lithePointer()
                .help("Stop active turn")
            }

            let canSubmit = !feature.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button {
                feature.submitComposerPrompt()
            } label: {
                Image(systemName: feature.isSelectedThreadRunning ? "text.badge.plus" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 26, height: 24)
                    .background(canSubmit ? LitheTheme.accent : LitheTheme.tertiaryText.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .lithePointer()
            .keyboardShortcut(.return, modifiers: [.command])
            .help(feature.isSelectedThreadRunning ? "Queue follow-up (⌘↩)" : "Send prompt (⌘↩)")
        }
    }

    private var backendPill: some View {
        let current = activeThread?.backend ?? model.settings.aiAgent.defaultBackend
        return Menu {
            ForEach(AIAgentBackendKind.allCases) { backend in
                let available = feature.detection(for: backend)?.isAvailable ?? true
                Button {
                    feature.updateSelectedThreadBackend(backend)
                } label: {
                    HStack {
                        Text(available ? backend.title : "\(backend.title) (not detected)")
                        if backend == current {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            pillLabel(icon: current.iconName, text: current.shortTitle, tint: LitheTheme.primaryText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .lithePointer()
        .help("Select AI Agent provider")
    }

    private var modelPill: some View {
        let backend = activeThread?.backend ?? .codexCLI
        let activeModel = activeThread?.model ?? ""
        let labelText = activeModel.isEmpty ? "Default" : activeModel
        return Menu {
            Button("Backend Default") {
                feature.updateSelectedThreadModel("")
            }
            Divider()
            ForEach(backend.suggestedModels.filter { !$0.isEmpty }, id: \.self) { modelName in
                Button {
                    feature.updateSelectedThreadModel(modelName)
                } label: {
                    HStack {
                        Text(modelName)
                        if activeModel == modelName {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button("Custom Model…") {
                customModelDraft = activeModel
                isCustomModelPopoverPresented = true
            }
        } label: {
            pillLabel(icon: "cpu", text: labelText, tint: LitheTheme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .lithePointer()
        .help("Select model for this thread")
        .popover(isPresented: $isCustomModelPopoverPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom Model")
                    .font(.system(size: 12, weight: .semibold))
                TextField("e.g. gpt-5.4, claude-sonnet-4-5", text: $customModelDraft)
                    .litheSettingsTextField()
                HStack {
                    Spacer()
                    Button("Apply") {
                        feature.updateSelectedThreadModel(customModelDraft)
                        isCustomModelPopoverPresented = false
                    }
                    .buttonStyle(LithePrimaryButtonStyle(
                        backgroundColor: LitheTheme.settingsPrimaryAction,
                        restingOpacity: 1
                    ))
                }
            }
            .padding(12)
            .frame(width: 240)
            .background(LitheTheme.raised)
        }
    }

    private var effortPill: some View {
        let current = activeThread?.reasoningEffort ?? .medium
        return Menu {
            ForEach(AIAgentReasoningEffort.allCases) { effort in
                Button {
                    feature.updateSelectedThreadEffort(effort)
                } label: {
                    HStack {
                        Text(effort.title)
                        if effort == current {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            pillLabel(icon: "dial.medium", text: current.title, tint: LitheTheme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .lithePointer()
        .help("Reasoning effort")
    }

    private var modePill: some View {
        let current = activeThread?.permissionMode ?? .supervised
        let tint: Color = {
            switch current {
            case .plan: LitheTheme.accent
            case .supervised: LitheTheme.success
            case .autoEdit: LitheTheme.warning
            case .fullAuto: LitheTheme.error
            }
        }()
        return Menu {
            ForEach(AIAgentPermissionMode.allCases) { mode in
                Button {
                    feature.updateSelectedThreadPermissionMode(mode)
                } label: {
                    HStack {
                        Text("\(mode.title) — \(mode.summary)")
                        if mode == current {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            pillLabel(icon: current.iconName, text: current.title, tint: tint)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .lithePointer()
        .help(current.summary)
    }

    private func pillLabel(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .medium))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(LitheTheme.raised.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(LitheTheme.divider, lineWidth: 1))
    }

    // MARK: - Slash & @file Autocomplete

    private var activeSlashSuggestions: [AIAgentSlashCommand]? {
        let trimmed = feature.composerDraft.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), !trimmed.contains(" ") else { return nil }
        let query = trimmed.lowercased()
        return AIAgentSlashCommand.builtIn.filter {
            $0.command.hasPrefix(query) || $0.title.lowercased().contains(String(query.dropFirst()))
        }
    }

    private var activeAtFileSuggestions: [String]? {
        guard let range = trailingAtQueryRange(in: feature.composerDraft),
              let workspaceURL = model.workspaceURL else { return nil }
        let query = String(feature.composerDraft[range]).dropFirst().lowercased()
        let rootPrefix = workspaceURL.standardizedFileURL.path.hasSuffix("/")
            ? workspaceURL.standardizedFileURL.path
            : workspaceURL.standardizedFileURL.path + "/"
        let relativeFiles = model.projectFiles.compactMap { url -> String? in
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPrefix) else { return nil }
            return String(path.dropFirst(rootPrefix.count))
        }
        let matches = relativeFiles.filter { path in
            query.isEmpty || path.lowercased().contains(query)
        }
        return Array(matches.prefix(8))
    }

    private func slashAutocompleteCard(_ commands: [AIAgentSlashCommand]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(commands.prefix(6)) { cmd in
                Button {
                    feature.composerDraft = cmd.command == "/model" ? "/model " : ""
                    if cmd.command != "/model" {
                        feature.sendPrompt(cmd.command, attachments: feature.attachedContexts)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: cmd.iconName)
                            .font(.system(size: 11))
                            .foregroundStyle(LitheTheme.accent)
                            .frame(width: 14)
                        Text(cmd.command)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LitheTheme.primaryText)
                        Text(cmd.subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lithePointer()
            }
        }
        .padding(4)
        .background(LitheTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(LitheTheme.panelBorder, lineWidth: 1))
    }

    private func fileMentionAutocompleteCard(_ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(paths, id: \.self) { path in
                Button {
                    feature.addAttachment(AIAgentContextAttachment(kind: .file(relativePath: path)))
                    if let range = trailingAtQueryRange(in: feature.composerDraft) {
                        feature.composerDraft.removeSubrange(range)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10.5))
                            .foregroundStyle(LitheTheme.accent)
                        Text(path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LitheTheme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lithePointer()
            }
        }
        .padding(4)
        .background(LitheTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(LitheTheme.panelBorder, lineWidth: 1))
    }

    private func trailingAtQueryRange(in text: String) -> Range<String.Index>? {
        guard let atIndex = text.lastIndex(of: "@") else { return nil }
        if atIndex > text.startIndex {
            let prev = text[text.index(before: atIndex)]
            guard prev.isWhitespace else { return nil }
        }
        let suffix = text[atIndex...]
        guard !suffix.contains(where: \.isWhitespace) else { return nil }
        return atIndex..<text.endIndex
    }
}
