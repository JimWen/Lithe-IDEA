import AppKit
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import Testing
@testable import Lithe

@Suite("P1-B completion engine, snippets, and format-on-save")
struct CompletionAndFormatOnSaveP1BTests {
    @Test
    func snippetExpansionResolvesPlaceholdersChoicesEscapesAndPrimaryCaret() {
        let placeholder = LanguageServerSnippet.expand("fmt.Printf(${1:\"hello\"}, ${2:arg})$0")
        #expect(placeholder.text == "fmt.Printf(\"hello\", arg)")
        // Primary tabstop $1 selects `"hello"` so typing replaces it immediately.
        #expect(placeholder.selectionUTF16Range == NSRange(location: 11, length: 7))

        let choice = LanguageServerSnippet.expand("mode = ${1|debug,release|}")
        #expect(choice.text == "mode = debug")
        #expect(choice.selectionUTF16Range == NSRange(location: 7, length: 5))

        let finalStopOnly = LanguageServerSnippet.expand("func name($0) {}")
        #expect(finalStopOnly.text == "func name() {}")
        #expect(finalStopOnly.selectionUTF16Range == NSRange(location: 10, length: 0))

        let escaped = LanguageServerSnippet.expand(#"price := \$100 + ${1:tax}"#)
        #expect(escaped.text == "price := $100 + tax")
        #expect(escaped.selectionUTF16Range == NSRange(location: 16, length: 3))

        // Regression for P2: escaped `$` / `\` inside placeholder defaults must survive recursive expansion.
        let escapedInPlaceholder = LanguageServerSnippet.expand(#"${1:\$100}"#)
        #expect(escapedInPlaceholder.text == "$100")
        #expect(escapedInPlaceholder.selectionUTF16Range == NSRange(location: 0, length: 4))

        let nestedEscaped = LanguageServerSnippet.expand(#"${1:price ${2:\$100}}"#)
        #expect(nestedEscaped.text == "price $100")
        #expect(nestedEscaped.selectionUTF16Range == NSRange(location: 0, length: 10))

        let escapedBackslashBeforeTabstop = LanguageServerSnippet.expand(#"${1:\\$2}"#)
        #expect(escapedBackslashBeforeTabstop.text == "\\")
    }

    @Test
    func completionPopupModelRanksPrefixPreselectAndPreservesSelectionAcrossUpdates() {
        var model = CompletionPopupModel()
        let items = [
            makeCompletion(label: "formatPrint", sortText: "1"),
            makeCompletion(label: "Println", detail: "func(a ...any)", sortText: "2"),
            makeCompletion(label: "Print", detail: "func(a ...any)", sortText: "3", preselect: true),
            makeCompletion(label: "printfHelper", sortText: "4"),
        ]
        model.update(items: items, query: "Pri")
        #expect(model.filteredItems.map(\.label) == ["Print", "Println", "printfHelper", "formatPrint"])
        #expect(model.selectedItem?.label == "Print")

        model.moveSelection(delta: 1)
        #expect(model.selectedItem?.label == "Println")

        // Incremental refinement keeps `Println` selected!
        model.updateQuery("Print")
        #expect(model.selectedItem?.label == "Println")

        // Wrap around up/down navigation.
        model.moveSelection(delta: -1)
        #expect(model.selectedItem?.label == "Print")
        model.moveSelection(delta: -1)
        #expect(model.selectedItem?.label == "formatPrint")

        // Storing a resolved item whose `detail` changes `resolved.id` must preserve `selectedBaseItemID`.
        let originalBaseID = model.selectedBaseItemID
        let resolvedChangedDetail = LanguageServerCompletionItem(
            label: "formatPrint",
            detail: "func formatPrint(v any) string",
            documentation: "Resolved docs",
            insertText: "formatPrint",
            sortText: "1",
            filterText: nil,
            kind: 3,
            textEdit: nil,
            additionalTextEdits: [],
            data: nil
        )
        let stored = model.storeResolved(resolvedChangedDetail, for: originalBaseID ?? "")
        #expect(stored)
        #expect(model.selectedBaseItemID == originalBaseID)
        #expect(model.selectedItem?.documentation == "Resolved docs")
        #expect(model.selectedItem?.id != originalBaseID)
    }

    @Test
    func completionPopupModelScopesResolvedItemsToBatchGeneration() {
        var model = CompletionPopupModel()
        let firstBatchItem = makeCompletion(label: "Println", detail: "batch-1")
        model.update(items: [firstBatchItem], query: "Pri")
        let gen1 = model.batchGeneration

        let resolvedBatch1 = LanguageServerCompletionItem(
            label: "Println",
            detail: "batch-1-resolved",
            documentation: "Old docs",
            insertText: "Println()",
            sortText: nil,
            filterText: nil,
            kind: 3,
            textEdit: nil,
            additionalTextEdits: [],
            data: nil
        )
        let storedBatch1 = model.storeResolved(resolvedBatch1, for: firstBatchItem.id, generation: gen1)
        #expect(storedBatch1)
        #expect(model.selectedItem?.documentation == "Old docs")

        // A new completion batch must clear old resolved snapshots and reject stale callbacks.
        let secondBatchItem = makeCompletion(label: "Println", detail: "batch-1")
        model.update(items: [secondBatchItem], query: "Prin")
        let gen2 = model.batchGeneration
        #expect(gen2 != gen1)
        #expect(model.selectedItem?.documentation == nil)
        let storedStale = model.storeResolved(resolvedBatch1, for: secondBatchItem.id, generation: gen1)
        #expect(!storedStale)
        #expect(model.selectedItem?.documentation == nil)
    }

    @Test
    @MainActor
    func sharedSaveWorkflowRunsBeforeSaveHookEvenWhenActiveTabChangesAndDuringSaveAll() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-format-on-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileA = root.appendingPathComponent("a.go")
        let fileB = root.appendingPathComponent("b.go")
        try "package main\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "package main\n".write(to: fileB, atomically: true, encoding: .utf8)

        let services = MacServiceContainer(store: FormatSaveTestStore(), settings: AppSettings(store: FormatSaveTestStore()), moduleLaunchMode: .safeMode).services
        let feature = DocumentFeatureModel(
            operations: services.workspaceOperations,
            documentLifecycleDecider: services.documentLifecycleDecider,
            fileOperations: services.fileOperations,
            fileStorage: services.fileStorage,
            binaryFileViewerRegistry: services.binaryFileViewerRegistry
        )

        let hookStarted = TestGate()
        let releaseHook = TestGate()
        defer { releaseHook.open() }
        var formattedPaths: [String] = []
        feature.configure(
            workspaceURLProvider: { root },
            autoSaveEnabledProvider: { false },
            autoSaveDelayProvider: { 0 },
            notify: { _ in },
            onDocumentOpened: { _ in },
            onDocumentChanged: { _ in },
            onDocumentClosed: { _ in },
            onRecordSave: { _, _ in },
            onRecordDiscard: { _ in },
            onRecordExternalChanges: { _ in },
            onDocumentCollectionChanged: {},
            onProjectCloseReady: {},
            beforeSaveDocument: { document in
                formattedPaths.append(document.url.lastPathComponent)
                if document.url.lastPathComponent == "a.go" {
                    hookStarted.open()
                    _ = await releaseHook.waitUntilOpen()
                }
                document.applyLiveEditorText(document.text + "// formatted\n")
            }
        )

        await feature.openFileAsync(fileA, isReadOnly: false, displayPath: nil, activateWhenReady: true)
        await feature.openFileAsync(fileB, isReadOnly: false, displayPath: nil, activateWhenReady: false)
        let docA = try #require(feature.openDocuments.first(where: { $0.url.lastPathComponent == "a.go" }))
        let docB = try #require(feature.openDocuments.first(where: { $0.url.lastPathComponent == "b.go" }))

        // 1. Trigger Save on A, switch active tab to B while formatting is pending,
        // and verify A is still formatted and saved to disk!
        docA.applyLiveEditorText("package main\nfunc a(){}\n")
        let saveTask = try #require(feature.saveActiveDocument())
        #expect(await hookStarted.waitUntilOpen())
        feature.activeDocumentID = docB.id
        releaseHook.open()
        await saveTask.value

        #expect(!docA.isDirty)
        #expect(try String(contentsOf: fileA, encoding: .utf8).contains("// formatted"))

        // 2. Save All also runs beforeSaveDocument consistently.
        docB.applyLiveEditorText("package main\nfunc b(){}\n")
        let savedAll = await feature.saveAllDocuments()
        #expect(savedAll)
        #expect(!docB.isDirty)
        #expect(try String(contentsOf: fileB, encoding: .utf8).contains("// formatted"))
        #expect(formattedPaths == ["a.go", "b.go"])
    }

    @Test
    @MainActor
    func sessionManagerCompletionRoutingFallsBackOnRecoverableErrorAndPreservesOverloads() async throws {
        let overloadA = LanguageServerCompletionItem(
            label: "New",
            detail: "pkg/a",
            documentation: nil,
            insertText: "New()",
            sortText: "1",
            filterText: nil,
            kind: 3,
            textEdit: nil,
            additionalTextEdits: [],
            data: nil
        )
        let overloadB = LanguageServerCompletionItem(
            label: "New",
            detail: "pkg/b",
            documentation: nil,
            insertText: "New(ctx)",
            sortText: "2",
            filterText: nil,
            kind: 3,
            textEdit: nil,
            additionalTextEdits: [],
            data: nil
        )
        let fallbackItem = LanguageServerCompletionItem(
            label: "NewLocal",
            detail: "local",
            documentation: nil,
            insertText: "NewLocal",
            sortText: nil,
            filterText: nil,
            kind: 6,
            textEdit: nil,
            additionalTextEdits: [],
            data: nil
        )

        // 1. Recoverable error from higher-priority provider falls back cleanly to lower provider.
        let failingProvider = StubCompletionProvider(
            priority: 200,
            result: .failure(StubError.timeout)
        )
        let workingFallback = StubCompletionProvider(
            priority: 100,
            result: .success([fallbackItem])
        )
        let fallbackManager = LanguageToolingSessionManager(
            languageFeatureProviders: [failingProvider, workingFallback]
        )
        let fallbackItems = try await requestCompletions(from: fallbackManager)
        #expect(fallbackItems.contains(where: { $0.label == "NewLocal" }))

        // 2. CancellationError terminates immediately without falling back.
        let cancellingProvider = StubCompletionProvider(
            priority: 200,
            result: .failure(CancellationError())
        )
        let cancelledManager = LanguageToolingSessionManager(
            languageFeatureProviders: [cancellingProvider, workingFallback]
        )
        do {
            _ = try await requestCompletions(from: cancelledManager)
            Issue.record("Expected CancellationError to propagate without fallback")
        } catch is CancellationError {
            // Expected.
        }

        // 3. Same-label overloads with different detail/insertText are both preserved!
        let overloadProvider = StubCompletionProvider(
            priority: 200,
            result: .success([overloadA, overloadB])
        )
        let overloadManager = LanguageToolingSessionManager(
            languageFeatureProviders: [overloadProvider]
        )
        let overloads = try await requestCompletions(from: overloadManager)
        #expect(overloads.filter { $0.label == "New" }.count == 2)
    }

    private func makeCompletion(
        label: String,
        detail: String? = nil,
        sortText: String? = nil,
        preselect: Bool = false
    ) -> LanguageServerCompletionItem {
        LanguageServerCompletionItem(
            label: label,
            detail: detail,
            documentation: nil,
            insertText: label,
            sortText: sortText,
            filterText: nil,
            kind: 3,
            textEdit: nil,
            additionalTextEdits: [],
            data: nil,
            insertTextFormat: 1,
            preselect: preselect
        )
    }

    @MainActor
    private func requestCompletions(
        from manager: LanguageToolingSessionManager
    ) async throws -> [LanguageServerCompletionItem] {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try manager.completions(
                    fileURL: URL(fileURLWithPath: "/tmp/demo/main.go"),
                    text: "package main\nfunc main() { N }\n",
                    position: .init(line: 1, utf16Column: 15),
                    rootURL: URL(fileURLWithPath: "/tmp/demo", isDirectory: true)
                ) { result in
                    continuation.resume(with: result)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private enum StubError: Error {
    case timeout
}

private final class FormatSaveTestStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func set(_ value: Any?, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value }
}

@MainActor
private final class StubCompletionProvider: LanguageFeatureProvider {
    let id: String
    let priority: LanguageFeatureProviderPriority
    let result: Result<[LanguageServerCompletionItem], Error>

    init(
        id: String = UUID().uuidString,
        priority: Int,
        result: Result<[LanguageServerCompletionItem], Error>
    ) {
        self.id = id
        self.priority = LanguageFeatureProviderPriority(rawValue: priority)
        self.result = result
    }

    func supports(_ feature: LanguageFeature, in _: LanguageFeatureRequestContext) -> Bool {
        feature == .completion
    }

    func completions(
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        completion(result)
    }

    func hover(
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        completion(.success(nil))
    }

    func navigate(
        method _: String,
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        completion(.success([]))
    }
}
