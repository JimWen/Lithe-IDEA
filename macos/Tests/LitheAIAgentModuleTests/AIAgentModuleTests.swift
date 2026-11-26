import Combine
import Foundation
import LitheAIAgentModule
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
import Testing

@Suite("AI Agent Stream Parsers & CLI Arguments")
struct AIAgentStreamParserTests {
    @Test
    func lineBufferHandlesFragmentedUTF8AndCRLF() {
        var buffer = AIAgentLineBuffer()
        let first = buffer.append(Data("{\"type\":\"turn".utf8))
        #expect(first.isEmpty)
        let second = buffer.append(Data(".started\"}\r\n{\"type\":\"ok\"}".utf8))
        #expect(second == ["{\"type\":\"turn.started\"}"])
        #expect(buffer.flushRemainder() == "{\"type\":\"ok\"}")
        #expect(buffer.flushRemainder() == nil)
    }

    @Test
    func codexJSONLParserDecodesRealCodexExecEvents() {
        let parser = CodexJSONLParser()

        let started = parser.parseLine(#"{"type":"thread.started","thread_id":"01a219f9-88dc"}"#)
        #expect(started == [.sessionEstablished("01a219f9-88dc")])

        // Benign config deprecation warnings are suppressed cleanly.
        let warning = parser.parseLine(#"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Codex is ignoring 6 unrecognized configuration settings."}}"#)
        #expect(warning.isEmpty)

        let msg = parser.parseLine(#"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Checking tests."}}"#)
        #expect(msg == [.assistantTextDelta(itemID: "item_2", text: "Checking tests.", isReplacement: true)])

        let cmd = parser.parseLine(#"{"type":"item.completed","item":{"id":"item_3","type":"command_execution","command":"go test ./...","aggregated_output":"ok\n","exit_code":0,"status":"completed"}}"#)
        #expect(cmd == [.commandUpdated(itemID: "item_3", command: "go test ./...", output: "ok\n", exitCode: 0, status: .completed)])

        let fileChange = parser.parseLine(#"{"type":"item.completed","item":{"id":"item_4","type":"file_change","changes":[{"path":"main.go","kind":"update"},{"path":"new.go","kind":"add"}],"status":"completed"}}"#)
        #expect(fileChange == [.fileChangesUpdated(
            itemID: "item_4",
            changes: [
                AIAgentFileChangeSummary(path: "main.go", kind: .modified),
                AIAgentFileChangeSummary(path: "new.go", kind: .added)
            ],
            status: .completed
        )])

        let usage = parser.parseLine(#"{"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":400,"output_tokens":80,"reasoning_output_tokens":15}}"#)
        #expect(usage == [.usage(AIAgentTokenUsage(inputTokens: 1200, cachedInputTokens: 400, outputTokens: 80, reasoningTokens: 15))])

        let failed = parser.parseLine(#"{"type":"turn.failed","error":{"message":"{\"error\":{\"message\":\"Model not found\"}}"}}"#)
        #expect(failed == [.failed("Model not found")])
    }

    @Test
    func claudeStreamJSONParserDecodesDeltasToolCallsAndCost() {
        var parser = ClaudeStreamJSONParser()

        let initEvents = parser.parseLine(#"{"type":"system","subtype":"init","session_id":"sess-42","model":"sonnet"}"#)
        #expect(initEvents == [.sessionEstablished("sess-42")])

        _ = parser.parseLine(#"{"type":"stream_event","event":{"type":"message_start"}}"#)
        _ = parser.parseLine(#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","id":"blk-1"}}}"#)
        let delta = parser.parseLine(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}}"#)
        #expect(delta == [.assistantTextDelta(itemID: "blk-1", text: "Hello", isReplacement: false)])

        let toolUse = parser.parseLine(#"{"type":"assistant","message":{"id":"msg-1","content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"cargo check"}}]}}"#)
        #expect(toolUse == [.commandUpdated(itemID: "tool-1", command: "cargo check", output: "", exitCode: nil, status: .running)])

        let toolResult = parser.parseLine(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"Finished dev","is_error":false}]}}"#)
        #expect(toolResult == [.commandUpdated(itemID: "tool-1", command: "cargo check", output: "Finished dev", exitCode: 0, status: .completed)])

        let result = parser.parseLine(#"{"type":"result","session_id":"sess-42","total_cost_usd":0.012,"is_error":false,"usage":{"input_tokens":500,"cache_read_input_tokens":100,"output_tokens":45}}"#)
        #expect(result.contains(.usage(AIAgentTokenUsage(inputTokens: 500, cachedInputTokens: 100, outputTokens: 45, reasoningTokens: 0, costUSD: 0.012))))
    }

    @Test
    func directHTTPSSEParserHandlesOpenAIAndAnthropicProtocols() {
        var chatState = DirectHTTPStreamState()
        let e1 = chatState.consumeSSELine(
            #"data: {"choices":[{"delta":{"content":"Hi ","tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":"{\"path\":"}}]}}]}"#,
            protocol: .chatCompletions,
            assistantItemID: "a1",
            reasoningItemID: "r1"
        )
        let _ = chatState.consumeSSELine(
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"main.go\"}"}}]}}]}"#,
            protocol: .chatCompletions,
            assistantItemID: "a1",
            reasoningItemID: "r1"
        )
        #expect(e1 == [.assistantTextDelta(itemID: "a1", text: "Hi ", isReplacement: false)])
        let calls = chatState.finalizeToolCalls()
        #expect(calls == [DirectHTTPToolInvocation(id: "c1", name: "read_file", argumentsJSON: #"{"path":"main.go"}"#)])

        var anthropicState = DirectHTTPStreamState()
        let a1 = anthropicState.consumeSSELine(
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Step 1"}}"#,
            protocol: .anthropicMessages,
            assistantItemID: "a2",
            reasoningItemID: "r2"
        )
        #expect(a1 == [.reasoningDelta(itemID: "r2", text: "Step 1", isReplacement: false)])
    }

    @Test
    func cliArgumentBuildersRespectPermissionModesAndSessionResume() {
        var codexThread = AIAgentThread(
            workspacePath: "/tmp/repo",
            backend: .codexCLI,
            model: "gpt-5.4",
            reasoningEffort: .high,
            permissionMode: .plan
        )
        let planArgs = AIAgentTurnRunner.buildCodexArguments(thread: codexThread, workingDirectory: "/tmp/repo")
        #expect(planArgs.contains("--sandbox"))
        #expect(planArgs.contains("read-only"))
        #expect(planArgs.contains("-m"))
        #expect(planArgs.contains("gpt-5.4"))
        #expect(planArgs.last == "-")

        codexThread.providerSessionID = "thread-abc"
        codexThread.permissionMode = .autoEdit
        let resumeArgs = AIAgentTurnRunner.buildCodexArguments(thread: codexThread, workingDirectory: "/tmp/repo")
        #expect(resumeArgs.prefix(3) == ["exec", "resume", "thread-abc"])
        #expect(!resumeArgs.contains("--full-auto"))
        #expect(resumeArgs.contains("sandbox_mode=\"workspace-write\""))

        var newAutoEditThread = AIAgentThread(
            workspacePath: "/tmp/repo",
            backend: .codexCLI,
            permissionMode: .autoEdit
        )
        let newAutoArgs = AIAgentTurnRunner.buildCodexArguments(thread: newAutoEditThread, workingDirectory: "/tmp/repo")
        #expect(!newAutoArgs.contains("--full-auto"))
        #expect(newAutoArgs.contains("--sandbox"))
        #expect(newAutoArgs.contains("workspace-write"))
        newAutoEditThread.permissionMode = .fullAuto
        #expect(AIAgentTurnRunner.buildCodexArguments(thread: newAutoEditThread, workingDirectory: "/tmp/repo").contains("--dangerously-bypass-approvals-and-sandbox"))

        var claudeThread = AIAgentThread(
            workspacePath: "/tmp/repo",
            backend: .claudeCLI,
            model: "sonnet",
            reasoningEffort: .medium,
            permissionMode: .autoEdit,
            providerSessionID: "sess-xyz"
        )
        let claudeArgs = AIAgentTurnRunner.buildClaudeArguments(thread: claudeThread)
        #expect(claudeArgs.contains("--resume"))
        #expect(claudeArgs.contains("sess-xyz"))
        #expect(claudeArgs.contains("--permission-mode"))
        #expect(claudeArgs.contains("acceptEdits"))

        claudeThread.permissionMode = .plan
        #expect(AIAgentTurnRunner.buildClaudeArguments(thread: claudeThread).contains("plan"))
    }
}

@Suite("AI Agent Module Lifecycle & Feature Model")
@MainActor
struct AIAgentModuleTests {
    @Test
    func moduleActivationSleepAndShutdownReleaseResourcesCleanly() async throws {
        let runtime = ModuleRuntime()
        let workspaceManifest = try #require(BuiltInModuleCatalog.manifest(for: .workspace))
        try runtime.register(ModuleFactory(manifest: workspaceManifest) { StubWorkspaceModule(manifest: workspaceManifest) })
        let processFactory = StubProcessSessionFactory(mode: .streamingAndComplete)
        try runtime.register(ModuleFactory(
            manifest: AIAgentModule.moduleManifest,
            contributions: AIAgentModule.moduleContributions
        ) {
            AIAgentModule(
                processFactory: processFactory,
                cliResolver: StubCLIResolver(),
                streamingTransportFactory: { StubStreamingTransport(chunks: []) },
                credentialResolver: StubCredentialResolver(),
                threadStore: InMemoryThreadStore()
            )
        })

        let capability = try #require(
            try await runtime.activateCapability(.aiAgentWorkspace) as? AIAgentCapability
        )
        #expect(try runtime.snapshot(for: .aiAgent).isInstantiated)

        try await runtime.sleep(.aiAgent)
        #expect(runtime.capability(.aiAgentWorkspace) == nil)
        #expect(try runtime.snapshot(for: .aiAgent).activity.activeResourceCount == 0)
        _ = capability
    }

    @Test
    func supervisedApprovalToolCallAndCheckpointRevertRoundTrip() async throws {
        let sseStep1 = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-w1","function":{"name":"write_file","arguments":"{\"path\":\"hello.txt\",\"content\":\"after\"}"}}]}}]}"#,
            "\n\n",
            "data: [DONE]\n\n"
        ].joined()
        let sseStep2 = [
            #"data: {"choices":[{"delta":{"content":"Updated hello.txt."}}]}"#,
            "\n\n",
            "data: [DONE]\n\n"
        ].joined()

        let transport = StubStreamingTransport(chunks: [Data(sseStep1.utf8), Data(sseStep2.utf8)])
        let runner = AIAgentTurnRunner(
            processFactory: StubProcessSessionFactory(mode: .streamingAndComplete),
            cliResolver: StubCLIResolver(),
            streamingTransport: transport,
            credentialResolver: StubCredentialResolver()
        )
        let store = InMemoryThreadStore()
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: store)
        let host = StubWorkspaceHost(workspacePath: "/tmp/demo", files: ["hello.txt": "before"])
        feature.configure(host: host)

        feature.updateSelectedThreadBackend(.directHTTP)
        feature.updateSelectedThreadPermissionMode(.supervised)
        feature.sendPrompt("Update hello.txt")

        // Observe deterministic state publication until the supervised approval request arrives.
        let approvalID = try await waitForState(on: feature) {
            feature.selectedThread?.turns.last?.items.compactMap(\.approval).first(where: { $0.decision == nil })?.id
        }
        #expect(feature.selectedThread?.turns.last?.status == .waitingApproval)
        feature.respondToApproval(requestID: approvalID, decision: .allowOnce)

        _ = try await waitForState(on: feature) {
            feature.selectedThread?.turns.last?.status == .completed ? true : nil
        }

        #expect(host.files["hello.txt"] == "after")
        let checkpoint = try #require(feature.selectedThread?.turns.last?.checkpoint)
        #expect(checkpoint.fileSnapshots.count == 1)
        #expect(checkpoint.fileSnapshots.first?.previousContent == "before")

        await feature.revertToCheckpoint(checkpoint)
        #expect(host.files["hello.txt"] == "before")
    }

    @Test
    func slashCommandsAndWorktreeIsolationUpdateThreadState() async throws {
        let runner = AIAgentTurnRunner(
            processFactory: StubProcessSessionFactory(mode: .streamingAndComplete),
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        let host = StubWorkspaceHost(workspacePath: "/tmp/demo", files: [:])
        feature.configure(host: host)

        feature.sendPrompt("/plan")
        #expect(feature.selectedThread?.permissionMode == .plan)

        feature.sendPrompt("/auto")
        #expect(feature.selectedThread?.permissionMode == .autoEdit)

        feature.sendPrompt("/model gpt-5.4")
        #expect(feature.selectedThread?.model == "gpt-5.4")

        await feature.attachWorktreeToSelectedThread(branchName: "agent/test-branch")
        #expect(feature.selectedThread?.worktreeBranch == "agent/test-branch")
        #expect(feature.selectedThread?.effectiveRootPath == "/tmp/demo-worktrees/agent-test-branch")

        let threadID = try #require(feature.selectedThreadID)
        await feature.removeWorktree(for: threadID)
        #expect(feature.selectedThread?.worktreePath == nil)
        #expect(feature.selectedThread?.effectiveRootPath == "/tmp/demo")
    }

    @Test
    func supervisedCodexCLITurnRequiresApprovalAndDenialPreventsSpawn() async throws {
        let processFactory = StubProcessSessionFactory(mode: .streamingAndComplete)
        let runner = AIAgentTurnRunner(
            processFactory: processFactory,
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        let host = StubWorkspaceHost(workspacePath: "/tmp/demo", files: [:])
        feature.configure(host: host)

        feature.updateSelectedThreadBackend(.codexCLI)
        feature.updateSelectedThreadPermissionMode(.supervised)
        feature.sendPrompt("Modify main.go")

        let approvalID = try await waitForState(on: feature) {
            feature.selectedThread?.turns.last?.items.compactMap(\.approval).first(where: { $0.decision == nil })?.id
        }
        #expect(processFactory.spawnCount == 0)
        feature.respondToApproval(requestID: approvalID, decision: .deny)

        _ = try await waitForState(on: feature) {
            feature.selectedThread?.turns.last?.status == .completed ? true : nil
        }
        #expect(processFactory.spawnCount == 0)
    }

    @Test
    func worktreeAttachmentReResolvesOriginalThreadAfterNewThreadInsertion() async throws {
        let runner = AIAgentTurnRunner(
            processFactory: StubProcessSessionFactory(mode: .streamingAndComplete),
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        let host = StubWorkspaceHost(workspacePath: "/tmp/demo", files: [:])
        feature.configure(host: host)

        let originalID = try #require(feature.selectedThreadID)
        await withCheckedContinuation { started in
            host.onWorktreeStart = { started.resume() }
            host.pendingTaskBox = Task { await feature.attachWorktreeToSelectedThread(branchName: "agent/original") }
        }
        let createdTask = try #require(host.pendingTaskBox)

        // Inserting a new thread shifts index 0 while worktree creation is in flight.
        let newerThread = try #require(feature.createThread())
        host.resumeWorktreeGate()
        await createdTask.value

        let originalThread = try #require(feature.threads.first { $0.id == originalID })
        let newThreadState = try #require(feature.threads.first { $0.id == newerThread.id })
        #expect(originalThread.worktreePath == "/tmp/demo-worktrees/agent-original")
        #expect(newThreadState.worktreePath == nil)
    }

    @Test
    func unreadableExistingFileAbortsWriteInsteadOfCreatingDeletionCheckpoint() async throws {
        let sseStep1 = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-u1","function":{"name":"write_file","arguments":"{\"path\":\"secret.bin\",\"content\":\"overwrite\"}"}}]}}]}"#,
            "\n\n",
            "data: [DONE]\n\n"
        ].joined()
        let sseStep2 = [
            #"data: {"choices":[{"delta":{"content":"Could not edit secret.bin."}}]}"#,
            "\n\n",
            "data: [DONE]\n\n"
        ].joined()

        let runner = AIAgentTurnRunner(
            processFactory: StubProcessSessionFactory(mode: .streamingAndComplete),
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: [Data(sseStep1.utf8), Data(sseStep2.utf8)]),
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        let host = StubWorkspaceHost(workspacePath: "/tmp/demo", files: ["secret.bin": "original"])
        host.unreadablePaths.insert("secret.bin")
        feature.configure(host: host)

        feature.updateSelectedThreadBackend(.directHTTP)
        feature.updateSelectedThreadPermissionMode(.autoEdit)
        feature.sendPrompt("Update secret.bin")

        _ = try await waitForState(on: feature) {
            feature.selectedThread?.turns.last?.status == .completed ? true : nil
        }
        #expect(host.files["secret.bin"] == "original")
        #expect(feature.selectedThread?.turns.last?.checkpoint?.fileSnapshots.isEmpty == true)
    }

    private func waitForState<T: Sendable>(
        on feature: AIAgentFeatureModel,
        timeout: DispatchTimeInterval = .seconds(5),
        condition: @escaping @MainActor @Sendable () -> T?
    ) async throws -> T {
        if let value = condition() {
            return value
        }
        let result: T? = await withCheckedContinuation { continuation in
            let box = SingleStateResumption<T>(continuation)
            box.observe(feature.objectWillChange.sink { _ in
                Task { @MainActor in
                    guard let value = condition() else { return }
                    box.finish(with: value)
                }
            })
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                box.finish(with: nil)
            }
        }
        guard let result else { throw CancellationError() }
        return result
    }
}

private final class SingleStateResumption<Value: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value?, Never>?
    private var observation: AnyCancellable?

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func observe(_ observation: AnyCancellable) {
        guard continuation != nil else {
            observation.cancel()
            return
        }
        self.observation = observation
    }

    func finish(with value: Value?) {
        guard let pending = continuation else { return }
        continuation = nil
        observation?.cancel()
        observation = nil
        pending.resume(returning: value)
    }
}

// MARK: - Deterministic Test Doubles

@MainActor
private final class StubWorkspaceModule: LitheModule {
    let manifest: ModuleManifest
    private let capability = NSObject()
    init(manifest: ModuleManifest) { self.manifest = manifest }
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [.workspaceFoundation: capability] }
    func contributions() -> [ModuleContribution] { [] }
}

private final class StubProcessSessionFactory: AIAgentProcessSessionFactory, @unchecked Sendable {
    enum Mode { case streamingAndComplete }
    let mode: Mode
    private let lock = NSLock()
    private var _spawnCount = 0
    var spawnCount: Int { lock.withLock { _spawnCount } }
    init(mode: Mode) { self.mode = mode }
    func makeSession() -> any AIAgentProcessSession {
        lock.withLock { _spawnCount += 1 }
        return StubProcessSession()
    }
}

private final class StubProcessSession: AIAgentProcessSession, @unchecked Sendable {
    func start(_ request: AIAgentProcessLaunchRequest, onEvent: @escaping @Sendable (AIAgentProcessEvent) -> Void) throws {
        let line = #"{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"Done"}}"# + "\n"
        onEvent(.stdout(Data(line.utf8)))
        onEvent(.terminated(0))
    }
    func writeStandardInput(_ data: Data) throws {}
    func closeStandardInput() {}
    func stopAndWait() async -> Bool { true }
}

private struct StubCLIResolver: AIAgentCLIResolving {
    func detectCLIs(settings: AIAgentSettings) async -> [AIAgentCLIDetection] {
        [
            AIAgentCLIDetection(backend: .codexCLI, isAvailable: true, executablePath: "/usr/local/bin/codex", version: "0.163.0", statusDetail: "Ready"),
            AIAgentCLIDetection(backend: .claudeCLI, isAvailable: true, executablePath: "/usr/local/bin/claude", version: "2.1.0", statusDetail: "Ready")
        ]
    }
    func resolveExecutable(for backend: AIAgentBackendKind, settings: AIAgentSettings) async -> String? {
        backend == .codexCLI ? "/usr/local/bin/codex" : "/usr/local/bin/claude"
    }
    func processEnvironment() async -> [String: String] { [:] }
}

private final class StubStreamingTransport: AIHTTPStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data]

    init(chunks: [Data]) { self.chunks = chunks }

    func stream(_ request: AIHTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let next: Data = lock.withLock {
            chunks.isEmpty ? Data() : chunks.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            if !next.isEmpty { continuation.yield(next) }
            continuation.finish()
        }
    }
}

private struct StubCredentialResolver: AIProviderCredentialResolver {
    func readAPIKey(for provider: AIProviderProfile) -> String? { "test-key" }
}

private final class InMemoryThreadStore: AIAgentThreadStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: [AIAgentThread]] = [:]

    func loadThreads(for workspacePath: String) -> [AIAgentThread] {
        lock.withLock { storage[workspacePath] ?? [] }
    }
    func saveThreads(_ threads: [AIAgentThread], for workspacePath: String) {
        lock.withLock { storage[workspacePath] = threads }
    }
}

@MainActor
private final class StubWorkspaceHost: AIAgentWorkspaceHost {
    var workspacePath: String?
    var files: [String: String]
    var unreadablePaths: Set<String> = []
    var agentSettings = AIAgentSettings.default
    var commitMessageAISettings: CommitMessageAISettings
    var onWorktreeStart: (() -> Void)?
    var pendingTaskBox: Task<Void, Never>?
    private var worktreeGate: CheckedContinuation<Void, Never>?

    func resumeWorktreeGate() {
        worktreeGate?.resume()
        worktreeGate = nil
    }

    init(workspacePath: String, files: [String: String]) {
        self.workspacePath = workspacePath
        self.files = files
        let provider = AIProviderProfile(
            name: "Stub OpenAI",
            endpoint: "https://api.example.com/v1",
            model: "gpt-test",
            apiProtocol: .chatCompletions
        )
        var ai = CommitMessageAISettings.default
        ai.providers = [provider]
        ai.activeProviderID = provider.id
        self.commitMessageAISettings = ai
    }

    func projectRelativeFiles(in rootPath: String) -> [String] { Array(files.keys).sorted() }
    func readFile(relativePath: String, rootPath: String) async throws -> String {
        if unreadablePaths.contains(relativePath) {
            throw AIAgentWorkspaceHostError.commandFailed("Permission denied reading \(relativePath)")
        }
        guard let text = files[relativePath] else { throw AIAgentWorkspaceHostError.fileNotFound(relativePath) }
        return text
    }
    func writeFile(relativePath: String, content: String, expectedSourceText: String?, rootPath: String) async throws {
        if let expectedSourceText, let current = files[relativePath], current != expectedSourceText {
            throw AIAgentWorkspaceHostError.commandFailed("File changed concurrently")
        }
        files[relativePath] = content
    }
    func deleteFile(relativePath: String, rootPath: String) async throws {
        files.removeValue(forKey: relativePath)
    }
    func fileExists(relativePath: String, rootPath: String) -> Bool {
        files[relativePath] != nil
    }
    func searchFiles(query: String, rootPath: String, maxResults: Int) async -> [String] { [] }
    func runShellCommand(_ command: String, rootPath: String) async -> (exitCode: Int32, output: String) { (0, "ok") }
    func workingTreeDiff(in rootPath: String) async -> AIAgentWorkingTreeDiff {
        AIAgentWorkingTreeDiff(rootPath: rootPath, branchName: "main", headHash: "abc123")
    }
    func createIsolatedWorktree(branchName: String, from workspaceRoot: String) async throws -> AIAgentWorktreeInfo {
        if let onStart = onWorktreeStart {
            onWorktreeStart = nil
            await withCheckedContinuation { continuation in
                worktreeGate = continuation
                onStart()
            }
        }
        let slug = branchName.replacingOccurrences(of: "/", with: "-")
        return AIAgentWorktreeInfo(path: "\(workspaceRoot)-worktrees/\(slug)", branchName: branchName)
    }
    func removeIsolatedWorktree(path: String, from workspaceRoot: String) async throws {}
    func commitChanges(message: String, in rootPath: String) async throws -> String { "Committed" }
    func pushCurrentBranch(in rootPath: String) async throws -> String { "Pushed" }
    func openFile(relativePath: String, rootPath: String) {}
    func openDiff(relativePath: String, rootPath: String) {}
    func refreshWorkspaceAndGit() async {}
    func notify(_ message: String) {}
}
