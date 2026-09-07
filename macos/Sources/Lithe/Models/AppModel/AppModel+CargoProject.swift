import Foundation
import LitheExecutionModule
import LitheModuleAPI

@MainActor
extension AppModel {
    /// Recognition reads the applied inventory; missing tools remain a visible
    /// error inside Cargo instead of making the entry disappear.
    var isCargoAvailable: Bool {
        !cargoManifestURLs.isEmpty
            && rightSidebarContributions.contains { $0.id == "language.rust.cargo" }
    }

    var cargoManifestURLs: [URL] {
        guard let workspaceURL else { return [] }
        return CargoManifestSelection.candidates(
            workspace: workspaceURL, files: workspaceFeature.appliedSnapshot?.files ?? []
        )
    }
    var cargoManifestURL: URL? {
        if let selectedCargoManifestURL, cargoManifestURLs.contains(selectedCargoManifestURL) {
            return selectedCargoManifestURL
        }
        return cargoManifestURLs.first
    }

    func selectCargoManifest(_ url: URL) {
        guard canRefreshCargoProject, cargoManifestURLs.contains(url), cargoManifestURL != url else { return }
        selectedCargoManifestURL = url
        cargoTreePresentation.reset()
        cargoProjectFeatureIfActive?.invalidateWorkspace()
        refreshCargoProject()
    }

    var isCargoToolWindowSelected: Bool { isCargoVisible && isCargoAvailable }
    var canRefreshCargoProject: Bool {
        isCargoAvailable && cargoRefreshTask == nil && cargoCancellationTask == nil
            && !(cargoProjectFeatureIfActive?.isActive ?? false)
    }
    var canCancelCargoRefresh: Bool {
        isCargoAvailable && !isCargoCancelling
            && (isCargoActivating || cargoProjectFeatureIfActive?.isActive == true)
    }

    func toggleCargoProject() {
        guard isCargoAvailable else { return }
        isCargoVisible.toggle()
        guard isCargoVisible else { return }
        if cargoProjectFeatureIfActive?.snapshot == nil { refreshCargoProject() }
    }

    func refreshCargoProject() {
        guard canRefreshCargoProject, let identity = currentWorkspaceIdentity,
              let manifestURL = cargoManifestURL else { return }
        isCargoVisible = true
        cargoActivationError = nil
        isCargoActivating = true
        let generation = cargoRequestGeneration
        cargoRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                cargoRefreshTask = nil
                isCargoActivating = false
                scheduleObjectWillChangeRelay()
            }
            _ = await activateExecutionModule()
            guard !Task.isCancelled, cargoRequestGeneration == generation,
                  currentWorkspaceIdentity == identity, isCargoAvailable,
                  cargoManifestURL == manifestURL else { return }
            guard let feature = cargoProjectFeatureIfActive else {
                cargoActivationError = String(localized: "Cargo metadata is unavailable.")
                return
            }
            isCargoActivating = false
            await feature.refresh(
                workspaceURL: identity.url, workspaceGeneration: identity.generation, manifestURL: manifestURL
            )
        }
    }

    func cancelCargoRefresh() {
        guard canCancelCargoRefresh else { return }
        cargoRequestGeneration += 1
        cargoRefreshTask?.cancel()
        isCargoCancelling = true
        let feature = cargoProjectFeatureIfActive
        cargoCancellationTask = Task { @MainActor [weak self] in
            await feature?.cancel()
            guard let self else { return }
            isCargoCancelling = false
            cargoCancellationTask = nil
            scheduleObjectWillChangeRelay()
        }
    }

    func invalidateCargoWorkspace() {
        cargoRequestGeneration += 1
        cargoRefreshTask?.cancel()
        cargoProjectFeatureIfActive?.invalidateWorkspace()
        isCargoVisible = false
        cargoActivationError = nil
        selectedCargoManifestURL = nil
        cargoTreePresentation.reset()
    }

    func handleCargoModuleEvent(_ event: ModuleEvent) {
        guard event.source == .languageExecutionExtension("rust") || event.source == .execution else { return }
        let retired = event.name == "module.sleeping" || event.name == "module.shutdown"
            || event.name == ModuleEvent.languageProjectToolsRetiredName
        let unavailable = event.name == ModuleEvent.stateChangedName
            && moduleSnapshots.first(where: { $0.manifest.id == event.source })?.state == .disabled
        guard retired || unavailable else { return }
        cargoRequestGeneration += 1
        cargoRefreshTask?.cancel()
        cargoProjectFeatureIfActive?.invalidateProvider(moduleID: event.source)
        isCargoVisible = false
        cargoActivationError = nil
        cargoTreePresentation.reset()
    }
}

/// Uses only the applied inventory, so recognition never probes a toolchain or
/// opens files while a toolbar/menu is being rendered.
enum CargoManifestSelection {
    static func candidates(workspace: URL, files: [URL]) -> [URL] {
        let root = workspace.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return files.map(\.standardizedFileURL).filter {
            $0.lastPathComponent == "Cargo.toml" && $0.path.hasPrefix(prefix)
        }.sorted {
            let left = String($0.path.dropFirst(prefix.count))
            let right = String($1.path.dropFirst(prefix.count))
            let leftDepth = left.split(separator: "/").count
            let rightDepth = right.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return left.utf8.lexicographicallyPrecedes(right.utf8)
        }
    }
}
