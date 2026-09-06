import SwiftUI
import LitheTerminalModule

struct TerminalSettingsView: View {
    @ObservedObject var settings: AppSettings
    let displayDiagnostics: [String]
    let retryDisplay: () -> Void
    @State private var argumentIDs: [UUID]
    @State private var environmentIDs: [UUID]

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
                                        width: 220, accessibilityLabel: "Default shell", title: \.title)
                }
                if settings.terminalShell == .custom {
                    row("Program") { field("Shell program", text: $settings.terminalConfiguration.customProgram) }
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
        }
        .font(.system(size: 13)).foregroundStyle(LitheTheme.primaryText)
        .onChange(of: settings.terminalConfiguration.arguments.count) { count in
            if argumentIDs.count != count { argumentIDs = (0..<count).map { _ in UUID() } }
        }
        .onChange(of: settings.terminalConfiguration.environment.count) { count in
            if environmentIDs.count != count { environmentIDs = (0..<count).map { _ in UUID() } }
        }
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
