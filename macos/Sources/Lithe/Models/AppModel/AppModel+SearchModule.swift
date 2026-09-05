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
        guard let workspaceURL, let searchFeature = await activateSearchModule() else { return }
        let identity = currentWorkspaceIdentity
        let query = searchQuery
        let options = suppliedOptions ?? projectSearchOptions
        let scope = projectSearchScope
        let directory = projectSearchDirectory
        projectSearchError = nil
        if options.regularExpression, !query.isEmpty {
            do { _ = try NSRegularExpression(pattern: query) }
            catch {
                searchFeature.clearProjectSearch()
                projectSearchError = error.localizedDescription
                return
            }
        }
        var root = workspaceURL
        if scope == .directory, !directory.isEmpty {
            root = directory.hasPrefix("/")
                ? URL(fileURLWithPath: directory).standardizedFileURL
                : workspaceURL.appendingPathComponent(directory).standardizedFileURL
            let base = workspaceURL.standardizedFileURL.path
            guard (root.path == base || root.path.hasPrefix(base + "/")),
                  workspaceFileOperations.isDirectory(at: root) else {
                searchFeature.clearProjectSearch()
                projectSearchError = String(localized: "Choose a directory inside the current project.")
                return
            }
        }
        await searchFeature.searchProject(
            at: root, query: query, options: options,
            visibilityRules: settings.fileVisibilityRules.searchRules,
            paths: scope == .openFiles ? openDocuments.compactMap {
                workspaceRelativePath(for: $0.url, root: workspaceURL)
            } : nil,
            textOverrides: scope == .openFiles ? openDocumentTextOverrides(rootURL: workspaceURL) : [:],
            isCurrent: { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled && self.currentWorkspaceIdentity == identity
                    && self.searchQuery == query && self.projectSearchScope == scope
                    && (suppliedOptions != nil || self.projectSearchOptions == options)
                    && self.projectSearchDirectory == directory
            }
        )
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
        searchFeatureIfActive?.clearSearchEverywhere()
    }

    func searchEverywhere(options: ProjectSearchOptions = .default) async {
        guard let searchFeature = await activateSearchModule() else { return }
        guard let workspaceURL else { searchFeature.clearSearchEverywhere(); return }
        let query = searchEverywhereQuery
        await searchFeature.searchEverywhere(
            at: workspaceURL, query: query, options: options,
            visibilityRules: settings.fileVisibilityRules.searchRules,
            isCurrent: { [weak self] in self?.workspaceURL == workspaceURL && self?.searchEverywhereQuery == query }
        )
        try? services.moduleRuntime.markIdle(.search)
    }

    func openProjectSearch() {
        guard workspaceURL != nil else { return }
        if !editorSelectedText.isEmpty { searchQuery = editorSelectedText }
        isProjectSearchPresented = true
    }

    func clearProjectReplacementPreview() {
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

    func previewProjectReplacement() async {
        guard let rootURL = workspaceURL, let searchFeature = await activateSearchModule() else { return }
        let query = projectReplaceQuery
        let overrides = openDocumentTextOverrides(rootURL: rootURL)
        await searchFeature.previewProjectReplacement(
            at: rootURL, query: query, replacement: projectReplaceText,
            paths: projectFiles.compactMap { workspaceRelativePath(for: $0, root: rootURL) },
            textOverrides: overrides, options: projectReplaceOptions,
            visibilityRules: settings.fileVisibilityRules.searchRules,
            isCurrent: { [weak self] in self?.workspaceURL == rootURL && self?.projectReplaceQuery == query }
        )
        try? services.moduleRuntime.markIdle(.search)
        guard projectReplaceQuery == query else { return }
        selectedProjectReplacementPaths = Set(projectReplacementFiles.map(\.relativePath))
    }

    func applyProjectReplacement() async {
        guard let rootURL = workspaceURL,
              !projectReplaceQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let searchFeature = await activateSearchModule() else { return }
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
                do { try self.saveDocument(document); return true }
                catch { document.text = previousText; throw error }
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

    private func openDocumentTextOverrides(rootURL: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: openDocuments.compactMap { document in
            guard let path = workspaceRelativePath(for: document.url, root: rootURL) else { return nil }
            return (path, document.text)
        })
    }
}
