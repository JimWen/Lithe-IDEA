import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("AI Agent Host Integration")
@MainActor
struct AIAgentIntegrationTests {
    @Test
    func aiAgentSettingsPersistAndRestoreDefaults() {
        let store = AIAgentTestKeyValueStore()
        let settings = AppSettings(store: store)
        #expect(settings.aiAgent == .default)

        settings.aiAgent.defaultBackend = .claudeCLI
        settings.aiAgent.defaultPermissionMode = .autoEdit
        settings.aiAgent.defaultReasoningEffort = .high
        settings.aiAgent.preferIsolatedWorktree = true

        let reloaded = AppSettings(store: store)
        #expect(reloaded.aiAgent.defaultBackend == .claudeCLI)
        #expect(reloaded.aiAgent.defaultPermissionMode == .autoEdit)
        #expect(reloaded.aiAgent.defaultReasoningEffort == .high)
        #expect(reloaded.aiAgent.preferIsolatedWorktree == true)

        reloaded.restoreDefaults()
        #expect(AppSettings(store: store).aiAgent == .default)
    }

    @Test
    func workbenchLayoutStorePersistsAndClampsRightSidebarWidth() {
        let store = AIAgentTestKeyValueStore()
        let layoutStore = WorkbenchLayoutStore(store: store)
        let workspaceURL = URL(fileURLWithPath: "/tmp/lithe-layout-test", isDirectory: true)

        layoutStore.save(
            WorkbenchLayout(sidebarWidth: 300, topPaneHeight: 280, rightSidebarWidth: 510),
            for: workspaceURL
        )
        let loaded = layoutStore.load(for: workspaceURL)
        #expect(loaded.sidebarWidth == 300)
        #expect(loaded.topPaneHeight == 280)
        #expect(loaded.rightSidebarWidth == 510)

        layoutStore.save(
            WorkbenchLayout(sidebarWidth: 300, topPaneHeight: nil, rightSidebarWidth: 9999),
            for: workspaceURL
        )
        #expect(layoutStore.load(for: workspaceURL).rightSidebarWidth == 760)
    }

    @Test
    func workspaceBridgeBlocksPathTraversalOutsideRoot() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-agent-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AIAgentTestKeyValueStore()
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: MacRuntimeLocator(),
            store: store,
            toolDiscovery: MacRuntimeToolDiscovery(),
            fileStorage: MacFileStorage()
        )
        let bridge = MacAIAgentWorkspaceBridge(
            callbacks: AIAgentHostCallbacks(
                workspacePath: { tempDir.path },
                agentSettings: { .default },
                commitMessageAISettings: { .default },
                readOpenDocumentText: { _ in nil },
                applyWorkspaceTextEdit: { relPath, expectedSource, replacement, rootURL in
                    let fileURL = rootURL.appendingPathComponent(relPath)
                    let current = try String(contentsOf: fileURL, encoding: .utf8)
                    guard current == expectedSource else { return false }
                    try replacement.write(to: fileURL, atomically: true, encoding: .utf8)
                    return true
                },
                openFile: { _ in },
                openDiffForRelativePath: { _, _ in },
                refreshWorkspaceAndGit: {},
                notify: { _ in }
            ),
            processRunner: MacProcessRunner(),
            runtimeService: runtimeService,
            fileStorage: MacFileStorage()
        )

        try await bridge.writeFile(relativePath: "nested/note.txt", content: "hello", rootPath: tempDir.path)
        let readBack = try await bridge.readFile(relativePath: "nested/note.txt", rootPath: tempDir.path)
        #expect(readBack == "hello")

        // Stale expectedSourceText is rejected by the document transaction callback.
        await #expect(throws: AIAgentWorkspaceHostError.self) {
            try await bridge.writeFile(
                relativePath: "nested/note.txt",
                content: "clobber",
                expectedSourceText: "stale",
                rootPath: tempDir.path
            )
        }

        await #expect(throws: AIAgentWorkspaceHostError.self) {
            _ = try await bridge.readFile(relativePath: "../../etc/passwd", rootPath: tempDir.path)
        }
        await #expect(throws: AIAgentWorkspaceHostError.self) {
            try await bridge.writeFile(relativePath: "../escape.txt", content: "nope", rootPath: tempDir.path)
        }
    }

    @Test
    func unifiedDiffSplitterPreservesFilenamesWithSpaces() {
        let patch = """
        diff --git a/folder with spaces/spaced name.txt b/folder with spaces/spaced name.txt
        index 1111111..2222222 100644
        --- a/folder with spaces/spaced name.txt
        +++ b/folder with spaces/spaced name.txt
        @@ -1 +1 @@
        -old
        +new
        """
        let map = MacAIAgentWorkspaceBridge.splitUnifiedDiffByFile(patch)
        #expect(map["folder with spaces/spaced name.txt"]?.contains("+new") == true)
    }

    @Test
    func unbornHeadGitRepoReportsUntrackedAndStagedChanges() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-agent-unborn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runner = MacProcessRunner()
        let initResult = runner.run(ProcessRequest(
            executablePath: "/usr/bin/git",
            arguments: ["init"],
            workingDirectory: tempDir.path,
            timeoutMilliseconds: 5000
        ))
        #expect(initResult.succeeded)
        try "hello".write(to: tempDir.appendingPathComponent("first file.txt"), atomically: true, encoding: .utf8)

        let store = AIAgentTestKeyValueStore()
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: MacRuntimeLocator(),
            store: store,
            toolDiscovery: MacRuntimeToolDiscovery(),
            fileStorage: MacFileStorage()
        )
        let bridge = MacAIAgentWorkspaceBridge(
            callbacks: AIAgentHostCallbacks(
                workspacePath: { tempDir.path },
                agentSettings: { .default },
                commitMessageAISettings: { .default },
                readOpenDocumentText: { _ in nil },
                applyWorkspaceTextEdit: { _, _, _, _ in false },
                openFile: { _ in },
                openDiffForRelativePath: { _, _ in },
                refreshWorkspaceAndGit: {},
                notify: { _ in }
            ),
            processRunner: runner,
            runtimeService: runtimeService,
            fileStorage: MacFileStorage()
        )

        let diff = await bridge.workingTreeDiff(in: tempDir.path)
        #expect(!diff.branchName.isEmpty)
        #expect(diff.headHash == nil)
        #expect(diff.files.contains { $0.path == "first file.txt" && $0.kind == .added })
    }

    @Test
    func rightSidebarCommandAndModuleContributionAreRegistered() async {
        let store = AIAgentTestKeyValueStore()
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .normal)
        let model = AppModel(settings: settings, services: container.services)
        defer { Task { await model.shutdownProjectSession() } }

        #expect(LitheCommandCatalog.command(id: "toggle-ai-agent") != nil)
        #expect(LitheCommandCatalog.command(id: "new-ai-agent-thread") != nil)
        #expect(model.rightSidebarContributions.contains { $0.id == "ai.agent" })
        await model.shutdownProjectSession()
    }
}

private final class AIAgentTestKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
