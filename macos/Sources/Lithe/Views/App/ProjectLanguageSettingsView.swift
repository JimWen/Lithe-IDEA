import AppKit
import SwiftUI

/// JetBrains-aligned (GoLand / RustRover / PyCharm) project-aware language configuration
/// page. Surfaces SDK/toolchain selection, language environment & library paths,
/// manifest dependency overview, and opt-in Precision LSP configuration without bloated
/// boilerplate options.
struct ProjectLanguageSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let category: SettingsCategory
    let editConfigurations: () -> Void

    @State private var executableDraft = ""
    @State private var envDrafts: [String: String] = [:]
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var isRefreshingEnv = false
    @State private var showLSPSetupDetails = false

    private var usesChinese: Bool { settings.language == .simplifiedChinese }
    private var command: String { category.runtimeCommand ?? "" }
    private var providerID: String { category.languageProviderID ?? "" }

    private var candidates: [RuntimeToolCandidate] {
        if category == .python {
            let py3 = model.runtimeFeature.executableCandidates("python3")
            let py = model.runtimeFeature.executableCandidates("python")
            var seen = Set<String>()
            return (py3 + py).filter { seen.insert($0.executableURL.standardizedFileURL.path).inserted }
        }
        return model.runtimeFeature.executableCandidates(command)
    }

    private var goSnapshot: GoProjectEnvironmentSnapshot? { model.projectEnvironmentSnapshot.go }
    private var rustSnapshot: RustProjectEnvironmentSnapshot? { model.projectEnvironmentSnapshot.rust }
    private var pythonSnapshot: PythonProjectEnvironmentSnapshot? { model.projectEnvironmentSnapshot.python }

    private var activeVersionBadge: String? {
        switch category {
        case .go: return goSnapshot?.version
        case .rust: return rustSnapshot?.rustcVersion ?? rustSnapshot?.activeToolchain
        case .python:
            guard let py = pythonSnapshot else { return nil }
            let base = py.version.map { "Python \($0)" }
            if let venv = py.virtualEnvName {
                return [base, "(\(venv))"].compactMap { $0 }.joined(separator: " ")
            }
            return base
        default: return nil
        }
    }

    private var isToolchainDetected: Bool {
        !candidates.isEmpty || !(executableDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var toolchainSectionTitle: String {
        switch category {
        case .go: usesChinese ? "Go SDK (GOROOT)" : "Go SDK (GOROOT)"
        case .rust: usesChinese ? "Rust 工具链 (Toolchain)" : "Rust Toolchain"
        case .python: usesChinese ? "Python 解释器" : "Python Interpreter"
        default: usesChinese ? "项目工具链" : "Project Toolchain"
        }
    }

    private var executablePlaceholder: String {
        switch category {
        case .go: usesChinese ? "自动检测 Go 可执行文件" : "Auto-detect Go SDK"
        case .rust: usesChinese ? "自动检测 Cargo / Rustup" : "Auto-detect Cargo"
        case .python: usesChinese ? "自动检测 .venv 或系统 Python" : "Auto-detect .venv or system Python"
        default: usesChinese ? "自动检测" : "Auto-detect"
        }
    }

    private var editableEnvKeys: [String] {
        switch category {
        case .go: ["GOPATH", "GOMODCACHE", "GOPROXY", "GOPRIVATE"]
        case .rust: ["CARGO_HOME", "RUSTUP_TOOLCHAIN", "RUSTFLAGS"]
        case .python: ["PYTHONPATH"]
        default: []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection
            toolchainSection
            environmentPathsSection
            dependenciesSection
            lspAndRunSection
        }
        .padding(16)
        .frame(maxWidth: 780, alignment: .leading)
        .foregroundStyle(LitheTheme.primaryText)
        .background(LitheTheme.settingsSurface)
        .task(id: "\(model.id)-\(providerID)") {
            loadDrafts()
            await model.prepareLanguageSettings()
            await refreshEnvironmentSnapshot()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(category.rawValue) · \(model.projectName)")
                        .font(.system(size: 15, weight: .semibold))
                    if let badge = activeVersionBadge {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(LitheTheme.success)
                                .frame(width: 6, height: 6)
                            Text(badge)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(LitheTheme.raised))
                    } else if !isToolchainDetected {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(LitheTheme.warning)
                                .frame(width: 6, height: 6)
                            Text(usesChinese ? "未检测到工具链" : "Toolchain not found")
                                .font(.system(size: 11))
                                .foregroundStyle(LitheTheme.warning)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(LitheTheme.warning.opacity(0.12)))
                    }
                }
                Text(usesChinese
                    ? "当前项目感知到的语言环境、库路径与依赖配置。修改将保存在项目的 .lithe/runtime.json 中，供 Run、Debug、终端与精确 LSP 共用。"
                    : "Project-aware SDK, environment, library paths, and dependencies saved in .lithe/runtime.json and shared across Run, Debug, Terminal, and Precision LSP.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                Task { await refreshEnvironmentSnapshot() }
            } label: {
                if isRefreshingEnv {
                    ProgressView().controlSize(.small)
                } else {
                    Label(usesChinese ? "刷新检测" : "Refresh", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(LitheSecondaryButtonStyle())
            .disabled(isRefreshingEnv)
        }
    }

    // MARK: - Section 1: SDK / Toolchain / Interpreter

    private var toolchainSection: some View {
        card(toolchainSectionTitle) {
            HStack(spacing: 8) {
                TextField(executablePlaceholder, text: $executableDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(saveExecutable)
                    .accessibilityLabel("Project executable")
                Button {
                    if let url = model.chooseProjectExecutable(language: category.rawValue) {
                        executableDraft = url.path
                        saveExecutable()
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .litheIconButton()
                .help(usesChinese ? "选择可执行文件" : "Choose executable")

                if !candidates.isEmpty {
                    Menu(usesChinese ? "已检测环境" : "Detected") {
                        ForEach(candidates) { candidate in
                            Button {
                                executableDraft = candidate.executableURL.path
                                saveExecutable()
                            } label: {
                                Text("\(candidate.source.displayName): \(candidate.executableURL.path)")
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Button(usesChinese ? "应用" : "Apply", action: saveExecutable)
                    .buttonStyle(LithePrimaryButtonStyle(
                        backgroundColor: LitheTheme.settingsPrimaryAction,
                        restingOpacity: 1
                    ))
                Button(usesChinese ? "自动检测" : "Auto-detect") {
                    executableDraft = ""
                    saveExecutable()
                }
                .buttonStyle(LitheSecondaryButtonStyle())
            }

            if let candidate = candidates.first {
                HStack(spacing: 6) {
                    Text(usesChinese ? "当前生效：" : "Effective:")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text(candidate.executableURL.path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.primaryText)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(candidate.source.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(LitheTheme.raised))
                }
            } else {
                Text(model.runtimeFeature.toolGuidance(command).message)
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(LitheTheme.error)
                    .font(LitheTheme.smallFont)
            } else if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(LitheTheme.accent)
                    .font(LitheTheme.smallFont)
            }
        }
    }

    // MARK: - Section 2: Environment & Library Paths

    private var environmentPathsSection: some View {
        card(usesChinese ? "环境变量与库路径" : "Environment & Library Paths") {
            switch category {
            case .go:
                goEnvironmentBody
            case .rust:
                rustEnvironmentBody
            case .python:
                pythonEnvironmentBody
            default:
                EmptyView()
            }

            HStack(spacing: 8) {
                Spacer()
                Button(usesChinese ? "恢复自动检测" : "Reset Overrides") {
                    resetEnvironmentOverrides()
                }
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(!hasAnyEnvOverride)

                Button(usesChinese ? "保存环境配置" : "Save Environment") {
                    saveEnvironmentOverrides()
                }
                .buttonStyle(LithePrimaryButtonStyle(
                    backgroundColor: LitheTheme.settingsPrimaryAction,
                    restingOpacity: 1
                ))
            }
        }
    }

    @ViewBuilder
    private var goEnvironmentBody: some View {
        readOnlyPathRow(
            label: "GOROOT",
            value: goSnapshot?.goRoot,
            missingText: usesChinese ? "未检测到 GOROOT" : "GOROOT not detected"
        )
        editableEnvRow(
            key: "GOPATH",
            placeholder: goSnapshot?.goPath ?? "~/go",
            supportsDirectoryPicker: true
        )
        editableEnvRow(
            key: "GOMODCACHE",
            placeholder: goSnapshot?.goModCache ?? "~/go/pkg/mod",
            supportsDirectoryPicker: true
        )
        editableEnvRow(
            key: "GOPROXY",
            placeholder: goSnapshot?.goProxy ?? "https://proxy.golang.org,direct",
            supportsDirectoryPicker: false
        )
        editableEnvRow(
            key: "GOPRIVATE",
            placeholder: goSnapshot?.goPrivate ?? (usesChinese ? "例如 git.corp.com/*" : "e.g. git.corp.com/*"),
            supportsDirectoryPicker: false
        )
    }

    @ViewBuilder
    private var rustEnvironmentBody: some View {
        readOnlyPathRow(
            label: "Sysroot",
            value: rustSnapshot?.sysrootPath,
            missingText: usesChinese ? "未检测到 rustc sysroot" : "rustc sysroot not detected"
        )
        readOnlyPathRow(
            label: usesChinese ? "标准库 (rust-src)" : "Standard Library",
            value: rustSnapshot?.stdLibURL?.path,
            missingText: usesChinese
                ? "未安装 rust-src（可运行 rustup component add rust-src 以在外部库中浏览标准库源码）"
                : "rust-src not installed (run `rustup component add rust-src` to browse stdlib source)"
        )
        editableEnvRow(
            key: "CARGO_HOME",
            placeholder: rustSnapshot?.cargoHome ?? "~/.cargo",
            supportsDirectoryPicker: true
        )
        editableEnvRow(
            key: "RUSTUP_TOOLCHAIN",
            placeholder: rustSnapshot?.activeToolchain ?? "stable",
            supportsDirectoryPicker: false
        )
        editableEnvRow(
            key: "RUSTFLAGS",
            placeholder: usesChinese ? "可选附加编译参数" : "Optional compiler flags",
            supportsDirectoryPicker: false
        )
    }

    @ViewBuilder
    private var pythonEnvironmentBody: some View {
        readOnlyPathRow(
            label: pythonSnapshot?.isVirtualEnvironment == true
                ? (usesChinese ? "虚拟环境 (prefix)" : "Virtual Env (prefix)")
                : "sys.prefix",
            value: pythonSnapshot?.prefixPath,
            missingText: usesChinese ? "未检测到 Python 环境" : "Python prefix not detected"
        )
        readOnlyPathRow(
            label: "stdlib",
            value: pythonSnapshot?.stdLibURL?.path,
            missingText: usesChinese ? "未检测到标准库路径" : "stdlib path not detected"
        )
        if let sitePackages = pythonSnapshot?.sitePackagesURLs, !sitePackages.isEmpty {
            ForEach(Array(sitePackages.enumerated()), id: \.offset) { index, url in
                readOnlyPathRow(
                    label: index == 0 ? "site-packages" : "site-packages #\(index + 1)",
                    value: url.path,
                    missingText: ""
                )
            }
        } else {
            readOnlyPathRow(
                label: "site-packages",
                value: nil,
                missingText: usesChinese ? "未检测到 site-packages 目录" : "site-packages directory not detected"
            )
        }
        editableEnvRow(
            key: "PYTHONPATH",
            placeholder: pythonSnapshot?.pythonPath ?? (usesChinese ? "额外模块搜索路径（以 : 分隔）" : "Extra module search paths (: separated)"),
            supportsDirectoryPicker: true
        )
    }

    // MARK: - Section 3: Dependencies & External Libraries Overview

    private var dependenciesSection: some View {
        let deps = activeDependencies
        let manifestURL = activeManifestURL

        return card(usesChinese ? "项目依赖与外部库" : "Dependencies & External Libraries") {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dependencySummaryTitle)
                        .font(.system(size: 12.5, weight: .medium))
                    Text(usesChinese
                        ? "完整依赖树与只读源码浏览已同步至左侧 Project 侧边栏底部的「外部库 (External Libraries)」。"
                        : "Browse the full read-only SDK and dependency source tree under External Libraries in the Project sidebar.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer(minLength: 8)
                if let manifestURL {
                    Button(usesChinese ? "打开 \(manifestURL.lastPathComponent)" : "Open \(manifestURL.lastPathComponent)") {
                        model.openFile(manifestURL)
                    }
                    .buttonStyle(LitheSecondaryButtonStyle())
                }
                if category == .go && model.isGoAvailable {
                    Button(usesChinese ? "打开 Go Tools" : "Open Go Tools") {
                        model.isGoVisible = true
                        if model.goProjectFeatureIfActive?.snapshot == nil { model.refreshGoProject() }
                    }
                    .buttonStyle(LitheSecondaryButtonStyle())
                } else if category == .rust && model.isCargoAvailable {
                    Button(usesChinese ? "打开 Cargo" : "Open Cargo") {
                        model.isCargoVisible = true
                        if model.cargoProjectFeatureIfActive?.snapshot == nil { model.refreshCargoProject() }
                    }
                    .buttonStyle(LitheSecondaryButtonStyle())
                }
            }

            if !deps.isEmpty {
                VStack(spacing: 0) {
                    let preview = Array(deps.prefix(8))
                    ForEach(Array(preview.enumerated()), id: \.element.id) { index, dep in
                        HStack(spacing: 8) {
                            Image(systemName: dep.isDirect ? "shippingbox" : "shippingbox.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(dep.isDirect ? LitheTheme.accent : LitheTheme.tertiaryText)
                            Text(dep.name)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                            if !dep.isDirect {
                                Text("indirect")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(LitheTheme.tertiaryText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(LitheTheme.raised))
                            }
                            Spacer(minLength: 6)
                            Text(dep.displaySubtitle)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .lineLimit(1)
                            if let srcURL = dep.sourceDirectoryURL {
                                Button {
                                    model.revealProjectItemInFinder(srcURL)
                                } label: {
                                    Image(systemName: "folder")
                                        .font(.system(size: 11))
                                }
                                .litheIconButton()
                                .help(usesChinese ? "在 Finder 中显示缓存源码" : "Reveal cached source in Finder")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        if index < preview.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(LitheTheme.inputBackground.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.divider, lineWidth: 1))

                if deps.count > 8 {
                    Text(usesChinese
                        ? "还有 \(deps.count - 8) 个依赖，请在左侧 Project → External Libraries 中展开查看源码。"
                        : "\(deps.count - 8) more dependencies available under Project → External Libraries.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
        }
    }

    // MARK: - Section 4: Precision LSP & Run Configurations

    private var lspAndRunSection: some View {
        card(usesChinese ? "精确 LSP 与运行配置" : "Precision LSP & Run Configurations") {
            HStack(spacing: 10) {
                LitheSettingsCheckbox(
                    isOn: Binding(
                        get: { !model.isLanguageServerDisabledInCurrentWorkspace(providerID: providerID) },
                        set: { model.setLanguageServerEnabled($0, providerID: providerID) }
                    ),
                    title: LocalizedStringKey(usesChinese
                        ? "在精确 LSP 模式下启用 \(category.rawValue) 语言服务器"
                        : "Enable \(category.rawValue) language server in Precision LSP mode")
                )
                Spacer(minLength: 8)
                Button(usesChinese ? "编辑运行配置…" : "Edit Configurations…", action: editConfigurations)
                    .buttonStyle(LitheSecondaryButtonStyle())
            }

            HStack(spacing: 8) {
                Image(systemName: model.isLightweightIntelligenceMode ? "bolt" : "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.accent)
                Text(model.isLightweightIntelligenceMode
                    ? (usesChinese
                        ? "当前窗口处于轻量模式（零 LSP 进程）。点击右侧按钮可按需开启精确 LSP。"
                        : "This window is in Lightweight Mode (zero LSP processes). Enable Precision LSP on demand when needed.")
                    : (usesChinese
                        ? "当前窗口已启用精确 LSP 模式。"
                        : "Precision LSP mode is active for this window."))
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer(minLength: 8)
                Button(model.isLightweightIntelligenceMode
                    ? (usesChinese ? "开启精确 LSP" : "Enable Precision LSP")
                    : (usesChinese ? "切回轻量模式" : "Switch to Lightweight")) {
                    model.toggleSessionLanguageIntelligenceMode()
                }
                .buttonStyle(LitheSecondaryButtonStyle())
            }

            DisclosureGroup(
                usesChinese ? "语言服务器可执行文件与安装" : "Language Server Executable & Installation",
                isExpanded: $showLSPSetupDetails
            ) {
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
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.divider, lineWidth: 1))
                    .padding(.top, 8)
                } else {
                    ProgressView(usesChinese ? "正在加载语言服务设置…" : "Loading language settings…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .font(.system(size: 12, weight: .medium))
        }
    }

    // MARK: - Helpers

    private var activeDependencies: [ProjectDependencyItem] {
        switch category {
        case .go: return goSnapshot?.dependencies ?? []
        case .rust: return rustSnapshot?.dependencies ?? []
        case .python: return pythonSnapshot?.dependencies ?? []
        default: return []
        }
    }

    private var activeManifestURL: URL? {
        switch category {
        case .go: return goSnapshot?.manifestURL ?? model.goManifestURL
        case .rust: return rustSnapshot?.manifestURL ?? model.cargoManifestURL
        case .python: return pythonSnapshot?.manifestURL ?? model.pythonManifestURLs.first
        default: return nil
        }
    }

    private var dependencySummaryTitle: String {
        switch category {
        case .go:
            let mod = goSnapshot?.moduleName ?? "go.mod"
            let directive = goSnapshot?.goDirective.map { " · go \($0)" } ?? ""
            let direct = goSnapshot?.directDependencies.count ?? 0
            let total = goSnapshot?.dependencies.count ?? 0
            return usesChinese
                ? "\(mod)\(directive)（直接依赖 \(direct) / 总计 \(total)）"
                : "\(mod)\(directive) (\(direct) direct / \(total) total)"
        case .rust:
            let crate = rustSnapshot?.crateName ?? "Cargo.toml"
            let count = rustSnapshot?.dependencies.count ?? 0
            return usesChinese ? "\(crate)（\(count) 个依赖 crate）" : "\(crate) (\(count) dependencies)"
        case .python:
            let count = pythonSnapshot?.dependencies.count ?? 0
            let spCount = pythonSnapshot?.sitePackagesURLs.count ?? 0
            return usesChinese
                ? "声明依赖 \(count) 项 · \(spCount) 个 site-packages 目录"
                : "\(count) declared dependencies · \(spCount) site-packages locations"
        default:
            return ""
        }
    }

    private var hasAnyEnvOverride: Bool {
        editableEnvKeys.contains { key in
            !(model.runtimeFeature.customEnvironmentValue(for: key) ?? "").isEmpty
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                .fill(LitheTheme.settingsSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                .stroke(LitheTheme.divider, lineWidth: 1)
        )
    }

    private func readOnlyPathRow(label: String, value: String?, missingText: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 130, alignment: .trailing)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(value)
                Spacer(minLength: 4)
                Button {
                    copyToPasteboard(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .litheIconButton()
                .help(usesChinese ? "复制路径" : "Copy path")
                Button {
                    model.revealProjectItemInFinder(URL(fileURLWithPath: value))
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .litheIconButton()
                .help(usesChinese ? "在 Finder 中显示" : "Reveal in Finder")
            } else {
                Text(missingText)
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
            }
        }
        .frame(minHeight: 24)
    }

    private func editableEnvRow(
        key: String,
        placeholder: String,
        supportsDirectoryPicker: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 130, alignment: .trailing)
            TextField(placeholder, text: Binding(
                get: { envDrafts[key] ?? "" },
                set: { envDrafts[key] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .onSubmit(saveEnvironmentOverrides)

            if supportsDirectoryPicker {
                Button {
                    if let dir = model.chooseProjectDirectory(title: usesChinese ? "选择 \(key) 目录" : "Choose \(key) Directory") {
                        envDrafts[key] = dir.path
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .litheIconButton()
                .help(usesChinese ? "选择目录" : "Choose directory")
            }
        }
        .frame(minHeight: 26)
    }

    private func loadDrafts() {
        executableDraft = model.runtimeFeature.customExecutablePath(for: command) ?? ""
        var next: [String: String] = [:]
        for key in editableEnvKeys {
            next[key] = model.runtimeFeature.customEnvironmentValue(for: key) ?? ""
        }
        envDrafts = next
        errorMessage = nil
        statusMessage = nil
    }

    private func saveExecutable() {
        do {
            try model.runtimeFeature.setCustomExecutablePath(executableDraft, for: command)
            if command == "go" { model.goToolchainDidChange() }
            executableDraft = model.runtimeFeature.customExecutablePath(for: command) ?? ""
            errorMessage = nil
            statusMessage = usesChinese ? "已保存项目工具链设置。" : "Saved project toolchain setting."
            Task { await refreshEnvironmentSnapshot() }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    private func saveEnvironmentOverrides() {
        do {
            for key in editableEnvKeys {
                try model.runtimeFeature.setCustomEnvironmentValue(envDrafts[key] ?? "", for: key)
            }
            if category == .go { model.goToolchainDidChange() }
            errorMessage = nil
            statusMessage = usesChinese ? "已保存项目环境变量配置。" : "Saved project environment overrides."
            Task { await refreshEnvironmentSnapshot() }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    private func resetEnvironmentOverrides() {
        do {
            for key in editableEnvKeys {
                envDrafts[key] = ""
                try model.runtimeFeature.setCustomEnvironmentValue("", for: key)
            }
            if category == .go { model.goToolchainDidChange() }
            errorMessage = nil
            statusMessage = usesChinese ? "已恢复为自动检测环境。" : "Reset environment overrides to auto-detect."
            Task { await refreshEnvironmentSnapshot() }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    private func refreshEnvironmentSnapshot() async {
        isRefreshingEnv = true
        defer { isRefreshingEnv = false }
        await model.refreshProjectEnvironmentSnapshot()?.value
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
