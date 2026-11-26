import LitheCoreContracts
import SwiftUI

/// Status bar indicator and popover for switching between zero-LSP Lightweight Mode
/// and opt-in Precision LSP Mode for the current window.
struct LanguageIntelligenceStatusView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var isPopoverPresented = false

    private var usesChinese: Bool { settings.language == .simplifiedChinese }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.isLightweightIntelligenceMode ? "bolt.fill" : "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusAccentColor)
                Text(model.languageIntelligenceStatusTitle)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .lithePointer()
        .help(model.languageServerStatusMessage)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            intelligencePopover
        }
    }

    private var statusAccentColor: Color {
        if model.isLightweightIntelligenceMode {
            return LitheTheme.success
        }
        if let document = model.activeDocument,
           let providerID = model.languageProviderCatalog.provider(for: document.url)?.id,
           let state = model.languageToolingSessionsIfActive?.languageServerStates[providerID] {
            switch state {
            case .ready: return LitheTheme.accent
            case .failed: return LitheTheme.error
            case .startingProcess, .initializing: return LitheTheme.warning
            case .stopping, .stopped: break
            }
        }
        return LitheTheme.accent
    }

    private var intelligencePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.isLightweightIntelligenceMode ? "bolt.fill" : "sparkles")
                    .foregroundStyle(statusAccentColor)
                Text(usesChinese ? "代码智能引擎" : "Code Intelligence")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer(minLength: 8)
                Button {
                    isPopoverPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .litheIconButton()
                .help("Close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                modeOptionButton(
                    mode: .lightweight,
                    title: usesChinese ? "轻量模式（默认）" : "Lightweight Mode (Default)",
                    subtitle: usesChinese
                        ? "零 LSP 进程，极低内存，毫秒级高亮、折叠与跨文件符号跳转"
                        : "Zero LSP processes, low memory, instant folding & cross-file symbols",
                    icon: "bolt.fill"
                )
                modeOptionButton(
                    mode: .lsp,
                    title: usesChinese ? "精确 LSP 模式" : "Precision LSP Mode",
                    subtitle: usesChinese
                        ? "按需启动 gopls / rust-analyzer / basedpyright 提供类型检查与安全重构"
                        : "On-demand gopls / rust-analyzer / basedpyright for type checks & safe rename",
                    icon: "sparkles"
                )
            }
            .padding(10)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            HStack(spacing: 10) {
                if !model.isLightweightIntelligenceMode {
                    Button(usesChinese ? "重启 LSP" : "Restart LSP") {
                        isPopoverPresented = false
                        model.restartLanguageServers()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                }
                Spacer(minLength: 8)
                Button(usesChinese ? "语言设置…" : "Language Settings…") {
                    isPopoverPresented = false
                    model.showSettings(category: .lsp)
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: 300)
        .background(LitheTheme.popupBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func modeOptionButton(
        mode: LanguageIntelligenceMode,
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        let isSelected = model.effectiveLanguageIntelligenceMode == mode
        return Button {
            model.setSessionLanguageIntelligenceMode(mode)
            isPopoverPresented = false
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isSelected ? LitheTheme.accent : LitheTheme.secondaryText)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LitheTheme.accent)
                        .padding(.top, 2)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? LitheTheme.subtleSelection : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .lithePointer()
    }
}

/// Status bar line:column indicator. Visually unchanged from the plain text
/// label; clicking opens the Go to Line dialog (a no-op without an active
/// document).
struct EditorCaretPositionLabel: View {
    @ObservedObject var chrome: EditorChromeModel
    let onShowGoToLine: () -> Void

    var body: some View {
        Button {
            onShowGoToLine()
        } label: {
            Text(chrome.caret.map { "\($0.line + 1):\($0.utf16Column + 1)" } ?? "1:1")
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .lithePointer()
        .help("Go to Line…")
    }
}

struct MemoryUsageStatusView: View {
    @EnvironmentObject private var memoryUsageMonitor: MemoryUsageMonitor
    @State private var isMemoryUsagePopoverPresented = false

    var body: some View {
        Button {
            isMemoryUsagePopoverPresented.toggle()
        } label: {
            Label {
                HStack(spacing: 4) {
                    Text("Total \(memoryUsageMonitor.totalText)")
                    Text("·")
                    Text("Lithe \(memoryUsageMonitor.litheText)")
                }
                .monospacedDigit()
            } icon: {
                Image(systemName: "memorychip")
            }
        }
        .buttonStyle(.plain)
        .lithePointer()
        .help(
            Text(
                "Total managed memory: \(memoryUsageMonitor.totalText)\n" +
                "Lithe: \(memoryUsageMonitor.litheText) · LSP: \(memoryUsageMonitor.lspText) · Services: \(memoryUsageMonitor.serviceText)"
            )
        )
        .popover(isPresented: $isMemoryUsagePopoverPresented, arrowEdge: .top) {
            memoryUsagePopover
        }
        .onChange(of: isMemoryUsagePopoverPresented) { isPresented in
            memoryUsageMonitor.setDetailedUsageVisible(isPresented)
        }
    }

    private var memoryUsagePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .foregroundStyle(LitheTheme.accent)
                Text("Managed Memory")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer(minLength: 8)
                Button {
                    isMemoryUsagePopoverPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .litheIconButton()
                .help("Close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            VStack(spacing: 0) {
                memoryMetric("Lithe", value: memoryUsageMonitor.litheText)
                memoryMetric(
                    "Language servers",
                    value: memoryUsageMonitor.languageServerProcessCount == 0
                        ? String(localized: "Not running")
                        : memoryUsageMonitor.lspText
                )
                memoryMetric(
                    "Running services",
                    value: memoryUsageMonitor.serviceProcessCount == 0
                        ? String(localized: "Not running")
                        : memoryUsageMonitor.serviceText
                )
                memoryMetric("Total", value: memoryUsageMonitor.totalText)
                memoryMetric("Average total", value: memoryUsageMonitor.averageText)
                memoryMetric("Peak total", value: memoryUsageMonitor.peakText)
                memoryMetric("Runtime", value: memoryUsageMonitor.runtimeText)
                memoryMetric("Sample interval", value: memoryUsageMonitor.samplingIntervalText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                Text("Resident memory of Lithe and its managed process trees")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(LitheTheme.smallFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(12)
        }
        .frame(width: 280)
        .background(LitheTheme.popupBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func memoryMetric(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .monospacedDigit()
        }
        .frame(minHeight: 27)
    }
}

struct FrameRateStatusView: View {
    @EnvironmentObject private var frameRateMonitor: FrameRateMonitor

    var body: some View {
        Label {
            Text(frameRateMonitor.framesPerSecondText)
                .monospacedDigit()
        } icon: {
            Image(systemName: "speedometer")
        }
        .help("Frames rendered per second")
        .accessibilityLabel(Text("\(frameRateMonitor.framesPerSecond) frames per second"))
    }
}
