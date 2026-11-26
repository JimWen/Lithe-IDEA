import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("Lightweight Mode & Zero-LSP Intelligence", .serialized)
@MainActor
struct LightweightModeAndIntelligenceTests {
    private final class InMemoryStore: KeyValueStore {
        private var values: [String: Any] = [:]
        func object(forKey defaultName: String) -> Any? { values[defaultName] }
        func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
        func stringArray(forKey defaultName: String) -> [String]? { values[defaultName] as? [String] }
        func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
        func set(_ value: Any?, forKey defaultName: String) {
            if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
        }
    }

    private struct StaticLogDir: LogDirectoryProviding {
        var defaultLogDirectory: URL { FileManager.default.temporaryDirectory }
    }

    private final class ProbeCountingCommandRunner: LanguageToolCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var invocationCount = 0

        func runLanguageToolCommand(
            operationID _: String,
            executableURL _: URL,
            arguments _: [String],
            environment _: [String: String],
            timeoutMilliseconds _: Int
        ) -> LanguageToolCommandResult {
            lock.lock()
            invocationCount += 1
            lock.unlock()
            return LanguageToolCommandResult(output: "ok", exitCode: 0)
        }
    }

    @MainActor
    private final class StubRuntimeService: LanguageToolRuntimePort {
        func executableOnPath(_ name: String) -> URL? { URL(fileURLWithPath: "/usr/bin/true") }
        func executableURL(at path: String) -> URL? { URL(fileURLWithPath: path) }
        func executableCandidates(_ command: String) -> [RuntimeToolCandidate] {
            [RuntimeToolCandidate(command: command, executableURL: URL(fileURLWithPath: "/usr/bin/true"), source: .path)]
        }
        func languageToolProcessEnvironment() -> [String: String] { [:] }
        func missingLanguageToolMessage(_ name: String) -> String { "missing \(name)" }
    }

    private final class StubToolSettings: LanguageToolSettingsStoring {
        private var map: [String: String] = [:]
        func loadLanguageToolExecutablePaths() -> [String: String] { map }
        func saveLanguageToolExecutablePaths(_ paths: [String: String]) { map = paths }
    }

    @Test
    func settingsDefaultToLightweightModeAndPersistAcrossInstances() {
        let store = InMemoryStore()
        let first = AppSettings(store: store, logDirectoryProvider: StaticLogDir())
        #expect(first.languageIntelligenceMode == .lightweight)

        first.languageIntelligenceMode = .lsp
        let second = AppSettings(store: store, logDirectoryProvider: StaticLogDir())
        #expect(second.languageIntelligenceMode == .lsp)

        second.restoreDefaults()
        #expect(second.languageIntelligenceMode == .lightweight)
    }

    @Test
    func languageIntelligenceGraphActivationSpawnsZeroDiscoveryProbesInLightweightMode() async {
        let runner = ProbeCountingCommandRunner()
        let tools = LanguageServerToolService(
            runtimeService: StubRuntimeService(),
            commandRunner: runner,
            settingsStore: StubToolSettings()
        )
        let rustDesc = LanguageProviderDescriptor(
            id: "rust",
            displayName: "Rust",
            fileExtensions: ["rs"],
            capabilities: [.languageServer],
            activationPolicy: .onDemand,
            languageServerLaunch: LanguageServerLaunchDescriptor(
                executableNames: ["rust-analyzer"],
                validationArguments: ["--version"]
            )
        )
        let manager = LanguageToolingSessionManager(catalog: LanguageProviderCatalog(descriptors: [rustDesc]))
        let graph = LanguageIntelligenceFeatureGraph(sessions: manager, tools: tools)
        let runtime = ModuleRuntime()
        let module = LanguageIntelligenceModule(makeGraph: { graph })
        try? runtime.register(ModuleFactory(manifest: module.manifest) { module })
        _ = try? await runtime.activateCapability(.languageIntelligence)

        // Zero probes must run merely because `.languageIntelligence` activated.
        #expect(runner.invocationCount == 0)

        await runtime.shutdownAll()
    }

    @Test
    func zeroLSPBuiltinEngineProvidesCrossFileGoRustPythonIntelligenceAndMultiLanguageFolding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-lightweight-swift-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root.appendingPathComponent("billing"), withIntermediateDirectories: true)
        defer {
            RustCoreBridge().invalidateSearchIndex(at: root)
            try? FileManager.default.removeItem(at: root)
        }

        let svcURL = root.appendingPathComponent("billing/service.go")
        let svcSource = """
        package billing

        // ComputeInvoice computes invoice total with tax.
        func (s *Service) ComputeInvoice(amount int, tax float64) float64 {
            return float64(amount) * tax
        }
        """
        try svcSource.write(to: svcURL, atomically: true, encoding: .utf8)

        let mainURL = root.appendingPathComponent("main.go")
        let mainSource = """
        package main

        func run(s *Service) {
            // ComputeInvoice in comment should not match references
            _ = billing.ComputeInvoice(42, 1.08)
        }
        """
        try mainSource.write(to: mainURL, atomically: true, encoding: .utf8)

        let bridge = RustCoreBridge()
        #expect(bridge.isAvailable)
        bridge.warmSearchIndex(at: root)

        let manager = LanguageToolingSessionManager(
            catalog: .compatibilityFallback,
            builtinCore: bridge,
            isLanguageServerEnabled: { _, _ in false }
        )

        let features = manager.features(for: mainURL)
        #expect(features.contains(.completion))
        #expect(features.contains(.hover))
        #expect(features.contains(.signatureHelp))
        #expect(features.contains(.definition))
        #expect(features.contains(.references))
        #expect(!features.contains(.implementation))
        #expect(!features.contains(.rename))

        // 1. Cross-file Go-to-Definition.
        let definitions = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[LanguageServerLocation], Error>) in
            do {
                try manager.navigate(
                    method: "textDocument/definition",
                    fileURL: mainURL,
                    text: mainSource,
                    position: LanguageServerPosition(line: 4, utf16Column: 18),
                    rootURL: root
                ) { continuation.resume(with: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(definitions.first?.url.lastPathComponent == "service.go")
        #expect(definitions.first?.range.start.line == 3)

        // 2. Cross-file References (excluding comment occurrence).
        let references = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[LanguageServerLocation], Error>) in
            do {
                try manager.navigate(
                    method: "textDocument/references",
                    fileURL: mainURL,
                    text: mainSource,
                    position: LanguageServerPosition(line: 4, utf16Column: 18),
                    rootURL: root
                ) { continuation.resume(with: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(references.count == 2)

        // 3. Rich Markdown Hover with doc comment.
        let hover = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LanguageServerHover?, Error>) in
            do {
                try manager.hover(
                    fileURL: mainURL,
                    text: mainSource,
                    position: LanguageServerPosition(line: 4, utf16Column: 18),
                    rootURL: root
                ) { continuation.resume(with: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(hover?.contents.contains("ComputeInvoice(amount int, tax float64)") == true)
        #expect(hover?.contents.contains("ComputeInvoice computes invoice total with tax.") == true)

        // 4. Cross-file Signature Help (second argument after comma).
        let sig = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LanguageServerSignatureHelp?, Error>) in
            do {
                try manager.signatureHelp(
                    fileURL: mainURL,
                    text: mainSource,
                    position: LanguageServerPosition(line: 4, utf16Column: 36),
                    rootURL: root
                ) { continuation.resume(with: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(sig?.effectiveActiveParameter == 1)
        #expect(sig?.currentSignature?.parameters.count == 2)

        // 5. Completions include workspace symbol + Go snippet (`iferr`) + Go builtin type (`string`).
        let completions = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[LanguageServerCompletionItem], Error>) in
            do {
                try manager.completions(
                    fileURL: mainURL,
                    text: "package main\nfunc f() { Comp }\n",
                    position: LanguageServerPosition(line: 1, utf16Column: 15),
                    rootURL: root
                ) { continuation.resume(with: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(completions.contains { $0.label == "ComputeInvoice" })

        let snippetCompletions = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[LanguageServerCompletionItem], Error>) in
            do {
                try manager.completions(
                    fileURL: mainURL,
                    text: "package main\nfunc f() { ifer }\n",
                    position: LanguageServerPosition(line: 1, utf16Column: 15),
                    rootURL: root
                ) { continuation.resume(with: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(snippetCompletions.contains { $0.label == "iferr" && $0.isSnippet })

        // 6. Multi-language folding works for Go, Rust, and Python.
        let goFolds = bridge.editorFoldRegions(path: "main.go", source: svcSource)
        #expect(goFolds.contains { $0.kind == .method && $0.startLine == 3 && $0.endLine == 5 })

        let pyFolds = bridge.editorFoldRegions(
            path: "app.py",
            source: "def calc(x):\n    if x > 0:\n        return x\n    return 0\n"
        )
        #expect(pyFolds.contains { $0.kind == .method && $0.startLine == 0 && $0.endLine == 3 })
        #expect(pyFolds.contains { $0.kind == .block && $0.startLine == 1 && $0.endLine == 2 })

        let rsFolds = bridge.editorFoldRegions(
            path: "lib.rs",
            source: "pub struct S<'a> {\n    x: &'a str,\n}\n"
        )
        #expect(rsFolds.contains { $0.kind == .type && $0.startLine == 0 && $0.endLine == 2 })

        // Zero external LSP processes were started!
        #expect(manager.activeLanguageServerIDs.isEmpty)
    }

    @Test
    func appModelEscalatesPrecisionActionsAndTogglesModeCleanly() async throws {
        let store = InMemoryStore()
        let settings = AppSettings(store: store, logDirectoryProvider: StaticLogDir())
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        container.moduleLifecycleCoordinator.stop()
        let model = AppModel(settings: settings, services: container.services)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-appmodel-lw-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let goFile = root.appendingPathComponent("main.go")
        try "package main\nfunc main() {}\n".write(to: goFile, atomically: true, encoding: .utf8)
        defer {
            RustCoreBridge().invalidateSearchIndex(at: root)
            try? FileManager.default.removeItem(at: root)
        }

        model.openProjectDirectly(root)
        await model.awaitModuleRuntimeShutdown()
        await model.documentFeature.openFileAsync(goFile, isReadOnly: false, displayPath: nil, activateWhenReady: true)

        #expect(model.isLightweightIntelligenceMode)
        #expect(model.languageToolingSessionsIfActive?.activeLanguageServerIDs.isEmpty ?? true)

        // Triggering Rename in Lightweight Mode offers one-click Precision LSP escalation.
        model.clearNotifications()
        model.triggerRenameSymbol()
        #expect(model.notifications.first?.action == .enablePrecisionLSP)

        // Triggering Go to Implementation in Lightweight Mode also offers escalation.
        model.clearNotifications()
        model.goToImplementation()
        #expect(model.notifications.first?.action == .enablePrecisionLSP)

        // Toggle command exists and flips session mode cleanly.
        let toggleAction = LitheActionRegistry.actions(for: model).first { $0.id == "toggle-language-intelligence-mode" }
        #expect(toggleAction != nil)
        toggleAction?.perform()
        #expect(!model.isLightweightIntelligenceMode)
        #expect(model.sessionLanguageIntelligenceModeOverride == .lsp)

        // Switching back to Lightweight stops LSP servers and clears session override back to global default.
        toggleAction?.perform()
        #expect(model.isLightweightIntelligenceMode)
        #expect(model.sessionLanguageIntelligenceModeOverride == nil)
        #expect(model.languageToolingSessionsIfActive?.activeLanguageServerIDs.isEmpty ?? true)

        await model.services.moduleRuntime.shutdownAll()
    }

    @Test
    func globalModeChangePropagatesAcrossMultipleProjectWindows() async throws {
        let store = InMemoryStore()
        let settings = AppSettings(store: store, logDirectoryProvider: StaticLogDir())
        settings.languageIntelligenceMode = .lsp

        let containerA = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        containerA.moduleLifecycleCoordinator.stop()
        let modelA = AppModel(settings: settings, services: containerA.services)

        let containerB = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        containerB.moduleLifecycleCoordinator.stop()
        let modelB = AppModel(settings: settings, services: containerB.services)

        let containerC = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        containerC.moduleLifecycleCoordinator.stop()
        let modelC = AppModel(settings: settings, services: containerC.services)
        // Window C has an explicit per-window override to stay in Lightweight even while global is .lsp.
        modelC.setSessionLanguageIntelligenceMode(.lightweight)

        #expect(modelA.appliedLanguageIntelligenceMode == .lsp)
        #expect(modelB.appliedLanguageIntelligenceMode == .lsp)
        #expect(modelC.appliedLanguageIntelligenceMode == .lightweight)

        // Switching the global default from Window A propagates to Window B too.
        modelA.applyGlobalLanguageIntelligenceMode(.lightweight)
        #expect(modelA.appliedLanguageIntelligenceMode == .lightweight)
        #expect(modelB.appliedLanguageIntelligenceMode == .lightweight)
        #expect(modelB.isLightweightIntelligenceMode)

        // Switching global back to .lsp updates both Window A and Window B, while Window C retains its override.
        modelA.applyGlobalLanguageIntelligenceMode(.lsp)
        #expect(modelA.appliedLanguageIntelligenceMode == .lsp)
        #expect(modelB.appliedLanguageIntelligenceMode == .lsp)
        #expect(modelC.effectiveLanguageIntelligenceMode == .lightweight)

        await modelA.services.moduleRuntime.shutdownAll()
        await modelB.services.moduleRuntime.shutdownAll()
        await modelC.services.moduleRuntime.shutdownAll()
    }

    @Test
    func rustTestArtifactSelectionResolvesOwningTargetForNestedSourceFile() {
        let cargoJSON = """
        {"reason":"compiler-artifact","target":{"kind":["lib"],"name":"demo","src_path":"/repo/src/lib.rs"},"profile":{"test":true},"executable":"/repo/target/debug/deps/demo-lib"}
        {"reason":"compiler-artifact","target":{"kind":["bin"],"name":"demo","src_path":"/repo/src/main.rs"},"profile":{"test":true},"executable":"/repo/target/debug/deps/demo-bin"}
        """
        let files: [String: String] = [
            "/repo/src/lib.rs": "pub mod math;\n",
            "/repo/src/main.rs": "mod cli;\nfn main() {}\n",
        ]

        let libMatch = RustDebugBuildService.parseBuiltTestExecutablePath(
            from: cargoJSON,
            sourcePath: "/repo/src/math.rs",
            expectedTargetName: nil,
            readFile: { files[$0] }
        )
        #expect(libMatch == "/repo/target/debug/deps/demo-lib")

        let binMatch = RustDebugBuildService.parseBuiltTestExecutablePath(
            from: cargoJSON,
            sourcePath: "/repo/src/cli.rs",
            expectedTargetName: nil,
            readFile: { files[$0] }
        )
        #expect(binMatch == "/repo/target/debug/deps/demo-bin")
    }

    @Test
    func standaloneFileAcceptsUnversionedLocalCompletionWithoutWorkspace() async throws {
        let store = InMemoryStore()
        let settings = AppSettings(store: store, logDirectoryProvider: StaticLogDir())
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        container.moduleLifecycleCoordinator.stop()
        let model = AppModel(settings: settings, services: container.services)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-standalone-comp-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("solo.go")
        try "package main\nfunc helper() {}\nfunc main() { hel }\n".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        model.openStandaloneFile(fileURL)
        let didOpen = await awaitChange(on: model.documentFeature) {
            model.activeDocument?.url.standardizedFileURL == fileURL
        }
        #expect(didOpen)
        let opened = try #require(model.activeDocument)
        #expect(opened.url.standardizedFileURL == fileURL)
        #expect(model.workspaceURL == nil)

        // Simulate accepting an unversioned refined local completion item (requestContextID == nil).
        let item = LanguageServerCompletionItem(
            label: "helper",
            detail: "Current file symbol",
            documentation: nil,
            insertText: "helper",
            sortText: nil,
            filterText: nil,
            kind: 3,
            textEdit: nil,
            additionalTextEdits: [],
            data: nil
        )
        let fallbackRange = LanguageServerRange(
            start: LanguageServerPosition(line: 2, utf16Column: 14),
            end: LanguageServerPosition(line: 2, utf16Column: 17)
        )
        model.applyLanguageCompletion(item, fallbackRange: fallbackRange)
        #expect(opened.text.contains("func main() { helper }"))

        await model.services.moduleRuntime.shutdownAll()
    }

    @Test
    func globalModeTransitionFromLightweightToLSPAvailableDuringWillSetAndActivatesOpenDocuments() async throws {
        let store = InMemoryStore()
        let settings = AppSettings(store: store, logDirectoryProvider: StaticLogDir())
        #expect(settings.languageIntelligenceMode == .lightweight)

        let containerA = MacServiceContainer(store: store, settings: settings)
        containerA.moduleLifecycleCoordinator.stop()
        let modelA = AppModel(settings: settings, services: containerA.services)

        let containerB = MacServiceContainer(store: store, settings: settings)
        containerB.moduleLifecycleCoordinator.stop()
        let modelB = AppModel(settings: settings, services: containerB.services)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-global-lsp-willset-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let goFile = root.appendingPathComponent("main.go")
        try "package main\nfunc main() {}\n".write(to: goFile, atomically: true, encoding: .utf8)
        defer {
            RustCoreBridge().invalidateSearchIndex(at: root)
            try? FileManager.default.removeItem(at: root)
        }

        modelB.openProjectDirectly(root)
        await modelB.awaitModuleRuntimeShutdown()
        await modelB.documentFeature.openFileAsync(goFile, isReadOnly: false, displayPath: nil, activateWhenReady: true)
        modelB.ensureLightweightLanguageIntelligenceActive()
        let sessionsReady = await awaitChange(on: modelB.languageToolingFeature) {
            modelB.languageToolingSessionsIfActive != nil
        }
        #expect(sessionsReady || modelB.languageToolingSessionsIfActive != nil)
        let sessionsB = try #require(modelB.languageToolingSessionsIfActive)
        // Disable `go` in Window B so entering `activateLanguageServerIfAvailable` records a
        // deterministic log entry without spawning an external `gopls` process.
        modelB.disableLanguageServerForCurrentWorkspace(providerID: "go")
        #expect(modelB.effectiveLanguageIntelligenceMode == .lightweight)

        // Switching global preference from Lightweight -> Precision LSP on Window A must make
        // `effectiveLanguageIntelligenceMode == .lsp` immediately during Combine's `willSet`
        // callback so Window B's open document actually enters LSP activation.
        modelA.applyGlobalLanguageIntelligenceMode(.lsp)
        #expect(modelB.effectiveLanguageIntelligenceMode == .lsp)
        #expect(modelB.appliedLanguageIntelligenceMode == .lsp)
        let goLogs = sessionsB.languageServerLogs.filter { $0.providerID == "go" }
        #expect(goLogs.contains { $0.message == "Language server activation skipped" })

        // Switching back immediately returns to Lightweight cleanly.
        modelA.applyGlobalLanguageIntelligenceMode(.lightweight)
        #expect(modelB.effectiveLanguageIntelligenceMode == .lightweight)
        #expect(modelB.languageToolingSessionsIfActive?.activeLanguageServerIDs.isEmpty ?? true)

        await modelA.services.moduleRuntime.shutdownAll()
        await modelB.services.moduleRuntime.shutdownAll()
    }

    @Test
    func gutterRunTestSavesDirtyDocumentBeforeLaunching() async throws {
        let store = InMemoryStore()
        let settings = AppSettings(store: store, logDirectoryProvider: StaticLogDir())
        let container = MacServiceContainer(store: store, settings: settings)
        container.moduleLifecycleCoordinator.stop()
        let model = AppModel(settings: settings, services: container.services)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-gutter-save-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let testFile = root.appendingPathComponent("calc_test.go")
        let initialText = "package main\nimport \"testing\"\nfunc TestAdd(t *testing.T) {}\n"
        try initialText.write(to: testFile, atomically: true, encoding: .utf8)
        defer {
            RustCoreBridge().invalidateSearchIndex(at: root)
            try? FileManager.default.removeItem(at: root)
        }

        model.openProjectDirectly(root)
        await model.awaitModuleRuntimeShutdown()
        await model.documentFeature.openFileAsync(testFile, isReadOnly: false, displayPath: nil, activateWhenReady: true)
        let document = try #require(model.activeDocument)

        let updatedText = "package main\nimport \"testing\"\nfunc TestAdd(t *testing.T) { _ = 42 }\n"
        document.applyLiveEditorText(updatedText)
        #expect(document.isDirty)

        let runnable = DocumentRunnable(
            id: "go-test:TestAdd",
            configurationID: nil,
            displayName: "TestAdd",
            kind: .test,
            line: 3,
            symbolRange: LanguageServerRange(
                start: LanguageServerPosition(line: 2, utf16Column: 5),
                end: LanguageServerPosition(line: 2, utf16Column: 12)
            )
        )
        model.runDocumentRunnable(runnable, in: testFile, debug: false)

        let didSave = await awaitChange(on: document) { !document.isDirty }
        #expect(didSave)
        let savedOnDisk = try String(contentsOf: testFile, encoding: .utf8)
        #expect(savedOnDisk == updatedText)

        model.languageTestServiceIfActive?.stop()
        await model.services.moduleRuntime.shutdownAll()
    }

    @Test
    func rustDebugBuildServiceResolvesCargoDirectoryTargetsAndSkipsSharedHelpers() {
        let root = "/repo"
        let existing: Set<String> = [
            "/repo/src/bin/tool/main.rs",
            "/repo/tests/suite/main.rs",
        ]
        let fileExists: (String) -> Bool = { existing.contains($0) }

        let dirBin = RustDebugBuildService.resolveCargoTestTarget(
            relativePath: "src/bin/tool/main.rs",
            workspaceRootPath: root,
            fileExists: fileExists
        )
        #expect(dirBin?.flag == "--bin" && dirBin?.name == "tool")

        let dirBinHelper = RustDebugBuildService.resolveCargoTestTarget(
            relativePath: "src/bin/tool/helper.rs",
            workspaceRootPath: root,
            fileExists: fileExists
        )
        #expect(dirBinHelper?.flag == "--bin" && dirBinHelper?.name == "tool")

        let dirTest = RustDebugBuildService.resolveCargoTestTarget(
            relativePath: "tests/suite/main.rs",
            workspaceRootPath: root,
            fileExists: fileExists
        )
        #expect(dirTest?.flag == "--test" && dirTest?.name == "suite")

        let dirTestHelper = RustDebugBuildService.resolveCargoTestTarget(
            relativePath: "tests/suite/sub.rs",
            workspaceRootPath: root,
            fileExists: fileExists
        )
        #expect(dirTestHelper?.flag == "--test" && dirTestHelper?.name == "suite")

        let sharedHelper = RustDebugBuildService.resolveCargoTestTarget(
            relativePath: "tests/common/mod.rs",
            workspaceRootPath: root,
            fileExists: fileExists
        )
        #expect(sharedHelper == nil)

        // Regression for P2: unit-test module under `src/tests/...` is NOT an integration target.
        let srcTestsModule = RustDebugBuildService.resolveCargoTestTarget(
            relativePath: "src/tests/arithmetic.rs",
            workspaceRootPath: root,
            fileExists: fileExists
        )
        #expect(srcTestsModule == nil)

        // Nested Cargo workspace member resolves relative to its own `Cargo.toml`.
        let nestedExisting: Set<String> = [
            "/repo/crates/sub/Cargo.toml",
            "/repo/crates/sub/tests/suite/main.rs",
        ]
        let nestedTest = RustDebugBuildService.resolveCargoTestTarget(
            relativePath: "crates/sub/tests/suite/main.rs",
            workspaceRootPath: root,
            fileExists: { nestedExisting.contains($0) }
        )
        #expect(nestedTest?.flag == "--test" && nestedTest?.name == "suite")
    }

    @Test
    func nestedCollapsedRangesMergeForExactBinaryLookup() {
        let merged = CodeTextView.mergeCollapsedRanges([
            NSRange(location: 0, length: 1000),
            NSRange(location: 10, length: 10),
            NSRange(location: 30, length: 10),
            NSRange(location: 1200, length: 50),
        ])
        #expect(merged == [
            NSRange(location: 0, length: 1000),
            NSRange(location: 1200, length: 50),
        ])
        #expect(CodeTextView.containsLocation(500, inMergedRanges: merged))
        #expect(CodeTextView.containsLocation(999, inMergedRanges: merged))
        #expect(!CodeTextView.containsLocation(1000, inMergedRanges: merged))
        #expect(CodeTextView.containsLocation(1225, inMergedRanges: merged))
    }
}
