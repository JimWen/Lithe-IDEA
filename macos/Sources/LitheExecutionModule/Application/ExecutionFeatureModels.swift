import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI


/// UI-facing projection for language-neutral run configurations and process sessions.
package enum RunConfigurationGenerationIntent: Sendable, Equatable {
    case identifyOnly
    case run
    case debug
    case cargoTarget(configurationID: String, name: String)
    case goTarget(configurationID: String, name: String)
}

@MainActor
package final class RunFeatureModel: ObservableObject {
    private let service: RunService
    private var observations: Set<AnyCancellable> = []
    @Published package var isGenerationConfirmationPresented = false
    /// The output shown in Run, also supporting tool tasks outside run configs.
    /// Explicit selections and launches synchronize configuration and session;
    /// output updates must preserve a later manual selection.
    @Published package var selectedSessionID: String?
    @Published package var selectedToolTaskID: UUID?
    package private(set) var generationIntent: RunConfigurationGenerationIntent = .identifyOnly

    package init(service: RunService) {
        self.service = service
        service.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &observations)
        service.$configurations.sink { [weak self] configurations in
            guard let self, let selectedSessionID,
                  !configurations.contains(where: { $0.id == selectedSessionID }) else { return }
            self.selectedSessionID = nil
        }.store(in: &observations)
    }

    package var selectedConfigurationID: String {
        get { service.selectedConfigurationID }
        set { service.selectedConfigurationID = newValue }
    }

    package var configurations: [RunConfiguration] { service.configurations }
    package var defaultConfigurationID: String? { service.defaultConfigurationID }
    package var selectedConfiguration: RunConfiguration? { service.selectedConfiguration }
    package var lastRunFileURL: URL? { service.lastRunFileURL }
    package var lastConfiguration: RunConfiguration? { service.lastConfiguration }
    /// Project configurations share session identity across toolbar and log selection.
    /// Current File alone uses the primary output stream.
    package var selectedProjectSessionID: String? {
        guard let configuration = selectedConfiguration, configuration.kind != .currentFile else { return nil }
        return configuration.id
    }
    package var isSelectedConfigurationRunning: Bool {
        guard let configuration = selectedConfiguration else { return false }
        if configuration.kind != .currentFile {
            return moduleSessions.contains { $0.configurationID == configuration.id && $0.isRunning }
        }
        return isRunning && lastConfiguration?.id == configuration.id
    }
    package var isLoadingProject: Bool { service.isLoadingProject }
    package var isRunning: Bool { service.isRunning }
    package var runningTitle: String? { service.runningTitle }
    package var output: String { service.output }
    package var lastExitCode: Int32? { service.lastExitCode }
    package var moduleSessions: [RunSession] { service.moduleSessions }
    package var portConflicts: [RunPortConflict] { service.portConflicts }
    package var configurationStatus: ProjectRunConfigurationStatus { service.configurationStatus }
    package var configurationDiagnostics: [RunConfigurationDiagnostic] { service.configurationDiagnostics }
    package var generationState: RunConfigurationGenerationState { service.generationState }
    package var projectLoadState: ProjectLoadState { service.projectLoadState }
    package func reportGenerationProjectNotReady() { service.reportGenerationProjectNotReady() }
    package var recoveryAction: RunConfigurationRecoveryAction { service.recoveryAction }
    package var recoveryPath: String? { service.recoveryPath }
    package var configurationSaveError: String? { service.configurationSaveError }
    package var projectToolchain: ProjectToolchainSelection { service.projectToolchain }
    package var blockingToolchainDiagnostic: RunConfigurationDiagnostic? {
        service.blockingToolchainDiagnostic(for: service.selectedConfiguration)
    }
    package var sourceSearchRoots: [URL] { service.sourceSearchRoots }
    package func isProjectReady(for workspace: URL, snapshotID: UUID?) -> Bool { service.isProjectReady(for: workspace, snapshotID: snapshotID) }
    package func hasReadyInventory(for workspace: URL) -> Bool { service.hasReadyInventory(for: workspace) }

    package func options(for configuration: RunConfiguration) -> RunOptions {
        service.options(for: configuration)
    }

    package func configuredServerPort(for configuration: RunConfiguration) -> Int? {
        service.configuredServerPort(for: configuration)
    }

    package func source(for configuration: RunConfiguration) -> RunConfigurationSource {
        service.source(for: configuration)
    }

    /// Applies the same selected configuration side effects used by Run,
    /// including project-scoped Java runtime selection, before Debug starts.
    package func select(_ configuration: RunConfiguration) {
        selectedToolTaskID = nil
        service.select(configuration)
        selectedSessionID = configuration.kind == .currentFile ? nil : configuration.id
    }

    package func serviceURL(for configuration: RunConfiguration) -> URL? {
        service.serviceURL(for: configuration)
    }

    @discardableResult
    package func saveEditorChanges(
        _ options: RunOptions,
        toolchain: ProjectToolchainSelection,
        for configuration: RunConfiguration,
        scope: RunConfigurationSaveScope
    ) -> Bool {
        service.saveEditorChanges(
            options,
            toolchain: toolchain,
            for: configuration,
            scope: scope
        )
    }

    package func resetOptions(for configuration: RunConfiguration) {
        service.resetOptions(for: configuration)
    }


    package func runAllServices() {
        selectedToolTaskID = nil
        service.runAllServices()
        if let first = service.configurations.first(where: { $0.execution == .service }) {
            select(first)
        }
    }

    package func stopAllServices() {
        service.stopAllServices()
    }

    /// Batch launches preserve the output the user chose while providers activate.
    package func startConfiguration(_ configuration: RunConfiguration, selectingOutput: Bool = true) {
        guard configuration.kind != .currentFile else { return }
        if selectingOutput { select(configuration) }
        service.startConfiguration(configuration)
    }

    package func stopModule(_ session: RunSession) {
        service.stopModule(session)
    }

    package func restartModule(_ session: RunSession) {
        if let configuration = configurations.first(where: { $0.id == session.configurationID }) {
            select(configuration)
        } else {
            selectedToolTaskID = nil
            selectedSessionID = session.id
        }
        service.restartModule(session)
    }

    package func clearModuleOutput(_ session: RunSession) {
        service.clearModuleOutput(session)
    }

    package func clearOutput() {
        service.clearOutput()
    }

    package func loadProject(
        at workspaceURL: URL,
        files: [URL],
        snapshotID: UUID? = nil
    ) async {
        await service.loadProject(at: workspaceURL, files: files, snapshotID: snapshotID)
    }

    package func generateRunConfigurations() async {
        isGenerationConfirmationPresented = false
        await service.generateRunConfigurations()
    }

    package func requestRunConfigurationGeneration(intent: RunConfigurationGenerationIntent = .identifyOnly) {
        guard recoveryAction != .upgradeApplication else { return }
        generationIntent = intent
        isGenerationConfirmationPresented = true
    }

    @discardableResult
    package func registerLanguageRunExtension(
        _ provider: any LanguageRunExtensionProviding,
        support: LanguageSupportDeclaration
    ) -> Bool {
        service.registerLanguageRunExtension(provider, support: support)
    }

    package func unregisterLanguageRunExtension(languageID: String) {
        service.unregisterLanguageRunExtension(languageID: languageID)
    }
    package func runSelected(currentFileURL: URL?) {
        selectedToolTaskID = nil
        selectedSessionID = nil
        service.runSelected(currentFileURL: currentFileURL)
    }
    package func restart() {
        selectedToolTaskID = nil
        selectedSessionID = nil
        service.restart()
    }
    package func stop() { service.stop() }
    package func reset() {
        selectedToolTaskID = nil
        selectedSessionID = nil
        service.reset()
    }
}

/// Coordinates project-scoped build and run loading without making AppModel
/// own build-system sequencing. Language-specific project loaders can later be
/// added here without changing the workspace/UI composition boundary.
@MainActor
package final class ProjectDevelopmentFeatureModel {
    private let runFeature: RunFeatureModel

    package init(runFeature: RunFeatureModel) {
        self.runFeature = runFeature
    }

    package func loadProject(at workspaceURL: URL, files: [URL], snapshotID: UUID? = nil) async {
        await runFeature.loadProject(
            at: workspaceURL,
            files: files,
            snapshotID: snapshotID
        )
    }
}

package typealias JavaRunFeatureModel = RunFeatureModel
