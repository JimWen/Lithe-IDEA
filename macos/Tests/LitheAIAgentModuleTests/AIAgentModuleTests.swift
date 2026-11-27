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

        // Claude Code 2.1+ rejects --permission-mode default; supervised mode must omit it.
        claudeThread.permissionMode = .supervised
        let supervisedClaudeArgs = AIAgentTurnRunner.buildClaudeArguments(thread: claudeThread)
        #expect(!supervisedClaudeArgs.contains("--permission-mode"))
        #expect(!supervisedClaudeArgs.contains("default"))

        // Claude Haiku does not support reasoning effort; --effort must be omitted.
        var haikuThread = AIAgentThread(
            workspacePath: "/tmp/repo",
            backend: .claudeCLI,
            model: "haiku",
            reasoningEffort: .xhigh,
            permissionMode: .autoEdit
        )
        let haikuArgs = AIAgentTurnRunner.buildClaudeArguments(thread: haikuThread)
        #expect(!haikuArgs.contains("--effort"))

        // Claude Sonnet clamps .xhigh down to .high.
        haikuThread.model = "sonnet"
        let sonnetClampedArgs = AIAgentTurnRunner.buildClaudeArguments(thread: haikuThread)
        if let idx = sonnetClampedArgs.firstIndex(of: "--effort"), idx + 1 < sonnetClampedArgs.count {
            #expect(sonnetClampedArgs[idx + 1] == "high")
        } else {
            Issue.record("Expected clamped --effort high for Claude Sonnet")
        }

        // Codex o3 clamps .xhigh down to .high.
        let o3Thread = AIAgentThread(
            workspacePath: "/tmp/repo",
            backend: .codexCLI,
            model: "o3",
            reasoningEffort: .xhigh,
            permissionMode: .autoEdit
        )
        let o3Args = AIAgentTurnRunner.buildCodexArguments(thread: o3Thread, workingDirectory: "/tmp/repo")
        #expect(o3Args.contains("model_reasoning_effort=\"high\""))

        // Codex exec and resume both forward attached images via -i.
        let imageArgs = AIAgentTurnRunner.buildCodexArguments(
            thread: codexThread,
            workingDirectory: "/tmp/repo",
            imagePaths: ["/tmp/screen.png"]
        )
        #expect(imageArgs.contains("-i"))
        #expect(imageArgs.contains("/tmp/screen.png"))
    }

    @Test
    func modelCatalogDeduplicatesEffortsMigratesLegacySuffixesAndComposesWireIDs() {
        // Legacy suffixed Antigravity IDs split cleanly into canonical family + effort.
        let migratedNeon = AIAgentModelCatalog.normalize(
            model: "gemini-4-neon-xhigh",
            effort: .low,
            backend: .antigravityCLI
        )
        #expect(migratedNeon.model == "gemini-4-neon")
        #expect(migratedNeon.effort == .xhigh)

        let migratedCarbon = AIAgentModelCatalog.normalize(
            model: "gemini-4-carbon-high",
            effort: .xhigh,
            backend: .antigravityCLI
        )
        #expect(migratedCarbon.model == "gemini-4-carbon")
        #expect(migratedCarbon.effort == .high)

        // Unsupported effort tier clamps to highest valid tier.
        let clampedOpus = AIAgentModelCatalog.normalize(
            model: "claude-opus-5-5",
            effort: .xhigh,
            backend: .antigravityCLI
        )
        #expect(clampedOpus.model == "claude-opus-5-5")
        #expect(clampedOpus.effort == .high)

        // Fixed single-tier models hide the effort picker and never get misparsed as suffixed.
        #expect(AIAgentModelCatalog.supportedEfforts(for: "gpt-oss-120b-medium", backend: .antigravityCLI).isEmpty)
        #expect(AIAgentModelCatalog.supportedEfforts(for: "gemini-pro-orchestrator-neon", backend: .antigravityCLI).isEmpty)
        #expect(AIAgentModelCatalog.supportedEfforts(for: "haiku", backend: .claudeCLI).isEmpty)
        #expect(AIAgentModelCatalog.supportedEfforts(for: "gpt-4o", backend: .directHTTP).isEmpty)

        let fixedNorm = AIAgentModelCatalog.normalize(
            model: "gpt-oss-120b-medium",
            effort: .xhigh,
            backend: .antigravityCLI
        )
        #expect(fixedNorm.model == "gpt-oss-120b-medium")

        // Wire ID composition adds effort suffix only for .modelIDSuffix families.
        #expect(
            AIAgentModelCatalog.wireModelID(model: "gemini-4-neon", effort: .xhigh, backend: .antigravityCLI)
            == "gemini-4-neon-xhigh"
        )
        #expect(
            AIAgentModelCatalog.wireModelID(model: "claude-opus-5-5", effort: .xhigh, backend: .antigravityCLI)
            == "claude-opus-5-5-high"
        )
        #expect(
            AIAgentModelCatalog.wireModelID(model: "gpt-oss-120b-medium", effort: .xhigh, backend: .antigravityCLI)
            == "gpt-oss-120b-medium"
        )
        #expect(
            AIAgentModelCatalog.wireModelID(model: "custom-model-v9", effort: .high, backend: .antigravityCLI)
            == "custom-model-v9"
        )
        #expect(AIAgentModelCatalog.supportedEfforts(for: "custom-model-v9", backend: .antigravityCLI).isEmpty)
    }

    @Test
    func claudeParserDeduplicatesIdenticalAssistantAndResultErrors() {
        var parser = ClaudeStreamJSONParser()
        let first = parser.parseLine(#"{"type":"assistant","is_api_error_message":true,"message":{"id":"m1","content":[{"type":"text","text":"Not logged in"}]}}"#)
        let second = parser.parseLine(#"{"type":"result","is_error":true,"result":"Not logged in"}"#)
        #expect(first == [.failed("Not logged in")])
        #expect(second.isEmpty)
    }

    @Test
    func antigravityACPArgumentsModesAndStreamParserCoverFullProtocol() throws {
        var agyThread = AIAgentThread(
            workspacePath: "/tmp/repo",
            backend: .antigravityCLI,
            permissionMode: .supervised
        )
        #expect(AIAgentTurnRunner.buildAntigravityArguments(thread: agyThread) == ["acp"])
        #expect(ACPJSONRPCBuilder.antigravityModeID(for: .plan) == "plan")
        #expect(ACPJSONRPCBuilder.antigravityModeID(for: .supervised) == "default")
        #expect(ACPJSONRPCBuilder.antigravityModeID(for: .autoEdit) == "accept-edits")
        #expect(ACPJSONRPCBuilder.antigravityModeID(for: .fullAuto) == "auto")

        agyThread.permissionMode = .fullAuto
        #expect(AIAgentTurnRunner.buildAntigravityArguments(thread: agyThread) == ["acp", "--dangerously-skip-permissions"])

        var parser = ACPStreamParser()
        let thought = parser.parseLine(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Checking files"}}}}"#)
        if case .sessionUpdate(let sid, let events) = thought {
            #expect(sid == "s1")
            #expect(events == [.reasoningDelta(itemID: "acp-thought-1", text: "Checking files", isReplacement: false)])
        } else {
            Issue.record("Expected thought sessionUpdate")
        }

        let cmd = parser.parseLine(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","name":"run_command","kind":"execute","title":"echo hi","status":"completed","rawInput":{"CommandLine":"echo hi"},"rawOutput":{"output":"hi","exitCode":0}}}}"#)
        if case .sessionUpdate(_, let events) = cmd {
            #expect(events == [.commandUpdated(itemID: "c1", command: "echo hi", output: "hi", exitCode: 0, status: .completed)])
        } else {
            Issue.record("Expected command sessionUpdate")
        }

        let perm = parser.parseLine(#"{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"c2","name":"run_command","kind":"execute","title":"go test","rawInput":{"CommandLine":"go test ./..."}},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}"#)
        if case .permissionRequest(let reqID, let request, let options) = perm {
            #expect(reqID == .string("perm-1"))
            #expect(request.kind == .command)
            #expect(request.command == "go test ./...")
            #expect(options.count == 2)
            let replyData = try ACPJSONRPCBuilder.permissionResponse(requestID: reqID, decision: .allowOnce, options: options)
            let replyObj = try #require(try JSONSerialization.jsonObject(with: replyData) as? [String: Any])
            #expect(replyObj["id"] as? String == "perm-1")
            let outcome = ((replyObj["result"] as? [String: Any])?["outcome"] as? [String: Any])
            #expect(outcome?["optionId"] as? String == "allow")
        } else {
            Issue.record("Expected permissionRequest")
        }

        let usage = ACPStreamParser.parsePromptUsage(from: [
            "usage": ["inputTokens": 120, "cachedReadTokens": 40, "outputTokens": 25, "thoughtTokens": 10]
        ])
        #expect(usage == AIAgentTokenUsage(inputTokens: 120, cachedInputTokens: 40, outputTokens: 25, reasoningTokens: 10))
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

    @Test
    func planModeProposalCanTriggerImplementPlanAndForkExportMarkdown() async throws {
        let processFactory = StubProcessSessionFactory(mode: .streamingAndComplete)
        let runner = AIAgentTurnRunner(
            processFactory: processFactory,
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        let host = StubWorkspaceHost(workspacePath: "/tmp/demo", files: ["main.go": "package main"])
        feature.configure(host: host)

        feature.updateSelectedThreadBackend(.codexCLI)
        feature.updateSelectedThreadPermissionMode(.plan)
        feature.sendPrompt("Design a feature")
        let planTurn: AIAgentTurn = try await waitForState(on: feature) { () -> AIAgentTurn? in
            guard let turn = feature.selectedThread?.turns.last, turn.status == .completed else { return nil }
            return turn
        }
        #expect(planTurn.permissionMode == .plan)
        #expect(planTurn.isCompletedPlanProposal == true)

        feature.implementPlan(from: planTurn, inNewWorktree: false)
        _ = try await waitForState(on: feature) { () -> Bool? in
            guard let turns = feature.selectedThread?.turns, turns.count == 2, turns[1].status == .completed else { return nil }
            return true
        }
        #expect(feature.selectedThread?.permissionMode == .autoEdit)
        #expect(feature.selectedThread?.turns.last?.permissionMode == .autoEdit)

        let sourceID = try #require(feature.selectedThreadID)
        let markdown = feature.exportThreadMarkdown(sourceID)
        #expect(markdown.contains("## Turn 1 · Plan"))
        #expect(markdown.contains("## Turn 2 · Auto-Edit"))
        #expect(markdown.contains("Design a feature"))

        let forked = try #require(feature.forkThread(sourceID))
        #expect(forked.id != sourceID)
        #expect(forked.providerSessionID == nil)
        #expect(forked.turns.count == 2)
        #expect(feature.selectedThreadID == forked.id)
    }

    @Test
    func gitTreeBackedCheckpointEnablesRevertForCLITurns() async throws {
        let processFactory = StubProcessSessionFactory(mode: .streamingAndComplete)
        let runner = AIAgentTurnRunner(
            processFactory: processFactory,
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        let host = StubWorkspaceHost(workspacePath: "/tmp/demo", files: ["main.go": "package main"])
        host.checkpointTrees = [
            String(repeating: "a", count: 40),
            String(repeating: "b", count: 40)
        ]
        host.treeDiffResult = [AIAgentFileChangeSummary(path: "main.go", kind: .modified, additions: 2, deletions: 1)]
        feature.configure(host: host)

        feature.updateSelectedThreadBackend(.codexCLI)
        feature.updateSelectedThreadPermissionMode(.autoEdit)
        feature.sendPrompt("Edit via Codex CLI")

        let turn: AIAgentTurn = try await waitForState(on: feature) { () -> AIAgentTurn? in
            guard let t = feature.selectedThread?.turns.last,
                  t.status == .completed,
                  t.checkpoint?.gitPostTurnTreeHash != nil else { return nil }
            return t
        }
        #expect(turn.canRevertCheckpoint == true)
        #expect(turn.changedFiles.map(\.path) == ["main.go"])

        let checkpoint = try #require(turn.checkpoint)
        await feature.revertToCheckpoint(checkpoint)
        #expect(host.restoredTreeHashes == [String(repeating: "a", count: 40)])
        #expect(feature.statusBannerMessage?.contains("Reverted 1 file") == true)
    }

    @Test
    func directHTTPMultimodalEncodesAttachedImageInRequestBody() async throws {
        let transport = StubStreamingTransport(chunks: [
            Data("data: {\"choices\":[{\"delta\":{\"content\":\"Looks good!\"}}]}\n\ndata: [DONE]\n\n".utf8)
        ])
        let runner = AIAgentTurnRunner(
            processFactory: StubProcessSessionFactory(mode: .streamingAndComplete),
            cliResolver: StubCLIResolver(),
            streamingTransport: transport,
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        let host = StubWorkspaceHost(workspacePath: "/tmp/demo", files: [:])
        host.stubbedImages["/tmp/mock.png"] = ("image/png", Data([0x89, 0x50, 0x4E, 0x47]))
        feature.configure(host: host)

        feature.updateSelectedThreadBackend(.directHTTP)
        feature.sendPrompt(
            "Inspect this screenshot",
            attachments: [AIAgentContextAttachment(kind: .image(path: "/tmp/mock.png", displayName: "mock.png"))]
        )
        _ = try await waitForState(on: feature) {
            feature.selectedThread?.turns.last?.status == .completed ? true : nil
        }

        let capturedBody = String(decoding: transport.recordedRequests.first?.body ?? Data(), as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        #expect(capturedBody.contains("data:image/png;base64,"))
        #expect(capturedBody.contains("image_url"))
    }

    @Test
    func gitTreeRevertStillReconcilesFileSnapshotsForIgnoredOrUnsavedFiles() async throws {
        let runner = AIAgentTurnRunner(
            processFactory: StubProcessSessionFactory(mode: .streamingAndComplete),
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        let host = StubWorkspaceHost(workspacePath: "/tmp/demo", files: ["ignored.env": "MODIFIED_IGNORED"])
        feature.configure(host: host)

        let checkpoint = AIAgentCheckpoint(
            turnID: UUID(),
            label: "Before edit",
            workingDirectoryPath: "/tmp/demo",
            gitTreeHash: String(repeating: "a", count: 40),
            gitPostTurnTreeHash: String(repeating: "b", count: 40),
            fileSnapshots: [AIAgentFileSnapshot(relativePath: "ignored.env", previousContent: "ORIGINAL_IGNORED")]
        )
        await feature.revertToCheckpoint(checkpoint)

        #expect(host.restoredTreeHashes == [String(repeating: "a", count: 40)])
        #expect(host.files["ignored.env"] == "ORIGINAL_IGNORED")
    }

    @Test
    func commitAndPushBindsPushToOriginalWorktreeRootWhenSelectionChanges() async throws {
        let runner = AIAgentTurnRunner(
            processFactory: StubProcessSessionFactory(mode: .streamingAndComplete),
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        let host = StubWorkspaceHost(workspacePath: "/tmp/main-repo", files: [:])
        feature.configure(host: host)

        let threadA = try #require(feature.createThread(worktree: AIAgentWorktreeInfo(path: "/tmp/wt-a", branchName: "agent/a")))
        let threadB = try #require(feature.createThread(worktree: AIAgentWorktreeInfo(path: "/tmp/wt-b", branchName: "agent/b")))
        feature.selectThread(threadA.id)

        host.onCommitStart = {
            // User switches to threadB while threadA's commit is in flight.
            feature.selectThread(threadB.id)
        }
        let ok = await feature.commitAndPushWorkingTreeChanges(message: "feat: commit A")
        #expect(ok == true)
        #expect(host.committedRoots == ["/tmp/wt-a"])
        #expect(host.pushedRoots == ["/tmp/wt-a"])
    }

    @Test
    func sharedWorktreeRemovalBlocksWhileRunningAndClearsAllForkedThreadsWhenIdle() async throws {
        let processFactory = StubProcessSessionFactory(mode: .streamingAndComplete)
        let runner = AIAgentTurnRunner(
            processFactory: processFactory,
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        let host = StubWorkspaceHost(workspacePath: "/tmp/main-repo", files: [:])
        feature.configure(host: host)

        let original = try #require(feature.createThread(worktree: AIAgentWorktreeInfo(path: "/tmp/wt-shared", branchName: "agent/shared")))
        let forked = try #require(feature.forkThread(original.id))
        #expect(forked.worktreePath == "/tmp/wt-shared")

        // Start a supervised turn on `original` so it pauses at approval (isRunning == true).
        feature.selectThread(original.id)
        feature.updateSelectedThreadBackend(.codexCLI)
        feature.updateSelectedThreadPermissionMode(.supervised)
        feature.sendPrompt("Hold worktree active")
        _ = try await waitForState(on: feature) { () -> Bool? in
            feature.threads.first(where: { $0.id == original.id })?.hasPendingApproval == true ? true : nil
        }

        // Attempt to remove shared worktree via the fork MUST be refused while original is running.
        await feature.removeWorktree(for: forked.id)
        #expect(host.removedWorktrees.isEmpty)
        #expect(feature.threads.first(where: { $0.id == original.id })?.worktreePath == "/tmp/wt-shared")

        // Stop original and retry removal: BOTH threads must be cleared together.
        await feature.stopTurn(for: original.id)
        await feature.removeWorktree(for: forked.id)
        #expect(host.removedWorktrees == ["/tmp/wt-shared"])
        #expect(feature.threads.first(where: { $0.id == original.id })?.worktreePath == nil)
        #expect(feature.threads.first(where: { $0.id == forked.id })?.worktreePath == nil)
    }

    @Test
    func implementPlanEmbedsPlanAndForkedCLISessionSeedsPriorConversation() async throws {
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
        feature.updateSelectedThreadPermissionMode(.plan)
        feature.sendPrompt("Plan refactoring step")
        let planTurn: AIAgentTurn = try await waitForState(on: feature) { () -> AIAgentTurn? in
            guard let t = feature.selectedThread?.turns.last, t.status == .completed else { return nil }
            return t
        }
        let originalID = try #require(feature.selectedThreadID)

        // Fork the thread (providerSessionID == nil) and send a follow-up CLI turn.
        _ = try #require(feature.forkThread(originalID))
        feature.updateSelectedThreadPermissionMode(.autoEdit)
        feature.sendPrompt("Continue from fork")
        _ = try await waitForState(on: feature) { () -> Bool? in
            guard let turns = feature.selectedThread?.turns, turns.count == 2, turns[1].status == .completed else { return nil }
            return true
        }
        let forkedStdin = String(decoding: processFactory.capturedStdins.last ?? Data(), as: UTF8.self)
        #expect(forkedStdin.contains("<prior_conversation>"))
        #expect(forkedStdin.contains("Plan refactoring step"))

        // Calling implementPlan embeds the selected plan inside <approved_plan>.
        feature.implementPlan(from: planTurn, inNewWorktree: false)
        _ = try await waitForState(on: feature) { () -> Bool? in
            guard let turns = feature.selectedThread?.turns, turns.count == 3, turns[2].status == .completed else { return nil }
            return true
        }
        let implStdin = String(decoding: processFactory.capturedStdins.last ?? Data(), as: UTF8.self)
        #expect(implStdin.contains("<approved_plan>"))
        #expect(implStdin.contains("Done"))
    }

    @Test
    func antigravityACPEndToEndTurnHandlesInteractiveApprovalStreamingImagesAndResumeFallback() async throws {
        let acpFactory = MockACPProcessSessionFactory()
        let runner = AIAgentTurnRunner(
            processFactory: acpFactory,
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        let host = StubWorkspaceHost(workspacePath: "/tmp/demo", files: [:])
        host.stubbedImages["/tmp/ui.png"] = ("image/png", Data([0x89, 0x50, 0x4E, 0x47]))
        feature.configure(host: host)

        feature.updateSelectedThreadBackend(.antigravityCLI)
        feature.updateSelectedThreadModel("gemini-4-neon-high")
        feature.updateSelectedThreadPermissionMode(.supervised)
        feature.sendPrompt(
            "Run checks with Antigravity",
            attachments: [AIAgentContextAttachment(kind: .image(path: "/tmp/ui.png", displayName: "ui.png"))]
        )

        // Wait for live mid-turn ACP session/request_permission approval card.
        let approvalID: UUID = try await waitForState(on: feature) { () -> UUID? in
            feature.selectedThread?.turns.last?.items.compactMap(\.approval).first(where: { $0.decision == nil })?.id
        }
        #expect(feature.selectedThread?.turns.last?.status == .waitingApproval)
        feature.respondToApproval(requestID: approvalID, decision: .allowOnce)

        let firstTurn: AIAgentTurn = try await waitForState(on: feature) { () -> AIAgentTurn? in
            guard let t = feature.selectedThread?.turns.last, t.status == .completed else { return nil }
            return t
        }
        #expect(feature.selectedThread?.providerSessionID == "acp-sess-1")
        #expect(firstTurn.assistantResponseText == "Antigravity ACP Done")
        #expect(firstTurn.usage?.inputTokens == 300)
        #expect(acpFactory.sentMethods.contains("initialize"))
        #expect(acpFactory.sentMethods.contains("session/new"))
        #expect(acpFactory.sentMethods.contains("session/set_mode"))
        #expect(acpFactory.sentMethods.contains("session/set_model"))
        #expect(acpFactory.sentPromptContainedImage == true)
        #expect(acpFactory.permissionReplyOptionIDs == ["allow"])

        // Second turn attempts session/resume; mock rejects resume so runner transparently
        // falls back to session/new and re-seeds <prior_conversation>.
        acpFactory.failNextResume = true
        feature.sendPrompt("Follow up after restart")
        let secondTurn: AIAgentTurn = try await waitForState(on: feature) { () -> AIAgentTurn? in
            guard let turns = feature.selectedThread?.turns, turns.count == 2, turns[1].status == .completed else { return nil }
            return turns[1]
        }
        #expect(secondTurn.assistantResponseText == "Antigravity ACP Done")
        #expect(acpFactory.sentMethods.contains("session/resume"))
        #expect(acpFactory.lastPromptText.contains("<prior_conversation>"))
        #expect(acpFactory.lastPromptText.contains("Run checks with Antigravity"))
    }

    @Test
    func acpPermissionResponseNeverEscalatesAllowOnceToAllowAlways() throws {
        var parser = ACPStreamParser()
        let line = """
        {"jsonrpc":"2.0","id":"perm-always-only","method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"tc-1","name":"run_command","kind":"execute","rawInput":{"CommandLine":"rm -rf build"}},"options":[{"optionId":"always-opt","name":"Always Allow","kind":"allow_always"},{"optionId":"deny-opt","name":"Reject","kind":"reject_once"}]}}
        """
        guard case .permissionRequest(let reqID, let request, let options) = parser.parseLine(line) else {
            Issue.record("Expected permissionRequest frame")
            return
        }
        #expect(!request.allowsAllowOnce)
        #expect(request.allowsAllowAlways)

        let allowOnceReply = try ACPJSONRPCBuilder.permissionResponse(
            requestID: reqID,
            decision: .allowOnce,
            options: options
        )
        let allowOnceText = String(decoding: allowOnceReply, as: UTF8.self)
        #expect(allowOnceText.contains("\"outcome\":\"cancelled\""))
        #expect(!allowOnceText.contains("always-opt"))

        let allowAlwaysReply = try ACPJSONRPCBuilder.permissionResponse(
            requestID: reqID,
            decision: .allowAlways,
            options: options
        )
        #expect(String(decoding: allowAlwaysReply, as: UTF8.self).contains("\"optionId\":\"always-opt\""))
    }

    @Test
    func acpFailsTurnWhenPermissionModeConfigurationFails() async throws {
        let host = StubWorkspaceHost(workspacePath: "/tmp/acp-mode-fail", files: [:])
        let acpFactory = MockACPProcessSessionFactory()
        acpFactory.failNextSetMode = true
        let runner = AIAgentTurnRunner(
            processFactory: acpFactory,
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        feature.configure(host: host)
        feature.updateSelectedThreadBackend(.antigravityCLI)
        feature.updateSelectedThreadPermissionMode(.plan)
        feature.updateSelectedThreadModel("")

        feature.sendPrompt("Inspect repo without writing")
        let failedTurn: AIAgentTurn = try await waitForState(on: feature) { () -> AIAgentTurn? in
            guard let turn = feature.selectedThread?.turns.first, turn.status == .failed else { return nil }
            return turn
        }
        #expect(failedTurn.errorMessage?.contains("permission mode") == true)
        #expect(!acpFactory.sentMethods.contains("session/prompt"))
    }

    @Test
    func acpTerminatesRunawaySubprocessWhenTransportBufferExceedsCap() async throws {
        let host = StubWorkspaceHost(workspacePath: "/tmp/acp-flood", files: [:])
        host.stubbedImages["/tmp/flood.png"] = ("image/png", Data([0x89, 0x50, 0x4E, 0x47]))
        let acpFactory = MockACPProcessSessionFactory()
        acpFactory.floodBytesOnPermissionPause = 4096
        let runner = AIAgentTurnRunner(
            processFactory: acpFactory,
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver(),
            maxACPQueuedTransportBytes: 1024
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        feature.configure(host: host)
        feature.updateSelectedThreadBackend(.antigravityCLI)
        feature.updateSelectedThreadPermissionMode(.supervised)

        feature.sendPrompt(
            "Trigger flood while waiting approval",
            attachments: [AIAgentContextAttachment(kind: .image(path: "/tmp/flood.png", displayName: "flood.png"))]
        )
        let failedTurn: AIAgentTurn = try await waitForState(on: feature) { () -> AIAgentTurn? in
            guard let turn = feature.selectedThread?.turns.first, turn.status == .failed else { return nil }
            return turn
        }
        #expect(failedTurn.errorMessage?.contains("transport buffer exceeded") == true)
        #expect(acpFactory.stopCount >= 1)
    }

    @Test
    func checkpointRevertPreservesPreTurnDirtyBuffersForCLITurns() async throws {
        let host = StubWorkspaceHost(workspacePath: "/tmp/dirty-cli-revert", files: ["notes.txt": "unsaved-pre-turn"])
        host.dirtySnapshots = [AIAgentFileSnapshot(relativePath: "notes.txt", previousContent: "unsaved-pre-turn")]
        host.checkpointTrees = [
            "1111111111111111111111111111111111111111",
            "2222222222222222222222222222222222222222",
            "2222222222222222222222222222222222222222"
        ]
        host.treeDiffResult = [
            AIAgentFileChangeSummary(path: "notes.txt", kind: .modified, additions: 1, deletions: 1)
        ]
        host.onRestoreTree = { [weak host] in
            // Simulate Git tree restore replacing open buffer with older pre-turn disk text.
            host?.files["notes.txt"] = "older-disk-text"
        }

        let runner = AIAgentTurnRunner(
            processFactory: StubProcessSessionFactory(mode: .streamingAndComplete),
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        feature.configure(host: host)
        feature.updateSelectedThreadBackend(.codexCLI)
        feature.updateSelectedThreadPermissionMode(.autoEdit)

        feature.sendPrompt("Update notes")
        let completedTurn: AIAgentTurn = try await waitForState(on: feature) { () -> AIAgentTurn? in
            guard let turn = feature.selectedThread?.turns.first,
                  turn.status == .completed,
                  turn.checkpoint?.gitPostTurnTreeHash != nil else { return nil }
            return turn
        }
        let checkpoint = try #require(completedTurn.checkpoint)
        #expect(checkpoint.preTurnDirtyBufferSnapshots.count == 1)

        await feature.revertToCheckpoint(checkpoint)
        #expect(host.restoredTreeHashes == ["1111111111111111111111111111111111111111"])
        #expect(host.files["notes.txt"] == "unsaved-pre-turn")
    }

    @Test
    func acpAllowAlwaysDoesNotAutoApproveSubsequentDifferentCommands() async throws {
        let host = StubWorkspaceHost(workspacePath: "/tmp/acp-scoped-always", files: [:])
        host.stubbedImages["/tmp/two.png"] = ("image/png", Data([0x89, 0x50, 0x4E, 0x47]))
        let acpFactory = MockACPProcessSessionFactory()
        acpFactory.requestSecondPermissionAfterFirst = true
        let runner = AIAgentTurnRunner(
            processFactory: acpFactory,
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        feature.configure(host: host)
        feature.updateSelectedThreadBackend(.antigravityCLI)
        feature.updateSelectedThreadPermissionMode(.supervised)

        feature.sendPrompt(
            "Run two distinct commands",
            attachments: [AIAgentContextAttachment(kind: .image(path: "/tmp/two.png", displayName: "two.png"))]
        )

        // First permission request: user clicks Allow Always.
        let firstApprovalID: UUID = try await waitForState(on: feature) { () -> UUID? in
            feature.selectedThread?.turns.last?.items.compactMap(\.approval).first(where: { $0.decision == nil })?.id
        }
        feature.respondToApproval(requestID: firstApprovalID, decision: .allowAlways)

        // Second permission request of the SAME kind (.command) MUST still prompt the user
        // rather than being auto-approved by a kind-wide client cache.
        let secondApprovalID: UUID = try await waitForState(on: feature) { () -> UUID? in
            feature.selectedThread?.turns.last?.items.compactMap(\.approval).first(where: { $0.decision == nil && $0.id != firstApprovalID })?.id
        }
        feature.respondToApproval(requestID: secondApprovalID, decision: .deny)

        let completedTurn: AIAgentTurn = try await waitForState(on: feature) { () -> AIAgentTurn? in
            guard let t = feature.selectedThread?.turns.last, t.status == .completed else { return nil }
            return t
        }
        #expect(completedTurn.items.compactMap(\.approval).count == 2)
        #expect(acpFactory.permissionReplyOptionIDs == ["allow-always", "deny"])
    }

    @Test
    func acpFailsExplicitlyWhenOversizedFrameExceedsLineLimit() async throws {
        let host = StubWorkspaceHost(workspacePath: "/tmp/acp-oversize-frame", files: [:])
        let acpFactory = MockACPProcessSessionFactory()
        acpFactory.emitOversizedLineBytes = 2048
        let runner = AIAgentTurnRunner(
            processFactory: acpFactory,
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver(),
            maxACPLineBytes: 1024
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        feature.configure(host: host)
        feature.updateSelectedThreadBackend(.antigravityCLI)
        feature.updateSelectedThreadPermissionMode(.autoEdit)

        feature.sendPrompt("Trigger oversized ACP frame")
        let failedTurn: AIAgentTurn = try await waitForState(on: feature) { () -> AIAgentTurn? in
            guard let turn = feature.selectedThread?.turns.first, turn.status == .failed else { return nil }
            return turn
        }
        #expect(failedTurn.errorMessage?.contains("frame limit") == true)
    }

    @Test
    func acpComposesCanonicalModelAndEffortIntoWireModelID() async throws {
        let host = StubWorkspaceHost(workspacePath: "/tmp/acp-wire-model", files: [:])
        let acpFactory = MockACPProcessSessionFactory()
        let runner = AIAgentTurnRunner(
            processFactory: acpFactory,
            cliResolver: StubCLIResolver(),
            streamingTransport: StubStreamingTransport(chunks: []),
            credentialResolver: StubCredentialResolver()
        )
        let feature = AIAgentFeatureModel(runner: runner, cliResolver: StubCLIResolver(), threadStore: InMemoryThreadStore())
        feature.configure(host: host)
        feature.updateSelectedThreadBackend(.antigravityCLI)
        feature.updateSelectedThreadPermissionMode(.autoEdit)
        feature.updateSelectedThreadModel("gemini-4-neon-xhigh")

        // Stored model must migrate to canonical family ID + effort without duplicating suffix.
        #expect(feature.selectedThread?.model == "gemini-4-neon")
        #expect(feature.selectedThread?.reasoningEffort == .xhigh)

        feature.sendPrompt("Verify wire model composition")
        let completedTurn: AIAgentTurn = try await waitForState(on: feature) { () -> AIAgentTurn? in
            guard let turn = feature.selectedThread?.turns.first, turn.status == .completed else { return nil }
            return turn
        }
        #expect(completedTurn.assistantResponseText.contains("Antigravity ACP Done"))
        #expect(acpFactory.recordedSetModels == ["gemini-4-neon-xhigh"])
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
    private var _capturedStdins: [Data] = []
    var spawnCount: Int { lock.withLock { _spawnCount } }
    var capturedStdins: [Data] { lock.withLock { _capturedStdins } }
    init(mode: Mode) { self.mode = mode }
    func makeSession() -> any AIAgentProcessSession {
        lock.withLock { _spawnCount += 1 }
        return StubProcessSession { [weak self] stdin in
            guard let self, let stdin else { return }
            self.lock.withLock { self._capturedStdins.append(stdin) }
        }
    }
}

private final class StubProcessSession: AIAgentProcessSession, @unchecked Sendable {
    private let onStartStdin: @Sendable (Data?) -> Void
    init(onStartStdin: @escaping @Sendable (Data?) -> Void = { _ in }) {
        self.onStartStdin = onStartStdin
    }
    func start(_ request: AIAgentProcessLaunchRequest, onEvent: @escaping @Sendable (AIAgentProcessEvent) -> Void) throws {
        onStartStdin(request.standardInput)
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
            AIAgentCLIDetection(backend: .antigravityCLI, isAvailable: true, executablePath: "/usr/local/bin/agy", version: "1.5.18", statusDetail: "ACP ready"),
            AIAgentCLIDetection(backend: .codexCLI, isAvailable: true, executablePath: "/usr/local/bin/codex", version: "0.163.0", statusDetail: "Ready"),
            AIAgentCLIDetection(backend: .claudeCLI, isAvailable: true, executablePath: "/usr/local/bin/claude", version: "2.1.0", statusDetail: "Ready")
        ]
    }
    func resolveExecutable(for backend: AIAgentBackendKind, settings: AIAgentSettings) async -> String? {
        switch backend {
        case .antigravityCLI: "/usr/local/bin/agy"
        case .codexCLI: "/usr/local/bin/codex"
        case .claudeCLI: "/usr/local/bin/claude"
        case .directHTTP: nil
        }
    }
    func processEnvironment() async -> [String: String] { [:] }
}

private final class MockACPProcessSessionFactory: AIAgentProcessSessionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentMethods: [String] = []
    private var _recordedSetModels: [String] = []
    private var _permissionReplyOptionIDs: [String] = []
    private var _sentPromptContainedImage = false
    private var _lastPromptText = ""
    private var _failNextResume = false
    private var _failNextSetMode = false
    private var _floodBytesOnPermissionPause = 0
    private var _requestSecondPermissionAfterFirst = false
    private var _emitOversizedLineBytes = 0
    private var _stopCount = 0
    private var _sessionCounter = 0

    var sentMethods: [String] { lock.withLock { _sentMethods } }
    var recordedSetModels: [String] { lock.withLock { _recordedSetModels } }
    var permissionReplyOptionIDs: [String] { lock.withLock { _permissionReplyOptionIDs } }
    var sentPromptContainedImage: Bool { lock.withLock { _sentPromptContainedImage } }
    var lastPromptText: String { lock.withLock { _lastPromptText } }
    var stopCount: Int { lock.withLock { _stopCount } }
    var failNextResume: Bool {
        get { lock.withLock { _failNextResume } }
        set { lock.withLock { _failNextResume = newValue } }
    }
    var failNextSetMode: Bool {
        get { lock.withLock { _failNextSetMode } }
        set { lock.withLock { _failNextSetMode = newValue } }
    }
    var floodBytesOnPermissionPause: Int {
        get { lock.withLock { _floodBytesOnPermissionPause } }
        set { lock.withLock { _floodBytesOnPermissionPause = newValue } }
    }
    var requestSecondPermissionAfterFirst: Bool {
        get { lock.withLock { _requestSecondPermissionAfterFirst } }
        set { lock.withLock { _requestSecondPermissionAfterFirst = newValue } }
    }
    var emitOversizedLineBytes: Int {
        get { lock.withLock { _emitOversizedLineBytes } }
        set { lock.withLock { _emitOversizedLineBytes = newValue } }
    }

    func makeSession() -> any AIAgentProcessSession {
        MockACPProcessSession(owner: self)
    }

    fileprivate func recordMethod(_ method: String) {
        lock.withLock { _sentMethods.append(method) }
    }

    fileprivate func recordSetModel(_ modelID: String) {
        lock.withLock { _recordedSetModels.append(modelID) }
    }

    fileprivate func recordPermissionReply(_ optionID: String) {
        lock.withLock { _permissionReplyOptionIDs.append(optionID) }
    }

    fileprivate func recordPrompt(text: String, hasImage: Bool) {
        lock.withLock {
            _lastPromptText = text
            if hasImage { _sentPromptContainedImage = true }
        }
    }

    fileprivate func nextSessionID() -> String {
        lock.withLock {
            _sessionCounter += 1
            return "acp-sess-\(_sessionCounter)"
        }
    }

    fileprivate func consumeFailResume() -> Bool {
        lock.withLock {
            let current = _failNextResume
            _failNextResume = false
            return current
        }
    }

    fileprivate func consumeFailSetMode() -> Bool {
        lock.withLock {
            let current = _failNextSetMode
            _failNextSetMode = false
            return current
        }
    }

    fileprivate func recordStop() {
        lock.withLock { _stopCount += 1 }
    }
}

private final class MockACPProcessSession: AIAgentProcessSession, @unchecked Sendable {
    private let owner: MockACPProcessSessionFactory
    private let lock = NSLock()
    private var onEvent: (@Sendable (AIAgentProcessEvent) -> Void)?
    private var lineBuffer = AIAgentLineBuffer()
    private var pendingPromptReqID: Int?
    private var activeSessionID = "acp-sess-1"
    private var isClosed = false

    init(owner: MockACPProcessSessionFactory) {
        self.owner = owner
    }

    func start(
        _ request: AIAgentProcessLaunchRequest,
        onEvent: @escaping @Sendable (AIAgentProcessEvent) -> Void
    ) throws {
        lock.withLock { self.onEvent = onEvent }
    }

    func writeStandardInput(_ data: Data) throws {
        let lines = lock.withLock { lineBuffer.append(data) }
        for line in lines {
            handleIncomingRPC(line)
        }
    }

    func closeStandardInput() {}

    func stopAndWait() async -> Bool {
        owner.recordStop()
        let callback: (@Sendable (AIAgentProcessEvent) -> Void)? = lock.withLock {
            if isClosed { return nil }
            isClosed = true
            return onEvent
        }
        callback?(.terminated(0))
        return true
    }

    private func emitJSON(_ object: [String: Any]) {
        guard let data = try? ACPJSONRPCBuilder.encodeLine(object) else { return }
        let callback = lock.withLock { isClosed ? nil : onEvent }
        callback?(.stdout(data))
    }

    private func handleIncomingRPC(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let method = json["method"] as? String {
            owner.recordMethod(method)
            let reqID = (json["id"] as? NSNumber)?.intValue ?? 0
            switch method {
            case "initialize":
                emitJSON(["jsonrpc": "2.0", "id": reqID, "result": ["protocolVersion": 1]])
            case "session/resume":
                if owner.consumeFailResume() {
                    emitJSON(["jsonrpc": "2.0", "id": reqID, "error": ["code": -32000, "message": "Session expired"]])
                } else {
                    let sid = (json["params"] as? [String: Any])?["sessionId"] as? String ?? "acp-sess-1"
                    lock.withLock { activeSessionID = sid }
                    emitJSON(["jsonrpc": "2.0", "id": reqID, "result": ["sessionId": sid, "modes": ["availableModes": [["id": "default"], ["id": "accept-edits"], ["id": "auto"], ["id": "plan"]]]]])
                }
            case "session/new":
                let sid = owner.nextSessionID()
                lock.withLock { activeSessionID = sid }
                emitJSON(["jsonrpc": "2.0", "id": reqID, "result": ["sessionId": sid, "modes": ["availableModes": [["id": "default"], ["id": "accept-edits"], ["id": "auto"], ["id": "plan"]]]]])
            case "session/set_mode":
                if owner.consumeFailSetMode() {
                    emitJSON(["jsonrpc": "2.0", "id": reqID, "error": ["code": -32001, "message": "Mode rejected"]])
                } else {
                    emitJSON(["jsonrpc": "2.0", "id": reqID, "result": [:]])
                }
            case "session/set_model":
                if let modelID = (json["params"] as? [String: Any])?["modelId"] as? String {
                    owner.recordSetModel(modelID)
                }
                emitJSON(["jsonrpc": "2.0", "id": reqID, "result": [:]])
            case "session/set_config_option":
                emitJSON(["jsonrpc": "2.0", "id": reqID, "result": [:]])
            case "session/prompt":
                let params = json["params"] as? [String: Any]
                let blocks = (params?["prompt"] as? [[String: Any]]) ?? []
                let text = blocks.compactMap { ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil }.joined()
                let hasImage = blocks.contains { ($0["type"] as? String) == "image" }
                owner.recordPrompt(text: text, hasImage: hasImage)
                let sid = lock.withLock { activeSessionID }
                if hasImage {
                    lock.withLock { pendingPromptReqID = reqID }
                    emitJSON([
                        "jsonrpc": "2.0",
                        "id": "perm-1",
                        "method": "session/request_permission",
                        "params": [
                            "sessionId": sid,
                            "toolCall": [
                                "toolCallId": "tc-1",
                                "name": "run_command",
                                "kind": "execute",
                                "title": "go test",
                                "rawInput": ["CommandLine": "go test ./..."]
                            ],
                            "options": [
                                ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                                ["optionId": "allow-always", "name": "Allow Always", "kind": "allow_always"],
                                ["optionId": "deny", "name": "Deny", "kind": "reject_once"]
                            ]
                        ]
                    ])
                    let floodBytes = owner.floodBytesOnPermissionPause
                    if floodBytes > 0 {
                        let chunk = Data(repeating: UInt8(ascii: "x"), count: floodBytes)
                        let callback = lock.withLock { isClosed ? nil : onEvent }
                        callback?(.stderr(chunk))
                    }
                } else if owner.emitOversizedLineBytes > 0 {
                    let padding = String(repeating: "a", count: owner.emitOversizedLineBytes)
                    emitJSON([
                        "jsonrpc": "2.0",
                        "method": "session/update",
                        "params": [
                            "sessionId": sid,
                            "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": padding]]
                        ]
                    ])
                } else {
                    emitPromptCompletion(reqID: reqID, sessionID: sid)
                }
            default:
                break
            }
            return
        }

        // Response to server -> client permission request.
        if let respID = json["id"] as? String, (respID == "perm-1" || respID == "perm-2"),
           let result = json["result"] as? [String: Any],
           let outcome = result["outcome"] as? [String: Any],
           let optionID = outcome["optionId"] as? String {
            owner.recordPermissionReply(optionID)
            let (promptID, sid) = lock.withLock { (pendingPromptReqID, activeSessionID) }
            if respID == "perm-1" && owner.requestSecondPermissionAfterFirst {
                emitJSON([
                    "jsonrpc": "2.0",
                    "id": "perm-2",
                    "method": "session/request_permission",
                    "params": [
                        "sessionId": sid,
                        "toolCall": [
                            "toolCallId": "tc-2",
                            "name": "run_command",
                            "kind": "execute",
                            "title": "rm -rf dist",
                            "rawInput": ["CommandLine": "rm -rf dist"]
                        ],
                        "options": [
                            ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                            ["optionId": "allow-always", "name": "Allow Always", "kind": "allow_always"],
                            ["optionId": "deny", "name": "Deny", "kind": "reject_once"]
                        ]
                    ]
                ])
            } else if let promptID {
                emitPromptCompletion(reqID: promptID, sessionID: sid)
            }
        }
    }

    private func emitPromptCompletion(reqID: Int, sessionID: String) {
        emitJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionID,
                "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Antigravity ACP Done"]]
            ]
        ])
        emitJSON([
            "jsonrpc": "2.0",
            "id": reqID,
            "result": [
                "stopReason": "end_turn",
                "usage": ["inputTokens": 300, "outputTokens": 12, "cachedReadTokens": 0, "thoughtTokens": 5]
            ]
        ])
    }
}

private final class StubStreamingTransport: AIHTTPStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data]
    private var _recordedRequests: [AIHTTPRequest] = []
    var recordedRequests: [AIHTTPRequest] { lock.withLock { _recordedRequests } }

    init(chunks: [Data]) { self.chunks = chunks }

    func stream(_ request: AIHTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let next: Data = lock.withLock {
            _recordedRequests.append(request)
            return chunks.isEmpty ? Data() : chunks.removeFirst()
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
    var onCommitStart: (() -> Void)?
    var pendingTaskBox: Task<Void, Never>?
    var checkpointTrees: [String] = []
    var dirtySnapshots: [AIAgentFileSnapshot] = []
    var treeDiffResult: [AIAgentFileChangeSummary] = []
    var restoredTreeHashes: [String] = []
    var onRestoreTree: (() -> Void)?
    var removedWorktrees: [String] = []
    var committedRoots: [String] = []
    var pushedRoots: [String] = []
    var stubbedImages: [String: (mimeType: String, data: Data)] = [:]
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
    func captureGitCheckpointTree(in rootPath: String) async -> String? {
        checkpointTrees.isEmpty ? nil : checkpointTrees.removeFirst()
    }
    func openDirtyFileSnapshots(in rootPath: String) -> [AIAgentFileSnapshot] {
        dirtySnapshots
    }
    func diffGitTrees(from preTree: String, to postTree: String, in rootPath: String) async -> [AIAgentFileChangeSummary] {
        treeDiffResult
    }
    func restoreGitCheckpointTree(_ treeHash: String, in rootPath: String) async throws -> Int {
        restoredTreeHashes.append(treeHash)
        onRestoreTree?()
        return max(1, treeDiffResult.count)
    }
    func readImageData(at path: String, maxBytes: Int) -> (mimeType: String, data: Data)? {
        stubbedImages[path]
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
    func removeIsolatedWorktree(path: String, from workspaceRoot: String) async throws {
        removedWorktrees.append(path)
    }
    func commitChanges(message: String, in rootPath: String) async throws -> String {
        onCommitStart?()
        committedRoots.append(rootPath)
        return "Committed"
    }
    func pushCurrentBranch(in rootPath: String) async throws -> String {
        pushedRoots.append(rootPath)
        return "Pushed"
    }
    func openFile(relativePath: String, rootPath: String) {}
    func openDiff(relativePath: String, rootPath: String) {}
    func refreshWorkspaceAndGit() async {}
    func notify(_ message: String) {}
}
