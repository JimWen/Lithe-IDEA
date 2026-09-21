import Combine
import Foundation
import LitheSearchModule

@MainActor
extension AppModel {
    var searchFeatureIfActive: SearchFeatureModel? { searchCapability?.feature }

    func activateSearchModule() async -> SearchFeatureModel? {
        if let feature = searchFeatureIfActive { return feature }
        do {
            let value = try await services.moduleRuntime.activateCapability(.searchWorkspace)
            guard let capability = value as? LitheSearchModule.SearchModuleCapability else { return nil }
            cacheModuleCapability(capability, id: .searchWorkspace, moduleID: .search)
            observeModuleFeature(.search, observation: capability.feature.objectWillChange.sink { [weak self] _ in
                self?.scheduleObjectWillChangeRelay()
            })
            if let workspaceURL {
                capability.feature.warmIndex(
                    at: workspaceURL,
                    visibilityRules: settings.fileVisibilityRules.searchRules
                )
            }
            return capability.feature
        } catch {
            showNotification(error.localizedDescription)
            return nil
        }
    }

    func searchProject(options suppliedOptions: ProjectSearchOptions? = nil) async {
        guard let workspaceURL else { return }
        let request = searchRequests.begin(.project)
        let identity = currentWorkspaceIdentity
        let query = searchQuery
        let options = suppliedOptions ?? projectSearchOptions
        let scope = projectSearchScope
        let directory = projectSearchDirectory
        let textScope = capturedSearchScope(rootURL: workspaceURL)
        let buffers = searchBufferIdentity(rootURL: workspaceURL)
        let overrides = openDocumentTextOverrides(rootURL: workspaceURL, scope: textScope)
        let isCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.searchRequests.isCurrent(request) && self.currentWorkspaceIdentity == identity
                && self.searchQuery == query && self.projectSearchScope == scope
                && (suppliedOptions != nil || self.projectSearchOptions == options)
                && self.projectSearchDirectory == directory
                && self.searchBufferIdentity(rootURL: workspaceURL) == buffers
        }
        guard let searchFeature = await searchRequests.activate(
            for: request, isValid: isCurrent, operation: { await self.activateSearchModule() }
        ) else { return }
        projectSearchError = nil
        await searchFeature.searchProject(
            at: workspaceURL, query: query, options: options,
            visibilityRules: settings.fileVisibilityRules.searchRules,
            scope: textScope, textOverrides: overrides, isCurrent: isCurrent
        )
        if isCurrent() {
            projectSearchError = searchFeature.searchFailure?.localizedDescription
        }
        try? services.moduleRuntime.markIdle(.search)
    }

    var projectSearchMatches: [FileSearchResult] {
        let matches = searchResults.filter { $0.kind == .content }
        guard projectSearchScope == .openFiles else { return matches }
        let urls = Set(openDocuments.map { $0.url.standardizedFileURL })
        return matches.filter { urls.contains($0.url.standardizedFileURL) }
    }

    func searchPreview(for result: FileSearchResult) async -> ProjectSearchPreview {
        if let document = openDocuments.first(where: { $0.url == result.url }) {
            return .context(in: document.text, line: result.line ?? 1)
        }
        let storage = services.fileStorage
        return await Task.detached(priority: .userInitiated) {
            do {
                let limit = 2 * 1024 * 1024
                if let size = storage.metadata(for: result.url)?.byteCount, size > limit {
                    return ProjectSearchPreview(lines: [], message: String(localized: "Open the file to preview this large result."))
                }
                let data = try storage.readPrefix(from: result.url, byteCount: limit)
                return ProjectSearchPreview.context(in: String(decoding: data, as: UTF8.self), line: result.line ?? 1)
            } catch {
                return ProjectSearchPreview(lines: [], message: error.localizedDescription)
            }
        }.value
    }

    func toggleSearchEverywhere() {
        guard workspaceURL != nil, !isSearchEverywhereVisible else { return }
        isSearchEverywhereVisible = true
    }

    func dismissSearchEverywhere() {
        isSearchEverywhereVisible = false
        searchEverywhereQuery = ""
    }

    func clearSearchEverywhereResults() {
        searchRequests.invalidate(.everywhere)
        searchFeatureIfActive?.clearSearchEverywhere()
    }

    func searchEverywhere(query requestedQuery: String? = nil, options: ProjectSearchOptions = .default) async {
        if let requestedQuery { searchEverywhereQuery = requestedQuery }
        guard let workspaceURL, isSearchEverywhereVisible else { return }
        let request = searchRequests.begin(.everywhere)
        let identity = currentWorkspaceIdentity
        let query = searchEverywhereQuery
        let isCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.searchRequests.isCurrent(request) && self.currentWorkspaceIdentity == identity
                && self.isSearchEverywhereVisible && self.searchEverywhereQuery == query
        }
        guard let searchFeature = await searchRequests.activate(
            for: request, isValid: isCurrent, operation: { await self.activateSearchModule() }
        ) else { return }
        await searchFeature.searchEverywhere(
            at: workspaceURL, query: query, options: options,
            visibilityRules: settings.fileVisibilityRules.searchRules, isCurrent: isCurrent
        )
        try? services.moduleRuntime.markIdle(.search)
    }

    func openProjectSearch() {
        guard workspaceURL != nil else { return }
        if !editorSelectedText.isEmpty { searchQuery = editorSelectedText }
        isProjectSearchPresented = true
    }

    func clearProjectReplacementPreview() {
        searchRequests.invalidate(.replacement)
        searchFeatureIfActive?.clearProjectReplacementPreview()
        selectedProjectReplacementPaths = []
    }

    func openProjectReplace(inheriting options: ProjectSearchOptions? = nil) {
        guard workspaceURL != nil else { return }
        if !editorSelectedText.isEmpty { searchQuery = editorSelectedText }
        projectReplaceQuery = searchQuery
        projectReplaceText = ""
        if let options { projectReplaceOptions = options }
        clearProjectReplacementPreview()
        isProjectReplaceVisible = true
    }

    func previewProjectReplacement(
        query requestedQuery: String? = nil,
        replacement requestedReplacement: String? = nil,
        options requestedOptions: ProjectSearchOptions? = nil
    ) async {
        if let requestedQuery { projectReplaceQuery = requestedQuery }
        if let requestedReplacement { projectReplaceText = requestedReplacement }
        if let requestedOptions { projectReplaceOptions = requestedOptions }
        guard let rootURL = workspaceURL, isProjectReplaceVisible else { return }
        let request = searchRequests.begin(.replacement)
        let identity = currentWorkspaceIdentity
        let query = projectReplaceQuery
        let replacement = projectReplaceText
        let options = projectReplaceOptions
        let scope = capturedSearchScope(rootURL: rootURL)
        let buffers = searchBufferIdentity(rootURL: rootURL)
        let overrides = openDocumentTextOverrides(rootURL: rootURL, scope: scope)
        let isCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.searchRequests.isCurrent(request) && self.currentWorkspaceIdentity == identity
                && self.isProjectReplaceVisible && self.projectReplaceQuery == query
                && self.projectReplaceText == replacement && self.projectReplaceOptions == options
                && self.capturedSearchScope(rootURL: rootURL) == scope
                && self.searchBufferIdentity(rootURL: rootURL) == buffers
        }
        guard let searchFeature = await searchRequests.activate(
            for: request, isValid: isCurrent, operation: { await self.activateSearchModule() }
        ) else { return }
        let accepted = await searchFeature.previewProjectReplacement(
            at: rootURL, query: query, replacement: replacement,
            scope: scope,
            textOverrides: overrides, options: options,
            visibilityRules: settings.fileVisibilityRules.searchRules, isCurrent: isCurrent
        )
        try? services.moduleRuntime.markIdle(.search)
        guard accepted, isCurrent() else { return }
        selectedProjectReplacementPaths = Set(projectReplacementFiles.map(\.relativePath))
    }

    func applyProjectReplacement() async {
        guard let rootURL = workspaceURL,
              !projectReplaceQuery.isEmpty,
              let searchFeature = await activateSearchModule(),
              !searchFeature.isLoadingProjectReplacement else { return }
        let result = await searchFeature.applyProjectReplacement(
            at: rootURL, selectedPaths: selectedProjectReplacementPaths,
            textOverrides: openDocumentTextOverrides(rootURL: rootURL),
            recordHistory: { [weak self] text, fileURL in
                guard let feature = await self?.activateHistoryModule() else { return }
                await feature.recordHistorySnapshot(text: text, for: fileURL, reason: .beforeBatchReplace)
            },
            saveTextOverride: { [weak self] url, text in
                guard let self,
                      let document = self.openDocuments.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return false }
                let previousText = document.text
                document.text = text
                let revision = document.lifecycleState.revision
                do { return try await self.saveDocument(document) }
                catch {
                    if document.lifecycleState.revision == revision, !document.hasMutationLease {
                        document.text = previousText
                    }
                    throw error
                }
            },
            applyTransaction: { [weak self] edits in
                guard let self else { return ProjectReplacementApplyResult(changedFiles: 0, failedFiles: edits.map(\.path)) }
                let transactionEdits = edits.map {
                    WorkspaceTextEdit(path: $0.path, sourceText: $0.sourceText,
                                      replacementText: $0.replacementText, sourceIdentity: "")
                }
                let result = await self.services.workspaceTextEditUndoController.apply(transactionEdits, at: rootURL)
                let failures = result.failedPaths + result.recoveryPaths
                return ProjectReplacementApplyResult(
                    changedFiles: result.state == .applied ? transactionEdits.count : 0,
                    failedFiles: result.state == .applied ? [] : (failures.isEmpty ? edits.map(\.path) : failures)
                )
            }
        )
        try? services.moduleRuntime.markIdle(.search)
        isProjectReplaceVisible = false
        searchFeature.clearProjectReplacementPreview()
        selectedProjectReplacementPaths = []
        await refreshWorkspace()
        if !result.failedFiles.isEmpty { showNotification("Could not replace in \(result.failedFiles.count) file(s)", severity: .error) }
        else if result.changedFiles > 0 { showNotification("Replaced text in \(result.changedFiles) file(s)") }
    }

    func openSearchEverywhereResult(_ result: FileSearchResult) { dismissSearchEverywhere(); openSearchResult(result) }
    func performSearchEverywhereAction(_ action: LitheAction) { dismissSearchEverywhere(); action.perform() }

    func openSearchResult(_ result: FileSearchResult) {
        if let line = result.line {
            navigateToEditorLocation(url: result.url, line: line - 1, utf16Column: 0)
        } else {
            openFile(result.url)
        }
    }

    private func capturedSearchScope(rootURL: URL) -> ProjectTextScope {
        switch projectSearchScope {
        case .project: return .project
        case .directory: return .directory(projectSearchDirectory)
        case .openFiles:
            return .files(openDocuments.compactMap { workspaceRelativePath(for: $0.url, root: rootURL) }.sorted())
        }
    }

    private func searchBufferIdentity(rootURL: URL) -> [String] {
        openDocuments.compactMap { document in
            guard let path = workspaceRelativePath(for: document.url, root: rootURL) else { return nil }
            return "\(path):\(document.id):\(document.lifecycleState.revision)"
        }.sorted()
    }

    private func openDocumentTextOverrides(rootURL: URL, scope: ProjectTextScope = .project) -> [String: String] {
        Dictionary(uniqueKeysWithValues: openDocuments.compactMap { document in
            guard let path = workspaceRelativePath(for: document.url, root: rootURL) else { return nil }
            switch scope {
            case .project: break
            case .directory(let directory):
                guard directory.isEmpty || path.hasPrefix(directory + "/") else { return nil }
            case .files(let paths):
                guard paths.contains(path) else { return nil }
            }
            return (path, document.text)
        })
    }
}
