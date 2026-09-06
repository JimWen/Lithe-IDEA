import SwiftUI
import LitheTerminalModule

struct TerminalTypographySettingsView: View {
    @ObservedObject var settings: AppSettings
    let diagnostics: [String]
    let retry: () -> Void
    @State private var fallbackIDs: [UUID]

    init(settings: AppSettings, diagnostics: [String], retry: @escaping () -> Void) {
        self.settings = settings
        self.diagnostics = diagnostics
        self.retry = retry
        _fallbackIDs = State(initialValue: settings.terminalDisplayConfiguration.fallbackFontNames.map { _ in UUID() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Terminal font").fontWeight(.medium)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }
            Text("Font changes apply to all open terminals without restarting their shells.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            ForEach(messages, id: \.self) { message in
                Label { Text(LocalizedStringKey(message)).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(LitheTheme.warning)
            }
            row("Font family") {
                TerminalFontPicker(selection: $settings.terminalDisplayConfiguration.fontName,
                                   fonts: settings.terminalFonts, includesDefault: true, label: "Terminal font family")
                    .frame(minWidth: 200, maxWidth: .infinity, minHeight: 30)
            }
            row("Font size") {
                numberField("Terminal font size", value: $settings.terminalDisplayConfiguration.fontSize,
                            range: TerminalDisplayConfiguration.fontSizeRange, step: 1)
            }
            row("Line height") {
                numberField("Terminal line height", value: $settings.terminalDisplayConfiguration.lineSpacing,
                            range: TerminalDisplayConfiguration.lineSpacingRange, step: 0.1)
            }
            Text("Fallback fonts").fontWeight(.medium).padding(.top, 4)
            Text("Fallbacks are tried in order before the system fallback fonts.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            ForEach(fallbackIDs, id: \.self) { id in
                HStack(spacing: 8) {
                    TerminalFontPicker(selection: fallbackBinding(id), fonts: settings.terminalFonts,
                                       includesDefault: false, label: "Fallback font")
                        .frame(minWidth: 180, maxWidth: .infinity, minHeight: 30)
                    Button { moveFallback(id, offset: -1) } label: { Image(systemName: "arrow.up") }
                        .litheIconButton().help("Move fallback font up")
                        .accessibilityLabel("Move fallback font up")
                        .disabled(fallbackIDs.first == id)
                    Button { moveFallback(id, offset: 1) } label: { Image(systemName: "arrow.down") }
                        .litheIconButton().help("Move fallback font down")
                        .accessibilityLabel("Move fallback font down")
                        .disabled(fallbackIDs.last == id)
                    Button { removeFallback(id) } label: { Image(systemName: "minus") }
                        .litheIconButton().help("Remove fallback font").accessibilityLabel("Remove fallback font")
                }
            }
            HStack(spacing: 10) {
                Button("Add fallback font") {
                    fallbackIDs.append(UUID())
                    settings.terminalDisplayConfiguration.fallbackFontNames.append("")
                }.disabled(fallbackIDs.count >= TerminalDisplayConfiguration.maximumFallbacks)
                Button("Refresh fonts") { settings.refreshTerminalFonts(); retry() }
                if !diagnostics.isEmpty { Button("Retry font settings", action: retry) }
            }.buttonStyle(LitheSecondaryButtonStyle())
        }
        .onAppear { settings.loadTerminalFontsIfNeeded() }
        .onChange(of: settings.terminalDisplayConfiguration.fallbackFontNames.count) { count in
            if fallbackIDs.count != count { fallbackIDs = (0..<count).map { _ in UUID() } }
        }
    }

    private var messages: [String] {
        let preferenceError = settings.terminalDisplayConfigurationLoadError
            ?? settings.terminalDisplayConfiguration.validationMessage
        let availability = settings.terminalFontAvailabilityDiagnostic.map { [$0] } ?? []
        return Array(Set((preferenceError.map { [$0] } ?? []) + diagnostics + availability)).sorted()
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(title)).frame(width: 145, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }.frame(minHeight: 30)
    }

    private func numberField(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        Stepper(value: value, in: range, step: step) {
            TextField(LocalizedStringKey(title), value: value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder).frame(width: 90)
                .accessibilityLabel(Text(LocalizedStringKey(title)))
        }.fixedSize()
    }

    private func fallbackIndex(_ id: UUID) -> Int? {
        guard let index = fallbackIDs.firstIndex(of: id),
              settings.terminalDisplayConfiguration.fallbackFontNames.indices.contains(index) else { return nil }
        return index
    }

    private func fallbackBinding(_ id: UUID) -> Binding<String?> {
        Binding(get: {
            guard let index = fallbackIndex(id) else { return nil }
            return settings.terminalDisplayConfiguration.fallbackFontNames[index]
        }, set: { value in
            guard let index = fallbackIndex(id) else { return }
            settings.terminalDisplayConfiguration.fallbackFontNames[index] = value ?? ""
        })
    }

    private func removeFallback(_ id: UUID) {
        guard let index = fallbackIndex(id) else { return }
        fallbackIDs.remove(at: index)
        settings.terminalDisplayConfiguration.fallbackFontNames.remove(at: index)
    }

    private func moveFallback(_ id: UUID, offset: Int) {
        guard let index = fallbackIndex(id), fallbackIDs.indices.contains(index + offset) else { return }
        fallbackIDs.swapAt(index, index + offset)
        settings.terminalDisplayConfiguration.fallbackFontNames.swapAt(index, index + offset)
    }
}
