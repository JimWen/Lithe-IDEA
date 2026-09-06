import SwiftUI
import LitheTerminalModule

struct TerminalInteractionSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("History") {
                row("Scrollback lines") {
                    Stepper(value: $settings.terminalDisplayConfiguration.scrollback,
                            in: TerminalDisplayConfiguration.scrollbackRange, step: 500) {
                        TextField("Terminal history lines", value: $settings.terminalDisplayConfiguration.scrollback, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 100)
                            .accessibilityLabel("Terminal history lines")
                    }.fixedSize()
                }
                hint("Reducing history removes older lines and clears the selection. Zero keeps no history.")
            }
            section("Cursor") {
                row("Cursor shape") {
                    LitheSettingsSelect(selection: $settings.terminalDisplayConfiguration.cursorShape,
                                        options: TerminalDisplayConfiguration.CursorShape.allCases, width: 180,
                                        accessibilityLabel: "Terminal cursor shape", title: \.title)
                }
                LitheSettingsCheckbox(isOn: $settings.terminalDisplayConfiguration.cursorBlink, title: "Blink cursor")
                hint("Terminal applications can override the cursor style while running.")
            }
            section("Input and scrolling") {
                LitheSettingsCheckbox(isOn: $settings.terminalDisplayConfiguration.optionAsMeta, title: "Use Option as Meta")
                row("Scroll sensitivity") {
                    Stepper(value: $settings.terminalDisplayConfiguration.scrollSensitivity,
                            in: TerminalDisplayConfiguration.scrollSensitivityRange, step: 0.05) {
                        TextField("Terminal scroll sensitivity", value: $settings.terminalDisplayConfiguration.scrollSensitivity,
                                  format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder).frame(width: 100)
                            .accessibilityLabel("Terminal scroll sensitivity")
                    }.fixedSize()
                }
            }
            section("Selection and links") {
                LitheSettingsCheckbox(isOn: $settings.terminalDisplayConfiguration.copyOnSelect, title: "Copy on selection")
                LitheSettingsCheckbox(isOn: $settings.terminalDisplayConfiguration.keepSelectionOnCopy, title: "Keep selection after manual copy")
                hint("Copy on selection keeps the selection. Applications that capture the mouse handle their own clicks.")
                row("Detect links") {
                    LitheSettingsSelect(selection: $settings.terminalDisplayConfiguration.linkDetection,
                                        options: TerminalDisplayConfiguration.LinkDetection.allCases, width: 220,
                                        accessibilityLabel: "Terminal link detection", title: \.title)
                }
                row("Open links with") {
                    LitheSettingsSelect(selection: $settings.terminalDisplayConfiguration.linkModifier,
                                        options: TerminalDisplayConfiguration.LinkModifier.allCases, width: 220,
                                        accessibilityLabel: "Terminal link modifier", title: \.title)
                        .disabled(settings.terminalDisplayConfiguration.linkDetection == .disabled)
                }
                hint("Drag or double-click to select link text. Command-click opens immediately.")
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(title)).fontWeight(.medium)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }
            content()
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(title)).frame(width: 145, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }.frame(minHeight: 30)
    }

    private func hint(_ text: String) -> some View {
        Text(LocalizedStringKey(text)).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
    }
}

private extension TerminalDisplayConfiguration.CursorShape {
    var title: String {
        switch self { case .block: "Block"; case .underline: "Underline"; case .bar: "Bar" }
    }
}

private extension TerminalDisplayConfiguration.LinkDetection {
    var title: String {
        switch self { case .automatic: "Automatic"; case .explicit: "Explicit hyperlinks only"; case .disabled: "Disabled" }
    }
}

private extension TerminalDisplayConfiguration.LinkModifier {
    var title: String {
        switch self { case .command: "Command-click"; case .none: "Click" }
    }
}
