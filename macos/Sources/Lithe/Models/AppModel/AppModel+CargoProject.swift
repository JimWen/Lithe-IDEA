import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

@MainActor
extension AppModel {
    /// Recognition reads the applied inventory; missing tools remain a visible
    /// error inside Cargo instead of making the entry disappear.
    var isCargoAvailable: Bool {
        // The contribution lookup is a small in-memory list, so it is asked
        // first and keeps the manifest scan off the path entirely for projects
        // that never loaded Rust support.
        rightSidebarContributions.contains { $0.id == "language.rust.cargo" }
            && !cargoManifestURLs.isEmpty
    }

    /// Resolves a metadata location to a project file URL. Only the workspace
    /// root is project-resolvable; external dependency roots carry no host
    /// mapping the tree may hand to the editor.
    func cargoFileURL(for location: ProjectMetadataLocation) -> URL? {
        guard let workspaceURL, location.rootID == "workspace" else { return nil }
        guard location.relativePath != "." else { return workspaceURL }
        return workspaceURL
            .appendingPathComponent(location.relativePath)
            .standardizedFileURL
    }

    /// Memoized against the applied scan that produced it. Recognition is read
    /// during view updates, and the underlying candidate scan is linear in the
    /// size of the workspace, so recomputing it per render puts the whole file
    /// list on the main actor several times per frame.
    var cargoManifestURLs: [URL] {
        guard let workspaceURL else { return [] }
        let workspace = workspaceURL.standardizedFileURL
        let snapshot = workspaceFeature.appliedSnapshot
        if let cache = cargoTreePresentation.manifestCache,
           cache.workspace == workspace,
           cache.snapshotID == snapshot?.id {
            return cache.urls
        }
        let urls = CargoManifestSelection.candidates(
            workspace: workspace, files: snapshot?.files ?? []
        )
        cargoTreePresentation.manifestCache = CargoManifestCache(
            workspace: workspace, snapshotID: snapshot?.id, urls: urls
        )
        return urls
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

    /// Detaches an explicitly chosen manifest and returns to the default one,
    /// mirroring RustRover's detach action for the Lithe manifest model.
    func resetCargoManifestSelection() {
        guard canRefreshCargoProject, selectedCargoManifestURL != nil else { return }
        selectedCargoManifestURL = nil
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

    /// Loads Cargo metadata in the background once a workspace scan is applied,
    /// so opening the tool window renders from memory instead of paying for two
    /// toolchain probes and `cargo metadata` at click time.
    ///
    /// Only a feature that has loaded nothing and failed at nothing is warmed:
    /// a failure stays on screen for the user to retry from Refresh rather than
    /// being re-attempted on every rescan.
    func prewarmCargoProject() {
        guard isCargoAvailable, canRefreshCargoProject else { return }
        if let feature = cargoProjectFeatureIfActive {
            guard feature.snapshot == nil, feature.state == .idle else { return }
        }
        startCargoRefresh(revealsToolWindow: false)
    }

    func refreshCargoProject() {
        startCargoRefresh(revealsToolWindow: true)
    }

    /// `revealsToolWindow` separates the user's Refresh, which is expected to
    /// bring the tool window forward, from the background warm-up, which must
    /// never open a panel the user did not ask for.
    private func startCargoRefresh(revealsToolWindow: Bool) {
        guard canRefreshCargoProject, let identity = currentWorkspaceIdentity,
              let manifestURL = cargoManifestURL else { return }
        if revealsToolWindow { isCargoVisible = true }
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

/// The result of one candidate scan, keyed by the scan it was derived from.
struct CargoManifestCache {
    let workspace: URL
    /// nil when no scan has been applied yet, which is a cacheable answer too.
    let snapshotID: UUID?
    let urls: [URL]
}

/// Uses only the applied inventory, so recognition never probes a toolchain or
/// opens files while a toolbar/menu is being rendered.
enum CargoManifestSelection {
    static func candidates(workspace: URL, files: [URL]) -> [URL] {
        let root = workspace.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        // Names are matched before standardizing. Workspace inventories are
        // built by appending normalized relative paths to the root, so
        // standardizing cannot change a last path component of `Cargo.toml`,
        // and doing it first would resolve every file in the project to find a
        // handful of manifests.
        return files.filter { $0.lastPathComponent == "Cargo.toml" }
            .map(\.standardizedFileURL)
            .filter { $0.path.hasPrefix(prefix) }
            .sorted {
            let left = String($0.path.dropFirst(prefix.count))
            let right = String($1.path.dropFirst(prefix.count))
            let leftDepth = left.split(separator: "/").count
            let rightDepth = right.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return left.utf8.lexicographicallyPrecedes(right.utf8)
        }
    }
}
