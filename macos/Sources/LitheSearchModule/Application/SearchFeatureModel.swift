import Combine
import Foundation

public struct ProjectReplacementApplyResult: Sendable {
    public let changedFiles: Int
    public let failedFiles: [String]
    public init(changedFiles: Int, failedFiles: [String]) {
        self.changedFiles = changedFiles; self.failedFiles = failedFiles
    }
}

public struct SearchReplacementEdit: Sendable {
    public let path: String
    public let sourceText: String
    public let replacementText: String
    public init(path: String, sourceText: String, replacementText: String) {
        self.path = path; self.sourceText = sourceText; self.replacementText = replacementText
    }
}

/// Owns search result state and delegates matching/replacement preview semantics
/// to the shared workspace operations port.
@MainActor
public final class SearchFeatureModel: ObservableObject {
    @Published public private(set) var searchResults: [FileSearchResult] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var searchEverywhereResults = SearchEverywhereResults(
        fileMatches: [],
        contentMatches: []
    )
    @Published public private(set) var isSearchingEverywhere = false
    @Published public private(set) var projectReplacementFiles: [ProjectReplacementFile] = []
    @Published public private(set) var isPreviewingProjectReplacement = false
    @Published public private(set) var isApplyingProjectReplacement = false

    public var isLoadingProjectReplacement: Bool {
        isPreviewingProjectReplacement || isApplyingProjectReplacement
    }

    @Published public private(set) var searchFailure: ProjectSearchFailure?
    @Published public private(set) var searchIssues: [ProjectTextPreviewIssue] = []
    @Published public private(set) var searchIsIncomplete = false
    @Published public private(set) var replacementFailure: ProjectSearchFailure?
    @Published public private(set) var replacementIssues: [ProjectTextPreviewIssue] = []
    @Published public private(set) var excludedReplacementOccurrences: Set<String> = []
    @Published public private(set) var replacementStatus: ProjectTextPreview.Status?

    public var canApplyReplacementPreview: Bool {
        replacementStatus == .complete && replacementFailure == nil
            && !projectReplacementFiles.isEmpty
            && projectReplacementFiles.allSatisfy { $0.sourceText != nil && !$0.edits.isEmpty }
    }

    private let previewWorker = SearchPreviewWorker()
    private var previewTasks: [String: Task<Result<ProjectTextPreview, ProjectSearchFailure>, Never>] = [:]
    private var currentSearchOperationID: String?
    private var currentReplacementOperationID: String?
    private let operations: any SearchOperations
    private var indexTask: Task<Void, Never>?
    private var indexTaskGeneration = 0
    private var searchGeneration = 0
    private var everywhereGeneration = 0
    private var replacementGeneration = 0

    public var hasActiveModuleWork: Bool {
        isSearching || isSearchingEverywhere || isLoadingProjectReplacement || indexTask != nil || !previewTasks.isEmpty
    }

    public init(operations: any SearchOperations) {
        self.operations = operations
    }

    public func reset() {
        for task in previewTasks.values { task.cancel() }
        currentSearchOperationID = nil
        currentReplacementOperationID = nil
        searchGeneration += 1
        everywhereGeneration += 1
        replacementGeneration += 1
        indexTaskGeneration += 1
        indexTask?.cancel()
        indexTask = nil
        searchResults = []
        searchFailure = nil
        searchIssues = []
        searchIsIncomplete = false
        isSearching = false
        searchEverywhereResults = SearchEverywhereResults(fileMatches: [], contentMatches: [])
        isSearchingEverywhere = false
        projectReplacementFiles = []
        replacementFailure = nil
        replacementIssues = []
        replacementStatus = nil
        excludedReplacementOccurrences = []
        isPreviewingProjectReplacement = false
    }

    public func warmIndex(at workspaceURL: URL, visibilityRules: SearchVisibilityRules) {
        replaceIndexTask { operations in
            operations.warmSearchIndex(at: workspaceURL, visibilityRules: visibilityRules)
        }
    }

    public func invalidateIndex(at workspaceURL: URL, visibilityRules: SearchVisibilityRules) {
        replaceIndexTask { operations in
            operations.invalidateSearchIndex(at: workspaceURL, visibilityRules: visibilityRules)
        }
    }

    public func updateIndex(
        at workspaceURL: URL,
        changedPaths: [String],
        visibilityRules: SearchVisibilityRules
    ) async {
        guard !changedPaths.isEmpty else { return }
        replaceIndexTask { operations in
            operations.updateSearchIndex(
                at: workspaceURL,
                changedPaths: changedPaths,
                visibilityRules: visibilityRules
            )
        }
        await indexTask?.value
    }

    private func replaceIndexTask(
        operation: @escaping @Sendable (any SearchOperations) -> Void
    ) {
        let previousTask = indexTask
        previousTask?.cancel()
        let operations = self.operations
        indexTaskGeneration += 1
        let generation = indexTaskGeneration
        let worker = Task.detached(priority: .utility) {
            await previousTask?.value
            guard !Task.isCancelled else { return }
            // Search operations are synchronous ports. Run them on a GCD worker
            // so a slow indexer cannot occupy Swift's cooperative executor.
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    operation(operations)
                    continuation.resume()
                }
            }
        }
        indexTask = Task { [weak self] in
            await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, self.indexTaskGeneration == generation else { return }
            self.indexTask = nil
        }
    }

    public func clearProjectSearch() {
        if let id = currentSearchOperationID { previewTasks[id]?.cancel() }
        currentSearchOperationID = nil
        searchGeneration += 1
        searchResults = []
        searchFailure = nil
        searchIssues = []
        searchIsIncomplete = false
        isSearching = false
    }

    public func searchProject(
        at workspaceURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules,
        scope: ProjectTextScope = .project,
        textOverrides: [String: String] = [:],
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
        guard !query.isEmpty else {
            clearProjectSearch()
            return
        }

        if let id = currentSearchOperationID { previewTasks[id]?.cancel() }
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        searchFailure = nil
        searchIssues = []
        searchIsIncomplete = false
        let request = ProjectTextPreviewRequest(rootURL: workspaceURL, scope: scope, purpose: .search,
            query: query, options: options, textOverrides: textOverrides, visibilityRules: visibilityRules)
        let outcome: Result<ProjectTextPreview, ProjectSearchFailure>
        if scope.isEmpty {
            outcome = .success(ProjectTextPreview(files: [], status: .complete))
        } else {
            currentSearchOperationID = request.operationID
            outcome = await runPreview(request)
        }

        guard generation == searchGeneration else { return }
        guard !Task.isCancelled, isCurrent() else {
            isSearching = false
            return
        }
        switch outcome {
        case .success(let preview):
            searchResults = preview.files.flatMap { file in
                file.matches.map { FileSearchResult(url: file.url, line: $0.line, preview: $0.before) }
            }
            searchIssues = preview.issues
            searchIsIncomplete = preview.status == .incomplete
        case .failure(let error):
            searchResults = []
            searchFailure = error
        }
        isSearching = false
    }

    public func clearSearchEverywhere() {
        everywhereGeneration += 1
        searchEverywhereResults = SearchEverywhereResults(fileMatches: [], contentMatches: [])
        isSearchingEverywhere = false
    }

    public func searchEverywhere(
        at workspaceURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules,
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearSearchEverywhere()
            return
        }

        everywhereGeneration += 1
        let generation = everywhereGeneration
        isSearchingEverywhere = true
        let operations = self.operations
        let indexedResults = await Self.runSearch {
            operations.searchEverywhere(
                at: workspaceURL,
                query: query,
                options: options,
                visibilityRules: visibilityRules
            ) ?? SearchEverywhereResults()
        }

        guard generation == everywhereGeneration else { return }
        guard !Task.isCancelled, isCurrent() else {
            isSearchingEverywhere = false
            return
        }
        searchEverywhereResults = SearchEverywhereResults(
            fileMatches: indexedResults.fileMatches,
            classMatches: indexedResults.classMatches,
            symbolMatches: indexedResults.symbolMatches,
            contentMatches: indexedResults.contentMatches
        )
        isSearchingEverywhere = false
    }

    public func setReplacementOccurrence(_ id: String, included: Bool) {
        guard !isApplyingProjectReplacement else { return }
        if included { excludedReplacementOccurrences.remove(id) }
        else { excludedReplacementOccurrences.insert(id) }
    }

    public func includeAllReplacementOccurrences() {
        guard !isApplyingProjectReplacement else { return }
        excludedReplacementOccurrences = []
    }

    public func clearProjectReplacementPreview() {
        if let id = currentReplacementOperationID { previewTasks[id]?.cancel() }
        currentReplacementOperationID = nil
        replacementGeneration += 1
        projectReplacementFiles = []
        replacementFailure = nil
        replacementIssues = []
        replacementStatus = nil
        excludedReplacementOccurrences = []
        isPreviewingProjectReplacement = false
    }

    public func applyProjectReplacement(
        at workspaceURL: URL,
        selectedPaths: Set<String>,
        textOverrides: [String: String],
        recordHistory: @escaping @MainActor (String, URL) async -> Void,
        saveTextOverride: @escaping @MainActor (URL, String) throws -> Bool,
        applyTransaction: (@MainActor ([SearchReplacementEdit]) async -> ProjectReplacementApplyResult)? = nil
    ) async -> ProjectReplacementApplyResult {
        guard !isLoadingProjectReplacement, canApplyReplacementPreview else {
            return ProjectReplacementApplyResult(changedFiles: 0, failedFiles: [])
        }
        let exclusions = excludedReplacementOccurrences
        let targets = projectReplacementFiles.filter {
            selectedPaths.contains($0.relativePath) && $0.edits.contains { !exclusions.contains($0.id) }
        }
        guard !targets.isEmpty else {
            return ProjectReplacementApplyResult(changedFiles: 0, failedFiles: [])
        }

        if let applyTransaction {
            var edits: [SearchReplacementEdit] = []
            for target in targets {
                let currentText = textOverrides[target.relativePath] ?? operations.readFile(at: workspaceURL, relativePath: target.relativePath)
                guard let currentText, case .success(let replacedText) = target.selectedReplacement(excluding: exclusions), replacedText != currentText else { continue }
                edits.append(SearchReplacementEdit(path: target.relativePath, sourceText: currentText, replacementText: replacedText))
            }
            return await applyTransaction(edits)
        }

        isApplyingProjectReplacement = true
        defer { isApplyingProjectReplacement = false }
        var changedFiles = 0
        var failedFiles: [String] = []
        for target in targets {
            let currentText = textOverrides[target.relativePath] ?? operations.readFile(
                at: workspaceURL,
                relativePath: target.relativePath
            )
            guard let currentText, case .success(let replacedText) = target.selectedReplacement(excluding: exclusions) else {
                failedFiles.append(target.relativePath)
                continue
            }
            guard replacedText != currentText else { continue }

            await recordHistory(currentText, target.url)
            do {
                let savedOverride = try saveTextOverride(target.url, replacedText)
                if !savedOverride && !operations.writeFile(
                    replacedText,
                    at: workspaceURL,
                    relativePath: target.relativePath
                ) {
                    throw NSError(domain: "LitheWorkspace", code: 1)
                }
                changedFiles += 1
            } catch {
                failedFiles.append(target.relativePath)
            }
        }
        return ProjectReplacementApplyResult(
            changedFiles: changedFiles,
            failedFiles: failedFiles
        )
    }

    @discardableResult
    public func previewProjectReplacement(
        at workspaceURL: URL,
        query: String,
        replacement: String,
        scope: ProjectTextScope,
        textOverrides: [String: String],
        options: ProjectSearchOptions = .default,
        visibilityRules: SearchVisibilityRules,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard !isApplyingProjectReplacement else { return false }
        guard !query.isEmpty else {
            clearProjectReplacementPreview()
            return false
        }

        if let id = currentReplacementOperationID { previewTasks[id]?.cancel() }
        replacementGeneration += 1
        let generation = replacementGeneration
        isPreviewingProjectReplacement = true
        replacementFailure = nil
        replacementIssues = []
        replacementStatus = nil
        excludedReplacementOccurrences = []
        let request = ProjectTextPreviewRequest(rootURL: workspaceURL, scope: scope, purpose: .replace,
            query: query, replacement: replacement, options: options,
            textOverrides: textOverrides, visibilityRules: visibilityRules)
        let outcome: Result<ProjectTextPreview, ProjectSearchFailure>
        if scope.isEmpty {
            outcome = .success(ProjectTextPreview(files: [], status: .complete))
        } else {
            currentReplacementOperationID = request.operationID
            outcome = await runPreview(request)
        }

        guard generation == replacementGeneration else { return false }
        guard !Task.isCancelled, isCurrent() else {
            isPreviewingProjectReplacement = false
            return false
        }
        switch outcome {
        case .success(let preview):
            projectReplacementFiles = preview.files
            replacementStatus = preview.status
            replacementIssues = preview.issues
        case .failure(let error):
            projectReplacementFiles = []
            replacementFailure = error
        }
        isPreviewingProjectReplacement = false
        return true
    }

    /// Presentation reset never abandons an operation that still owns a worker.
    public func shutdownWork() async {
        let index = indexTask
        let pending = Array(previewTasks.values)
        reset()
        await index?.value
        for task in pending { _ = await task.value }
    }

    private func runPreview(_ request: ProjectTextPreviewRequest) async -> Result<ProjectTextPreview, ProjectSearchFailure> {
        let worker = previewWorker
        let operations = operations
        let task = Task { await worker.perform(request, operations: operations) }
        previewTasks[request.operationID] = task
        defer { previewTasks.removeValue(forKey: request.operationID) }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Synchronous ports run on GCD, never on Swift's cooperative executor.
    /// The awaiting request owns completion; stale generations discard results.
    private nonisolated static func runSearch<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: operation())
            }
        }
    }
}
