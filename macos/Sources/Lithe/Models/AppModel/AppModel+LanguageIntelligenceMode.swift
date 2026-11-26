import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule

@MainActor
extension AppModel {
    /// Active intelligence mode for this project window (session override wins over global setting).
    var effectiveLanguageIntelligenceMode: LanguageIntelligenceMode {
        sessionLanguageIntelligenceModeOverride ?? observedGlobalLanguageIntelligenceMode
    }

    var isLightweightIntelligenceMode: Bool {
        effectiveLanguageIntelligenceMode == .lightweight
    }

    /// Concise status bar label describing the active intelligence mode or running LSP.
    var languageIntelligenceStatusTitle: String {
        let usesChinese = settings.language == .simplifiedChinese
        if isLightweightIntelligenceMode {
            return usesChinese ? "轻量模式" : "Lightweight"
        }
        if let document = activeDocument,
           let descriptor = languageProviderCatalog.provider(for: document.url),
           descriptor.capabilities.contains(.languageServer) {
            let state = languageToolingSessionsIfActive?.languageServerStates[descriptor.id]
            switch state {
            case .startingProcess, .initializing:
                return usesChinese ? "\(descriptor.displayName) LSP 启动中…" : "\(descriptor.displayName) LSP…"
            case .ready:
                return "\(descriptor.displayName) LSP"
            case .failed:
                return usesChinese ? "\(descriptor.displayName) LSP 异常" : "\(descriptor.displayName) LSP !"
            case .stopping, .stopped, nil:
                break
            }
        }
        let activeCount = languageToolingSessionsIfActive?.activeLanguageServerIDs.count ?? 0
        if activeCount > 0 {
            return usesChinese ? "精确 LSP (\(activeCount))" : "LSP (\(activeCount))"
        }
        return usesChinese ? "精确 LSP" : "Precision LSP"
    }

    /// Activates the in-process language intelligence module without launching any
    /// external LSP server or executable-validation subprocesses.
    func ensureLightweightLanguageIntelligenceActive() {
        if languageToolingSessionsIfActive != nil { return }
        guard let snapshot = try? services.moduleRuntime.snapshot(for: .languageIntelligence),
              snapshot.state != .disabled,
              !snapshot.isQuarantined,
              !snapshot.isSuppressedBySafeMode else { return }

        let identity = currentWorkspaceIdentity
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.awaitModuleRuntimeShutdown()
            guard self.currentWorkspaceIdentity == identity,
                  self.languageToolingSessionsIfActive == nil else { return }
            do {
                let value = try await self.services.moduleRuntime.activateCapability(.languageIntelligence)
                guard self.currentWorkspaceIdentity == identity,
                      let capability = value as? LanguageIntelligenceCapability else { return }
                self.bindLanguageIntelligenceCapability(capability)
            } catch {
                // Lightweight activation is best-effort; plain editing remains usable.
            }
        }
    }

    func ensureLanguageServerDiscoveryStarted(for providerID: String? = nil) {
        languageCapability?.ensureDiscoveryStarted(for: providerID)
    }

    /// Switches the active window between zero-LSP Lightweight Mode and Precision LSP Mode.
    func setSessionLanguageIntelligenceMode(_ mode: LanguageIntelligenceMode) {
        sessionLanguageIntelligenceModeOverride = (mode == observedGlobalLanguageIntelligenceMode) ? nil : mode
        guard appliedLanguageIntelligenceMode != mode else { return }
        applyLanguageIntelligenceModeTransition(to: mode, showNotificationBanner: true)
    }

    func toggleSessionLanguageIntelligenceMode() {
        setSessionLanguageIntelligenceMode(isLightweightIntelligenceMode ? .lsp : .lightweight)
    }

    /// Updates the persisted global default mode and propagates the transition to every window.
    func applyGlobalLanguageIntelligenceMode(_ mode: LanguageIntelligenceMode) {
        sessionLanguageIntelligenceModeOverride = nil
        observedGlobalLanguageIntelligenceMode = mode
        if settings.languageIntelligenceMode != mode {
            // Setting the shared preference triggers `handleGlobalLanguageIntelligenceModeChanged`
            // on every open AppModel window (including this one) without duplicate transitions.
            settings.languageIntelligenceMode = mode
        }
        if appliedLanguageIntelligenceMode != mode {
            applyLanguageIntelligenceModeTransition(to: mode, showNotificationBanner: true)
        }
    }

    /// Invoked via `AppSettings.$languageIntelligenceMode` on every project window so changing
    /// the shared global mode stops or starts language servers consistently across all windows.
    /// Updates `observedGlobalLanguageIntelligenceMode` first because `@Published` emits in
    /// `willSet` before `settings.languageIntelligenceMode` stores the new value.
    func handleGlobalLanguageIntelligenceModeChanged(_ mode: LanguageIntelligenceMode) {
        observedGlobalLanguageIntelligenceMode = mode
        guard sessionLanguageIntelligenceModeOverride == nil else {
            scheduleObjectWillChangeRelay()
            return
        }
        guard appliedLanguageIntelligenceMode != mode else { return }
        applyLanguageIntelligenceModeTransition(to: mode, showNotificationBanner: true)
    }

    private func applyLanguageIntelligenceModeTransition(
        to mode: LanguageIntelligenceMode,
        showNotificationBanner: Bool
    ) {
        appliedLanguageIntelligenceMode = mode
        let usesChinese = settings.language == .simplifiedChinese
        switch mode {
        case .lightweight:
            cancelJavaLanguageServerPreparation()
            languageToolingSessionsIfActive?.stopAllLanguageServers()
            languageToolingFeature.resetWorkspaceState()
            editorDiagnosticsStore.reset()
            ensureLightweightLanguageIntelligenceActive()
            scheduleObjectWillChangeRelay()
            if showNotificationBanner {
                showNotification(
                    usesChinese
                        ? "已切换为轻量模式，已停止后台语言服务器并释放内存。"
                        : "Switched to Lightweight Mode. Background language servers stopped."
                )
            }
        case .lsp:
            scheduleObjectWillChangeRelay()
            activateOpenDocumentsForPrecisionLSP()
            if showNotificationBanner {
                showNotification(
                    usesChinese
                        ? "已启用精确 LSP 模式，按需启动当前语言服务器。"
                        : "Precision LSP enabled. Starting language servers for open files on demand."
                )
            }
        }
    }

    private func activateOpenDocumentsForPrecisionLSP() {
        guard workspaceURL != nil else { return }
        // Activate active tab first so user gets immediate responsiveness, then sync
        // every open sibling tab so cross-file rename / diagnostics never hit staleSource.
        var orderedDocuments = openDocuments
        if let active = activeDocument {
            orderedDocuments.removeAll { $0.id == active.id }
            orderedDocuments.insert(active, at: 0)
        }
        var activatedProviders = Set<String>()
        for document in orderedDocuments {
            if let providerID = languageProviderCatalog.provider(for: document.url)?.id {
                ensureLanguageServerDiscoveryStarted(for: providerID)
                activatedProviders.insert(providerID)
            }
            _ = activateLanguageServerIfAvailable(for: document)
        }
        if activatedProviders.isEmpty, let workspaceURL {
            prepareJavaLanguageServerForWorkspaceIfNeeded(at: workspaceURL, files: projectFiles)
        }
    }

    /// Shows a one-click escalation notification when the user explicitly triggers an
    /// LSP-only feature (such as Rename, Format, Code Actions, or Go to Implementation)
    /// while Lightweight Mode is active.
    func requestPrecisionLSPEscalation(forAction actionName: String, fileURL: URL) {
        let usesChinese = settings.language == .simplifiedChinese
        let providerName = languageProviderCatalog.provider(for: fileURL)?.displayName
        let message: String
        if let providerName {
            message = usesChinese
                ? "“\(actionName)”需要 \(providerName) 精确 LSP。点击按钮可为当前窗口按需启用。"
                : "\"\(actionName)\" requires \(providerName) Precision LSP. Enable it on demand for this window."
        } else {
            message = usesChinese
                ? "“\(actionName)”需要精确 LSP 模式。点击按钮可为当前窗口按需启用。"
                : "\"\(actionName)\" requires Precision LSP mode. Enable it on demand for this window."
        }
        showNotification(
            message,
            severity: .information,
            title: usesChinese ? "当前为轻量模式" : "Lightweight Mode",
            action: .enablePrecisionLSP
        )
    }

    /// Computes deterministic multi-language fold regions via Rust Core off the MainActor.
    func editorFoldRegions(path: String, source: String) async -> [JavaFoldRegion] {
        await Task.detached(priority: .userInitiated) {
            RustCoreBridge().editorFoldRegions(path: path, source: source)
        }.value
    }

    /// Warms the shared Rust Core symbol/trigram index on workspace open so Lightweight
    /// Mode cross-file definition, references, hover, signature help, and completions work
    /// immediately even before the Search module is opened.
    func warmWorkspaceSearchIndexForLightweightIntelligence(
        at rootURL: URL,
        rules: FileVisibilityRules
    ) {
        let hiddenDirs = rules.hiddenDirectoryNames
        let hiddenFiles = rules.hiddenFilePatterns
        Task.detached(priority: .utility) {
            RustCoreBridge().warmSearchIndex(
                at: rootURL,
                hiddenDirectoryNames: hiddenDirs,
                hiddenFilePatterns: hiddenFiles
            )
        }
    }

    func updateWorkspaceSearchIndexForLightweightIntelligence(
        at rootURL: URL,
        changedPaths: [String],
        rules: FileVisibilityRules
    ) async {
        let hiddenDirs = rules.hiddenDirectoryNames
        let hiddenFiles = rules.hiddenFilePatterns
        await Task.detached(priority: .utility) {
            RustCoreBridge().updateSearchIndex(
                at: rootURL,
                changedPaths: changedPaths,
                hiddenDirectoryNames: hiddenDirs,
                hiddenFilePatterns: hiddenFiles
            )
        }.value
    }

    func invalidateWorkspaceSearchIndexForLightweightIntelligence(
        at rootURL: URL,
        rules: FileVisibilityRules
    ) {
        let hiddenDirs = rules.hiddenDirectoryNames
        let hiddenFiles = rules.hiddenFilePatterns
        Task.detached(priority: .utility) {
            RustCoreBridge().invalidateSearchIndex(
                at: rootURL,
                hiddenDirectoryNames: hiddenDirs,
                hiddenFilePatterns: hiddenFiles
            )
        }
    }
}
