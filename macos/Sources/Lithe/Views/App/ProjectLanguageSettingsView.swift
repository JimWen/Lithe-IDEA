import SwiftUI

/// Project-specific language settings reuse the existing runtime resolver and
/// language-server setup UI; no separate tool discovery or launch path is added.
struct ProjectLanguageSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let category: SettingsCategory
    let editConfigurations: () -> Void
    @State private var executableDraft = ""
    @State private var errorMessage: String?

    private var command: String { category.runtimeCommand ?? "" }
    private var providerID: String { category.languageProviderID ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(category.rawValue) · \(model.projectName)")
                .font(.system(size: 15, weight: .semibold))
            Text(category == .python ? "Project interpreter" : "Project toolchain")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                TextField("Auto-detect", text: $executableDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveExecutable)
                    .accessibilityLabel("Project executable")
                Button {
                    if let url = model.chooseProjectExecutable(language: category.rawValue) {
                        executableDraft = url.path
                        saveExecutable()
                    }
                } label: { Image(systemName: "folder") }
                .litheIconButton()
                .help("Choose executable")
                Button("Apply", action: saveExecutable)
                Button("Auto-detect") {
                    executableDraft = ""
                    saveExecutable()
                }
            }
            if let candidate = model.runtimeFeature.executableCandidates(command).first {
                Text(candidate.executableURL.path)
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .textSelection(.enabled)
            } else {
                Text(model.runtimeFeature.toolGuidance(command).message)
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.warning)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(LitheTheme.error).font(.system(size: 12))
            }
            Text("This choice applies to this project's next Run, Debug and language-tool launch. Running sessions keep their current process.")
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
            HStack {
                Toggle("Enable language server", isOn: Binding(
                    get: { !model.isLanguageServerDisabledInCurrentWorkspace(providerID: providerID) },
                    set: { model.setLanguageServerEnabled($0, providerID: providerID) }
                ))
                Spacer()
                Button("Edit Configurations…", action: editConfigurations)
            }
            Divider()
            if let tools = model.languageServerToolsIfActive {
                LanguageServerSetupView(
                    tools: tools,
                    providers: model.languageProviderCatalog.descriptors.filter { $0.id == providerID },
                    initialProviderID: providerID,
                    language: settings.language,
                    chooseExecutable: { model.chooseLanguageServerExecutable(providerName: $0.displayName) },
                    openOfficialDownload: model.openLanguageServerDownload,
                    configurationChanged: model.languageServerToolConfigurationDidChange,
                    isEmbedded: true
                )
            } else {
                ProgressView("Loading language settings…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .foregroundStyle(LitheTheme.primaryText)
        .background(LitheTheme.settingsSurface)
        .task(id: "\(model.id)-\(providerID)") {
            executableDraft = model.runtimeFeature.customExecutablePath(for: command) ?? ""
            await model.prepareLanguageSettings()
        }
    }

    private func saveExecutable() {
        do {
            try model.runtimeFeature.setCustomExecutablePath(executableDraft, for: command)
            if command == "go" { model.goToolchainDidChange() }
            executableDraft = model.runtimeFeature.customExecutablePath(for: command) ?? ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
