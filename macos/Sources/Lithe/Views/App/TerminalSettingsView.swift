import SwiftUI
import LitheTerminalModule

struct TerminalSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settings: AppSettings
    let displayDiagnostics: [String]
    let retryDisplay: () -> Void
    @State private var argumentIDs: [UUID]
    @State private var environmentIDs: [UUID]
    @State private var detectedShells: [String] = []
    @State private var knownShells: [String] = []
    @State private var missingShellPath: String?

    init(settings: AppSettings, displayDiagnostics: [String], retryDisplay: @escaping () -> Void) {
        self.settings = settings
        self.displayDiagnostics = displayDiagnostics
        self.retryDisplay = retryDisplay
        _argumentIDs = State(initialValue: settings.terminalConfiguration.arguments.map { _ in UUID() })
        _environmentIDs = State(initialValue: settings.terminalConfiguration.environment.map { _ in UUID() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TerminalTypographySettingsView(settings: settings, diagnostics: displayDiagnostics, retry: retryDisplay)
            TerminalInteractionSettingsView(settings: settings)
            Text("Launch settings apply to new terminals. Restart keeps the original session configuration.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            if let error = settings.terminalConfigurationLoadError ?? settings.terminalConfiguration.validationMessage {
                Label { Text(LocalizedStringKey(error)).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(LitheTheme.warning)
            }
            section("Shell") {
                row("Default shell") {
                    LitheSettingsSelect(selection: $settings.terminalShell, options: TerminalShell.allCases,
                                        width: 320, accessibilityLabel: "Default shell", title: shellTitle,
                                        isAvailable: shellIsAvailable,
                                        onUnavailableSelection: { missingShellPath = shellPath($0) })
                }
                if settings.terminalShell == .custom {
                    row("Program") { field("Shell program", text: $settings.terminalConfiguration.customProgram) }
                }
                HStack(spacing: 10) {
                    Menu("Detected shells") {
                        ForEach(shellOptions, id: \.self) { path in
                            Button {
                                guard detectedShells.contains(path) else { missingShellPath = path; return }
                                // Selecting a discovered executable changes only shell choice;
                                // arguments, environment and virtual-environment settings stay intact.
                                settings.terminalConfiguration.customProgram = path
                                settings.terminalShell = .custom
                            } label: {
                                Text(verbatim: "\(URL(fileURLWithPath: path).lastPathComponent) (\(path))")
                                    .foregroundStyle(detectedShells.contains(path) ? LitheTheme.primaryText : LitheTheme.tertiaryText)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button("Detect Installed Shells", action: refreshShellChoices)
                        .buttonStyle(LitheSecondaryButtonStyle())
                }
                LitheSettingsCheckbox(isOn: $settings.terminalConfiguration.loginShell, title: "Run as login shell")
                Text("Login adds -l before the arguments. Explicit -l or --login arguments are preserved.")
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            }
            section("Arguments") {
                ForEach(argumentIDs, id: \.self) { id in
                    HStack(spacing: 8) {
                        field("Argument", text: argumentBinding(id))
                        removeButton("Remove argument") { removeArgument(id) }
                    }
                }
                Button("Add argument") {
                    argumentIDs.append(UUID())
                    settings.terminalConfiguration.arguments.append("")
                }.buttonStyle(LitheSecondaryButtonStyle())
                    .disabled(argumentIDs.count >= TerminalShellConfiguration.maximumArguments)
                Text("One argument per row. Spaces, quotes and empty arguments are passed literally.")
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            }
            section("Working directory") {
                row("Start in") {
                    LitheSettingsSelect(selection: $settings.terminalConfiguration.workingDirectory,
                                        options: TerminalWorkingDirectory.allCases, width: 240,
                                        accessibilityLabel: "Start in", title: \.title)
                }
                if settings.terminalConfiguration.workingDirectory == .custom {
                    row("Directory") { field("Terminal directory", text: $settings.terminalConfiguration.customDirectory) }
                    Text("Use an absolute path, ~/ or a path relative to this project.")
                        .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                }
            }
            section("Environment variables") {
                ForEach(environmentIDs, id: \.self) { id in
                    HStack(spacing: 8) {
                        field("Name", text: environmentBinding(id, name: true)).frame(maxWidth: 155)
                        field("Value", text: environmentBinding(id, name: false))
                            .disabled(environmentIsUnset(id))
                        LitheSettingsCheckbox(isOn: unsetBinding(id), title: "Unset")
                        removeButton("Remove environment variable") { removeEnvironment(id) }
                    }
                }
                Button("Add environment variable") {
                    environmentIDs.append(UUID())
                    settings.terminalConfiguration.environment.append(TerminalEnvironmentChange(name: "", value: ""))
                }.buttonStyle(LitheSecondaryButtonStyle())
                    .disabled(environmentIDs.count >= TerminalShellConfiguration.maximumEnvironmentVariables)
                Text("Values are literal. Unset removes an inherited variable; an empty value keeps it defined.")
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            }
            TerminalVirtualEnvironmentSettingsView(settings: settings)
        }
        .font(.system(size: 13)).foregroundStyle(LitheTheme.primaryText)
        .task {
            guard await model.activateTerminalModule(), !Task.isCancelled else { return }
            refreshShellChoices()
        }
        .alert("Shell not found", isPresented: Binding(
            get: { missingShellPath != nil },
            set: { if !$0 { missingShellPath = nil } }
        )) {
            Button("OK", role: .cancel) { missingShellPath = nil }
        } message: {
            if let missingShellPath {
                Text("No shell was found at \(missingShellPath). Choose a detected shell or run detection again.")
            }
        }
        .onChange(of: settings.terminalConfiguration.arguments.count) { count in
            if argumentIDs.count != count { argumentIDs = (0..<count).map { _ in UUID() } }
        }
        .onChange(of: settings.terminalConfiguration.environment.count) { count in
            if environmentIDs.count != count { environmentIDs = (0..<count).map { _ in UUID() } }
        }
    }

    private var shellOptions: [String] {
        var options = knownShells
        options += detectedShells.filter { !options.contains($0) }
        if let selected = settings.terminalShellPath, !selected.isEmpty, !options.contains(selected) {
            options.append(selected)
        }
        return options
    }

    private func refreshShellChoices() {
        model.terminalFeature?.refreshAvailableShells()
        detectedShells = model.availableTerminalShells
        knownShells = MacTerminalShellDiscovery.knownShells()
    }

    private func shellPath(_ shell: TerminalShell) -> String {
        switch shell {
        case .system: return MacTerminalShellDiscovery.defaultShellPath()
        case .custom: return settings.terminalConfiguration.customProgram
        case .zsh, .bash:
            var configuration = TerminalShellConfiguration()
            configuration.shell = shell
            return configuration.specifiedShellPath ?? ""
        }
    }

    private func shellIsAvailable(_ shell: TerminalShell) -> Bool {
        // Custom also accepts PATH names/wrappers; native launch validation owns
        // that resolution. Choosing Custom must remain possible before editing it.
        shell == .custom || detectedShells.contains(shellPath(shell))
    }

    private func shellTitle(_ shell: TerminalShell) -> String {
        guard shell != .custom else { return shell.title }
        let path = shellPath(shell)
        if shell == .system {
            guard detectedShells.contains(path) else {
                return localizedShellString("System default · Shell not detected")
            }
            return String(format: localizedShellString("System default · %@ (%@)"),
                          URL(fileURLWithPath: path).lastPathComponent, path)
        }
        return "\(URL(fileURLWithPath: path).lastPathComponent) (\(path))"
    }

    private func localizedShellString(_ key: String) -> String {
        let bundle = Bundle.main.path(forResource: settings.language.locale.identifier, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(title)).fontWeight(.medium)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(title)).frame(width: 145, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }.frame(minHeight: 30)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(LocalizedStringKey(title), text: text)
            .textFieldStyle(.plain).padding(.horizontal, 8).frame(height: 30)
            .background(LitheTheme.settingsControlBackground)
            .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius).stroke(LitheTheme.inputBorder, lineWidth: 1))
            .accessibilityLabel(Text(LocalizedStringKey(title)))
    }

    private func removeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus") }
            .litheIconButton().help(Text(LocalizedStringKey(title)))
            .accessibilityLabel(Text(LocalizedStringKey(title)))
    }

    // Bindings re-resolve stable row IDs when an event arrives after deletion.
    // A stale text-field callback cannot write into a different array position.
    private func argumentBinding(_ id: UUID) -> Binding<String> {
        Binding(get: {
            guard let index = argumentIDs.firstIndex(of: id), settings.terminalConfiguration.arguments.indices.contains(index) else { return "" }
            return settings.terminalConfiguration.arguments[index]
        }, set: { value in
            guard let index = argumentIDs.firstIndex(of: id), settings.terminalConfiguration.arguments.indices.contains(index) else { return }
            settings.terminalConfiguration.arguments[index] = value
        })
    }

    private func removeArgument(_ id: UUID) {
        guard let index = argumentIDs.firstIndex(of: id), settings.terminalConfiguration.arguments.indices.contains(index) else { return }
        argumentIDs.remove(at: index)
        settings.terminalConfiguration.arguments.remove(at: index)
    }

    private func environmentBinding(_ id: UUID, name: Bool) -> Binding<String> {
        Binding(get: {
            guard let index = environmentIndex(id) else { return "" }
            let entry = settings.terminalConfiguration.environment[index]
            return name ? entry.name : entry.value ?? ""
        }, set: { value in
            guard let index = environmentIndex(id) else { return }
            if name { settings.terminalConfiguration.environment[index].name = value }
            else { settings.terminalConfiguration.environment[index].value = value }
        })
    }

    private func environmentIndex(_ id: UUID) -> Int? {
        guard let index = environmentIDs.firstIndex(of: id), settings.terminalConfiguration.environment.indices.contains(index) else { return nil }
        return index
    }

    private func environmentIsUnset(_ id: UUID) -> Bool {
        guard let index = environmentIndex(id) else { return false }
        return settings.terminalConfiguration.environment[index].value == nil
    }

    private func unsetBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { environmentIsUnset(id) }, set: { unset in
            guard let index = environmentIndex(id) else { return }
            settings.terminalConfiguration.environment[index].value = unset ? nil : ""
        })
    }

    private func removeEnvironment(_ id: UUID) {
        guard let index = environmentIndex(id) else { return }
        environmentIDs.remove(at: index)
        settings.terminalConfiguration.environment.remove(at: index)
    }
}

private extension TerminalWorkingDirectory {
    var title: String {
        switch self {
        case .currentProject: "Current project directory"
        case .currentFile: "Current file directory"
        case .firstProject: "First project directory"
        case .home: "Home directory"
        case .custom: "Custom directory"
        }
    }
}
