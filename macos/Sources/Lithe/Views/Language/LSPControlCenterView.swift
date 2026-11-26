import LitheCoreContracts
import SwiftUI

struct LSPControlCenterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    private var usesChinese: Bool { settings.language == .simplifiedChinese }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intelligenceModeSection
                    projectSummary
                    if projectLanguageServers.isEmpty {
                        emptyState
                    } else {
                        ForEach(projectLanguageServers) { descriptor in
                            languageRow(descriptor)
                        }
                    }
                    if model.languageProviderCatalogSnapshot.isDegraded {
                        degradedCatalogNotice
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
            .background(LitheTheme.settingsSurface)
        }
        .background(LitheTheme.settingsSurface)
    }

    private var header: some View {
        HStack {
            Text(usesChinese ? "语言支持" : "Language Support")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(LitheTheme.settingsSurface)
    }

    private var intelligenceModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(usesChinese ? "代码智能模式" : "Code Intelligence Mode")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text(usesChinese
                        ? "默认使用轻量模式（零 LSP 常驻进程，毫秒级高亮、折叠、跨文件符号跳转/悬停/参数提示与引用检索）；需要精确类型诊断或跨文件重命名时可按需开启精确 LSP。"
                        : "Lightweight Mode is the default (zero background LSP processes; instant highlighting, folding, cross-file jump, hover, signature help, and references). Enable Precision LSP on demand for type diagnostics and safe cross-file rename.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker(
                    usesChinese ? "代码智能模式" : "Code Intelligence Mode",
                    selection: Binding(
                        get: { settings.languageIntelligenceMode },
                        set: { model.applyGlobalLanguageIntelligenceMode($0) }
                    )
                ) {
                    Text(usesChinese ? "轻量模式（默认）" : "Lightweight (Default)")
                        .tag(LanguageIntelligenceMode.lightweight)
                    Text(usesChinese ? "精确 LSP" : "Precision LSP")
                        .tag(LanguageIntelligenceMode.lsp)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            if let overrideMode = model.sessionLanguageIntelligenceModeOverride {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.circle")
                        .foregroundStyle(LitheTheme.accent)
                    Text(usesChinese
                        ? "当前窗口临时覆盖为：\(overrideMode == .lsp ? "精确 LSP" : "轻量模式")"
                        : "This window currently overrides the global default: \(overrideMode == .lsp ? "Precision LSP" : "Lightweight Mode")")
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Spacer(minLength: 8)
                    Button(usesChinese ? "恢复默认" : "Reset") {
                        model.setSessionLanguageIntelligenceMode(settings.languageIntelligenceMode)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .medium))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                .fill(LitheTheme.settingsSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                .stroke(LitheTheme.divider, lineWidth: 1)
        }
    }

    private var projectSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.projectName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(usesChinese
                ? "仅显示当前项目使用的语言。开关状态会自动为此项目保存，关闭后会停止语言服务器并释放资源，下次打开仍保持关闭。"
                : "Only languages used by this project are shown. Changes are saved automatically for this project. Turning a language off stops its server, releases its resources, and keeps it off when you reopen the project.")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func languageRow(_ descriptor: LanguageProviderDescriptor) -> some View {
        let status = serverStatus(for: descriptor)
        let isEnabled = !model.isLanguageServerDisabledInCurrentWorkspace(providerID: descriptor.id)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(descriptor.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text(statusDescription(for: descriptor, status: status))
                        .font(.system(size: 11))
                        .foregroundStyle(status == .error ? LitheTheme.error : LitheTheme.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                LitheSettingsCheckbox(
                    isOn: Binding(
                        get: { isEnabled },
                        set: { model.setLanguageServerEnabled($0, providerID: descriptor.id) }
                    ),
                    accessibilityLabel: LocalizedStringKey(usesChinese
                        ? "启用 \(descriptor.displayName) 语言服务器"
                        : "Enable \(descriptor.displayName) language server")
                )
            }

        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                .fill(LitheTheme.settingsSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                .stroke(LitheTheme.divider, lineWidth: 1)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(usesChinese ? "当前项目没有可配置的语言服务器" : "No configurable language servers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(usesChinese
                ? "识别到支持的源码语言后，会在这里显示对应设置。"
                : "Settings appear here when supported source languages are detected.")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .padding(.vertical, 10)
    }

    private var degradedCatalogNotice: some View {
        Label(
            usesChinese ? "语言服务器配置加载异常，当前正在使用兼容配置。" : "Language server configuration is degraded; compatibility settings are in use.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.system(size: 11))
        .foregroundStyle(LitheTheme.warning)
    }

    private var projectLanguageServers: [LanguageProviderDescriptor] {
        LSPControlCenterPresenter.projectLanguageServers(
            catalog: model.languageProviderCatalog,
            files: model.projectFiles
        )
    }

    private func serverStatus(for descriptor: LanguageProviderDescriptor) -> LSPServerStatus {
        LSPControlCenterPresenter.serverStatus(
            isDisabled: model.isLanguageServerDisabledInCurrentWorkspace(providerID: descriptor.id),
            sessionState: model.languageToolingSessionsIfActive?.languageServerStates[descriptor.id]
        )
    }

    private func statusDescription(
        for descriptor: LanguageProviderDescriptor,
        status: LSPServerStatus
    ) -> String {
        switch status {
        case .starting: return usesChinese ? "正在启动" : "Starting"
        case .initializing: return usesChinese ? "正在初始化项目索引" : "Initializing project index"
        case .active: return usesChinese ? "运行中" : "Running"
        case .stopping: return usesChinese ? "正在停止" : "Stopping"
        case .disabled: return usesChinese ? "已关闭" : "Off"
        case .stopped:
            if model.isLightweightIntelligenceMode {
                return usesChinese ? "待机（轻量模式，未启动进程）" : "Standby (Lightweight Mode)"
            }
            return usesChinese ? "按需启动，打开对应文件时运行" : "Starts on demand when a matching file is opened"
        case .error:
            if descriptor.id == "java" {
                return usesChinese
                    ? "启动失败，请检查 LSP 运行 JDK"
                    : "Failed to start; check the LSP runtime JDK"
            }
            return usesChinese
                ? "启动失败，请检查语言服务器配置"
                : "Failed to start; check the language server configuration"
        }
    }

    private func statusColor(_ status: LSPServerStatus) -> Color {
        switch status {
        case .starting, .initializing: LitheTheme.accent
        case .active: LitheTheme.success
        case .stopping: LitheTheme.warning
        case .stopped, .disabled: LitheTheme.secondaryText
        case .error: LitheTheme.error
        }
    }
}
