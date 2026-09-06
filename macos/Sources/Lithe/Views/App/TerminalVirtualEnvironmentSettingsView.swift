import SwiftUI
import LitheTerminalModule

struct TerminalVirtualEnvironmentSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var directoryIDs: [UUID]

    init(settings: AppSettings) {
        self.settings = settings
        _directoryIDs = State(initialValue: settings.terminalConfiguration.virtualEnvironmentDirectories.map { _ in UUID() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Python virtual environments").fontWeight(.medium)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }
            LitheSettingsCheckbox(isOn: $settings.terminalConfiguration.detectVirtualEnvironment,
                                  title: "Automatically activate virtual environments")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(directoryIDs, id: \.self) { id in
                    HStack(spacing: 8) {
                        TextField("Virtual environment directory", text: directoryBinding(id))
                            .textFieldStyle(.plain).padding(.horizontal, 8).frame(height: 30)
                            .background(LitheTheme.settingsControlBackground)
                            .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
                            .overlay(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                                .stroke(LitheTheme.inputBorder, lineWidth: 1))
                            .accessibilityLabel("Virtual environment directory")
                        Button {
                            guard let index = directoryIDs.firstIndex(of: id),
                                  settings.terminalConfiguration.virtualEnvironmentDirectories.indices.contains(index) else { return }
                            directoryIDs.remove(at: index)
                            settings.terminalConfiguration.virtualEnvironmentDirectories.remove(at: index)
                        } label: { Image(systemName: "minus") }
                            .litheIconButton().help("Remove virtual environment directory")
                            .accessibilityLabel("Remove virtual environment directory")
                    }
                }
                Button("Add virtual environment directory") {
                    directoryIDs.append(UUID())
                    settings.terminalConfiguration.virtualEnvironmentDirectories.append("")
                }.buttonStyle(LitheSecondaryButtonStyle())
                    .disabled(directoryIDs.count >= TerminalShellConfiguration.maximumVirtualEnvironmentDirectories)
            }.disabled(!settings.terminalConfiguration.detectVirtualEnvironment)
            Text("Directories are checked in order, relative to the terminal working directory. Existing shell environments are preserved.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            Text("Available for interactive zsh and bash. Use deactivate to leave the environment. Restart keeps the original selection.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
        }
        .onChange(of: settings.terminalConfiguration.virtualEnvironmentDirectories.count) { count in
            if directoryIDs.count != count { directoryIDs = (0..<count).map { _ in UUID() } }
        }
    }

    private func directoryBinding(_ id: UUID) -> Binding<String> {
        Binding(get: {
            guard let index = directoryIDs.firstIndex(of: id),
                  settings.terminalConfiguration.virtualEnvironmentDirectories.indices.contains(index) else { return "" }
            return settings.terminalConfiguration.virtualEnvironmentDirectories[index]
        }, set: { value in
            guard let index = directoryIDs.firstIndex(of: id),
                  settings.terminalConfiguration.virtualEnvironmentDirectories.indices.contains(index) else { return }
            settings.terminalConfiguration.virtualEnvironmentDirectories[index] = value
        })
    }
}
