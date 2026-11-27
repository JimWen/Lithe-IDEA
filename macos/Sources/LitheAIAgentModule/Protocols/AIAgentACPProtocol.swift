import Foundation
import LitheCoreContracts

public enum ACPJSONRPCID: Equatable, Hashable, Sendable {
    case int(Int)
    case string(String)

    public var rawJSONValue: Any {
        switch self {
        case .int(let value): value
        case .string(let value): value
        }
    }

    public static func parse(_ value: Any?) -> ACPJSONRPCID? {
        if let str = value as? String {
            return .string(str)
        }
        if let num = value as? NSNumber {
            // Avoid mistaking JSON booleans for integers.
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
            return .int(num.intValue)
        }
        return nil
    }
}

public struct ACPPermissionOption: Equatable, Sendable {
    public let optionID: String
    public let name: String
    public let kind: String

    public init(optionID: String, name: String, kind: String) {
        self.optionID = optionID
        self.name = name
        self.kind = kind
    }
}

public struct ACPResponsePayload: Equatable, Sendable {
    public let sessionID: String?
    public let availableModeIDs: [String]
    public let supportedThoughtLevels: [String]
    public let usage: AIAgentTokenUsage?
    public let stopReason: String?

    public init(
        sessionID: String? = nil,
        availableModeIDs: [String] = [],
        supportedThoughtLevels: [String] = [],
        usage: AIAgentTokenUsage? = nil,
        stopReason: String? = nil
    ) {
        self.sessionID = sessionID
        self.availableModeIDs = availableModeIDs
        self.supportedThoughtLevels = supportedThoughtLevels
        self.usage = usage
        self.stopReason = stopReason
    }
}

public enum ACPIncomingMessage: Sendable {
    case response(id: ACPJSONRPCID, payload: ACPResponsePayload, errorMessage: String?)
    case sessionUpdate(sessionID: String, events: [AIAgentStreamEvent])
    case permissionRequest(id: ACPJSONRPCID, request: AIAgentApprovalRequest, options: [ACPPermissionOption])
    case ignored
}

/// Encodes ACP (Agent Client Protocol) v1 JSON-RPC 2.0 requests and notifications for `agy acp`.
public enum ACPJSONRPCBuilder {
    public static func antigravityModeID(for permissionMode: AIAgentPermissionMode) -> String {
        switch permissionMode {
        case .plan: "plan"
        case .supervised: "default"
        case .autoEdit: "accept-edits"
        case .fullAuto: "auto"
        }
    }

    public static func encodeLine(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    public static func initializeRequest(id: Int) throws -> Data {
        try encodeLine([
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": 1,
                "clientCapabilities": [String: Any](),
                "clientInfo": [
                    "name": "Lithe",
                    "version": "0.1.0"
                ]
            ]
        ])
    }

    public static func sessionNewRequest(id: Int, cwd: String) throws -> Data {
        try encodeLine([
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/new",
            "params": [
                "cwd": cwd,
                "mcpServers": [Any]()
            ]
        ])
    }

    public static func sessionResumeRequest(id: Int, sessionID: String, cwd: String) throws -> Data {
        try encodeLine([
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/resume",
            "params": [
                "sessionId": sessionID,
                "cwd": cwd,
                "mcpServers": [Any]()
            ]
        ])
    }

    public static func sessionSetModeRequest(id: Int, sessionID: String, modeID: String) throws -> Data {
        try encodeLine([
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/set_mode",
            "params": [
                "sessionId": sessionID,
                "modeId": modeID
            ]
        ])
    }

    public static func sessionSetModelRequest(id: Int, sessionID: String, modelID: String) throws -> Data {
        try encodeLine([
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/set_model",
            "params": [
                "sessionId": sessionID,
                "modelId": modelID
            ]
        ])
    }

    public static func sessionSetConfigOptionRequest(
        id: Int,
        sessionID: String,
        configID: String,
        value: String
    ) throws -> Data {
        try encodeLine([
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/set_config_option",
            "params": [
                "sessionId": sessionID,
                "configId": configID,
                "value": value
            ]
        ])
    }

    public static func sessionPromptRequest(
        id: Int,
        sessionID: String,
        text: String,
        images: [(mimeType: String, base64Data: String)] = []
    ) throws -> Data {
        var blocks: [[String: Any]] = [
            ["type": "text", "text": text]
        ]
        for image in images {
            blocks.append([
                "type": "image",
                "mimeType": image.mimeType,
                "data": image.base64Data
            ])
        }
        return try encodeLine([
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/prompt",
            "params": [
                "sessionId": sessionID,
                "prompt": blocks
            ]
        ])
    }

    public static func sessionCancelNotification(sessionID: String) throws -> Data {
        try encodeLine([
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": [
                "sessionId": sessionID
            ]
        ])
    }

    public static func permissionResponse(
        requestID: ACPJSONRPCID,
        decision: AIAgentApprovalDecision,
        options: [ACPPermissionOption]
    ) throws -> Data {
        let outcome: [String: Any]
        switch decision {
        case .allowOnce:
            // Never silently escalate a one-time approval into a persistent `allow_always`
            // authorization or an unknown option kind.
            if let optionID = options.first(where: { $0.kind == "allow_once" })?.optionID {
                outcome = ["outcome": "selected", "optionId": optionID]
            } else {
                outcome = ["outcome": "cancelled"]
            }
        case .allowAlways:
            // Prefer persistent approval, or safely narrow to `allow_once` if unavailable;
            // never fall back to an arbitrary option that could be a rejection or unknown action.
            let optionID = options.first(where: { $0.kind == "allow_always" })?.optionID
                ?? options.first(where: { $0.kind == "allow_once" })?.optionID
            if let optionID {
                outcome = ["outcome": "selected", "optionId": optionID]
            } else {
                outcome = ["outcome": "cancelled"]
            }
        case .deny:
            if let rejectID = options.first(where: { $0.kind == "reject_once" || $0.kind == "reject_always" })?.optionID {
                outcome = ["outcome": "selected", "optionId": rejectID]
            } else {
                outcome = ["outcome": "cancelled"]
            }
        }
        return try encodeLine([
            "jsonrpc": "2.0",
            "id": requestID.rawJSONValue,
            "result": [
                "outcome": outcome
            ]
        ])
    }
}

/// Stateful parser for incoming ACP JSON-RPC 2.0 lines emitted by `agy acp`.
public struct ACPStreamParser: Sendable {
    private var messageSegmentIndex = 0
    private var thoughtSegmentIndex = 0
    private var lastUpdateKind = ""
    private var toolNamesByID: [String: String] = [:]
    private var toolKindsByID: [String: String] = [:]
    private var toolCommandsByID: [String: String] = [:]
    private var toolSummariesByID: [String: String] = [:]

    public init() {}

    public mutating func parseLine(_ rawLine: String) -> ACPIncomingMessage {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignored
        }

        let method = json["method"] as? String
        let parsedID = ACPJSONRPCID.parse(json["id"])

        // Server -> Client JSON-RPC request (e.g. interactive `session/request_permission`).
        if let method, let requestID = parsedID {
            if method == "session/request_permission",
               let params = json["params"] as? [String: Any] {
                let parsed = parsePermissionRequest(params)
                return .permissionRequest(id: requestID, request: parsed.request, options: parsed.options)
            }
            return .ignored
        }

        // Server -> Client JSON-RPC notification (`session/update`).
        if let method {
            if method == "session/update",
               let params = json["params"] as? [String: Any],
               let update = params["update"] as? [String: Any] {
                let sessionID = (params["sessionId"] as? String) ?? ""
                let events = parseSessionUpdate(update)
                return .sessionUpdate(sessionID: sessionID, events: events)
            }
            return .ignored
        }

        // Response to a Client -> Server JSON-RPC request.
        if let responseID = parsedID {
            let result = json["result"] as? [String: Any]
            var errorMessage: String?
            if let errorDict = json["error"] as? [String: Any] {
                let msg = (errorDict["message"] as? String) ?? "ACP request failed."
                if let detail = errorDict["data"] as? String, !detail.isEmpty {
                    errorMessage = "\(msg): \(detail)"
                } else {
                    errorMessage = msg
                }
            }
            let payload = Self.parseResponsePayload(result)
            return .response(id: responseID, payload: payload, errorMessage: errorMessage)
        }

        return .ignored
    }

    private static func parseResponsePayload(_ result: [String: Any]?) -> ACPResponsePayload {
        guard let result else { return ACPResponsePayload() }
        let sessionID = result["sessionId"] as? String
        let availableModeIDs: [String] = {
            guard let modes = result["modes"] as? [String: Any],
                  let list = modes["availableModes"] as? [[String: Any]] else {
                return []
            }
            return list.compactMap { $0["id"] as? String }
        }()
        let supportedThoughtLevels: [String] = {
            guard let configOptions = result["configOptions"] as? [[String: Any]],
                  let thoughtOpt = configOptions.first(where: { ($0["id"] as? String) == "thought_level" }),
                  let options = thoughtOpt["options"] as? [[String: Any]] else {
                return []
            }
            return options.compactMap { $0["value"] as? String }
        }()
        let usage = parsePromptUsage(from: result)
        let stopReason = result["stopReason"] as? String
        return ACPResponsePayload(
            sessionID: sessionID,
            availableModeIDs: availableModeIDs,
            supportedThoughtLevels: supportedThoughtLevels,
            usage: usage,
            stopReason: stopReason
        )
    }

    public static func parsePromptUsage(from result: [String: Any]?) -> AIAgentTokenUsage? {
        guard let usage = result?["usage"] as? [String: Any] else { return nil }
        let input = (usage["inputTokens"] as? NSNumber)?.intValue
            ?? (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
        let cached = (usage["cachedReadTokens"] as? NSNumber)?.intValue
            ?? (usage["cached_read_tokens"] as? NSNumber)?.intValue ?? 0
        let output = (usage["outputTokens"] as? NSNumber)?.intValue
            ?? (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
        let reasoning = (usage["thoughtTokens"] as? NSNumber)?.intValue
            ?? (usage["reasoningTokens"] as? NSNumber)?.intValue ?? 0
        guard input > 0 || output > 0 || reasoning > 0 else { return nil }
        return AIAgentTokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningTokens: reasoning
        )
    }

    private mutating func parseSessionUpdate(_ update: [String: Any]) -> [AIAgentStreamEvent] {
        guard let kind = update["sessionUpdate"] as? String else { return [] }
        defer { lastUpdateKind = kind }

        switch kind {
        case "agent_message_chunk":
            if lastUpdateKind != "agent_message_chunk" {
                messageSegmentIndex += 1
            }
            guard let content = update["content"] as? [String: Any],
                  let text = content["text"] as? String, !text.isEmpty else {
                return []
            }
            return [.assistantTextDelta(
                itemID: "acp-msg-\(messageSegmentIndex)",
                text: text,
                isReplacement: false
            )]

        case "agent_thought_chunk":
            if lastUpdateKind != "agent_thought_chunk" {
                thoughtSegmentIndex += 1
            }
            guard let content = update["content"] as? [String: Any],
                  let text = content["text"] as? String, !text.isEmpty else {
                return []
            }
            return [.reasoningDelta(
                itemID: "acp-thought-\(thoughtSegmentIndex)",
                text: text,
                isReplacement: false
            )]

        case "tool_call", "tool_call_update":
            return parseToolCallUpdate(update)

        case "plan":
            if let entries = update["entries"] as? [[String: Any]] {
                let lines = entries.compactMap { entry -> String? in
                    guard let content = entry["content"] as? String, !content.isEmpty else { return nil }
                    let status = (entry["status"] as? String) ?? "pending"
                    let marker = status == "completed" ? "[x]" : (status == "in_progress" ? "[~]" : "[ ]")
                    return "\(marker) \(content)"
                }
                if !lines.isEmpty {
                    return [.toolCallUpdated(
                        itemID: "acp-plan",
                        name: "Plan",
                        inputSummary: "\(lines.count) steps",
                        output: lines.joined(separator: "\n"),
                        status: .completed
                    )]
                }
            }
            return []

        default:
            return []
        }
    }

    private mutating func parseToolCallUpdate(_ update: [String: Any]) -> [AIAgentStreamEvent] {
        let toolCallID = (update["toolCallId"] as? String) ?? UUID().uuidString
        let rawName = (update["name"] as? String)
            ?? toolNamesByID[toolCallID]
            ?? (update["title"] as? String)
            ?? "Tool"
        let toolKind = (update["kind"] as? String) ?? toolKindsByID[toolCallID] ?? ""
        toolNamesByID[toolCallID] = rawName
        if !toolKind.isEmpty { toolKindsByID[toolCallID] = toolKind }

        let status = Self.mapToolStatus(update["status"] as? String)
        let rawInput = (update["rawInput"] as? [String: Any]) ?? (update["args"] as? [String: Any])
        let title = (update["title"] as? String) ?? rawName

        let isCommandTool = toolKind == "execute"
            || rawName == "run_command"
            || rawName == "bash"
            || rawName == "Bash"

        if isCommandTool {
            let command = (rawInput?["CommandLine"] as? String)
                ?? (rawInput?["command"] as? String)
                ?? toolCommandsByID[toolCallID]
                ?? title
            toolCommandsByID[toolCallID] = command
            let (output, exitCode) = Self.extractToolOutputAndExitCode(update)
            return [.commandUpdated(
                itemID: toolCallID,
                command: command,
                output: output,
                exitCode: exitCode,
                status: status
            )]
        }

        let summary = Self.extractToolInputSummary(rawInput: rawInput, title: title, fallback: toolSummariesByID[toolCallID] ?? "")
        if !summary.isEmpty { toolSummariesByID[toolCallID] = summary }
        let (output, _) = Self.extractToolOutputAndExitCode(update)

        var events: [AIAgentStreamEvent] = [
            .toolCallUpdated(
                itemID: toolCallID,
                name: rawName,
                inputSummary: summary,
                output: output,
                status: status
            )
        ]

        if status == .completed,
           let editedPath = Self.extractEditedFilePath(name: rawName, kind: toolKind, rawInput: rawInput) {
            let changeKind: AIAgentFileChangeKind = rawName.contains("write") ? .added : .modified
            events.append(.fileChangesUpdated(
                itemID: "acp-fc-\(toolCallID)",
                changes: [AIAgentFileChangeSummary(path: editedPath, kind: changeKind)],
                status: .completed
            ))
        }
        return events
    }

    private func parsePermissionRequest(_ params: [String: Any]) -> (request: AIAgentApprovalRequest, options: [ACPPermissionOption]) {
        let toolCall = params["toolCall"] as? [String: Any]
        let rawName = (toolCall?["name"] as? String) ?? "Tool"
        let toolKind = (toolCall?["kind"] as? String) ?? ""
        let title = (toolCall?["title"] as? String) ?? rawName
        let rawInput = (toolCall?["rawInput"] as? [String: Any]) ?? (toolCall?["args"] as? [String: Any])

        let command = (rawInput?["CommandLine"] as? String) ?? (rawInput?["command"] as? String)
        let filePath = (rawInput?["Path"] as? String)
            ?? (rawInput?["TargetFile"] as? String)
            ?? (rawInput?["path"] as? String)

        let approvalKind: AIAgentApprovalKind
        if toolKind == "delete" {
            approvalKind = .fileDelete
        } else if toolKind == "edit" || filePath != nil {
            approvalKind = .fileWrite
        } else {
            approvalKind = .command
        }

        let displayTitle: String
        let detail: String
        if let command, !command.isEmpty {
            displayTitle = "Approve Antigravity command"
            detail = (rawInput?["toolSummary"] as? String) ?? "Allow `\(rawName)` to execute in the workspace?"
        } else if let filePath, !filePath.isEmpty {
            displayTitle = "Approve file edit: \((filePath as NSString).lastPathComponent)"
            detail = "Allow Antigravity (`\(rawName)`) to modify \(filePath)?"
        } else {
            displayTitle = "Approve \(title)"
            detail = "Allow Antigravity to execute tool `\(rawName)`?"
        }

        let rawOptions = (params["options"] as? [[String: Any]]) ?? []
        let options: [ACPPermissionOption] = rawOptions.compactMap { entry in
            guard let id = entry["optionId"] as? String, !id.isEmpty else { return nil }
            let name = (entry["name"] as? String) ?? id
            let kind = (entry["kind"] as? String) ?? "allow_once"
            return ACPPermissionOption(optionID: id, name: name, kind: kind)
        }

        let hasAllowOnce = options.contains(where: { $0.kind == "allow_once" })
        let hasAllowAlways = options.contains(where: { $0.kind == "allow_always" })

        let request = AIAgentApprovalRequest(
            kind: approvalKind,
            title: displayTitle,
            detail: detail,
            command: command,
            filePath: filePath,
            allowsAllowOnce: options.isEmpty ? true : hasAllowOnce,
            allowsAllowAlways: options.isEmpty ? true : hasAllowAlways,
            cacheAlwaysAllowByKind: false
        )
        return (request, options)
    }

    private static func mapToolStatus(_ raw: String?) -> AIAgentToolCallStatus {
        switch (raw ?? "").lowercased() {
        case "pending": .waitingApproval
        case "in_progress", "running": .running
        case "completed", "done", "succeeded": .completed
        case "failed", "error": .failed
        case "cancelled", "canceled", "denied", "rejected": .denied
        default: .running
        }
    }

    private static func extractToolInputSummary(
        rawInput: [String: Any]?,
        title: String,
        fallback: String
    ) -> String {
        if let rawInput {
            for key in ["Path", "TargetFile", "path", "CommandLine", "command", "Query", "query", "Pattern", "toolSummary"] {
                if let val = rawInput[key] as? String, !val.isEmpty {
                    return val
                }
            }
            let compact = CodexJSONLParser.compactJSON(rawInput)
            if !compact.isEmpty && compact != "{}" {
                return String(compact.prefix(240))
            }
        }
        return title.isEmpty ? fallback : title
    }

    private static func extractToolOutputAndExitCode(_ update: [String: Any]) -> (output: String, exitCode: Int32?) {
        var exitCode: Int32?
        if let rawOutput = update["rawOutput"] as? [String: Any] {
            if let code = (rawOutput["exitCode"] as? NSNumber) ?? (rawOutput["exit_code"] as? NSNumber) {
                exitCode = Int32(code.intValue)
            }
            if let out = rawOutput["output"] as? String, !out.isEmpty {
                return (out, exitCode)
            }
            if let stdout = rawOutput["stdout"] as? String, !stdout.isEmpty {
                return (stdout, exitCode)
            }
            let compact = CodexJSONLParser.compactJSON(rawOutput)
            if !compact.isEmpty && compact != "{}" {
                return (compact, exitCode)
            }
        } else if let rawOutputString = update["rawOutput"] as? String, !rawOutputString.isEmpty {
            return (rawOutputString, exitCode)
        }
        if let contentArray = update["content"] as? [[String: Any]] {
            let texts = contentArray.compactMap { entry -> String? in
                if let inner = entry["content"] as? [String: Any], let text = inner["text"] as? String {
                    return text
                }
                return entry["text"] as? String
            }
            if !texts.isEmpty {
                return (texts.joined(separator: "\n"), exitCode)
            }
        }
        return ("", exitCode)
    }

    private static func extractEditedFilePath(
        name: String,
        kind: String,
        rawInput: [String: Any]?
    ) -> String? {
        let lowerName = name.lowercased()
        let isEdit = kind == "edit"
            || lowerName.contains("write_file")
            || lowerName.contains("write_to_file")
            || lowerName.contains("edit_file")
            || lowerName.contains("replace_file")
        guard isEdit, let rawInput else { return nil }
        for key in ["Path", "TargetFile", "path"] {
            if let path = rawInput[key] as? String, !path.isEmpty {
                return path
            }
        }
        return nil
    }
}
