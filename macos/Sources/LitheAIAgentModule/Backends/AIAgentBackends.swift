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
        }
    }
}

/// Executes AI Agent turns across Codex CLI, Claude Code CLI, and Direct HTTP Streaming.
public struct AIAgentTurnRunner: Sendable {
    private let processFactory: any AIAgentProcessSessionFactory
    private let cliResolver: any AIAgentCLIResolving
    private let streamingTransport: any AIHTTPStreamingTransport
    private let credentialResolver: any AIProviderCredentialResolver

    public init(
        processFactory: any AIAgentProcessSessionFactory,
        cliResolver: any AIAgentCLIResolving,
        streamingTransport: any AIHTTPStreamingTransport,
        credentialResolver: any AIProviderCredentialResolver
    ) {
        self.processFactory = processFactory
        self.cliResolver = cliResolver
        self.streamingTransport = streamingTransport
        self.credentialResolver = credentialResolver
    }

    public static func buildCodexArguments(
        thread: AIAgentThread,
        workingDirectory: String
    ) -> [String] {
        var args: [String] = ["exec"]
        if let sessionID = thread.providerSessionID, !sessionID.isEmpty {
            args.append(contentsOf: ["resume", sessionID, "--json", "--skip-git-repo-check"])
            let trimmedModel = thread.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedModel.isEmpty {
                args.append(contentsOf: ["-m", trimmedModel])
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
        switch thread.permissionMode {
        case .plan:
            args.append(contentsOf: ["--permission-mode", "plan"])
        case .supervised:
            args.append(contentsOf: ["--permission-mode", "default"])
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
        let composedPrompt = await AIAgentPromptBuilder.buildPrompt(
            userPrompt: prompt,
            attachments: attachments,
            customInstructions: settings.customSystemInstructions,
            permissionMode: thread.permissionMode,
            rootPath: thread.effectiveRootPath,
            host: host
        )

        switch thread.backend {
        case .codexCLI:
            try await runCodexCLI(
                thread: thread,
                prompt: composedPrompt,
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
                host: host,
                hooks: hooks
            )
        }
    }

    @MainActor
    private func runCodexCLI(
        thread: AIAgentThread,
        prompt: String,
        settings: AIAgentSettings,
        hooks: AIAgentTurnExecutionHooks
    ) async throws {
        guard let executable = await cliResolver.resolveExecutable(for: .codexCLI, settings: settings) else {
            throw AIAgentBackendError.executableNotFound(.codexCLI)
        }
        let args = Self.buildCodexArguments(thread: thread, workingDirectory: thread.effectiveRootPath)
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

        var conversationMessages = Self.seedConversationHistory(from: thread, latestPrompt: userPrompt)
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

    private enum ConversationMessage {
        case user(String)
        case assistant(text: String, toolCalls: [DirectHTTPToolInvocation])
        case toolResult(callID: String, name: String, output: String)
    }

    private static func seedConversationHistory(from thread: AIAgentThread, latestPrompt: String) -> [ConversationMessage] {
        var result: [ConversationMessage] = []
        // Include up to last 8 completed turns for coherent multi-turn context.
        let recentCompleted = thread.turns.filter { $0.status == .completed }.suffix(8)
        for turn in recentCompleted {
            result.append(.user(turn.prompt))
            let assistantReply = turn.items
                .filter { $0.kind == .assistantText }
                .map(\.content)
                .joined(separator: "\n\n")
            if !assistantReply.isEmpty {
                result.append(.assistant(text: assistantReply, toolCalls: []))
            }
        }
        result.append(.user(latestPrompt))
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
                case .user(let text):
                    inputItems.append(["role": "user", "content": text])
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
                case .user(let text):
                    chatMessages.append(["role": "user", "content": text])
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
                case .user(let text):
                    anthropicMessages.append(["role": "user", "content": text])
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
