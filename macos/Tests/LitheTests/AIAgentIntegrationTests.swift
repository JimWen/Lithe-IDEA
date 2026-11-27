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
        settings.aiAgent.antigravityCLIPath = "/usr/local/bin/agy"
        settings.aiAgent.defaultAntigravityModel = "gemini-4-neon-high"
        settings.aiAgent.defaultPermissionMode = .autoEdit
        settings.aiAgent.defaultReasoningEffort = .high
        settings.aiAgent.preferIsolatedWorktree = true

        let reloaded = AppSettings(store: store)
        #expect(reloaded.aiAgent.defaultBackend == .claudeCLI)
        #expect(reloaded.aiAgent.antigravityCLIPath == "/usr/local/bin/agy")
        #expect(reloaded.aiAgent.defaultAntigravityModel == "gemini-4-neon-high")
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
                applyWorkspaceTextEdit: { relPath, expectedSource, replacement, rootURL, _ in
                    let fileURL = rootURL.appendingPathComponent(relPath)
                    let current = try String(contentsOf: fileURL, encoding: .utf8)
                    guard current == expectedSource else { return false }
                    try replacement.write(to: fileURL, atomically: true, encoding: .utf8)
                    return true
                },
                generateAICommitMessage: { _ in nil },
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
                applyWorkspaceTextEdit: { _, _, _, _, _ in false },
                generateAICommitMessage: { _ in nil },
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
        let addedFile = diff.files.first { $0.path == "first file.txt" && $0.kind == .added }
        #expect(addedFile != nil)
        #expect(addedFile?.additions == 1)
        #expect(addedFile?.diffText.contains("+hello") == true)
    }

    @Test
    func gitTreeCheckpointCapturesExactTurnDiffAndRevertsWithoutTouchingIgnoredFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-agent-ckpt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runner = MacProcessRunner()
        func runGit(_ args: [String]) {
            let result = runner.run(ProcessRequest(
                executablePath: "/usr/bin/git",
                arguments: args,
                workingDirectory: tempDir.path,
                timeoutMilliseconds: 5000
            ))
            #expect(result.succeeded, "git \(args.joined(separator: " ")) failed: \(result.output)")
        }

        runGit(["init"])
        runGit(["config", "user.email", "test@lithe.dev"])
        runGit(["config", "user.name", "Lithe Test"])
        try "ignored.log\n".write(to: tempDir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "line1\n".write(to: tempDir.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        runGit(["add", "-A"])
        runGit(["commit", "-m", "initial"])

        // Pre-existing dirty edit before the agent turn starts + an ignored file.
        try "line1\npre-turn-dirty\n".write(to: tempDir.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "keep-me".write(to: tempDir.appendingPathComponent("ignored.log"), atomically: true, encoding: .utf8)

        let bridge = makeBridge(rootURL: tempDir, runner: runner)
        let preTree = await bridge.captureGitCheckpointTree(in: tempDir.path)
        #expect(preTree != nil)

        // Agent modifies the already-dirty tracked file and creates a new file.
        try "line1\npre-turn-dirty\nagent-edit\n".write(to: tempDir.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "new-file-body\n".write(to: tempDir.appendingPathComponent("agent_new.txt"), atomically: true, encoding: .utf8)

        let postTree = await bridge.captureGitCheckpointTree(in: tempDir.path)
        #expect(postTree != nil)
        #expect(postTree != preTree)

        let turnChanges = await bridge.diffGitTrees(from: preTree!, to: postTree!, in: tempDir.path)
        #expect(turnChanges.contains { $0.path == "tracked.txt" && $0.kind == .modified && $0.additions == 1 })
        #expect(turnChanges.contains { $0.path == "agent_new.txt" && $0.kind == .added && $0.additions == 1 })
        #expect(!turnChanges.contains { $0.path == "ignored.log" })

        let restoredCount = try await bridge.restoreGitCheckpointTree(preTree!, in: tempDir.path)
        #expect(restoredCount == 2)
        #expect(try String(contentsOf: tempDir.appendingPathComponent("tracked.txt"), encoding: .utf8) == "line1\npre-turn-dirty\n")
        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("agent_new.txt").path))
        #expect(try String(contentsOf: tempDir.appendingPathComponent("ignored.log"), encoding: .utf8) == "keep-me")
    }

    @Test
    func discardFileChangeRevertsTrackedAndDeletesUntrackedAndSummarizesCommit() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-agent-discard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runner = MacProcessRunner()
        func runGit(_ args: [String]) {
            let result = runner.run(ProcessRequest(
                executablePath: "/usr/bin/git",
                arguments: args,
                workingDirectory: tempDir.path,
                timeoutMilliseconds: 5000
            ))
            #expect(result.succeeded)
        }

        runGit(["init"])
        runGit(["config", "user.email", "test@lithe.dev"])
        runGit(["config", "user.name", "Lithe Test"])
        try "original\n".write(to: tempDir.appendingPathComponent("app.swift"), atomically: true, encoding: .utf8)
        runGit(["add", "-A"])
        runGit(["commit", "-m", "initial"])

        try "changed\n".write(to: tempDir.appendingPathComponent("app.swift"), atomically: true, encoding: .utf8)
        try "temp\n".write(to: tempDir.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)

        let bridge = makeBridge(rootURL: tempDir, runner: runner)
        let fallbackMsg = try await bridge.generateCommitMessage(in: tempDir.path)
        #expect(fallbackMsg.contains("add 1") && fallbackMsg.contains("update 1"))

        try await bridge.discardFileChange(relativePath: "app.swift", in: tempDir.path)
        #expect(try String(contentsOf: tempDir.appendingPathComponent("app.swift"), encoding: .utf8) == "original\n")

        try await bridge.discardFileChange(relativePath: "scratch.txt", in: tempDir.path)
        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("scratch.txt").path))
    }

    @Test
    func gitTreeCheckpointPreservesSymlinksAndExecutableModes() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-agent-modes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runner = MacProcessRunner()
        func runGit(_ args: [String]) {
            let result = runner.run(ProcessRequest(
                executablePath: "/usr/bin/git",
                arguments: args,
                workingDirectory: tempDir.path,
                timeoutMilliseconds: 5000
            ))
            #expect(result.succeeded, "git \(args.joined(separator: " ")) failed: \(result.output)")
        }

        runGit(["init"])
        runGit(["config", "user.email", "test@lithe.dev"])
        runGit(["config", "user.name", "Lithe Test"])

        let scriptURL = tempDir.appendingPathComponent("run.sh")
        try "#!/bin/sh\necho hi\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let targetURL = tempDir.appendingPathComponent("target.txt")
        try "real-target\n".write(to: targetURL, atomically: true, encoding: .utf8)
        let linkURL = tempDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "target.txt")

        runGit(["add", "-A"])
        runGit(["commit", "-m", "initial"])

        let bridge = makeBridge(rootURL: tempDir, runner: runner)
        let preTree = try #require(await bridge.captureGitCheckpointTree(in: tempDir.path))

        // Mutate executable bit, replace symlink with regular file, and modify target.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scriptURL.path)
        try FileManager.default.removeItem(at: linkURL)
        try "not-a-link".write(to: linkURL, atomically: true, encoding: .utf8)

        let restoredCount = try await bridge.restoreGitCheckpointTree(preTree, in: tempDir.path)
        #expect(restoredCount == 2)

        let attrs = try FileManager.default.attributesOfItem(atPath: linkURL.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) == "target.txt")
        #expect(try String(contentsOf: targetURL, encoding: .utf8) == "real-target\n")

        let scriptPerms = (try FileManager.default.attributesOfItem(atPath: scriptURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect((scriptPerms & 0o111) != 0)
    }

    @Test
    func discardFileChangeRestoresSourcePathOnStagedRename() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-agent-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runner = MacProcessRunner()
        func runGit(_ args: [String]) {
            let result = runner.run(ProcessRequest(
                executablePath: "/usr/bin/git",
                arguments: args,
                workingDirectory: tempDir.path,
                timeoutMilliseconds: 5000
            ))
            #expect(result.succeeded)
        }

        runGit(["init"])
        runGit(["config", "user.email", "test@lithe.dev"])
        runGit(["config", "user.name", "Lithe Test"])
        try "original-body\n".write(to: tempDir.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        runGit(["add", "-A"])
        runGit(["commit", "-m", "initial"])

        runGit(["mv", "old.txt", "new.txt"])

        let bridge = makeBridge(rootURL: tempDir, runner: runner)
        try await bridge.discardFileChange(relativePath: "new.txt", in: tempDir.path)

        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("new.txt").path))
        #expect(try String(contentsOf: tempDir.appendingPathComponent("old.txt"), encoding: .utf8) == "original-body\n")
        let diffAfter = await bridge.workingTreeDiff(in: tempDir.path)
        #expect(diffAfter.files.isEmpty)
    }

    @Test
    func discardFileChangeTreatsBracketsAsLiteralPathspec() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-agent-literal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runner = MacProcessRunner()
        func runGit(_ args: [String]) {
            let result = runner.run(ProcessRequest(
                executablePath: "/usr/bin/git",
                arguments: args,
                workingDirectory: tempDir.path,
                timeoutMilliseconds: 5000
            ))
            #expect(result.succeeded)
        }

        runGit(["init"])
        runGit(["config", "user.email", "test@lithe.dev"])
        runGit(["config", "user.name", "Lithe Test"])
        try "bracket-orig\n".write(to: tempDir.appendingPathComponent("[id].txt"), atomically: true, encoding: .utf8)
        try "sibling-orig\n".write(to: tempDir.appendingPathComponent("i.txt"), atomically: true, encoding: .utf8)
        runGit(["add", "-A"])
        runGit(["commit", "-m", "initial"])

        try "bracket-mod\n".write(to: tempDir.appendingPathComponent("[id].txt"), atomically: true, encoding: .utf8)
        try "sibling-mod\n".write(to: tempDir.appendingPathComponent("i.txt"), atomically: true, encoding: .utf8)
        runGit(["add", "i.txt"])

        let bridge = makeBridge(rootURL: tempDir, runner: runner)
        try await bridge.discardFileChange(relativePath: "[id].txt", in: tempDir.path)

        #expect(try String(contentsOf: tempDir.appendingPathComponent("[id].txt"), encoding: .utf8) == "bracket-orig\n")
        #expect(try String(contentsOf: tempDir.appendingPathComponent("i.txt"), encoding: .utf8) == "sibling-mod\n")
    }

    @Test
    func gitTreeCheckpointPreservesPreExistingIgnoredFileWhenGitignoreChanges() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-agent-ignore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runner = MacProcessRunner()
        func runGit(_ args: [String]) {
            let result = runner.run(ProcessRequest(
                executablePath: "/usr/bin/git",
                arguments: args,
                workingDirectory: tempDir.path,
                timeoutMilliseconds: 5000
            ))
            #expect(result.succeeded)
        }

        runGit(["init"])
        runGit(["config", "user.email", "test@lithe.dev"])
        runGit(["config", "user.name", "Lithe Test"])
        try "private.env\n".write(to: tempDir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        runGit(["add", "-A"])
        runGit(["commit", "-m", "initial"])
        try "SECRET=keep\n".write(to: tempDir.appendingPathComponent("private.env"), atomically: true, encoding: .utf8)

        let bridge = makeBridge(rootURL: tempDir, runner: runner)
        let preTree = try #require(await bridge.captureGitCheckpointTree(in: tempDir.path))

        // Agent unignores private.env and creates a genuinely new file.
        try "# cleared\n".write(to: tempDir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "temp-agent\n".write(to: tempDir.appendingPathComponent("created.txt"), atomically: true, encoding: .utf8)

        _ = try await bridge.restoreGitCheckpointTree(preTree, in: tempDir.path)
        #expect(try String(contentsOf: tempDir.appendingPathComponent(".gitignore"), encoding: .utf8) == "private.env\n")
        #expect(try String(contentsOf: tempDir.appendingPathComponent("private.env"), encoding: .utf8) == "SECRET=keep\n")
        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("created.txt").path))
    }

    @Test
    func subdirectoryWorkspaceRebasesCheckpointAndPreservesCRLFAndRawBytes() async throws {
        let repoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-agent-subdir-\(UUID().uuidString)", isDirectory: true)
        let srcDir = repoDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }

        let runner = MacProcessRunner()
        func runGit(_ args: [String]) {
            let result = runner.run(ProcessRequest(
                executablePath: "/usr/bin/git",
                arguments: args,
                workingDirectory: repoDir.path,
                timeoutMilliseconds: 5000
            ))
            #expect(result.succeeded, "git \(args.joined(separator: " ")) failed: \(result.output)")
        }

        runGit(["init"])
        runGit(["config", "user.email", "test@lithe.dev"])
        runGit(["config", "user.name", "Lithe Test"])
        try "*.win text eol=crlf\n".write(to: repoDir.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "outside-orig\n".write(to: repoDir.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try Data("line1\r\nline2\r\n".utf8).write(to: srcDir.appendingPathComponent("win.win"))
        // 3-byte truncated UTF-8 sequence with no NUL bytes (would become EF BF BD if lossily decoded).
        let rawInvalidUTF8 = Data([0xF0, 0x9F, 0x92])
        try rawInvalidUTF8.write(to: srcDir.appendingPathComponent("raw.dat"))
        runGit(["add", "-A"])
        runGit(["commit", "-m", "initial"])

        let bridge = makeBridge(rootURL: srcDir, runner: runner)
        let preTree = try #require(await bridge.captureGitCheckpointTree(in: srcDir.path))

        try "outside-changed\n".write(to: repoDir.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try Data("changed\n".utf8).write(to: srcDir.appendingPathComponent("win.win"))
        try Data("overwritten".utf8).write(to: srcDir.appendingPathComponent("raw.dat"))

        let diff = await bridge.workingTreeDiff(in: srcDir.path)
        #expect(diff.files.map(\.path).sorted() == ["raw.dat", "win.win"])

        _ = try await bridge.restoreGitCheckpointTree(preTree, in: srcDir.path)
        #expect(!FileManager.default.fileExists(atPath: srcDir.appendingPathComponent("src").path))
        #expect(try Data(contentsOf: srcDir.appendingPathComponent("win.win")) == Data("line1\r\nline2\r\n".utf8))
        #expect(try Data(contentsOf: srcDir.appendingPathComponent("raw.dat")) == rawInvalidUTF8)
        #expect(try String(contentsOf: repoDir.appendingPathComponent("outside.txt"), encoding: .utf8) == "outside-changed\n")

        // Verify subdirectory commitChanges scopes commits strictly to srcDir, leaving outside.txt dirty.
        try Data("src-new\r\n".utf8).write(to: srcDir.appendingPathComponent("win.win"))
        _ = try await bridge.commitChanges(message: "chore: update src only", in: srcDir.path)
        let repoStatus = runner.run(ProcessRequest(
            executablePath: "/usr/bin/git",
            arguments: ["status", "--porcelain=v1"],
            workingDirectory: repoDir.path,
            timeoutMilliseconds: 5000
        ))
        #expect(repoStatus.output.contains("outside.txt"))
        #expect(!repoStatus.output.contains("win.win"))
    }

    @Test
    func gitTreeCheckpointHandlesFileDirectoryBlockerAndAttrChanges() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-agent-blocker-\(UUID().uuidString)", isDirectory: true)
        let nestedDir = tempDir.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runner = MacProcessRunner()
        func runGit(_ args: [String]) {
            let result = runner.run(ProcessRequest(
                executablePath: "/usr/bin/git",
                arguments: args,
                workingDirectory: tempDir.path,
                timeoutMilliseconds: 5000
            ))
            #expect(result.succeeded, "git \(args.joined(separator: " ")) failed: \(result.output)")
        }

        runGit(["init"])
        runGit(["config", "user.email", "test@lithe.dev"])
        runGit(["config", "user.name", "Lithe Test"])
        try "*.txt text eol=lf\n".write(to: tempDir.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try Data("hello\nworld\n".utf8).write(to: nestedDir.appendingPathComponent("leaf.txt"))
        runGit(["add", "-A"])
        runGit(["commit", "-m", "initial"])

        let bridge = makeBridge(rootURL: tempDir, runner: runner)
        let preTree = try #require(await bridge.captureGitCheckpointTree(in: tempDir.path))

        // Replace directory `pkg` with a regular file `pkg` AND flip .gitattributes to eol=crlf.
        try FileManager.default.removeItem(at: nestedDir)
        try "blocker-file\n".write(to: tempDir.appendingPathComponent("pkg"), atomically: true, encoding: .utf8)
        try "*.txt text eol=crlf\n".write(to: tempDir.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)

        _ = try await bridge.restoreGitCheckpointTree(preTree, in: tempDir.path)
        #expect(try Data(contentsOf: nestedDir.appendingPathComponent("leaf.txt")) == Data("hello\nworld\n".utf8))
        #expect(try String(contentsOf: tempDir.appendingPathComponent(".gitattributes"), encoding: .utf8) == "*.txt text eol=lf\n")
    }

    @Test
    func workingTreeDiffRendersUntrackedSymlinkWithoutReadingExternalTarget() async throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-agent-symlink-\(UUID().uuidString)", isDirectory: true)
        let repoDir = baseDir.appendingPathComponent("repo", isDirectory: true)
        let externalSecret = baseDir.appendingPathComponent("secret.txt")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        try "TOP_SECRET_CREDENTIAL_DO_NOT_LEAK\n".write(to: externalSecret, atomically: true, encoding: .utf8)

        let runner = MacProcessRunner()
        func runGit(_ args: [String]) {
            let result = runner.run(ProcessRequest(
                executablePath: "/usr/bin/git",
                arguments: args,
                workingDirectory: repoDir.path,
                timeoutMilliseconds: 5000
            ))
            #expect(result.succeeded, "git \(args.joined(separator: " ")) failed: \(result.output)")
        }
        runGit(["init"])
        runGit(["config", "user.email", "test@lithe.dev"])
        runGit(["config", "user.name", "Lithe Test"])
        try "ok\n".write(to: repoDir.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        runGit(["add", "-A"])
        runGit(["commit", "-m", "initial"])

        try FileManager.default.createSymbolicLink(
            atPath: repoDir.appendingPathComponent("leak-link").path,
            withDestinationPath: externalSecret.path
        )

        let bridge = makeBridge(rootURL: repoDir, runner: runner)
        let diff = await bridge.workingTreeDiff(in: repoDir.path)
        let entry = try #require(diff.files.first(where: { $0.path == "leak-link" }))
        #expect(entry.diffText.contains("new file mode 120000"))
        #expect(entry.diffText.contains(externalSecret.path))
        #expect(!entry.diffText.contains("TOP_SECRET_CREDENTIAL_DO_NOT_LEAK"))
    }

    @Test
    func gitTreeCheckpointRestoresFileBlockedByDirectoryAndCompensatesPartialSaveFailure() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-agent-dirblock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runner = MacProcessRunner()
        func runGit(_ args: [String]) {
            let result = runner.run(ProcessRequest(
                executablePath: "/usr/bin/git",
                arguments: args,
                workingDirectory: tempDir.path,
                timeoutMilliseconds: 5000
            ))
            #expect(result.succeeded, "git \(args.joined(separator: " ")) failed: \(result.output)")
        }
        runGit(["init"])
        runGit(["config", "user.email", "test@lithe.dev"])
        runGit(["config", "user.name", "Lithe Test"])
        try "original-file-pkg\n".write(to: tempDir.appendingPathComponent("pkg"), atomically: true, encoding: .utf8)
        try "alpha-v1\n".write(to: tempDir.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        runGit(["add", "-A"])
        runGit(["commit", "-m", "initial"])

        let bridge = makeBridge(rootURL: tempDir, runner: runner)
        let preTree = try #require(await bridge.captureGitCheckpointTree(in: tempDir.path))

        // Part A: Replace file `pkg` with directory `pkg/sub/child.txt`, then restore checkpoint.
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("pkg"))
        let nestedDir = tempDir.appendingPathComponent("pkg/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try "child\n".write(to: nestedDir.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)

        _ = try await bridge.restoreGitCheckpointTree(preTree, in: tempDir.path)
        #expect(try String(contentsOf: tempDir.appendingPathComponent("pkg"), encoding: .utf8) == "original-file-pkg\n")

        // Part B: Simulate open buffer mutation succeeded followed by saveDocument failure;
        // compensation must restore the open buffer back to its pre-revert text.
        try "alpha-v2\n".write(to: tempDir.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        var openBufferText = "alpha-v2\n"
        var failNextSave = true
        let store = AIAgentTestKeyValueStore()
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: MacRuntimeLocator(),
            store: store,
            toolDiscovery: MacRuntimeToolDiscovery(),
            fileStorage: MacFileStorage()
        )
        let failingBridge = MacAIAgentWorkspaceBridge(
            callbacks: AIAgentHostCallbacks(
                workspacePath: { tempDir.path },
                agentSettings: { .default },
                commitMessageAISettings: { .default },
                readOpenDocumentText: { url in
                    url.lastPathComponent == "alpha.txt" ? openBufferText : nil
                },
                applyWorkspaceTextEdit: { relPath, _, replacement, _, persistToDisk in
                    if relPath == "alpha.txt" {
                        openBufferText = replacement
                        if persistToDisk && failNextSave {
                            failNextSave = false
                            throw AIAgentWorkspaceHostError.commandFailed("Simulated disk save failure")
                        }
                    }
                    return true
                },
                generateAICommitMessage: { _ in nil },
                openFile: { _ in },
                openDiffForRelativePath: { _, _ in },
                refreshWorkspaceAndGit: {},
                notify: { _ in }
            ),
            processRunner: runner,
            runtimeService: runtimeService,
            fileStorage: MacFileStorage()
        )

        var didThrow = false
        do {
            _ = try await failingBridge.restoreGitCheckpointTree(preTree, in: tempDir.path)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        #expect(openBufferText == "alpha-v2\n")
        #expect(try String(contentsOf: tempDir.appendingPathComponent("alpha.txt"), encoding: .utf8) == "alpha-v2\n")
    }

    @Test
    func gitTreeCheckpointPreservesIgnoredFilesUnderDirectoryBlockerAndTrailingSpaceSymlinks() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-agent-r5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runner = MacProcessRunner()
        func runGit(_ args: [String]) {
            let result = runner.run(ProcessRequest(
                executablePath: "/usr/bin/git",
                arguments: args,
                workingDirectory: tempDir.path,
                timeoutMilliseconds: 5000
            ))
            #expect(result.succeeded, "git \(args.joined(separator: " ")) failed: \(result.output)")
        }
        runGit(["init"])
        runGit(["config", "user.email", "test@lithe.dev"])
        runGit(["config", "user.name", "Lithe Test"])
        try "*.log\n".write(to: tempDir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: tempDir.appendingPathComponent("pkg").path,
            withDestinationPath: "target"
        )
        try "unrelated-file\n".write(to: tempDir.appendingPathComponent("link"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: tempDir.appendingPathComponent("link ").path,
            withDestinationPath: "orig-target"
        )
        runGit(["add", "-A"])
        runGit(["commit", "-m", "initial"])

        let bridge = makeBridge(rootURL: tempDir, runner: runner)
        let preTree = try #require(await bridge.captureGitCheckpointTree(in: tempDir.path))

        // Part A: Replace symlink `pkg` with directory `pkg/` containing tracked `child.txt`
        // AND ignored `private.log`. Restore MUST fail without deleting `private.log` or `child.txt`.
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("pkg"))
        let pkgDir = tempDir.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        try "tracked-child\n".write(to: pkgDir.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)
        try "PRIVATE_IGNORED\n".write(to: pkgDir.appendingPathComponent("private.log"), atomically: true, encoding: .utf8)

        var blockedByIgnored = false
        do {
            _ = try await bridge.restoreGitCheckpointTree(preTree, in: tempDir.path)
        } catch {
            blockedByIgnored = true
        }
        #expect(blockedByIgnored)
        #expect(try String(contentsOf: pkgDir.appendingPathComponent("private.log"), encoding: .utf8) == "PRIVATE_IGNORED\n")
        #expect(try String(contentsOf: pkgDir.appendingPathComponent("child.txt"), encoding: .utf8) == "tracked-child\n")

        // Clean up `pkg` blocker, then test Part B: trailing-space symlink `"link "` vs unrelated `"link"`.
        try FileManager.default.removeItem(at: pkgDir)
        try FileManager.default.createSymbolicLink(
            atPath: tempDir.appendingPathComponent("pkg").path,
            withDestinationPath: "target"
        )
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("link "))
        try FileManager.default.createSymbolicLink(
            atPath: tempDir.appendingPathComponent("link ").path,
            withDestinationPath: "changed-target"
        )

        _ = try await bridge.restoreGitCheckpointTree(preTree, in: tempDir.path)
        let restoredDest = try FileManager.default.destinationOfSymbolicLink(
            atPath: tempDir.appendingPathComponent("link ").path
        )
        #expect(restoredDest == "orig-target")
        #expect(try String(contentsOf: tempDir.appendingPathComponent("link"), encoding: .utf8) == "unrelated-file\n")
    }

    private func makeBridge(rootURL: URL, runner: MacProcessRunner) -> MacAIAgentWorkspaceBridge {
        let store = AIAgentTestKeyValueStore()
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: MacRuntimeLocator(),
            store: store,
            toolDiscovery: MacRuntimeToolDiscovery(),
            fileStorage: MacFileStorage()
        )
        return MacAIAgentWorkspaceBridge(
            callbacks: AIAgentHostCallbacks(
                workspacePath: { rootURL.path },
                agentSettings: { .default },
                commitMessageAISettings: { .default },
                readOpenDocumentText: { _ in nil },
                applyWorkspaceTextEdit: { relPath, expectedSource, replacement, root, _ in
                    let fileURL = root.appendingPathComponent(relPath)
                    let current = try String(contentsOf: fileURL, encoding: .utf8)
                    guard current == expectedSource else { return false }
                    try replacement.write(to: fileURL, atomically: true, encoding: .utf8)
                    return true
                },
                generateAICommitMessage: { _ in nil },
                openFile: { _ in },
                openDiffForRelativePath: { _, _ in },
                refreshWorkspaceAndGit: {},
                notify: { _ in }
            ),
            processRunner: runner,
            runtimeService: runtimeService,
            fileStorage: MacFileStorage()
        )
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
        #expect(LitheCommandCatalog.command(id: "ask-ai-agent") != nil)
        #expect(LitheCommandCatalog.command(id: "explain-with-ai-agent") != nil)
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
