import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI

@MainActor
final class MacPluginManager: PluginManaging {
    private let packageStore: MacPluginPackageStore
    private let moduleRuntime: ModuleRuntime
    private let configurationStore: MacModuleConfigurationStore
    private let launchMode: ModuleLaunchMode
    private let managedBuiltInPlugins: [PluginManifest]
    private let activeNativeManifestsByID: [PluginID: PluginManifest]
    private let syntaxProfileRegistry: LanguageSyntaxProfileRegistry?
    private var installedPlugins: [PluginID: InstalledPluginPackage]
    private var syntaxProfilesByPlugin: [PluginID: [LanguageSyntaxProfile]]
    private var syntaxEnrichmentsByPlugin: [PluginID: [String: LanguageSyntaxEnrichment]]
    private var restartRequiredPluginIDs: Set<PluginID> = []
    private(set) var issues: [PluginManagementIssue]

    init(
        packageStore: MacPluginPackageStore,
        moduleRuntime: ModuleRuntime,
        configurationStore: MacModuleConfigurationStore,
        launchMode: ModuleLaunchMode,
        startup: MacPluginStartupResult,
        managedBuiltInPlugins: [PluginManifest] = [],
        syntaxProfileRegistry: LanguageSyntaxProfileRegistry? = nil
    ) {
        self.packageStore = packageStore
        self.moduleRuntime = moduleRuntime
        self.configurationStore = configurationStore
        self.launchMode = launchMode
        self.managedBuiltInPlugins = managedBuiltInPlugins.sorted { $0.id < $1.id }
        self.syntaxProfileRegistry = syntaxProfileRegistry
        activeNativeManifestsByID = Dictionary(
            startup.activeNativeManifests.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        installedPlugins = Dictionary(
            uniqueKeysWithValues: startup.installedPlugins.map { ($0.manifest.id, $0) }
        )
        syntaxProfilesByPlugin = startup.syntaxProfilesByPlugin
        syntaxEnrichmentsByPlugin = startup.syntaxEnrichmentsByPlugin
        issues = startup.issues.map {
            PluginManagementIssue(pluginID: $0.pluginID, message: $0.message)
        }
        synchronizeInstalledSyntaxProfiles()
    }

    var snapshots: [PluginManagementSnapshot] {
        let runtimeSnapshots = Dictionary(
            uniqueKeysWithValues: moduleRuntime.snapshots().map { ($0.manifest.id, $0) }
        )
        let native = installedPlugins.values
            .map {
                snapshot(
                    manifest: $0.manifest,
                    origin: $0.installation.origin,
                    installationStatus: $0.installation.status,
                    previousVersion: $0.installation.previousVersion,
                    runtimeSnapshots: runtimeSnapshots
                )
            }
        let builtIn = managedBuiltInPlugins.map {
            snapshot(
                manifest: $0,
                origin: .bundled,
                installationStatus: .installed,
                previousVersion: nil,
                runtimeSnapshots: runtimeSnapshots
            )
        }
        return (builtIn + native).sorted { $0.manifest.displayName < $1.manifest.displayName }
    }

    func setEnabled(_ enabled: Bool, for pluginID: PluginID) async throws {
        guard let manifest = manifest(for: pluginID) else {
            throw PluginManagerError.unknownPlugin(pluginID)
        }
        let activeNativeManifest = activeNativeManifestsByID[pluginID]
        let effectiveModules = activeNativeManifest?.modules ?? manifest.modules
        guard enabled || !effectiveModules.contains(where: { $0.manifest.isRequired }) else {
            throw PluginManagerError.requiredPluginCannotBeDisabled(pluginID)
        }

        let isSuppressedBySafeMode = launchMode == .safeMode
            && !effectiveModules.contains(where: { $0.manifest.isRequired })

        if manifest.entrypoint.kind == .declarative && activeNativeManifest == nil {
            let toggleID = Self.declarativeToggleModuleID(for: pluginID)
            if enabled {
                configurationStore.setQuarantined(false, for: toggleID)
            }
            configurationStore.setEnabledState(enabled, for: toggleID)
            applySyntaxProfileState(enabled: enabled && !isSuppressedBySafeMode, for: manifest)
            return
        }

        if manifest.entrypoint.kind == .declarative {
            let toggleID = Self.declarativeToggleModuleID(for: pluginID)
            if enabled {
                configurationStore.setQuarantined(false, for: toggleID)
            }
            configurationStore.setEnabledState(enabled, for: toggleID)
        }

        let registeredIDs = Set(moduleRuntime.snapshots().map(\.manifest.id))
        let declarations: [PluginModuleDeclaration] = enabled
            ? effectiveModules
            : Array(effectiveModules.reversed())
        for declaration in declarations {
            let moduleID = declaration.manifest.id
            if enabled {
                // A module can already be registered when the manager is
                // recovering a previous native-plugin load. Clear the
                // quarantine marker before toggling the runtime state so a
                // user action can actually re-enable that module.
                configurationStore.setQuarantined(false, for: moduleID)
            }
            if registeredIDs.contains(moduleID) {
                try await moduleRuntime.setEnabled(enabled, for: moduleID)
            } else {
                configurationStore.setEnabledState(enabled, for: moduleID)
            }
        }
        applySyntaxProfileState(enabled: enabled && !isSuppressedBySafeMode, for: activeNativeManifest ?? manifest)

        let involvesNative = manifest.entrypoint.kind == .nativeBundle || activeNativeManifest != nil
        if involvesNative,
           enabled != (activeNativeManifest != nil) {
            restartRequiredPluginIDs.insert(pluginID)
        } else if involvesNative, !enabled {
            // The module graph is stopped immediately, but Swift Bundle code
            // remains mapped until this process exits.
            restartRequiredPluginIDs.insert(pluginID)
        }
    }

    func installPackage(at packageURL: URL) throws {
        let incomingManifest = try packageStore.loadManifest(at: packageURL)
        let previousPackage = installedPlugins[incomingManifest.id]
        let previousLanguageIDs = Set(
            (previousPackage?.manifest.languageSupports ?? []).map(\.id)
        )
        let isPureDeclarativeTransition = incomingManifest.entrypoint.kind == .declarative
            && activeNativeManifestsByID[incomingManifest.id] == nil
            && (previousPackage == nil || previousPackage?.manifest.entrypoint.kind == .declarative)

        let installed = try packageStore.installPackage(
            from: packageURL,
            deferActivationUntilRestart: !isPureDeclarativeTransition
        )
        if isPureDeclarativeTransition {
            restartRequiredPluginIDs.remove(installed.manifest.id)
            syntaxProfilesByPlugin.removeValue(forKey: installed.manifest.id)
            syntaxEnrichmentsByPlugin.removeValue(forKey: installed.manifest.id)
        } else {
            restartRequiredPluginIDs.insert(installed.manifest.id)
        }
        try refreshInstalledPlugins()
        if isPureDeclarativeTransition {
            unregisterObsoleteLanguageSupports(
                previousLanguageIDs: previousLanguageIDs,
                for: installed.manifest.id
            )
            synchronizeInstalledSyntaxProfiles()
        }
    }

    func rollback(_ pluginID: PluginID) throws {
        let previousPackage = installedPlugins[pluginID]
        let previousLanguageIDs = Set(
            (previousPackage?.manifest.languageSupports ?? []).map(\.id)
        )
        let targetManifest = try packageStore.rollbackTargetManifest(for: pluginID)
        let isPureDeclarativeTransition = targetManifest.entrypoint.kind == .declarative
            && activeNativeManifestsByID[pluginID] == nil
            && (previousPackage == nil || previousPackage?.manifest.entrypoint.kind == .declarative)

        _ = try packageStore.rollback(
            pluginID,
            deferActivationUntilRestart: !isPureDeclarativeTransition
        )
        if isPureDeclarativeTransition {
            restartRequiredPluginIDs.remove(pluginID)
            syntaxProfilesByPlugin.removeValue(forKey: pluginID)
            syntaxEnrichmentsByPlugin.removeValue(forKey: pluginID)
        } else {
            restartRequiredPluginIDs.insert(pluginID)
        }
        try refreshInstalledPlugins()
        if isPureDeclarativeTransition {
            unregisterObsoleteLanguageSupports(
                previousLanguageIDs: previousLanguageIDs,
                for: pluginID
            )
            synchronizeInstalledSyntaxProfiles()
        }
    }

    func uninstall(_ pluginID: PluginID) async throws {
        guard let installed = installedPlugins[pluginID] else {
            guard issues.contains(where: { $0.pluginID == pluginID }) else {
                throw PluginManagerError.unknownPlugin(pluginID)
            }
            try packageStore.stageInvalidPackageUninstall(pluginID)
            restartRequiredPluginIDs.insert(pluginID)
            issues.removeAll { $0.pluginID == pluginID }
            issues.append(PluginManagementIssue(
                pluginID: pluginID,
                message: "Will be uninstalled after restart"
            ))
            return
        }
        let activeNativeManifest = activeNativeManifestsByID[pluginID]
        let effectiveModules = activeNativeManifest?.modules ?? installed.manifest.modules
        guard !effectiveModules.contains(where: { $0.manifest.isRequired }) else {
            throw PluginManagerError.requiredPluginCannotBeUninstalled(pluginID)
        }
        if installed.manifest.entrypoint.kind == .declarative && activeNativeManifest == nil {
            for support in installed.manifest.languageSupports ?? [] {
                syntaxProfileRegistry?.setPluginDisabled(false, forLanguageID: support.id)
                syntaxProfileRegistry?.unregister(languageID: support.id)
            }
            syntaxProfilesByPlugin.removeValue(forKey: pluginID)
            syntaxEnrichmentsByPlugin.removeValue(forKey: pluginID)
            restartRequiredPluginIDs.remove(pluginID)
            try packageStore.uninstall(pluginID)
            try refreshInstalledPlugins()
            return
        }
        if activeNativeManifest != nil {
            try await setEnabled(false, for: pluginID)
        }
        try packageStore.stageUninstall(pluginID)
        restartRequiredPluginIDs.insert(pluginID)
        try refreshInstalledPlugins()
    }

    private func unregisterObsoleteLanguageSupports(
        previousLanguageIDs: Set<String>,
        for pluginID: PluginID
    ) {
        let currentLanguageIDs = Set(
            (installedPlugins[pluginID]?.manifest.languageSupports ?? []).map(\.id)
        )
        for obsoleteID in previousLanguageIDs.subtracting(currentLanguageIDs) {
            syntaxProfileRegistry?.setPluginDisabled(false, forLanguageID: obsoleteID)
            syntaxProfileRegistry?.unregister(languageID: obsoleteID)
        }
    }

    private func manifest(for pluginID: PluginID) -> PluginManifest? {
        installedPlugins[pluginID]?.manifest
            ?? managedBuiltInPlugins.first { $0.id == pluginID }
    }

    private func refreshInstalledPlugins() throws {
        let scan = try packageStore.scanInstalledPlugins()
        installedPlugins = Dictionary(
            uniqueKeysWithValues: scan.packages.map { ($0.manifest.id, $0) }
        )
        issues = issues.filter { issue in
            guard let pluginID = issue.pluginID else { return true }
            return installedPlugins[pluginID] == nil
        } + scan.issues.map {
            PluginManagementIssue(pluginID: $0.pluginID, message: $0.message)
        }
    }

    private func snapshot(
        manifest: PluginManifest,
        origin: PluginInstallationOrigin,
        installationStatus: PluginInstallationStatus,
        previousVersion: PluginVersion?,
        runtimeSnapshots: [ModuleID: ModuleSnapshot]
    ) -> PluginManagementSnapshot {
        let activeNativeManifest = activeNativeManifestsByID[manifest.id]
        let effectiveModules = activeNativeManifest?.modules ?? manifest.modules
        let moduleSnapshots = effectiveModules.compactMap { runtimeSnapshots[$0.manifest.id] }
        let isConfiguredEnabled: Bool
        let isQuarantined: Bool
        if manifest.entrypoint.kind == .declarative && activeNativeManifest == nil {
            let toggleID = Self.declarativeToggleModuleID(for: manifest.id)
            isConfiguredEnabled = configurationStore.enabledState(for: toggleID) ?? true
            isQuarantined = configurationStore.isQuarantined(toggleID)
        } else {
            isConfiguredEnabled = effectiveModules.contains { declaration in
                if let runtime = runtimeSnapshots[declaration.manifest.id] {
                    return runtime.state != .disabled
                }
                return configurationStore.enabledState(for: declaration.manifest.id)
                    ?? (declaration.manifest.defaultState == .enabled)
            }
            isQuarantined = effectiveModules.contains { declaration in
                runtimeSnapshots[declaration.manifest.id]?.isQuarantined
                    ?? configurationStore.isQuarantined(declaration.manifest.id)
            }
        }
        let isEnabled = isConfiguredEnabled && !isQuarantined
        let isSuppressedBySafeMode = launchMode == .safeMode
            && !effectiveModules.contains(where: { $0.manifest.isRequired })
        let isRunning = (manifest.entrypoint.kind == .declarative && activeNativeManifest == nil)
            ? (isEnabled && !isSuppressedBySafeMode && !(syntaxProfilesByPlugin[manifest.id]?.isEmpty ?? true))
            : moduleSnapshots.contains { $0.isInstantiated }
        let requiresRestart = restartRequiredPluginIDs.contains(manifest.id)
            || installationStatus != .installed
        let matchingIssue = issues.first { $0.pluginID == manifest.id }
        let statusMessage: String
        if let matchingIssue {
            statusMessage = matchingIssue.message
        } else if installationStatus == .uninstallPending {
            statusMessage = "Will be uninstalled after restart"
        } else if requiresRestart {
            statusMessage = "Restart required"
        } else if isQuarantined {
            statusMessage = "Disabled after the previous plugin session ended unexpectedly"
        } else if isSuppressedBySafeMode {
            statusMessage = "Disabled in Safe Mode"
        } else if isRunning {
            statusMessage = "Running"
        } else if isEnabled {
            statusMessage = "Enabled"
        } else {
            statusMessage = "Disabled"
        }
        return PluginManagementSnapshot(
            manifest: manifest,
            origin: origin,
            installationStatus: installationStatus,
            isEnabled: isEnabled,
            isRequired: manifest.modules.contains(where: { $0.manifest.isRequired }),
            isRunning: isRunning,
            isQuarantined: isQuarantined,
            isSuppressedBySafeMode: isSuppressedBySafeMode,
            requiresRestart: requiresRestart,
            canRollback: previousVersion != nil,
            statusMessage: statusMessage
        )
    }

    private static func declarativeToggleModuleID(for pluginID: PluginID) -> ModuleID {
        ModuleID("plugin.\(pluginID.rawValue)")
    }

    private func synchronizeInstalledSyntaxProfiles() {
        let runtimeSnapshots = Dictionary(
            uniqueKeysWithValues: moduleRuntime.snapshots().map { ($0.manifest.id, $0) }
        )
        for installed in installedPlugins.values {
            let snap = snapshot(
                manifest: installed.manifest,
                origin: installed.installation.origin,
                installationStatus: installed.installation.status,
                previousVersion: installed.installation.previousVersion,
                runtimeSnapshots: runtimeSnapshots
            )
            applySyntaxProfileState(
                enabled: snap.isEnabled && !snap.isSuppressedBySafeMode,
                for: installed.manifest
            )
        }
    }

    private func applySyntaxProfileState(enabled: Bool, for manifest: PluginManifest) {
        guard let registry = syntaxProfileRegistry,
              let supports = manifest.languageSupports,
              !supports.isEmpty else { return }
        if !enabled {
            for support in supports {
                registry.setPluginDisabled(true, forLanguageID: support.id)
            }
            return
        }
        for support in supports {
            registry.setPluginDisabled(false, forLanguageID: support.id)
        }
        var profiles = syntaxProfilesByPlugin[manifest.id] ?? []
        var enrichments = syntaxEnrichmentsByPlugin[manifest.id] ?? [:]
        if profiles.isEmpty, let installed = installedPlugins[manifest.id] {
            let definitions = (try? MacPluginPackageStore.loadSyntaxDefinitions(
                at: installed.packageURL,
                manifest: installed.manifest
            )) ?? []
            if !definitions.isEmpty {
                profiles = definitions.map(\.profile)
                enrichments = Dictionary(
                    definitions.map { ($0.profile.languageID, $0.enrichment) },
                    uniquingKeysWith: { _, latest in latest }
                )
                syntaxProfilesByPlugin[manifest.id] = profiles
                syntaxEnrichmentsByPlugin[manifest.id] = enrichments
            }
        }
        for profile in profiles {
            registry.register(profile, enrichment: enrichments[profile.languageID])
        }
    }
}

enum PluginManagerError: Error, Equatable, LocalizedError {
    case unknownPlugin(PluginID)
    case requiredPluginCannotBeDisabled(PluginID)
    case requiredPluginCannotBeUninstalled(PluginID)

    var errorDescription: String? {
        switch self {
        case .unknownPlugin(let id): "Plugin \(id) is not installed."
        case .requiredPluginCannotBeDisabled(let id): "Required plugin \(id) cannot be disabled."
        case .requiredPluginCannotBeUninstalled(let id): "Required plugin \(id) cannot be uninstalled."
        }
    }
}
