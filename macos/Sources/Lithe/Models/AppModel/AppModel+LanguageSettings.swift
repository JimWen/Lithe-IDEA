import Foundation
import LitheLanguageIntelligenceModule

@MainActor
extension AppModel {
    var pythonManifestURLs: [URL] {
        let priority: [String: Int] = [
            "pyproject.toml": 0,
            "requirements.txt": 1,
            "pipfile": 2,
            "setup.py": 3
        ]
        return projectFiles
            .filter { priority[$0.lastPathComponent.lowercased()] != nil }
            .sorted { lhs, rhs in
                let lhsDepth = lhs.pathComponents.count
                let rhsDepth = rhs.pathComponents.count
                if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                let lhsRank = priority[lhs.lastPathComponent.lowercased()] ?? 99
                let rhsRank = priority[rhs.lastPathComponent.lowercased()] ?? 99
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.path < rhs.path
            }
    }

    var hasDetectedGoProject: Bool {
        hasDetectedLanguage(id: "go", manifestNames: ["go.mod", "go.work"])
    }

    var hasDetectedRustProject: Bool {
        hasDetectedLanguage(id: "rust", manifestNames: ["cargo.toml"])
    }

    var hasDetectedPythonProject: Bool {
        hasDetectedLanguage(id: "python", manifestNames: ["pyproject.toml", "requirements.txt", "pipfile", "setup.py"])
    }

    private func hasDetectedLanguage(id: String, manifestNames: Set<String>) -> Bool {
        if projectFiles.contains(where: { manifestNames.contains($0.lastPathComponent.lowercased()) }) {
            return true
        }
        guard let provider = languageProviderCatalog.descriptors.first(where: { $0.id == id }) else {
            return false
        }
        return projectFiles.contains(where: provider.handles(fileURL:))
            || activeDocument.map { provider.handles(fileURL: $0.url) } == true
    }

    func resetProjectEnvironmentSnapshot() {
        projectEnvironmentRefreshTask?.cancel()
        projectEnvironmentRefreshTask = nil
        projectEnvironmentGeneration &+= 1
        projectEnvironmentSnapshot = ProjectEnvironmentSnapshot()
    }

    /// Inspects detected Go, Rust, and Python environments and dependency caches off
    /// the MainActor so Settings and External Libraries stay responsive without blocking UI.
    @discardableResult
    func refreshProjectEnvironmentSnapshot(for targetURL: URL? = nil) -> Task<Void, Never>? {
        guard let root = (targetURL ?? workspaceURL)?.standardizedFileURL else {
            resetProjectEnvironmentSnapshot()
            return nil
        }
        let detectGo = hasDetectedGoProject
        let detectRust = hasDetectedRustProject
        let detectPython = hasDetectedPythonProject
        guard detectGo || detectRust || detectPython else {
            resetProjectEnvironmentSnapshot()
            return nil
        }

        projectEnvironmentRefreshTask?.cancel()
        projectEnvironmentGeneration &+= 1
        let generation = projectEnvironmentGeneration
        let operationID = "project-env-\(generation)-\(UUID().uuidString)"
        let inspector = services.projectEnvironmentInspector
        let environment = runtimeFeature.processEnvironment()
        let goExec = detectGo ? runtimeFeature.executableOnPath("go") : nil
        let goManifest = detectGo ? goManifestURL : nil
        let cargoExec = detectRust ? runtimeFeature.executableOnPath("cargo") : nil
        let cargoManifest = detectRust ? cargoManifestURL : nil
        let pythonExec = detectPython
            ? (runtimeFeature.executableOnPath("python3") ?? runtimeFeature.executableOnPath("python"))
            : nil
        let pythonManifest = detectPython ? pythonManifestURLs.first : nil

        let task = Task { @MainActor [weak self] in
            let snapshot = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) { () -> ProjectEnvironmentSnapshot in
                    var result = ProjectEnvironmentSnapshot()
                    if detectGo, !Task.isCancelled {
                        result.go = inspector.inspectGo(
                            workspaceURL: root,
                            manifestURL: goManifest,
                            executableURL: goExec,
                            environment: environment,
                            operationID: operationID
                        )
                    }
                    if detectRust, !Task.isCancelled {
                        result.rust = inspector.inspectRust(
                            workspaceURL: root,
                            manifestURL: cargoManifest,
                            cargoURL: cargoExec,
                            environment: environment,
                            operationID: operationID
                        )
                    }
                    if detectPython, !Task.isCancelled {
                        result.python = inspector.inspectPython(
                            workspaceURL: root,
                            manifestURL: pythonManifest,
                            pythonURL: pythonExec,
                            environment: environment,
                            operationID: operationID
                        )
                    }
                    return result
                }.value
            } onCancel: {
                inspector.cancelInspection(operationID: operationID)
            }
            guard !Task.isCancelled,
                  let self,
                  self.workspaceURL?.standardizedFileURL == root,
                  self.projectEnvironmentGeneration == generation else { return }
            self.projectEnvironmentSnapshot = snapshot
        }
        projectEnvironmentRefreshTask = task
        return task
    }

    func scheduleProjectRuntimeEnvironmentPrompt(for projectURL: URL) {
        let normalizedProjectURL = projectURL.standardizedFileURL
        let refreshTask = refreshProjectEnvironmentSnapshot(for: normalizedProjectURL)

        struct DetectedLanguagePromptTarget {
            let id: String
            let command: String
            let displayName: String
            let action: WorkbenchNotificationAction
            let hasManifest: Bool
        }

        var targets: [DetectedLanguagePromptTarget] = []
        if !goManifestURLs.isEmpty {
            targets.append(.init(
                id: "go", command: "go", displayName: "Go",
                action: .configureGoRuntime, hasManifest: true
            ))
        }
        if !cargoManifestURLs.isEmpty {
            targets.append(.init(
                id: "rust", command: "cargo", displayName: "Rust",
                action: .configureRustRuntime, hasManifest: true
            ))
        }
        if !pythonManifestURLs.isEmpty || hasDetectedPythonProject {
            targets.append(.init(
                id: "python", command: "python3", displayName: "Python",
                action: .configurePythonRuntime, hasManifest: !pythonManifestURLs.isEmpty
            ))
        }
        guard !targets.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self, self.workspaceURL?.standardizedFileURL == normalizedProjectURL else { return }
            await refreshTask?.value
            guard !Task.isCancelled,
                  self.workspaceURL?.standardizedFileURL == normalizedProjectURL else { return }

            let usesChinese = self.settings.language == .simplifiedChinese

            // Prioritize reporting any missing toolchain first as a warning; otherwise surface
            // a single concise project-aware environment summary for the primary manifest language
            // when no project-local override has been saved yet.
            for target in targets {
                let candidate: URL? = target.command == "python3"
                    ? (self.runtimeFeature.executableOnPath("python3") ?? self.runtimeFeature.executableOnPath("python"))
                    : self.runtimeFeature.executableOnPath(target.command)
                if candidate == nil {
                    self.showNotification(
                        usesChinese
                            ? "检测到 \(target.displayName) 项目，但未找到可用工具链。请配置项目运行环境与库路径。"
                            : "Detected a \(target.displayName) project, but no toolchain was found. Configure the project environment and library paths.",
                        severity: .warning,
                        title: usesChinese ? "配置 \(target.displayName) 环境" : "Configure \(target.displayName) Environment",
                        action: target.action
                    )
                    return
                }
            }

            guard let primary = targets.first(where: \.hasManifest) ?? targets.first,
                  self.runtimeFeature.customExecutablePath(for: primary.command) == nil,
                  self.runtimeFeature.customEnvironmentOverrides.isEmpty else { return }

            let detailSummary: String
            switch primary.id {
            case "go":
                let ver = self.projectEnvironmentSnapshot.go?.version ?? "Go SDK"
                let depCount = self.projectEnvironmentSnapshot.go?.dependencies.count ?? 0
                detailSummary = usesChinese
                    ? "已识别 Go 项目（\(ver)，\(depCount) 个模块依赖）。点击可查看或调整 GOROOT / GOPATH / GOMODCACHE 与外部库。"
                    : "Detected Go project (\(ver), \(depCount) module dependencies). Click to review GOROOT, GOPATH, GOMODCACHE, and external libraries."
            case "rust":
                let ver = self.projectEnvironmentSnapshot.rust?.rustcVersion
                    ?? self.projectEnvironmentSnapshot.rust?.activeToolchain
                    ?? "Cargo"
                let depCount = self.projectEnvironmentSnapshot.rust?.dependencies.count ?? 0
                detailSummary = usesChinese
                    ? "已识别 Rust 项目（\(ver)，\(depCount) 个依赖）。点击可查看或调整 Toolchain、sysroot 与 Cargo 路径。"
                    : "Detected Rust project (\(ver), \(depCount) dependencies). Click to review toolchain, sysroot, and Cargo paths."
            case "python":
                let snap = self.projectEnvironmentSnapshot.python
                let ver = snap?.version.map { "Python \($0)" } ?? "Python"
                let envLabel = snap?.isVirtualEnvironment == true
                    ? (snap?.virtualEnvName.map { " · \($0)" } ?? " · venv")
                    : ""
                detailSummary = usesChinese
                    ? "已识别 Python 项目（\(ver)\(envLabel)）。点击可查看或切换解释器、虚拟环境与 site-packages 路径。"
                    : "Detected Python project (\(ver)\(envLabel)). Click to review interpreter, virtual environment, and site-packages paths."
            default:
                return
            }

            self.showNotification(
                detailSummary,
                severity: .information,
                title: usesChinese ? "\(primary.displayName) 项目环境" : "\(primary.displayName) Project Environment",
                action: primary.action
            )
        }
    }

    func chooseProjectExecutable(language: String) -> URL? {
        platformUI.chooseFile(
            title: settings.language == .simplifiedChinese
                ? "选择 \(language) 项目可执行文件" : "Choose \(language) project executable",
            prompt: settings.language == .simplifiedChinese ? "选择" : "Choose"
        )
    }

    func chooseProjectDirectory(title: String) -> URL? {
        platformUI.chooseDirectory(
            title: title,
            prompt: settings.language == .simplifiedChinese ? "选择" : "Choose"
        )
    }

    func externalLibraryEntries(at directoryURL: URL) async -> [ExternalLibraryFileEntry] {
        let inspector = services.projectEnvironmentInspector
        return await Task.detached(priority: .userInitiated) {
            inspector.listDirectory(at: directoryURL)
        }.value
    }

    func openExternalLibraryFile(_ url: URL, displayPrefix: String? = nil) {
        let displayPath: String?
        if let displayPrefix, !displayPrefix.isEmpty {
            displayPath = "\(displayPrefix)/\(url.lastPathComponent)"
        } else {
            displayPath = url.lastPathComponent
        }
        openFile(url, isReadOnly: true, displayPath: displayPath)
    }

    var availableSettingsCategories: [SettingsCategory] {
        return SettingsCategory.allCases.filter { category in
            switch category {
            case .go: return hasDetectedGoProject
            case .rust: return hasDetectedRustProject
            case .python: return hasDetectedPythonProject
            default: return true
            }
        }
    }

    func prepareLanguageSettings() async {
        if let capability = languageCapability {
            capability.ensureDiscoveryStarted()
            return
        }
        do {
            let value = try await services.moduleRuntime.activateCapability(.languageIntelligence)
            guard let capability = value as? LitheLanguageIntelligenceModule.LanguageIntelligenceCapability else { return }
            bindLanguageIntelligenceCapability(capability)
            capability.ensureDiscoveryStarted()
        } catch {
            showNotification(error.localizedDescription, severity: .error, title: "Could not load language settings")
        }
    }
}
