import Foundation
import LitheCoreContracts

@MainActor
public struct AIAgentTurnExecutionHooks {
    public let onEvent: @MainActor (AIAgentStreamEvent) -> Void
    public let onRequestApproval: @MainActor (AIAgentApprovalRequest) async -> AIAgentApprovalDecision
    public let onRecordFileSnapshot: @MainActor (String) async throws -> Void
    public let onRegisterProcess: @MainActor ((any AIAgentProcessSession)?) -> Void

    public init(
        onEvent: @escaping @MainActor (AIAgentStreamEvent) -> Void,
        onRequestApproval: @escaping @MainActor (AIAgentApprovalRequest) async -> AIAgentApprovalDecision,
        onRecordFileSnapshot: @escaping @MainActor (String) async throws -> Void,
        onRegisterProcess: @escaping @MainActor ((any AIAgentProcessSession)?) -> Void
    ) {
        self.onEvent = onEvent
        self.onRequestApproval = onRequestApproval
        self.onRecordFileSnapshot = onRecordFileSnapshot
        self.onRegisterProcess = onRegisterProcess
    }
}

public enum AIAgentBackendError: LocalizedError, Sendable {
    case executableNotFound(AIAgentBackendKind)
    case missingDirectProvider
    case missingAPIKey(String)
    case invalidEndpoint(String)
    case processExitedWithError(Int32, String)
    case acpProtocolError(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let backend):
            return "\(backend.title) CLI was not found. Install it or configure its path in Settings → AI & Agent."
        case .missingDirectProvider:
            return "Configure an AI Provider profile in Settings → AI & Agent to use Direct API mode."
        case .missingAPIKey(let name):
            return "No API key is configured for provider '\(name)'."
        case .invalidEndpoint(let endpoint):
            return "Invalid AI endpoint URL: \(endpoint)"
        case .processExitedWithError(let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "Agent process exited with code \(code)."
            }
            return "Agent process exited with code \(code): \(String(detail.prefix(600)))"
        case .acpProtocolError(let detail):
            return detail
        }
    }
}

/// Executes AI Agent turns across Codex CLI, Claude Code CLI, and Direct HTTP Streaming.
public struct AIAgentTurnRunner: Sendable {
    private let processFactory: any AIAgentProcessSessionFactory
    private let cliResolver: any AIAgentCLIResolving
    private let streamingTransport: any AIHTTPStreamingTransport
    private let credentialResolver: any AIProviderCredentialResolver
    private let maxACPQueuedTransportBytes: Int
    private let maxACPLineBytes: Int

    public init(
        processFactory: any AIAgentProcessSessionFactory,
        cliResolver: any AIAgentCLIResolving,
        streamingTransport: any AIHTTPStreamingTransport,
        credentialResolver: any AIProviderCredentialResolver,
        maxACPQueuedTransportBytes: Int = 16 * 1024 * 1024,
        maxACPLineBytes: Int = 4 * 1024 * 1024
    ) {
        self.processFactory = processFactory
        self.cliResolver = cliResolver
        self.streamingTransport = streamingTransport
        self.credentialResolver = credentialResolver
        self.maxACPQueuedTransportBytes = max(1024, maxACPQueuedTransportBytes)
        self.maxACPLineBytes = max(1024, maxACPLineBytes)
    }

    public static func buildAntigravityArguments(thread: AIAgentThread) -> [String] {
        var args = ["acp"]
        if thread.permissionMode == .fullAuto {
            args.append("--dangerously-skip-permissions")
        }
        return args
    }

    public static func buildCodexArguments(
        thread: AIAgentThread,
        workingDirectory: String,
        imagePaths: [String] = []
    ) -> [String] {
        var args: [String] = ["exec"]
        if let sessionID = thread.providerSessionID, !sessionID.isEmpty {
            args.append(contentsOf: ["resume", sessionID, "--json", "--skip-git-repo-check"])
            let trimmedModel = thread.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedModel.isEmpty {
                args.append(contentsOf: ["-m", trimmedModel])
            }
            for imagePath in imagePaths where !imagePath.isEmpty {
                args.append(contentsOf: ["-i", imagePath])
            }
            args.append(contentsOf: ["-c", "model_reasoning_effort=\"\(thread.reasoningEffort.rawValue)\""])
            switch thread.permissionMode {
            case .plan:
                args.append(contentsOf: ["-c", "sandbox_mode=\"read-only\""])
            case .supervised, .autoEdit:
                args.append(contentsOf: ["-c", "sandbox_mode=\"workspace-write\""])
            case .fullAuto:
                args.append("--dangerously-bypass-approvals-and-sandbox")
            }
            args.append("-")
            return args
        }

        args.append(contentsOf: ["--json", "--skip-git-repo-check", "-C", workingDirectory])
        let trimmedModel = thread.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            args.append(contentsOf: ["-m", trimmedModel])
        }
        for imagePath in imagePaths where !imagePath.isEmpty {
            args.append(contentsOf: ["-i", imagePath])
        }
        args.append(contentsOf: ["-c", "model_reasoning_effort=\"\(thread.reasoningEffort.rawValue)\""])
        switch thread.permissionMode {
        case .plan:
            args.append(contentsOf: ["--sandbox", "read-only"])
        case .supervised, .autoEdit:
            args.append(contentsOf: ["--sandbox", "workspace-write"])
        case .fullAuto:
            args.append("--dangerously-bypass-approvals-and-sandbox")
        }
        args.append("-")
        return args
    }

    public static func buildClaudeArguments(thread: AIAgentThread) -> [String] {
        var args: [String] = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages"
        ]
        if let sessionID = thread.providerSessionID, !sessionID.isEmpty {
            args.append(contentsOf: ["--resume", sessionID])
        }
        let trimmedModel = thread.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            args.append(contentsOf: ["--model", trimmedModel])
        }
        args.append(contentsOf: ["--effort", thread.reasoningEffort.rawValue])
        // Claude Code 2.1+ accepts: acceptEdits, auto, bypassPermissions, manual, dontAsk, plan.
        // In supervised mode, Lithe gates execution with a pre-turn approval card and omits
        // --permission-mode so Claude uses its built-in safe default without failing option validation.
        switch thread.permissionMode {
        case .plan:
            args.append(contentsOf: ["--permission-mode", "plan"])
        case .supervised:
            break
        case .autoEdit:
            args.append(contentsOf: ["--permission-mode", "acceptEdits"])
        case .fullAuto:
            args.append(contentsOf: ["--permission-mode", "bypassPermissions"])
        }
        return args
    }

    @MainActor
    public func runTurn(
        thread: AIAgentThread,
        prompt: String,
        attachments: [AIAgentContextAttachment],
        host: any AIAgentWorkspaceHost,
        hooks: AIAgentTurnExecutionHooks
    ) async throws {
        let settings = host.agentSettings
        // For fresh CLI sessions (no providerSessionID yet) on threads with prior completed turns
        // (such as forked threads, provider switches, or newly attached worktrees), inject bounded
        // prior conversation history so the new CLI session retains context.
        let shouldSeedPriorHistory = thread.backend != .directHTTP
            && (thread.providerSessionID?.isEmpty ?? true)
        let priorTurnsForCLI = shouldSeedPriorHistory
            ? thread.turns.filter { !$0.isInFlight }
            : []
        let composedPrompt = await AIAgentPromptBuilder.buildPrompt(
            userPrompt: prompt,
            attachments: attachments,
            customInstructions: settings.customSystemInstructions,
            permissionMode: thread.permissionMode,
            priorTurns: priorTurnsForCLI,
            rootPath: thread.effectiveRootPath,
            host: host
        )
        let imagePaths = attachments.compactMap(\.imageFilePath)

        switch thread.backend {
        case .antigravityCLI:
            try await runAntigravityACP(
                thread: thread,
                rawPrompt: prompt,
                composedPrompt: composedPrompt,
                attachments: attachments,
                imagePaths: imagePaths,
                settings: settings,
                host: host,
                hooks: hooks
            )
        case .codexCLI:
            try await runCodexCLI(
                thread: thread,
                prompt: composedPrompt,
                imagePaths: imagePaths,
                settings: settings,
                hooks: hooks
            )
        case .claudeCLI:
            try await runClaudeCLI(
                thread: thread,
                prompt: composedPrompt,
                settings: settings,
                hooks: hooks
            )
        case .directHTTP:
            try await runDirectHTTP(
                thread: thread,
                userPrompt: composedPrompt,
                imagePaths: imagePaths,
                host: host,
                hooks: hooks
            )
        }
    }

    /// Runs a turn against Antigravity CLI via the Agent Client Protocol (`agy acp`),
    /// matching T3 Code's bidirectional ACP stdio architecture with live streaming updates,
    /// interactive per-tool `session/request_permission` approvals, session resume, and images.
    @MainActor
    private func runAntigravityACP(
        thread: AIAgentThread,
        rawPrompt: String,
        composedPrompt: String,
        attachments: [AIAgentContextAttachment],
        imagePaths: [String],
        settings: AIAgentSettings,
        host: any AIAgentWorkspaceHost,
        hooks: AIAgentTurnExecutionHooks
    ) async throws {
        guard let executable = await cliResolver.resolveExecutable(for: .antigravityCLI, settings: settings) else {
            throw AIAgentBackendError.executableNotFound(.antigravityCLI)
        }
        let args = Self.buildAntigravityArguments(thread: thread)
        let env = await cliResolver.processEnvironment()

        let session = processFactory.makeSession()
        hooks.onRegisterProcess(session)
        defer { hooks.onRegisterProcess(nil) }

        let transportBudget = ACPTransportBudgetBox(maxQueuedBytes: maxACPQueuedTransportBytes)

        // ACP uses bidirectional JSON-RPC where dropping middle frames would corrupt RPC
        // framing; enforce a hard queued-byte budget that terminates runaway subprocesses
        // instead of silently dropping frames or exhausting memory while awaiting approvals.
        let stream = AsyncStream<AIAgentProcessEvent>(bufferingPolicy: .unbounded) { continuation in
            do {
                try session.start(
                    AIAgentProcessLaunchRequest(
                        executablePath: executable,
                        arguments: args,
                        workingDirectory: thread.effectiveRootPath,
                        environment: env,
                        standardInput: nil
                    )
                ) { event in
                    switch event {
                    case .stdout(let data), .stderr(let data):
                        if !transportBudget.recordEnqueue(bytes: data.count) {
                            session.closeStandardInput()
                            Task { _ = await session.stopAndWait() }
                            continuation.finish()
                            transportBudget.triggerOverflowHandler()
                            return
                        }
                        continuation.yield(event)
                    case .terminated:
                        continuation.yield(event)
                        continuation.finish()
                    }
                }
            } catch {
                continuation.yield(.stderr(Data(error.localizedDescription.utf8)))
                continuation.yield(.terminated(127))
                continuation.finish()
            }
        }

        let stateBox = ACPRuntimeStateBox()
        var lineBuffer = AIAgentLineBuffer(maxLineBytes: maxACPLineBytes)
        var parser = ACPStreamParser()
        var stderrCollector = Data()
        var displayedUpdateBytes = 0
        var didWarnOutputLimit = false
        var terminatedCode: Int32?
        var nextRequestID = 1

        func allocateID() -> Int {
            defer { nextRequestID += 1 }
            return nextRequestID
        }

        func sendRPC(_ data: Data) throws {
            try session.writeStandardInput(data)
        }

        enum ACPConfigStepKind {
            case permissionMode(String)
            case model
            case thoughtLevel
        }

        struct ACPConfigStep {
            let id: Int
            let payload: Data
            let kind: ACPConfigStepKind
        }

        enum ACPPhase {
            case awaitingInitialize(Int)
            case awaitingResume(Int)
            case awaitingNew(Int)
            case awaitingConfigure(current: ACPConfigStep, remaining: [ACPConfigStep], sessionID: String, didFallbackFromResume: Bool)
            case awaitingPrompt(Int)
            case completed
        }

        let encodedImages: [(mimeType: String, base64Data: String)] = imagePaths.prefix(4).compactMap { path in
            guard let payload = host.readImageData(at: path, maxBytes: 4 * 1024 * 1024) else { return nil }
            return (payload.mimeType, payload.data.base64EncodedString())
        }

        func dispatchPrompt(sessionID: String, didFallbackFromResume: Bool) async throws -> ACPPhase {
            let finalPromptText: String
            if didFallbackFromResume && !thread.turns.isEmpty {
                finalPromptText = await AIAgentPromptBuilder.buildPrompt(
                    userPrompt: rawPrompt,
                    attachments: attachments,
                    customInstructions: settings.customSystemInstructions,
                    permissionMode: thread.permissionMode,
                    priorTurns: thread.turns.filter { !$0.isInFlight },
                    rootPath: thread.effectiveRootPath,
                    host: host
                )
            } else {
                finalPromptText = composedPrompt
            }
            let promptID = allocateID()
            try sendRPC(try ACPJSONRPCBuilder.sessionPromptRequest(
                id: promptID,
                sessionID: sessionID,
                text: finalPromptText,
                images: encodedImages
            ))
            return .awaitingPrompt(promptID)
        }

        func beginConfigureOrPrompt(
            payload: ACPResponsePayload,
            didFallbackFromResume: Bool
        ) async throws -> ACPPhase {
            guard let sessionID = payload.sessionID, !sessionID.isEmpty else {
                throw AIAgentBackendError.acpProtocolError("Antigravity ACP did not return a sessionId.")
            }
            stateBox.setSessionID(sessionID)
            hooks.onEvent(.sessionEstablished(sessionID))

            var configSteps: [ACPConfigStep] = []
            let targetModeID = ACPJSONRPCBuilder.antigravityModeID(for: thread.permissionMode)
            if !payload.availableModeIDs.isEmpty && !payload.availableModeIDs.contains(targetModeID) {
                throw AIAgentBackendError.acpProtocolError(
                    "Antigravity ACP server does not support requested permission mode '\(targetModeID)'."
                )
            }
            let modeID = allocateID()
            configSteps.append(ACPConfigStep(
                id: modeID,
                payload: try ACPJSONRPCBuilder.sessionSetModeRequest(
                    id: modeID,
                    sessionID: sessionID,
                    modeID: targetModeID
                ),
                kind: .permissionMode(targetModeID)
            ))

            let trimmedModel = thread.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedModel.isEmpty {
                let modelID = allocateID()
                configSteps.append(ACPConfigStep(
                    id: modelID,
                    payload: try ACPJSONRPCBuilder.sessionSetModelRequest(
                        id: modelID,
                        sessionID: sessionID,
                        modelID: trimmedModel
                    ),
                    kind: .model
                ))
            } else if payload.supportedThoughtLevels.contains(thread.reasoningEffort.rawValue) {
                let effortID = allocateID()
                configSteps.append(ACPConfigStep(
                    id: effortID,
                    payload: try ACPJSONRPCBuilder.sessionSetConfigOptionRequest(
                        id: effortID,
                        sessionID: sessionID,
                        configID: "thought_level",
                        value: thread.reasoningEffort.rawValue
                    ),
                    kind: .thoughtLevel
                ))
            }

            if let first = configSteps.first {
                try sendRPC(first.payload)
                return .awaitingConfigure(
                    current: first,
                    remaining: Array(configSteps.dropFirst()),
                    sessionID: sessionID,
                    didFallbackFromResume: didFallbackFromResume
                )
            }
            return try await dispatchPrompt(sessionID: sessionID, didFallbackFromResume: didFallbackFromResume)
        }

        var phase: ACPPhase = .awaitingInitialize(allocateID())
        let initialReqID: Int = {
            if case .awaitingInitialize(let id) = phase { return id }
            return 1
        }()

        do {
            try sendRPC(try ACPJSONRPCBuilder.initializeRequest(id: initialReqID))

            try await withTaskCancellationHandler {
                let readerTask = Task { @MainActor in
                    eventLoop: for await event in stream {
                        if transportBudget.isExceeded { break eventLoop }
                        try Task.checkCancellation()
                        switch event {
                        case .stdout(let data):
                            transportBudget.recordDequeue(bytes: data.count)
                            // Always continue parsing ACP JSON-RPC lines so protocol responses and
                            // interactive permission requests are never dropped; fail explicitly if
                            // any single JSON-RPC frame exceeds the configured frame-size limit.
                            let parsedLines = lineBuffer.append(data)
                            if lineBuffer.droppedOversizedLineCount > 0 {
                                throw AIAgentBackendError.acpProtocolError(
                                    "Antigravity ACP emitted a JSON-RPC frame exceeding the \(maxACPLineBytes)-byte frame limit."
                                )
                            }
                            for line in parsedLines {
                                if transportBudget.isExceeded { break eventLoop }
                                let incoming = parser.parseLine(line)
                                switch incoming {
                                case .sessionUpdate(_, let events):
                                    if displayedUpdateBytes >= Self.maxTurnStdoutBytes {
                                        if !didWarnOutputLimit {
                                            didWarnOutputLimit = true
                                            hooks.onEvent(.systemNotice("ACP stream output exceeded the 8 MiB per-turn cap; additional display deltas are suppressed while awaiting turn completion."))
                                        }
                                        continue
                                    }
                                    displayedUpdateBytes += line.utf8.count
                                    for ev in events {
                                        hooks.onEvent(ev)
                                    }
                                case .permissionRequest(let reqID, let approvalRequest, let options):
                                    if transportBudget.isExceeded { break eventLoop }
                                    let decision: AIAgentApprovalDecision
                                    if thread.permissionMode == .fullAuto {
                                        decision = .allowAlways
                                    } else {
                                        decision = await hooks.onRequestApproval(approvalRequest)
                                    }
                                    if transportBudget.isExceeded { break eventLoop }
                                    let reply = try ACPJSONRPCBuilder.permissionResponse(
                                        requestID: reqID,
                                        decision: decision,
                                        options: options
                                    )
                                    try sendRPC(reply)
                                case .response(let responseID, let payload, let errorMessage):
                                    switch phase {
                                    case .awaitingInitialize(let expectedID) where responseID == .int(expectedID):
                                        if let err = errorMessage {
                                            throw AIAgentBackendError.acpProtocolError(err)
                                        }
                                        if let existingID = thread.providerSessionID, !existingID.isEmpty {
                                            let resumeID = allocateID()
                                            try sendRPC(try ACPJSONRPCBuilder.sessionResumeRequest(
                                                id: resumeID,
                                                sessionID: existingID,
                                                cwd: thread.effectiveRootPath
                                            ))
                                            phase = .awaitingResume(resumeID)
                                        } else {
                                            let newID = allocateID()
                                            try sendRPC(try ACPJSONRPCBuilder.sessionNewRequest(
                                                id: newID,
                                                cwd: thread.effectiveRootPath
                                            ))
                                            phase = .awaitingNew(newID)
                                        }

                                    case .awaitingResume(let expectedID) where responseID == .int(expectedID):
                                        if errorMessage == nil, let sid = payload.sessionID, !sid.isEmpty {
                                            phase = try await beginConfigureOrPrompt(payload: payload, didFallbackFromResume: false)
                                        } else {
                                            let newID = allocateID()
                                            try sendRPC(try ACPJSONRPCBuilder.sessionNewRequest(
                                                id: newID,
                                                cwd: thread.effectiveRootPath
                                            ))
                                            phase = .awaitingNew(newID)
                                        }

                                    case .awaitingNew(let expectedID) where responseID == .int(expectedID):
                                        if let err = errorMessage {
                                            throw AIAgentBackendError.acpProtocolError(err)
                                        }
                                        let didFallback = !(thread.providerSessionID?.isEmpty ?? true)
                                        phase = try await beginConfigureOrPrompt(payload: payload, didFallbackFromResume: didFallback)

                                    case .awaitingConfigure(let currentStep, let remainingSteps, let sid, let didFallback) where responseID == .int(currentStep.id):
                                        if let err = errorMessage {
                                            switch currentStep.kind {
                                            case .permissionMode(let modeID):
                                                throw AIAgentBackendError.acpProtocolError(
                                                    "Failed to apply Antigravity permission mode '\(modeID)': \(err)"
                                                )
                                            case .model, .thoughtLevel:
                                                hooks.onEvent(.systemNotice("Antigravity session config warning: \(err)"))
                                            }
                                        }
                                        if let next = remainingSteps.first {
                                            try sendRPC(next.payload)
                                            phase = .awaitingConfigure(
                                                current: next,
                                                remaining: Array(remainingSteps.dropFirst()),
                                                sessionID: sid,
                                                didFallbackFromResume: didFallback
                                            )
                                        } else {
                                            phase = try await dispatchPrompt(sessionID: sid, didFallbackFromResume: didFallback)
                                        }

                                    case .awaitingPrompt(let expectedID) where responseID == .int(expectedID):
                                        if let err = errorMessage {
                                            throw AIAgentBackendError.acpProtocolError(err)
                                        }
                                        if let usage = payload.usage {
                                            hooks.onEvent(.usage(usage))
                                        }
                                        phase = .completed
                                        break eventLoop

                                    default:
                                        break
                                    }
                                case .ignored:
                                    break
                                }
                            }

                        case .stderr(let data):
                            transportBudget.recordDequeue(bytes: data.count)
                            if stderrCollector.count < 32_768 {
                                stderrCollector.append(data.prefix(32_768 - stderrCollector.count))
                            }

                        case .terminated(let code):
                            terminatedCode = code
                        }
                    }
                }
                transportBudget.setOverflowHandler { readerTask.cancel() }
                defer { transportBudget.setOverflowHandler(nil) }
                do {
                    try await withTaskCancellationHandler {
                        try await readerTask.value
                    } onCancel: {
                        readerTask.cancel()
                    }
                } catch is CancellationError {
                    if !transportBudget.isExceeded {
                        throw CancellationError()
                    }
                }

                if transportBudget.isExceeded {
                    throw AIAgentBackendError.acpProtocolError(
                        "Antigravity ACP transport buffer exceeded \(maxACPQueuedTransportBytes) bytes; terminated runaway subprocess."
                    )
                }
                if case .completed = phase {
                    // Turn completed normally.
                } else {
                    let code = terminatedCode ?? 1
                    let stderrText = String(decoding: stderrCollector, as: UTF8.self)
                    throw AIAgentBackendError.processExitedWithError(code, stderrText)
                }
            } onCancel: {
                if let sid = stateBox.sessionID,
                   let cancelData = try? ACPJSONRPCBuilder.sessionCancelNotification(sessionID: sid) {
                    try? session.writeStandardInput(cancelData)
                }
                session.closeStandardInput()
                Task { _ = await session.stopAndWait() }
            }
        } catch {
            session.closeStandardInput()
            _ = await session.stopAndWait()
            throw error
        }

        session.closeStandardInput()
        _ = await session.stopAndWait()
    }

    @MainActor
    private func runCodexCLI(
        thread: AIAgentThread,
        prompt: String,
        imagePaths: [String],
        settings: AIAgentSettings,
        hooks: AIAgentTurnExecutionHooks
    ) async throws {
        guard let executable = await cliResolver.resolveExecutable(for: .codexCLI, settings: settings) else {
            throw AIAgentBackendError.executableNotFound(.codexCLI)
        }
        let args = Self.buildCodexArguments(
            thread: thread,
            workingDirectory: thread.effectiveRootPath,
            imagePaths: imagePaths
        )
        if thread.permissionMode == .supervised {
            let decision = await hooks.onRequestApproval(AIAgentApprovalRequest(
                kind: .command,
                title: "Approve Codex CLI turn",
                detail: "Allow Codex CLI to run in workspace-write sandbox inside \(thread.effectiveRootPath)? Switch to Plan mode for read-only, or Direct API for per-tool approvals.",
                command: "codex \(args.joined(separator: " "))"
            ))
            if decision == .deny {
                hooks.onEvent(.systemNotice("Codex CLI turn was denied by user."))
                return
            }
        }
        let env = await cliResolver.processEnvironment()
        let parser = CodexJSONLParser()
        try await runCLIProcess(
            executablePath: executable,
            arguments: args,
            workingDirectory: thread.effectiveRootPath,
            environment: env,
            standardInput: Data(prompt.utf8),
            hooks: hooks,
            parseLine: { line in parser.parseLine(line) }
        )
    }

    @MainActor
    private func runClaudeCLI(
        thread: AIAgentThread,
        prompt: String,
        settings: AIAgentSettings,
        hooks: AIAgentTurnExecutionHooks
    ) async throws {
        guard let executable = await cliResolver.resolveExecutable(for: .claudeCLI, settings: settings) else {
            throw AIAgentBackendError.executableNotFound(.claudeCLI)
        }
        let args = Self.buildClaudeArguments(thread: thread)
        if thread.permissionMode == .supervised {
            let decision = await hooks.onRequestApproval(AIAgentApprovalRequest(
                kind: .command,
                title: "Approve Claude Code CLI turn",
                detail: "Allow Claude Code CLI to run in \(thread.effectiveRootPath)? Switch to Plan mode for read-only, or Direct API for per-tool approvals.",
                command: "claude \(args.joined(separator: " "))"
            ))
            if decision == .deny {
                hooks.onEvent(.systemNotice("Claude Code CLI turn was denied by user."))
                return
            }
        }
        let env = await cliResolver.processEnvironment()
        let parserBox = MainActorParserBox(parser: ClaudeStreamJSONParser())
        try await runCLIProcess(
            executablePath: executable,
            arguments: args,
            workingDirectory: thread.effectiveRootPath,
            environment: env,
            standardInput: Data(prompt.utf8),
            hooks: hooks,
            parseLine: { line in parserBox.parse(line) }
        )
    }

    private static let maxTurnStdoutBytes = 8 * 1024 * 1024

    @MainActor
    private func runCLIProcess(
        executablePath: String,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String],
        standardInput: Data,
        hooks: AIAgentTurnExecutionHooks,
        parseLine: @escaping @MainActor (String) -> [AIAgentStreamEvent]
    ) async throws {
        let session = processFactory.makeSession()
        hooks.onRegisterProcess(session)
        defer { hooks.onRegisterProcess(nil) }

        let stream = AsyncStream<AIAgentProcessEvent>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            do {
                try session.start(
                    AIAgentProcessLaunchRequest(
                        executablePath: executablePath,
                        arguments: arguments,
                        workingDirectory: workingDirectory,
                        environment: environment,
                        standardInput: standardInput
                    )
                ) { event in
                    continuation.yield(event)
                    if case .terminated = event {
                        continuation.finish()
                    }
                }
            } catch {
                continuation.yield(.stderr(Data(error.localizedDescription.utf8)))
                continuation.yield(.terminated(127))
                continuation.finish()
            }
        }

        var lineBuffer = AIAgentLineBuffer()
        var stderrCollector = Data()
        var stdoutBytesProcessed = 0
        var didWarnOutputLimit = false
        var reportedFailure = false
        var exitCode: Int32 = 0

        await withTaskCancellationHandler {
            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .stdout(let data):
                    if stdoutBytesProcessed >= Self.maxTurnStdoutBytes {
                        if !didWarnOutputLimit {
                            didWarnOutputLimit = true
                            hooks.onEvent(.systemNotice("CLI output exceeded the 8 MiB per-turn cap; additional stream data is truncated."))
                        }
                        continue
                    }
                    let remaining = Self.maxTurnStdoutBytes - stdoutBytesProcessed
                    let slice = data.prefix(remaining)
                    stdoutBytesProcessed += slice.count
                    for line in lineBuffer.append(slice) {
                        for parsed in parseLine(line) {
                            if case .failed = parsed { reportedFailure = true }
                            hooks.onEvent(parsed)
                        }
                    }
                case .stderr(let data):
                    if stderrCollector.count < 32_768 {
                        stderrCollector.append(data.prefix(32_768 - stderrCollector.count))
                    }
                case .terminated(let code):
                    exitCode = code
                }
            }
            if stdoutBytesProcessed < Self.maxTurnStdoutBytes,
               let remainder = lineBuffer.flushRemainder() {
                for parsed in parseLine(remainder) {
                    if case .failed = parsed { reportedFailure = true }
                    hooks.onEvent(parsed)
                }
            }
        } onCancel: {
            Task { _ = await session.stopAndWait() }
        }

        if Task.isCancelled {
            _ = await session.stopAndWait()
            throw CancellationError()
        }

        if exitCode != 0 && !reportedFailure {
            let stderrText = String(decoding: stderrCollector, as: UTF8.self)
            throw AIAgentBackendError.processExitedWithError(exitCode, stderrText)
        }
    }

    // MARK: - Direct HTTP Streaming Agent Loop

    @MainActor
    private func runDirectHTTP(
        thread: AIAgentThread,
        userPrompt: String,
        imagePaths: [String],
        host: any AIAgentWorkspaceHost,
        hooks: AIAgentTurnExecutionHooks
    ) async throws {
        let aiSettings = host.commitMessageAISettings
        guard var provider = aiSettings.activeProvider ?? aiSettings.providers.first else {
            throw AIAgentBackendError.missingDirectProvider
        }
        let threadModel = thread.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !threadModel.isEmpty {
            provider.model = threadModel
        }
        guard let requestURL = Self.resolvedEndpointURL(for: provider) else {
            throw AIAgentBackendError.invalidEndpoint(provider.endpoint)
        }
        let apiKey = credentialResolver.readAPIKey(for: provider)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.requiresAPIKey && (apiKey?.isEmpty ?? true) {
            throw AIAgentBackendError.missingAPIKey(provider.name)
        }

        let systemPrompt = Self.directAgentSystemPrompt(
            rootPath: thread.effectiveRootPath,
            permissionMode: thread.permissionMode,
            customInstructions: host.agentSettings.customSystemInstructions
        )

        let attachedImages: [EncodedImage] = imagePaths.prefix(4).compactMap { path in
            guard let payload = host.readImageData(at: path, maxBytes: 4 * 1024 * 1024) else { return nil }
            return EncodedImage(mimeType: payload.mimeType, base64Data: payload.data.base64EncodedString())
        }

        var conversationMessages = Self.seedConversationHistory(
            from: thread,
            latestPrompt: userPrompt,
            latestImages: attachedImages
        )
        let maxSteps = 10

        for step in 0..<maxSteps {
            try Task.checkCancellation()
            let request = try Self.makeDirectHTTPRequest(
                provider: provider,
                url: requestURL,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                messages: conversationMessages,
                permissionMode: thread.permissionMode,
                reasoningEffort: thread.reasoningEffort
            )

            let assistantItemID = "http-assistant-\(step)-\(UUID().uuidString.prefix(6))"
            let reasoningItemID = "http-reasoning-\(step)-\(UUID().uuidString.prefix(6))"
            var lineBuffer = AIAgentLineBuffer()
            var streamState = DirectHTTPStreamState()

            let byteStream = try await streamingTransport.stream(request)
            for try await chunk in byteStream {
                try Task.checkCancellation()
                for line in lineBuffer.append(chunk) {
                    let events = streamState.consumeSSELine(
                        line,
                        protocol: provider.apiProtocol,
                        assistantItemID: assistantItemID,
                        reasoningItemID: reasoningItemID
                    )
                    for event in events {
                        hooks.onEvent(event)
                    }
                }
            }
            if let remainder = lineBuffer.flushRemainder() {
                for event in streamState.consumeSSELine(
                    remainder,
                    protocol: provider.apiProtocol,
                    assistantItemID: assistantItemID,
                    reasoningItemID: reasoningItemID
                ) {
                    hooks.onEvent(event)
                }
            }

            if let errorMessage = streamState.errorMessage {
                throw AIAgentBackendError.processExitedWithError(1, errorMessage)
            }

            let calls = streamState.finalizeToolCalls()
            guard !calls.isEmpty else {
                break
            }

            conversationMessages.append(.assistant(text: streamState.assistantText, toolCalls: calls))

            for call in calls {
                try Task.checkCancellation()
                let resultText = await executeDirectTool(
                    call: call,
                    thread: thread,
                    host: host,
                    hooks: hooks
                )
                conversationMessages.append(.toolResult(callID: call.id, name: call.name, output: resultText))
            }
        }
    }

    @MainActor
    private func executeDirectTool(
        call: DirectHTTPToolInvocation,
        thread: AIAgentThread,
        host: any AIAgentWorkspaceHost,
        hooks: AIAgentTurnExecutionHooks
    ) async -> String {
        let args = (call.argumentsJSON.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }) ?? [:]
        let rootPath = thread.effectiveRootPath

        func reportTool(_ summary: String, output: String = "", status: AIAgentToolCallStatus) {
            hooks.onEvent(.toolCallUpdated(
                itemID: call.id,
                name: call.name,
                inputSummary: summary,
                output: output,
                status: status
            ))
        }

        switch call.name {
        case "list_files":
            let prefix = (args["prefix"] as? String) ?? ""
            reportTool(prefix.isEmpty ? "." : prefix, status: .running)
            let files = host.projectRelativeFiles(in: rootPath)
                .filter { prefix.isEmpty || $0.hasPrefix(prefix) }
                .prefix(200)
            let output = files.joined(separator: "\n")
            reportTool(prefix.isEmpty ? "." : prefix, output: output, status: .completed)
            return output.isEmpty ? "(no files)" : output

        case "read_file":
            let path = (args["path"] as? String) ?? ""
            reportTool(path, status: .running)
            do {
                let text = try await host.readFile(relativePath: path, rootPath: rootPath)
                let clipped = text.count > 24_000 ? String(text.prefix(24_000)) + "\n... [truncated]" : text
                reportTool(path, output: "\(text.count) chars", status: .completed)
                return clipped
            } catch {
                reportTool(path, output: error.localizedDescription, status: .failed)
                return "Error: \(error.localizedDescription)"
            }

        case "search_files":
            let query = (args["query"] as? String) ?? ""
            reportTool(query, status: .running)
            let matches = await host.searchFiles(query: query, rootPath: rootPath, maxResults: 60)
            let output = matches.joined(separator: "\n")
            reportTool(query, output: output, status: .completed)
            return output.isEmpty ? "No matches found for '\(query)'." : output

        case "write_file":
            let path = (args["path"] as? String) ?? ""
            let content = (args["content"] as? String) ?? ""
            guard thread.permissionMode != .plan else {
                reportTool(path, output: "Blocked in Plan mode.", status: .denied)
                return "Blocked: currently in Plan (read-only) mode."
            }
            let existedBeforeApproval = host.fileExists(relativePath: path, rootPath: rootPath)
            let expectedSourceBeforeApproval: String?
            if existedBeforeApproval {
                do {
                    expectedSourceBeforeApproval = try await host.readFile(relativePath: path, rootPath: rootPath)
                } catch {
                    reportTool(path, output: "Cannot read existing file before edit: \(error.localizedDescription)", status: .failed)
                    return "Error: refused write because existing file could not be read for checkpointing: \(error.localizedDescription)"
                }
            } else {
                expectedSourceBeforeApproval = nil
            }
            if thread.permissionMode == .supervised {
                let decision = await hooks.onRequestApproval(AIAgentApprovalRequest(
                    kind: .fileWrite,
                    title: "Write file \(path)",
                    detail: "Create or overwrite \(path) (\(content.count) characters).",
                    filePath: path,
                    diffPreview: String(content.prefix(800))
                ))
                if decision == .deny {
                    reportTool(path, output: "Denied by user.", status: .denied)
                    return "User denied writing \(path)."
                }
            }
            reportTool(path, status: .running)
            do {
                try await hooks.onRecordFileSnapshot(path)
                try await host.writeFile(
                    relativePath: path,
                    content: content,
                    expectedSourceText: expectedSourceBeforeApproval,
                    rootPath: rootPath
                )
                let change = AIAgentFileChangeSummary(path: path, kind: existedBeforeApproval ? .modified : .added)
                hooks.onEvent(.fileChangesUpdated(itemID: "fc-\(call.id)", changes: [change], status: .completed))
                reportTool(path, output: "Saved \(content.count) chars", status: .completed)
                return "Successfully wrote \(path)."
            } catch {
                reportTool(path, output: error.localizedDescription, status: .failed)
                return "Error: \(error.localizedDescription)"
            }

        case "replace_in_file":
            let path = (args["path"] as? String) ?? ""
            let target = (args["target"] as? String) ?? ""
            let replacement = (args["replacement"] as? String) ?? ""
            guard thread.permissionMode != .plan else {
                reportTool(path, output: "Blocked in Plan mode.", status: .denied)
                return "Blocked: currently in Plan (read-only) mode."
            }
            let originalBeforeApproval: String
            do {
                originalBeforeApproval = try await host.readFile(relativePath: path, rootPath: rootPath)
            } catch {
                reportTool(path, output: error.localizedDescription, status: .failed)
                return "Error: \(error.localizedDescription)"
            }
            guard !target.isEmpty, originalBeforeApproval.contains(target) else {
                reportTool(path, output: "Target text not found.", status: .failed)
                return "Error: target text not found in \(path)."
            }
            if thread.permissionMode == .supervised {
                let preview = "- \(target.prefix(300))\n+ \(replacement.prefix(300))"
                let decision = await hooks.onRequestApproval(AIAgentApprovalRequest(
                    kind: .fileWrite,
                    title: "Edit \(path)",
                    detail: "Replace matching snippet in \(path).",
                    filePath: path,
                    diffPreview: preview
                ))
                if decision == .deny {
                    reportTool(path, output: "Denied by user.", status: .denied)
                    return "User denied editing \(path)."
                }
            }
            reportTool(path, status: .running)
            do {
                try await hooks.onRecordFileSnapshot(path)
                let updated = originalBeforeApproval.replacingOccurrences(of: target, with: replacement)
                try await host.writeFile(
                    relativePath: path,
                    content: updated,
                    expectedSourceText: originalBeforeApproval,
                    rootPath: rootPath
                )
                let change = AIAgentFileChangeSummary(path: path, kind: .modified)
                hooks.onEvent(.fileChangesUpdated(itemID: "fc-\(call.id)", changes: [change], status: .completed))
                reportTool(path, output: "Updated \(path)", status: .completed)
                return "Successfully updated \(path)."
            } catch {
                reportTool(path, output: error.localizedDescription, status: .failed)
                return "Error: \(error.localizedDescription)"
            }

        case "run_command":
            let command = (args["command"] as? String) ?? ""
            guard thread.permissionMode != .plan else {
                hooks.onEvent(.commandUpdated(itemID: call.id, command: command, output: "Blocked in Plan mode.", exitCode: nil, status: .denied))
                return "Blocked: shell commands are disabled in Plan mode."
            }
            if thread.permissionMode == .supervised || thread.permissionMode == .autoEdit {
                let decision = await hooks.onRequestApproval(AIAgentApprovalRequest(
                    kind: .command,
                    title: "Run shell command",
                    detail: "Execute command in \(rootPath)",
                    command: command
                ))
                if decision == .deny {
                    hooks.onEvent(.commandUpdated(itemID: call.id, command: command, output: "Denied by user.", exitCode: nil, status: .denied))
                    return "User denied command execution."
                }
            }
            hooks.onEvent(.commandUpdated(itemID: call.id, command: command, output: "", exitCode: nil, status: .running))
            let result = await host.runShellCommand(command, rootPath: rootPath)
            hooks.onEvent(.commandUpdated(
                itemID: call.id,
                command: command,
                output: result.output,
                exitCode: result.exitCode,
                status: result.exitCode == 0 ? .completed : .failed
            ))
            return "Exit code: \(result.exitCode)\n\(result.output.prefix(16_000))"

        default:
            reportTool(call.argumentsJSON, output: "Unknown tool \(call.name)", status: .failed)
            return "Error: unknown tool '\(call.name)'."
        }
    }

    // MARK: - Direct HTTP Payload Builders

    private struct EncodedImage {
        let mimeType: String
        let base64Data: String
    }

    private enum ConversationMessage {
        case user(String, images: [EncodedImage])
        case assistant(text: String, toolCalls: [DirectHTTPToolInvocation])
        case toolResult(callID: String, name: String, output: String)
    }

    private static func seedConversationHistory(
        from thread: AIAgentThread,
        latestPrompt: String,
        latestImages: [EncodedImage] = []
    ) -> [ConversationMessage] {
        var result: [ConversationMessage] = []
        // Include up to last 8 completed turns for coherent multi-turn context.
        let recentCompleted = thread.turns.filter { $0.status == .completed }.suffix(8)
        for turn in recentCompleted {
            result.append(.user(turn.prompt, images: []))
            let assistantReply = turn.items
                .filter { $0.kind == .assistantText }
                .map(\.content)
                .joined(separator: "\n\n")
            if !assistantReply.isEmpty {
                result.append(.assistant(text: assistantReply, toolCalls: []))
            }
        }
        result.append(.user(latestPrompt, images: latestImages))
        return result
    }

    private static func resolvedEndpointURL(for provider: AIProviderProfile) -> URL? {
        guard let base = provider.endpointURL else { return nil }
        let suffix = provider.apiProtocol.endpointSuffix
        let normalizedPath = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.hasSuffix(suffix) {
            return base
        }
        return base.appendingPathComponent(suffix)
    }

    private static func directAgentSystemPrompt(
        rootPath: String,
        permissionMode: AIAgentPermissionMode,
        customInstructions: String
    ) -> String {
        var lines = [
            "You are Lithe AI Agent, an expert software engineering agent operating inside the user's macOS IDE.",
            "Active workspace root: \(rootPath)",
            "Permission mode: \(permissionMode.title) — \(permissionMode.summary)",
            "Use the provided tools to inspect files, search code, make targeted edits, and verify builds/tests.",
            "Keep explanations concise, cite file paths clearly, and never modify files outside the workspace."
        ]
        let extra = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            lines.append("Custom instructions:\n\(extra)")
        }
        return lines.joined(separator: "\n")
    }

    private static func toolDefinitions(permissionMode: AIAgentPermissionMode) -> [[String: Any]] {
        var defs: [[String: Any]] = [
            [
                "name": "list_files",
                "description": "List relative file paths in the active workspace.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "prefix": ["type": "string", "description": "Optional relative directory prefix."]
                    ]
                ]
            ],
            [
                "name": "read_file",
                "description": "Read a UTF-8 file relative to the active workspace root.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Relative path to read."]
                    ],
                    "required": ["path"]
                ]
            ],
            [
                "name": "search_files",
                "description": "Search for a text query across workspace files.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Text to search for."]
                    ],
                    "required": ["query"]
                ]
            ]
        ]
        if permissionMode != .plan {
            defs.append(contentsOf: [
                [
                    "name": "replace_in_file",
                    "description": "Replace an exact target snippet in an existing workspace file.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": ["type": "string"],
                            "target": ["type": "string"],
                            "replacement": ["type": "string"]
                        ],
                        "required": ["path", "target", "replacement"]
                    ]
                ],
                [
                    "name": "write_file",
                    "description": "Create or overwrite a file relative to the workspace root.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": ["type": "string"],
                            "content": ["type": "string"]
                        ],
                        "required": ["path", "content"]
                    ]
                ],
                [
                    "name": "run_command",
                    "description": "Execute a shell command in the workspace root (e.g., go test ./..., cargo check, pytest).",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": ["type": "string"]
                        ],
                        "required": ["command"]
                    ]
                ]
            ])
        }
        return defs
    }

    private static func makeDirectHTTPRequest(
        provider: AIProviderProfile,
        url: URL,
        apiKey: String?,
        systemPrompt: String,
        messages: [ConversationMessage],
        permissionMode: AIAgentPermissionMode,
        reasoningEffort: AIAgentReasoningEffort
    ) throws -> AIHTTPRequest {
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "text/event-stream"
        ]
        if let apiKey, !apiKey.isEmpty {
            switch provider.authentication {
            case .bearer:
                headers["Authorization"] = "Bearer \(apiKey)"
            case .apiKey:
                if provider.apiProtocol == .anthropicMessages {
                    headers["x-api-key"] = apiKey
                } else {
                    headers["Authorization"] = "Bearer \(apiKey)"
                }
            }
        }
        if provider.apiProtocol == .anthropicMessages {
            headers["anthropic-version"] = "2023-06-01"
        }

        let tools = toolDefinitions(permissionMode: permissionMode)
        let payload: [String: Any]
        switch provider.apiProtocol {
        case .responses:
            var inputItems: [[String: Any]] = []
            for msg in messages {
                switch msg {
                case .user(let text, let images):
                    if images.isEmpty {
                        inputItems.append(["role": "user", "content": text])
                    } else {
                        var parts: [[String: Any]] = [["type": "input_text", "text": text]]
                        for img in images {
                            parts.append([
                                "type": "input_image",
                                "image_url": "data:\(img.mimeType);base64,\(img.base64Data)"
                            ])
                        }
                        inputItems.append(["role": "user", "content": parts])
                    }
                case .assistant(let text, let toolCalls):
                    if !text.isEmpty {
                        inputItems.append(["role": "assistant", "content": text])
                    }
                    for call in toolCalls {
                        inputItems.append([
                            "type": "function_call",
                            "call_id": call.id,
                            "name": call.name,
                            "arguments": call.argumentsJSON
                        ])
                    }
                case .toolResult(let callID, _, let output):
                    inputItems.append([
                        "type": "function_call_output",
                        "call_id": callID,
                        "output": output
                    ])
                }
            }
            let responseTools = tools.map { def -> [String: Any] in
                [
                    "type": "function",
                    "name": def["name"] as Any,
                    "description": def["description"] as Any,
                    "parameters": def["parameters"] as Any
                ]
            }
            payload = [
                "model": provider.model,
                "instructions": systemPrompt,
                "input": inputItems,
                "tools": responseTools,
                "reasoning": ["effort": reasoningEffort.rawValue],
                "stream": true
            ]

        case .chatCompletions:
            var chatMessages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
            for msg in messages {
                switch msg {
                case .user(let text, let images):
                    if images.isEmpty {
                        chatMessages.append(["role": "user", "content": text])
                    } else {
                        var parts: [[String: Any]] = [["type": "text", "text": text]]
                        for img in images {
                            parts.append([
                                "type": "image_url",
                                "image_url": ["url": "data:\(img.mimeType);base64,\(img.base64Data)"]
                            ])
                        }
                        chatMessages.append(["role": "user", "content": parts])
                    }
                case .assistant(let text, let toolCalls):
                    var dict: [String: Any] = ["role": "assistant", "content": text]
                    if !toolCalls.isEmpty {
                        dict["tool_calls"] = toolCalls.map { call in
                            [
                                "id": call.id,
                                "type": "function",
                                "function": ["name": call.name, "arguments": call.argumentsJSON]
                            ] as [String: Any]
                        }
                    }
                    chatMessages.append(dict)
                case .toolResult(let callID, _, let output):
                    chatMessages.append([
                        "role": "tool",
                        "tool_call_id": callID,
                        "content": output
                    ])
                }
            }
            let chatTools = tools.map { def -> [String: Any] in
                ["type": "function", "function": def]
            }
            payload = [
                "model": provider.model,
                "messages": chatMessages,
                "tools": chatTools,
                "stream": true
            ]

        case .anthropicMessages:
            var anthropicMessages: [[String: Any]] = []
            for msg in messages {
                switch msg {
                case .user(let text, let images):
                    if images.isEmpty {
                        anthropicMessages.append(["role": "user", "content": text])
                    } else {
                        var blocks: [[String: Any]] = []
                        for img in images {
                            blocks.append([
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": img.mimeType,
                                    "data": img.base64Data
                                ]
                            ])
                        }
                        blocks.append(["type": "text", "text": text])
                        anthropicMessages.append(["role": "user", "content": blocks])
                    }
                case .assistant(let text, let toolCalls):
                    var blocks: [[String: Any]] = []
                    if !text.isEmpty {
                        blocks.append(["type": "text", "text": text])
                    }
                    for call in toolCalls {
                        let inputObj = (call.argumentsJSON.data(using: .utf8).flatMap {
                            try? JSONSerialization.jsonObject(with: $0)
                        }) ?? [String: Any]()
                        blocks.append([
                            "type": "tool_use",
                            "id": call.id,
                            "name": call.name,
                            "input": inputObj
                        ])
                    }
                    anthropicMessages.append(["role": "assistant", "content": blocks])
                case .toolResult(let callID, _, let output):
                    anthropicMessages.append([
                        "role": "user",
                        "content": [[
                            "type": "tool_result",
                            "tool_use_id": callID,
                            "content": output
                        ]]
                    ])
                }
            }
            let anthropicTools = tools.map { def -> [String: Any] in
                [
                    "name": def["name"] as Any,
                    "description": def["description"] as Any,
                    "input_schema": def["parameters"] as Any
                ]
            }
            payload = [
                "model": provider.model,
                "max_tokens": 4096,
                "system": systemPrompt,
                "messages": anthropicMessages,
                "tools": anthropicTools,
                "stream": true
            ]
        }

        let body = try JSONSerialization.data(withJSONObject: payload)
        return AIHTTPRequest(
            url: url,
            headers: headers,
            body: body,
            timeout: 180,
            allowsInsecureHTTP: provider.allowsInsecureHTTP
        )
    }
}

@MainActor
private final class MainActorParserBox {
    private var parser: ClaudeStreamJSONParser

    init(parser: ClaudeStreamJSONParser) {
        self.parser = parser
    }

    func parse(_ line: String) -> [AIAgentStreamEvent] {
        parser.parseLine(line)
    }
}

private final class ACPRuntimeStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _sessionID: String?

    var sessionID: String? { lock.withLock { _sessionID } }

    func setSessionID(_ id: String) {
        lock.withLock { _sessionID = id }
    }
}

private final class ACPTransportBudgetBox: @unchecked Sendable {
    private let lock = NSLock()
    private let maxQueuedBytes: Int
    private var queuedBytes = 0
    private var exceeded = false
    private var overflowHandler: (@Sendable () -> Void)?

    init(maxQueuedBytes: Int) {
        self.maxQueuedBytes = maxQueuedBytes
    }

    var isExceeded: Bool { lock.withLock { exceeded } }

    func setOverflowHandler(_ handler: (@Sendable () -> Void)?) {
        let shouldFireImmediately: Bool = lock.withLock {
            overflowHandler = handler
            return exceeded && handler != nil
        }
        if shouldFireImmediately {
            handler?()
        }
    }

    func triggerOverflowHandler() {
        let handler: (@Sendable () -> Void)? = lock.withLock { overflowHandler }
        handler?()
    }

    /// Records incoming bytes before enqueueing; returns `false` once the hard cap is breached.
    func recordEnqueue(bytes: Int) -> Bool {
        lock.withLock {
            if exceeded { return false }
            queuedBytes += max(0, bytes)
            if queuedBytes > maxQueuedBytes {
                exceeded = true
                return false
            }
            return true
        }
    }

    func recordDequeue(bytes: Int) {
        lock.withLock {
            queuedBytes = max(0, queuedBytes - max(0, bytes))
        }
    }
}
