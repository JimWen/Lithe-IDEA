import Foundation
import LitheApplicationKernel
import LitheModuleAPI
import LitheSearchModule
import Testing

@MainActor
struct SearchModuleTests {
    @Test
    func explicitFileScopeSearchesUnsavedBuffersWithoutWriting() async {
        let feature = SearchFeatureModel(operations: ScopedSearchOperations())
        defer { feature.reset() }
        let root = URL(fileURLWithPath: "/search-fixture")
        await feature.searchProject(
            at: root, query: "unsaved", options: ProjectSearchOptions(fileMask: "*.go"),
            visibilityRules: SearchVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: []),
            scope: .files(["last.go"]), textOverrides: ["last.go": "unsaved buffer"], isCurrent: { true }
        )
        #expect(feature.searchResults == [FileSearchResult(
            url: root.appendingPathComponent("last.go"), line: 4, preview: "unsaved buffer"
        )])
        #expect(!feature.isSearching)
    }

    @Test
    func emptyExplicitScopesDoNotCallTheEngineOrEnlargeTheSelection() async {
        let feature = SearchFeatureModel(operations: UnexpectedPreviewOperations())
        defer { feature.reset() }
        let root = URL(fileURLWithPath: "/search-fixture")
        let rules = SearchVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: [])
        await feature.searchProject(at: root, query: "x", options: .default,
            visibilityRules: rules, scope: .files([]), textOverrides: ["a": "x"], isCurrent: { true })
        #expect(feature.searchResults.isEmpty)
        #expect(feature.searchFailure == nil)
        #expect(await feature.previewProjectReplacement(at: root, query: "x", replacement: "y",
            scope: .files([]), textOverrides: ["a": "x"], visibilityRules: rules, isCurrent: { true }))
        #expect(feature.projectReplacementFiles.isEmpty)
        #expect(feature.replacementStatus == .complete)
        #expect(!feature.canApplyReplacementPreview)
    }

    @Test
    func engineErrorsAndIncompleteResultsRemainVisibleAndCannotBeApplied() async {
        let root = URL(fileURLWithPath: "/search-fixture")
        let rules = SearchVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: [])
        let failure = ProjectSearchFailure(code: "parse_failed", message: "Invalid search expression", details: "lookaround is not supported")
        let feature = SearchFeatureModel(operations: PreviewOutcomeOperations(outcome: .failure(failure)))
        defer { feature.reset() }
        await feature.searchProject(at: root, query: "(?<=x)y", options: .default,
            visibilityRules: rules, isCurrent: { true })
        #expect(feature.searchFailure == failure)
        #expect(!feature.isSearching)
        #expect(await feature.previewProjectReplacement(at: root, query: "(?<=x)y", replacement: "y",
            scope: .project, textOverrides: [:], visibilityRules: rules, isCurrent: { true }))
        #expect(feature.replacementFailure == failure)
        #expect(!feature.canApplyReplacementPreview)

        let issue = ProjectTextPreviewIssue(path: "large.go", code: "previewBudgetExceeded", message: "Narrow scope")
        let partial = SearchFeatureModel(operations: PreviewOutcomeOperations(outcome: .success(ProjectTextPreview(
            files: [ProjectReplacementFile(url: root.appendingPathComponent("file.go"), relativePath: "file.go",
                matches: [], replacementText: "y", sourceText: "x")], status: .incomplete, issues: [issue]))))
        defer { partial.reset() }
        #expect(await partial.previewProjectReplacement(at: root, query: "x", replacement: "y",
            scope: .project, textOverrides: [:], visibilityRules: rules, isCurrent: { true }))
        #expect(partial.replacementIssues == [issue])
        #expect(!partial.canApplyReplacementPreview)
        let result = await partial.applyProjectReplacement(at: root, selectedPaths: ["file.go"], textOverrides: [:],
            recordHistory: { _, _ in Issue.record("Incomplete preview reached history") },
            saveTextOverride: { _, _ in Issue.record("Incomplete preview wrote a buffer"); return false })
        #expect(result.changedFiles == 0)
    }

    @Test
    func occurrenceExclusionRebuildsFromOriginalUnicodeAndZeroWidthRanges() throws {
        let file = ProjectReplacementFile(url: URL(fileURLWithPath: "/search-fixture/unicode.txt"),
            relativePath: "unicode.txt", matches: [], replacementText: "x😀 e\u{0301}!\r\n",
            sourceText: "😀 é e\u{0301}\r\n", edits: [
                ProjectReplacementEdit(id: "first", line: 1, utf16Start: 0, utf16Length: 0, newText: "x"),
                ProjectReplacementEdit(id: "middle", line: 1, utf16Start: 2, utf16Length: 2, newText: ""),
                ProjectReplacementEdit(id: "last", line: 1, utf16Start: 7, utf16Length: 0, newText: "!")
            ])
        #expect(try file.selectedReplacement(excluding: []).get() == "x😀 e\u{0301}!\r\n")
        #expect(try file.selectedReplacement(excluding: ["middle"]).get() == "x😀 é e\u{0301}!\r\n")
        let original = try file.selectedReplacement(excluding: ["first", "middle", "last"]).get()
        #expect(Array(original.utf8) == Array("😀 é e\u{0301}\r\n".utf8))
    }

    @Test
    func malformedOccurrenceRangesFailEvenWhenExcluded() {
        let invalidSets: [[ProjectReplacementEdit]] = [
            [ProjectReplacementEdit(id: "bad", line: 1, utf16Start: 1, utf16Length: 1, newText: "x")],
            [ProjectReplacementEdit(id: "bad", line: 1, utf16Start: 0, utf16Length: -1, newText: "x")],
            [ProjectReplacementEdit(id: "bad", line: 1, utf16Start: Int.max, utf16Length: 1, newText: "x")],
            [ProjectReplacementEdit(id: "a", line: 1, utf16Start: 0, utf16Length: 2, newText: "x"),
             ProjectReplacementEdit(id: "bad", line: 1, utf16Start: 0, utf16Length: 0, newText: "x")],
            [ProjectReplacementEdit(id: "bad", line: 1, utf16Start: 0, utf16Length: 0, newText: "x"),
             ProjectReplacementEdit(id: "bad", line: 1, utf16Start: 2, utf16Length: 0, newText: "x")]
        ]
        for edits in invalidSets {
            let file = ProjectReplacementFile(url: URL(fileURLWithPath: "/search-fixture/unicode.txt"),
                relativePath: "unicode.txt", matches: [], sourceText: "😀", edits: edits)
            guard case .failure(let error) = file.selectedReplacement(excluding: ["bad"]) else {
                Issue.record("An excluded malformed range was accepted"); continue
            }
            #expect(error.code == "invalid_preview")
        }
    }

    @Test
    func disabledSearchDoesNotConstructFactoryOrFeature() async throws {
        let recorder = SearchRecorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(
            ModuleFactory(manifest: SearchModule.moduleManifest, contributions: SearchModule.moduleContributions) {
                recorder.factoryCalls += 1
                return SearchModule(operations: TestSearchOperations())
            },
            enabled: false
        )

        await #expect(throws: ModuleRuntimeError.moduleDisabled(.search)) {
            _ = try await runtime.activateCapability(.searchWorkspace)
        }
        #expect(recorder.factoryCalls == 0)
        #expect(try !runtime.snapshot(for: .search).isInstantiated)
    }

    @Test
    func sleepReleasesFeatureAndWakeCreatesANewOne() async throws {
        let recorder = SearchRecorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: SearchModule.moduleManifest, contributions: SearchModule.moduleContributions) {
            recorder.factoryCalls += 1
            return SearchModule(operations: TestSearchOperations())
        })

        var first: SearchFeatureModel? = try #require(
            (try await runtime.activateCapability(.searchWorkspace) as? SearchModuleCapability)?.feature
        )
        weak var releasedFeature = first
        first = nil
        try await runtime.sleep(.search)

        #expect(releasedFeature == nil)
        #expect(runtime.capability(.searchWorkspace) == nil)
        #expect(try runtime.snapshot(for: .search).activity.activeResourceCount == 0)

        let second = try #require(
            (try await runtime.activateCapability(.searchWorkspace) as? SearchModuleCapability)?.feature
        )
        #expect(second !== releasedFeature)
        #expect(recorder.factoryCalls == 2)
    }

    @Test
    func replacingIndexWorkKeepsTheNewestTaskActiveUntilItFinishes() async throws {
        let operations = BlockingIndexOperations()
        defer {
            operations.finishWarmIndex()
            operations.finishInvalidation()
        }
        let feature = SearchFeatureModel(operations: operations)
        let workspaceURL = URL(fileURLWithPath: "/test-workspace")
        let visibilityRules = SearchVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: [])

        feature.warmIndex(at: workspaceURL, visibilityRules: visibilityRules)
        try #require(await operations.waitForWarmIndexStart())

        feature.invalidateIndex(at: workspaceURL, visibilityRules: visibilityRules)
        operations.finishWarmIndex()
        try #require(await operations.waitForInvalidationStart())

        #expect(feature.hasActiveModuleWork)

        operations.finishInvalidation()
        try #require(await waitUntil { !feature.hasActiveModuleWork })
        #expect(operations.completedOperations == ["warm", "invalidate"])
    }

    @Test
    func anOlderQueryCannotStopOrOverwriteTheNewerOptionsSearch() async {
        let operations = OrderedSearchOperations()
        let feature = SearchFeatureModel(operations: operations)
        let root = URL(fileURLWithPath: "/search-fixture")
        let rules = SearchVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: [])
        defer { operations.firstGate.signal(); operations.secondGate.signal(); feature.reset() }
        let first = Task {
            await feature.searchProject(at: root, query: "same", options: .default,
                visibilityRules: rules, isCurrent: { true })
        }
        #expect(await operations.firstStarted.waitUntilSignaled(timeout: .seconds(2)))
        let second = Task {
            await feature.searchProject(at: root, query: "same", options: ProjectSearchOptions(caseSensitive: true),
                visibilityRules: rules, isCurrent: { true })
        }
        #expect(await operations.secondStarted.waitUntilSignaled(timeout: .seconds(2)))
        operations.firstGate.signal()
        await first.value
        #expect(feature.isSearching)
        #expect(feature.searchResults.isEmpty)
        operations.secondGate.signal()
        await second.value
        #expect(!feature.isSearching)
        #expect(feature.searchResults.first?.preview == "new options")
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func workspaceFactory() -> ModuleFactory {
        ModuleFactory(
            manifest: ModuleManifest(
                id: .workspace, displayName: "Workspace", scope: .workspace,
                activationPolicy: .onDemand
            )
        ) { EmptyWorkspaceModule() }
    }
}

@MainActor
private final class SearchRecorder { var factoryCalls = 0 }

@MainActor
private final class EmptyWorkspaceModule: LitheModule {
    let manifest = ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

private struct TestSearchOperations: SearchOperations {
    func cancelTextPreview(operationID: String) {}
    func textPreview(_ request: ProjectTextPreviewRequest) -> Result<ProjectTextPreview, ProjectSearchFailure> {
        .success(ProjectTextPreview(files: [], status: .complete))
    }

    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { [] }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> SearchEverywhereResults? { SearchEverywhereResults() }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? { [] }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private struct ScopedSearchOperations: SearchOperations {
    func cancelTextPreview(operationID: String) {}
    func textPreview(_ request: ProjectTextPreviewRequest) -> Result<ProjectTextPreview, ProjectSearchFailure> {
        #expect(request.scope == .files(["last.go"]))
        #expect(request.purpose == .search)
        #expect(request.query == "unsaved")
        #expect(request.options.fileMask == "*.go")
        #expect(request.textOverrides == ["last.go": "unsaved buffer"])
        return .success(ProjectTextPreview(files: [ProjectReplacementFile(
            url: request.rootURL.appendingPathComponent("last.go"), relativePath: "last.go", matches: [
                ProjectReplacementMatch(line: 4, before: "unsaved buffer", after: " buffer", occurrenceCount: 1)
            ], sourceText: "unsaved buffer")], status: .complete))
    }

    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? {
        Issue.record("A restricted file scope must not filter a truncated project search")
        return []
    }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> SearchEverywhereResults? { nil }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? {
        #expect(paths == ["last.go"])
        #expect(query == "unsaved")
        #expect(options.fileMask == "*.go")
        #expect(textOverrides == ["last.go": "unsaved buffer"])
        return [ProjectReplacementFile(url: rootURL.appendingPathComponent("last.go"), relativePath: "last.go", matches: [
            ProjectReplacementMatch(line: 4, before: "unsaved buffer", after: " buffer", occurrenceCount: 1)
        ])]
    }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool {
        Issue.record("Search must never save a buffer")
        return false
    }
}

private final class BlockingIndexOperations: SearchOperations, @unchecked Sendable {
    func cancelTextPreview(operationID: String) {}
    func textPreview(_ request: ProjectTextPreviewRequest) -> Result<ProjectTextPreview, ProjectSearchFailure> {
        .success(ProjectTextPreview(files: [], status: .complete))
    }

    private let lock = NSLock()
    private let warmIndexGate = DispatchSemaphore(value: 0)
    private let invalidationGate = DispatchSemaphore(value: 0)
    private let warmIndexStarted = AsyncTestSignal()
    private let invalidationStarted = AsyncTestSignal()
    private var completions: [String] = []

    var completedOperations: [String] { withLock { completions } }

    func warmSearchIndex(at rootURL: URL, visibilityRules: SearchVisibilityRules) {
        warmIndexStarted.signal()
        _ = warmIndexGate.wait(timeout: .now() + 5)
        withLock { completions.append("warm") }
    }

    func invalidateSearchIndex(at rootURL: URL, visibilityRules: SearchVisibilityRules) {
        invalidationStarted.signal()
        _ = invalidationGate.wait(timeout: .now() + 5)
        withLock { completions.append("invalidate") }
    }

    func waitForWarmIndexStart() async -> Bool {
        await warmIndexStarted.waitUntilSignaled()
    }

    func waitForInvalidationStart() async -> Bool {
        await invalidationStarted.waitUntilSignaled()
    }

    func finishWarmIndex() {
        warmIndexGate.signal()
    }

    func finishInvalidation() {
        invalidationGate.signal()
    }

    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { [] }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> SearchEverywhereResults? { SearchEverywhereResults() }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? { [] }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class AsyncTestSignal: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func signal() {
        continuation.yield()
        continuation.finish()
    }

    func waitUntilSignaled(timeout: Duration = .seconds(5)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [stream] in
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                // test-stability: allow(swift-real-sleep) reason: this task is the bounded failure deadline for an event-driven test signal.
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

private final class OrderedSearchOperations: SearchOperations, @unchecked Sendable {
    func cancelTextPreview(operationID: String) {}
    func textPreview(_ request: ProjectTextPreviewRequest) -> Result<ProjectTextPreview, ProjectSearchFailure> {
        let results = search(at: request.rootURL, query: request.query, options: request.options,
            visibilityRules: request.visibilityRules)!
        return .success(ProjectTextPreview(files: results.map { result in
            ProjectReplacementFile(url: result.url, relativePath: "file.go", matches: [
                ProjectReplacementMatch(line: 1, before: result.preview, after: "", occurrenceCount: 1)
            ])
        }, status: .complete))
    }

    let firstGate = DispatchSemaphore(value: 0)
    let secondGate = DispatchSemaphore(value: 0)
    let firstStarted = AsyncTestSignal()
    let secondStarted = AsyncTestSignal()

    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? {
        let isSecond = options.caseSensitive
        (isSecond ? secondStarted : firstStarted).signal()
        // SearchOperations is synchronous and invoked on the search worker; the
        // local deadline prevents a failed expectation from stranding that worker.
        let completed = (isSecond ? secondGate : firstGate).wait(timeout: .now() + 4)
        guard completed == .success else { return [] }
        return [FileSearchResult(url: rootURL.appendingPathComponent("file.go"), line: 1,
            preview: isSecond ? "new options" : "old options")]
    }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> SearchEverywhereResults? { SearchEverywhereResults() }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? { [] }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private struct UnexpectedPreviewOperations: SearchOperations {
    func cancelTextPreview(operationID: String) {}
    func textPreview(_ request: ProjectTextPreviewRequest) -> Result<ProjectTextPreview, ProjectSearchFailure> {
        Issue.record("An empty explicit scope must not invoke the engine")
        return .failure(ProjectSearchFailure(code: "unexpected", message: "Unexpected engine call"))
    }
    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { nil }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> SearchEverywhereResults? { nil }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? { nil }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { Issue.record("Unexpected write"); return false }
}

private struct PreviewOutcomeOperations: SearchOperations {
    let outcome: Result<ProjectTextPreview, ProjectSearchFailure>
    func cancelTextPreview(operationID: String) {}
    func textPreview(_ request: ProjectTextPreviewRequest) -> Result<ProjectTextPreview, ProjectSearchFailure> { outcome }
    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { nil }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> SearchEverywhereResults? { nil }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? { nil }
    func readFile(at rootURL: URL, relativePath: String) -> String? { Issue.record("Incomplete preview must not read disk"); return nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { Issue.record("Incomplete preview must not write disk"); return false }
}
