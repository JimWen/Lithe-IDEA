import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

@MainActor
extension AppModel {
    /// Recognition reads the applied inventory; missing tools remain a visible
    /// error inside Go Tools instead of making the entry disappear.
    var isGoAvailable: Bool {
        // The contribution lookup is a small in-memory list, so it is asked
        // first and keeps the manifest scan off the path entirely for projects
        // that never loaded Go support.
        rightSidebarContributions.contains { $0.id == "language.go.projecttools" }
            && !goManifestURLs.isEmpty
    }

    /// Resolves a metadata location to a project file URL. Only the workspace
    /// root is project-resolvable; external dependency roots carry no host
    /// mapping the tree may hand to the editor.
    func goFileURL(for location: ProjectMetadataLocation) -> URL? {
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
    var goManifestURLs: [URL] {
        guard let workspaceURL else { return [] }
        let workspace = workspaceURL.standardizedFileURL
        let snapshot = workspaceFeature.appliedSnapshot
        if let cache = goTreePresentation.manifestCache,
           cache.workspace == workspace,
           cache.snapshotID == snapshot?.id {
            return cache.urls
        }
        let urls = GoManifestSelection.candidates(
            workspace: workspace, files: snapshot?.files ?? []
        )
        goTreePresentation.manifestCache = GoManifestCache(
            workspace: workspace, snapshotID: snapshot?.id, urls: urls
        )
        return urls
    }
    var goManifestURL: URL? {
        if let selectedGoManifestURL, goManifestURLs.contains(selectedGoManifestURL) {
            return selectedGoManifestURL
        }
        return goManifestURLs.first
    }

    func selectGoManifest(_ url: URL) {
        guard canRefreshGoProject, goManifestURLs.contains(url), goManifestURL != url else { return }
        selectedGoManifestURL = url
        goTreePresentation.reset()
        goProjectFeatureIfActive?.invalidateWorkspace()
        refreshGoProject()
    }

    /// Detaches an explicitly chosen go.mod and returns to the default one,
    /// mirroring the Cargo detach action for the Lithe manifest model.
    func resetGoManifestSelection() {
        guard canRefreshGoProject, selectedGoManifestURL != nil else { return }
        selectedGoManifestURL = nil
        goTreePresentation.reset()
        goProjectFeatureIfActive?.invalidateWorkspace()
        refreshGoProject()
    }

    var isGoToolWindowSelected: Bool { isGoVisible && isGoAvailable }
    var canRefreshGoProject: Bool {
        isGoAvailable && goRefreshTask == nil && goCancellationTask == nil
            && !(goProjectFeatureIfActive?.isActive ?? false)
    }
    var canCancelGoRefresh: Bool {
        isGoAvailable && !isGoCancelling
            && (isGoActivating || goProjectFeatureIfActive?.isActive == true)
    }

    func toggleGoProject() {
        guard isGoAvailable else { return }
        isGoVisible.toggle()
        guard isGoVisible else { return }
        if goProjectFeatureIfActive?.snapshot == nil { refreshGoProject() }
    }

    /// Loads Go metadata in the background once a workspace scan is applied,
    /// so opening the tool window renders from memory instead of paying for a
    /// toolchain probe and several `go list` rounds at click time.
    ///
    /// Only a feature that has loaded nothing and failed at nothing is warmed:
    /// a failure stays on screen for the user to retry from Refresh rather
    /// than being re-attempted on every rescan.
    func prewarmGoProject() {
        guard isGoAvailable, canRefreshGoProject else { return }
        if let feature = goProjectFeatureIfActive {
            guard feature.snapshot == nil, feature.state == .idle else { return }
        }
        startGoRefresh(revealsToolWindow: false)
    }

    func refreshGoProject() {
        startGoRefresh(revealsToolWindow: true)
    }

    /// `revealsToolWindow` separates the user's Refresh, which is expected to
    /// bring the tool window forward, from the background warm-up, which must
    /// never open a panel the user did not ask for.
    private func startGoRefresh(revealsToolWindow: Bool) {
        guard canRefreshGoProject, let identity = currentWorkspaceIdentity,
              let manifestURL = goManifestURL else { return }
        if revealsToolWindow { isGoVisible = true }
        goActivationError = nil
        isGoActivating = true
        let generation = goRequestGeneration
        goRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                goRefreshTask = nil
                isGoActivating = false
                scheduleObjectWillChangeRelay()
            }
            _ = await activateExecutionModule()
            guard !Task.isCancelled, goRequestGeneration == generation,
                  currentWorkspaceIdentity == identity, isGoAvailable,
                  goManifestURL == manifestURL else { return }
            guard let feature = goProjectFeatureIfActive else {
                goActivationError = String(localized: "Go metadata is unavailable.")
                return
            }
            isGoActivating = false
            await feature.refresh(
                workspaceURL: identity.url, workspaceGeneration: identity.generation, manifestURL: manifestURL
            )
        }
    }

    func cancelGoRefresh() {
        guard canCancelGoRefresh else { return }
        goRequestGeneration += 1
        goRefreshTask?.cancel()
        isGoCancelling = true
        let feature = goProjectFeatureIfActive
        goCancellationTask = Task { @MainActor [weak self] in
            await feature?.cancel()
            guard let self else { return }
            isGoCancelling = false
            goCancellationTask = nil
            scheduleObjectWillChangeRelay()
        }
    }

    func invalidateGoWorkspace() {
        projectToolTasksIfActive?.invalidateWorkspace()
        goRequestGeneration += 1
        goRefreshTask?.cancel()
        goProjectFeatureIfActive?.invalidateWorkspace()
        isGoVisible = false
        goActivationError = nil
        selectedGoManifestURL = nil
        goTreePresentation.reset()
    }

    func handleGoModuleEvent(_ event: ModuleEvent) {
        guard event.source == .languageExecutionExtension("go") || event.source == .execution else { return }
        let retired = event.name == "module.sleeping" || event.name == "module.shutdown"
            || event.name == ModuleEvent.languageProjectToolsRetiredName
        let unavailable = event.name == ModuleEvent.stateChangedName
            && moduleSnapshots.first(where: { $0.manifest.id == event.source })?.state == .disabled
        guard retired || unavailable else { return }
        goRequestGeneration += 1
        goRefreshTask?.cancel()
        goProjectFeatureIfActive?.invalidateProvider(moduleID: event.source)
        projectToolTasksIfActive?.invalidateProvider(moduleID: event.source)
        isGoVisible = false
        goActivationError = nil
        goTreePresentation.reset()
    }
}
