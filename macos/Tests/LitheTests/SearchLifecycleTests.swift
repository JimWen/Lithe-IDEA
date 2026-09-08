import Foundation
import LitheSearchModule
import Testing
@testable import Lithe

@MainActor
struct SearchLifecycleTests {
    @Test(arguments: SearchLane.allCases, [false, true])
    func newestRequestOwnsResultsAndLoading(lane: SearchLane, newestFinishesFirst: Bool) async {
        let operations = GatedSearchOperations()
        let feature = SearchFeatureModel(operations: operations)
        defer { operations.releaseAll(); feature.reset() }
        let first = Task { await lane.run(feature, newest: false) }
        #expect(await operations.firstStarted.waitUntilOpen())
        let second = Task { await lane.run(feature, newest: true) }
        #expect(await operations.secondStarted.waitUntilOpen())
        if newestFinishesFirst {
            operations.secondGate.open()
            #expect(await second.value)
            #expect(lane.value(feature) == "new")
            operations.firstGate.open()
            #expect(await first.value == false)
        } else {
            operations.firstGate.open()
            #expect(await first.value == false)
            #expect(lane.isLoading(feature))
            #expect(lane.value(feature) == nil)
            operations.secondGate.open()
            #expect(await second.value)
        }
        #expect(!lane.isLoading(feature))
        #expect(lane.value(feature) == "new")
    }

    @Test(arguments: SearchLane.allCases, SearchInvalidation.allCases)
    func invalidatedRequestCannotRefillResults(lane: SearchLane, invalidation: SearchInvalidation) async {
        let operations = GatedSearchOperations()
        let feature = SearchFeatureModel(operations: operations)
        defer { operations.releaseAll(); feature.reset() }
        let task = Task { await lane.run(feature, newest: false) }
        #expect(await operations.firstStarted.waitUntilOpen())
        switch invalidation {
        case .clear: lane.clear(feature)
        case .reset: feature.reset()
        case .cancel: task.cancel()
        }
        if lane == .replacement { #expect(feature.hasActiveModuleWork) }
        operations.firstGate.open()
        #expect(await task.value == false)
        #expect(!lane.isLoading(feature))
        #expect(lane.value(feature) == nil)
    }

    @Test
    func shutdownRetainsPreviewOwnershipUntilItsWorkerActuallyReturns() async {
        let operations = GatedSearchOperations()
        let feature = SearchFeatureModel(operations: operations)
        let shutdownStarted = TestGate()
        var shutdownFinished = false
        defer { operations.releaseAll(); feature.reset() }
        let preview = Task { await SearchLane.replacement.run(feature, newest: false) }
        #expect(await operations.firstStarted.waitUntilOpen())
        let shutdown = Task {
            shutdownStarted.open()
            await feature.shutdownWork()
            shutdownFinished = true
        }
        #expect(await shutdownStarted.waitUntilOpen())
        #expect(!shutdownFinished)
        #expect(feature.hasActiveModuleWork)
        operations.firstGate.open()
        #expect(await preview.value == false)
        await shutdown.value
        #expect(shutdownFinished)
        #expect(!feature.hasActiveModuleWork)
    }

    @Test(arguments: [false, true])
    func clearingPreviewCannotUnlockAnApply(reset: Bool) async {
        let operations = GatedSearchOperations()
        operations.releaseAll()
        let feature = SearchFeatureModel(operations: operations)
        let historyStarted = TestGate(), historyGate = TestGate()
        defer { historyGate.open(); feature.reset() }
        #expect(await SearchLane.replacement.run(feature, newest: true))
        var saved = 0
        let apply = Task {
            await feature.applyProjectReplacement(
                at: searchRoot, selectedPaths: ["file.go"], textOverrides: ["file.go": "old"],
                recordHistory: { _, _ in
                    historyStarted.open()
                    #expect(await historyGate.waitUntilOpen())
                }, saveTextOverride: { _, _ in saved += 1; return true }
            )
        }
        #expect(await historyStarted.waitUntilOpen())
        if reset { feature.reset() } else { feature.clearProjectReplacementPreview() }
        #expect(feature.isLoadingProjectReplacement)
        #expect(feature.isApplyingProjectReplacement)
        #expect(await SearchLane.replacement.run(feature, newest: true) == false)
        let duplicate = await feature.applyProjectReplacement(
            at: searchRoot, selectedPaths: ["file.go"], textOverrides: [:],
            recordHistory: { _, _ in Issue.record("Duplicate apply reached history") },
            saveTextOverride: { _, _ in Issue.record("Duplicate apply wrote text"); return true }
        )
        #expect(duplicate.changedFiles == 0)
        historyGate.open()
        #expect(await apply.value.changedFiles == 1)
        #expect(saved == 1)
        #expect(!feature.isLoadingProjectReplacement)
    }

    @Test
    func closingAppModelSearchSurfacesInvalidatesBeforeModuleActivation() async {
        let store = SearchLifecycleStore()
        let settings = AppSettings(store: store)
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode
        ).services)
        #expect(model.searchFeatureIfActive == nil)
        model.isSearchEverywhereVisible = true
        let search = model.searchRequests.begin(.everywhere)
        model.isSearchEverywhereVisible = false
        model.isSearchEverywhereVisible = true
        #expect(!model.searchRequests.isCurrent(search))
        model.isProjectReplaceVisible = true
        let preview = model.searchRequests.begin(.replacement)
        model.isProjectReplaceVisible = false
        model.isProjectReplaceVisible = true
        #expect(!model.searchRequests.isCurrent(preview))
        await model.shutdownProjectSession()
    }

    @Test(arguments: [false, true])
    func activationWaitCannotReviveAnOlderRequest(closeAndReopen: Bool) async {
        // This is the same pre/post-activation owner used by AppModel. No real
        // module runtime or filesystem is needed to control its suspension.
        let lifecycle = SearchRequestLifecycle()
        let started = TestGate(), release = TestGate()
        defer { release.open() }
        let request = lifecycle.begin(.everywhere)
        let first = Task {
            await lifecycle.activate(for: request, isValid: { true }) {
                started.open()
                #expect(await release.waitUntilOpen())
                return "old module"
            }
        }
        #expect(await started.waitUntilOpen())
        if closeAndReopen { lifecycle.invalidate(.everywhere) }
        let newest = lifecycle.begin(.everywhere)
        let result = await lifecycle.activate(for: newest, isValid: { true }) { "new module" }
        #expect(result == "new module")
        release.open()
        #expect(await first.value == nil)
        #expect(lifecycle.isCurrent(newest))
    }
}

private let searchRoot = URL(fileURLWithPath: "/search-lifecycle-fixture")
private let searchRules = SearchVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: [])

enum SearchInvalidation: CaseIterable { case clear, reset, cancel }
enum SearchLane: CaseIterable {
    case everywhere, replacement

    @MainActor func run(_ feature: SearchFeatureModel, newest: Bool) async -> Bool {
        switch self {
        case .everywhere:
            await feature.searchEverywhere(at: searchRoot, query: "same",
                options: ProjectSearchOptions(caseSensitive: newest), visibilityRules: searchRules, isCurrent: { true })
            return value(feature) == (newest ? "new" : "old")
        case .replacement:
            return await feature.previewProjectReplacement(at: searchRoot, query: "same",
                replacement: newest ? "new" : "old", scope: .files(["file.go"]), textOverrides: [:],
                visibilityRules: searchRules, isCurrent: { true })
        }
    }

    @MainActor func value(_ feature: SearchFeatureModel) -> String? {
        switch self {
        case .everywhere: feature.searchEverywhereResults.fileMatches.first?.preview
        case .replacement: feature.projectReplacementFiles.first?.replacementText
        }
    }
    @MainActor func isLoading(_ feature: SearchFeatureModel) -> Bool {
        switch self {
        case .everywhere: feature.isSearchingEverywhere
        case .replacement: feature.isLoadingProjectReplacement
        }
    }
    @MainActor func clear(_ feature: SearchFeatureModel) {
        switch self {
        case .everywhere: feature.clearSearchEverywhere()
        case .replacement: feature.clearProjectReplacementPreview()
        }
    }
}

private final class GatedSearchOperations: SearchOperations, @unchecked Sendable {
    func cancelTextPreview(operationID: String) {}
    func textPreview(_ request: ProjectTextPreviewRequest) -> Result<ProjectTextPreview, ProjectSearchFailure> {
        enter(newest: request.replacement == "new")
        return .success(ProjectTextPreview(files: [ProjectReplacementFile(
            url: request.rootURL.appendingPathComponent("file.go"), relativePath: "file.go", matches: [
                ProjectReplacementMatch(line: 1, before: "same", after: request.replacement, occurrenceCount: 1)
            ], replacementText: request.replacement, sourceText: "old", edits: [
                ProjectReplacementEdit(id: "file.go:0:0", line: 1, utf16Start: 0, utf16Length: 3, newText: request.replacement)
            ])], status: .complete))
    }

    let firstStarted = TestGate(), secondStarted = TestGate()
    let firstGate = TestGate(), secondGate = TestGate()
    func releaseAll() { firstGate.open(); secondGate.open() }
    private func enter(newest: Bool) {
        (newest ? secondStarted : firstStarted).open()
        // The production port runs on GCD; the local deadline is asserted so a
        // missed release cannot silently turn a scheduling failure into success.
        #expect((newest ? secondGate : firstGate).waitSynchronously(timeout: 3))
    }
    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { [] }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> SearchEverywhereResults? {
        enter(newest: options.caseSensitive)
        return SearchEverywhereResults(fileMatches: [FileSearchResult(url: rootURL.appendingPathComponent("file.go"), line: nil,
            preview: options.caseSensitive ? "new" : "old")])
    }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions,
        paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? {
        enter(newest: replacement == "new")
        return [ProjectReplacementFile(url: rootURL.appendingPathComponent("file.go"), relativePath: "file.go",
            matches: [ProjectReplacementMatch(line: 1, before: "same", after: replacement, occurrenceCount: 1)],
            replacementText: replacement)]
    }
    func readFile(at rootURL: URL, relativePath: String) -> String? { "same" }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool {
        Issue.record("Test must never write through the disk port")
        return false
    }
}

private struct SearchLifecycleStore: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
    func removeObject(forKey key: String) {}
}
