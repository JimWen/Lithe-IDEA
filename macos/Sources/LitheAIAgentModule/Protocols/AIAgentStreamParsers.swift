import Foundation
import LitheCoreContracts

public enum AIAgentStreamEvent: Equatable, Sendable {
    case sessionEstablished(String)
    case assistantTextDelta(itemID: String, text: String, isReplacement: Bool)
    case reasoningDelta(itemID: String, text: String, isReplacement: Bool)
    case commandUpdated(
        itemID: String,
        command: String,
        output: String,
        exitCode: Int32?,
        status: AIAgentToolCallStatus
    )
    case toolCallUpdated(
        itemID: String,
        name: String,
        inputSummary: String,
        output: String,
        status: AIAgentToolCallStatus
    )
    case fileChangesUpdated(
        itemID: String,
        changes: [AIAgentFileChangeSummary],
        status: AIAgentToolCallStatus
    )
    case systemNotice(String)
    case usage(AIAgentTokenUsage)
    case failed(String)
}

/// Incremental UTF-8 line splitter that tolerates arbitrary pipe chunk boundaries
/// and bounds per-line memory so runaway subprocess output cannot exhaust RAM.
public struct AIAgentLineBuffer: Sendable {
    public static let defaultMaxLineBytes = 1_048_576
    private var buffer = Data()
    private let maxLineBytes: Int
    private var discardingOversizedLine = false

    public init(maxLineBytes: Int = AIAgentLineBuffer.defaultMaxLineBytes) {
        self.maxLineBytes = max(1024, maxLineBytes)
    }

    public mutating func append(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }
        var lines: [String] = []
        let newline: UInt8 = 0x0A
        var cursor = chunk.startIndex

        while cursor < chunk.endIndex {
            if let nlIndex = chunk[cursor...].firstIndex(of: newline) {
                if discardingOversizedLine {
                    discardingOversizedLine = false
                    buffer.removeAll(keepingCapacity: true)
                } else {
                    let slice = chunk[cursor..<nlIndex]
                    if buffer.count + slice.count <= maxLineBytes {
                        buffer.append(contentsOf: slice)
                        if buffer.last == 0x0D { buffer.removeLast() }
                        lines.append(String(decoding: buffer, as: UTF8.self))
                    }
                    buffer.removeAll(keepingCapacity: true)
                }
                cursor = chunk.index(after: nlIndex)
            } else {
                if !discardingOversizedLine {
                    let remaining = chunk[cursor...]
                    if buffer.count + remaining.count > maxLineBytes {
                        buffer.removeAll(keepingCapacity: false)
                        discardingOversizedLine = true
                    } else {
                        buffer.append(contentsOf: remaining)
                    }
                }
                break
            }
        }
        return lines
    }

    public mutating func flushRemainder() -> String? {
        if discardingOversizedLine {
            discardingOversizedLine = false
            buffer.removeAll(keepingCapacity: false)
            return nil
        }
        guard !buffer.isEmpty else { return nil }
        var lineData = buffer
        if lineData.last == 0x0D {
            lineData.removeLast()
        }
        buffer.removeAll(keepingCapacity: false)
        let text = String(decoding: lineData, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}

/// Parses JSONL events emitted by `codex exec --json` and `codex exec resume --json`.
public struct CodexJSONLParser: Sendable {
    public init() {}

    public func parseLine(_ rawLine: String) -> [AIAgentStreamEvent] {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return []
        }

        switch type {
        case "thread.started":
            if let threadID = json["thread_id"] as? String, !threadID.isEmpty {
                return [.sessionEstablished(threadID)]
            }
            return []

        case "item.started", "item.updated", "item.completed":
            guard let item = json["item"] as? [String: Any] else { return [] }
            return parseItem(item, eventType: type)

        case "turn.completed":
            if let usage = parseUsage(json["usage"] as? [String: Any]) {
                return [.usage(usage)]
            }
            return []

        case "turn.failed":
            let errorDict = json["error"] as? [String: Any]
            let rawMessage = (errorDict?["message"] as? String)
                ?? (json["message"] as? String)
                ?? "Codex turn failed."
            return [.failed(Self.humanizeErrorMessage(rawMessage))]

        case "error":
            if let rawMessage = json["message"] as? String, !rawMessage.isEmpty {
                return [.failed(Self.humanizeErrorMessage(rawMessage))]
            }
            return []

        default:
            return []
        }
    }

    private func parseItem(_ item: [String: Any], eventType: String) -> [AIAgentStreamEvent] {
        let itemID = (item["id"] as? String) ?? UUID().uuidString
        let itemType = (item["type"] as? String) ?? ""
        let rawStatus = (item["status"] as? String) ?? ""
        let status: AIAgentToolCallStatus = {
            switch rawStatus {
            case "in_progress", "running": return .running
            case "failed", "error": return .failed
            case "completed", "done": return .completed
            default:
                return eventType == "item.completed" ? .completed : .running
            }
        }()

        switch itemType {
        case "agent_message", "assistant_message", "message":
            let text = extractText(from: item)
            guard !text.isEmpty else { return [] }
            return [.assistantTextDelta(itemID: itemID, text: text, isReplacement: true)]

        case "reasoning":
            let text = extractText(from: item)
            guard !text.isEmpty else { return [] }
            return [.reasoningDelta(itemID: itemID, text: text, isReplacement: true)]

        case "command_execution":
            let command = (item["command"] as? String) ?? ""
            let output = (item["aggregated_output"] as? String)
                ?? (item["output"] as? String)
                ?? ""
            let exitCode: Int32? = (item["exit_code"] as? NSNumber).map { Int32($0.intValue) }
            let resolvedStatus: AIAgentToolCallStatus
            if let exitCode, exitCode != 0, eventType == "item.completed" {
                resolvedStatus = .failed
            } else {
                resolvedStatus = status
            }
            return [.commandUpdated(
                itemID: itemID,
                command: command,
                output: output,
                exitCode: exitCode,
                status: resolvedStatus
            )]

        case "file_change":
            let rawChanges = (item["changes"] as? [[String: Any]]) ?? []
            let summaries: [AIAgentFileChangeSummary] = rawChanges.compactMap { entry in
                guard let path = entry["path"] as? String, !path.isEmpty else { return nil }
                let kindString = ((entry["kind"] as? String) ?? "update").lowercased()
                let kind: AIAgentFileChangeKind
                switch kindString {
                case "add", "added", "create", "created": kind = .added
                case "delete", "deleted", "remove", "removed": kind = .deleted
                case "rename", "renamed", "move", "moved": kind = .renamed
                default: kind = .modified
                }
                return AIAgentFileChangeSummary(path: path, kind: kind)
            }
            guard !summaries.isEmpty else { return [] }
            return [.fileChangesUpdated(itemID: itemID, changes: summaries, status: status)]

        case "mcp_tool_call", "tool_call", "web_search":
            let server = item["server"] as? String
            let toolName = (item["tool"] as? String)
                ?? (item["name"] as? String)
                ?? (itemType == "web_search" ? "web_search" : "tool")
            let displayName = server.map { "\($0)/\(toolName)" } ?? toolName
            let inputSummary = (item["query"] as? String)
                ?? Self.compactJSON(item["arguments"] ?? item["input"])
            let output = Self.compactJSON(item["result"] ?? item["output"] ?? item["error"])
            return [.toolCallUpdated(
                itemID: itemID,
                name: displayName,
                inputSummary: inputSummary,
                output: output,
                status: status
            )]

        case "todo_list":
            if let items = item["items"] as? [[String: Any]] {
                let lines = items.compactMap { entry -> String? in
                    guard let text = entry["text"] as? String else { return nil }
                    let completed = (entry["completed"] as? Bool) ?? false
                    return "\(completed ? "[x]" : "[ ]") \(text)"
                }
                if !lines.isEmpty {
                    return [.toolCallUpdated(
                        itemID: itemID,
                        name: "Plan Checklist",
                        inputSummary: "\(items.count) items",
                        output: lines.joined(separator: "\n"),
                        status: status
                    )]
                }
            }
            return []

        case "error":
            let message = (item["message"] as? String) ?? ""
            guard !message.isEmpty else { return [] }
            // Codex emits non-fatal config deprecation notices as item.type == "error".
            if message.contains("ignoring") && message.contains("configuration settings") {
                return []
            }
            if message.contains("service tier") && message.contains("omitted") {
                return []
            }
            if message.contains("Model metadata") && message.contains("fallback metadata") {
                return []
            }
            return [.systemNotice(Self.humanizeErrorMessage(message))]

        default:
            return []
        }
    }

    private func extractText(from item: [String: Any]) -> String {
        if let text = item["text"] as? String { return text }
        if let content = item["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    private func parseUsage(_ usage: [String: Any]?) -> AIAgentTokenUsage? {
        guard let usage else { return nil }
        let input = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
        let cached = (usage["cached_input_tokens"] as? NSNumber)?.intValue ?? 0
        let output = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
        let reasoning = (usage["reasoning_output_tokens"] as? NSNumber)?.intValue ?? 0
        guard input > 0 || output > 0 else { return nil }
        return AIAgentTokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningTokens: reasoning
        )
    }

    static func humanizeErrorMessage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let nested = obj["error"] as? [String: Any],
               let message = nested["message"] as? String, !message.isEmpty {
                return message
            }
            if let message = obj["message"] as? String, !message.isEmpty {
                return message
            }
        }
        return trimmed
    }

    static func compactJSON(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Parses NDJSON events emitted by `claude -p --output-format stream-json --verbose --include-partial-messages`.
public struct ClaudeStreamJSONParser: Sendable {
    private var activeBlockItemIDs: [Int: String] = [:]
    private var activeBlockKinds: [Int: String] = [:]
    private var streamedMessageHasText = false
    private var toolNamesByID: [String: String] = [:]
    private var toolInputsByID: [String: String] = [:]

    public init() {}

    public mutating func parseLine(_ rawLine: String) -> [AIAgentStreamEvent] {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return []
        }

        switch type {
        case "system":
            if (json["subtype"] as? String) == "init",
               let sessionID = json["session_id"] as? String, !sessionID.isEmpty {
                return [.sessionEstablished(sessionID)]
            }
            return []

        case "stream_event":
            guard let event = json["event"] as? [String: Any] else { return [] }
            return parseStreamEvent(event)

        case "assistant":
            return parseAssistantMessage(json)

        case "user":
            return parseUserToolResults(json)

        case "result":
            return parseResult(json)

        default:
            return []
        }
    }

    private mutating func parseStreamEvent(_ event: [String: Any]) -> [AIAgentStreamEvent] {
        guard let eventType = event["type"] as? String else { return [] }
        switch eventType {
        case "message_start":
            activeBlockItemIDs.removeAll()
            activeBlockKinds.removeAll()
            streamedMessageHasText = false
            return []

        case "content_block_start":
            let index = (event["index"] as? NSNumber)?.intValue ?? 0
            let block = event["content_block"] as? [String: Any]
            let blockType = (block?["type"] as? String) ?? "text"
            let itemID = (block?["id"] as? String) ?? "claude-block-\(index)-\(UUID().uuidString.prefix(6))"
            activeBlockItemIDs[index] = itemID
            activeBlockKinds[index] = blockType
            if blockType == "tool_use" {
                let name = (block?["name"] as? String) ?? "Tool"
                toolNamesByID[itemID] = name
                return [.toolCallUpdated(
                    itemID: itemID,
                    name: name,
                    inputSummary: "",
                    output: "",
                    status: .running
                )]
            }
            return []

        case "content_block_delta":
            let index = (event["index"] as? NSNumber)?.intValue ?? 0
            let itemID = activeBlockItemIDs[index] ?? "claude-block-\(index)"
            guard let delta = event["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return [] }
            switch deltaType {
            case "text_delta":
                guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                streamedMessageHasText = true
                return [.assistantTextDelta(itemID: itemID, text: text, isReplacement: false)]
            case "thinking_delta":
                guard let thinking = delta["thinking"] as? String, !thinking.isEmpty else { return [] }
                return [.reasoningDelta(itemID: itemID, text: thinking, isReplacement: false)]
            default:
                return []
            }

        default:
            return []
        }
    }

    private mutating func parseAssistantMessage(_ json: [String: Any]) -> [AIAgentStreamEvent] {
        var events: [AIAgentStreamEvent] = []
        if let sessionID = json["session_id"] as? String, !sessionID.isEmpty {
            events.append(.sessionEstablished(sessionID))
        }
        guard let message = json["message"] as? [String: Any] else { return events }
        let messageID = (message["id"] as? String) ?? UUID().uuidString
        let isError = (json["is_api_error_message"] as? Bool) ?? false
        let contentBlocks = (message["content"] as? [[String: Any]]) ?? []

        for (index, block) in contentBlocks.enumerated() {
            let blockType = (block["type"] as? String) ?? ""
            switch blockType {
            case "text":
                let text = (block["text"] as? String) ?? ""
                guard !text.isEmpty else { continue }
                if isError {
                    events.append(.failed(text))
                } else if !streamedMessageHasText {
                    events.append(.assistantTextDelta(
                        itemID: "\(messageID)-text-\(index)",
                        text: text,
                        isReplacement: true
                    ))
                }

            case "thinking":
                let thinking = (block["thinking"] as? String) ?? ""
                guard !thinking.isEmpty else { continue }
                if !activeBlockKinds.values.contains("thinking") {
                    events.append(.reasoningDelta(
                        itemID: "\(messageID)-thinking-\(index)",
                        text: thinking,
                        isReplacement: true
                    ))
                }

            case "tool_use":
                let toolID = (block["id"] as? String) ?? "\(messageID)-tool-\(index)"
                let name = (block["name"] as? String) ?? "Tool"
                let input = CodexJSONLParser.compactJSON(block["input"])
                toolNamesByID[toolID] = name
                toolInputsByID[toolID] = input
                if name == "Bash",
                   let inputDict = block["input"] as? [String: Any],
                   let command = inputDict["command"] as? String {
                    events.append(.commandUpdated(
                        itemID: toolID,
                        command: command,
                        output: "",
                        exitCode: nil,
                        status: .running
                    ))
                } else {
                    events.append(.toolCallUpdated(
                        itemID: toolID,
                        name: name,
                        inputSummary: input,
                        output: "",
                        status: .running
                    ))
                }

            default:
                break
            }
        }
        streamedMessageHasText = false
        return events
    }

    private func parseUserToolResults(_ json: [String: Any]) -> [AIAgentStreamEvent] {
        guard let message = json["message"] as? [String: Any],
              let contentBlocks = message["content"] as? [[String: Any]] else {
            return []
        }
        var events: [AIAgentStreamEvent] = []
        for block in contentBlocks where (block["type"] as? String) == "tool_result" {
            let toolID = (block["tool_use_id"] as? String) ?? UUID().uuidString
            let isError = (block["is_error"] as? Bool) ?? false
            let output: String
            if let text = block["content"] as? String {
                output = text
            } else if let array = block["content"] as? [[String: Any]] {
                output = array.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                output = ""
            }
            let toolName = toolNamesByID[toolID] ?? "Tool"
            if toolName == "Bash" {
                let command = extractCommand(fromJSON: toolInputsByID[toolID] ?? "")
                events.append(.commandUpdated(
                    itemID: toolID,
                    command: command,
                    output: output,
                    exitCode: isError ? 1 : 0,
                    status: isError ? .failed : .completed
                ))
            } else {
                events.append(.toolCallUpdated(
                    itemID: toolID,
                    name: toolName,
                    inputSummary: toolInputsByID[toolID] ?? "",
                    output: output,
                    status: isError ? .failed : .completed
                ))
            }
        }
        return events
    }

    private func parseResult(_ json: [String: Any]) -> [AIAgentStreamEvent] {
        var events: [AIAgentStreamEvent] = []
        if let sessionID = json["session_id"] as? String, !sessionID.isEmpty {
            events.append(.sessionEstablished(sessionID))
        }
        if let usage = json["usage"] as? [String: Any] {
            let input = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
            let cached = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
            let output = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
            let cost = (json["total_cost_usd"] as? NSNumber)?.doubleValue
            if input > 0 || output > 0 || (cost ?? 0) > 0 {
                events.append(.usage(AIAgentTokenUsage(
                    inputTokens: input,
                    cachedInputTokens: cached,
                    outputTokens: output,
                    reasoningTokens: 0,
                    costUSD: cost
                )))
            }
        }
        if (json["is_error"] as? Bool) == true,
           let resultText = json["result"] as? String, !resultText.isEmpty {
            events.append(.failed(resultText))
        }
        return events
    }

    private func extractCommand(fromJSON jsonString: String) -> String {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = dict["command"] as? String else {
            return jsonString
        }
        return command
    }
}

public struct DirectHTTPToolInvocation: Equatable, Sendable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct DirectHTTPStreamState: Sendable {
    public var assistantText = ""
    public var reasoningText = ""
    public var toolCalls: [DirectHTTPToolInvocation] = []
    public var usage: AIAgentTokenUsage?
    public var errorMessage: String?

    private var openAIChatToolCallBuilders: [Int: (id: String, name: String, arguments: String)] = [:]
    private var openAIResponseCallsByItemID: [String: (callID: String, name: String, arguments: String)] = [:]
    private var anthropicToolCallsByIndex: [Int: (id: String, name: String, arguments: String)] = [:]
    private var currentSSEEventName: String?

    public init() {}

    public mutating func consumeSSELine(
        _ line: String,
        protocol apiProtocol: CommitMessageAPIProtocol,
        assistantItemID: String,
        reasoningItemID: String
    ) -> [AIAgentStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            currentSSEEventName = nil
            return []
        }
        if trimmed.hasPrefix("event:") {
            currentSSEEventName = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return []
        }
        guard trimmed.hasPrefix("data:") else { return [] }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" || payload.isEmpty {
            return []
        }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        switch apiProtocol {
        case .responses:
            return parseOpenAIResponsesEvent(json, assistantItemID: assistantItemID, reasoningItemID: reasoningItemID)
        case .chatCompletions:
            return parseOpenAIChatEvent(json, assistantItemID: assistantItemID, reasoningItemID: reasoningItemID)
        case .anthropicMessages:
            return parseAnthropicEvent(json, assistantItemID: assistantItemID, reasoningItemID: reasoningItemID)
        }
    }

    public mutating func finalizeToolCalls() -> [DirectHTTPToolInvocation] {
        if !openAIChatToolCallBuilders.isEmpty {
            let built = openAIChatToolCallBuilders.keys.sorted().compactMap { index -> DirectHTTPToolInvocation? in
                guard let entry = openAIChatToolCallBuilders[index], !entry.name.isEmpty else { return nil }
                return DirectHTTPToolInvocation(
                    id: entry.id.isEmpty ? "call_\(index)" : entry.id,
                    name: entry.name,
                    argumentsJSON: entry.arguments.isEmpty ? "{}" : entry.arguments
                )
            }
            toolCalls.append(contentsOf: built)
            openAIChatToolCallBuilders.removeAll()
        }
        if !anthropicToolCallsByIndex.isEmpty {
            let built = anthropicToolCallsByIndex.keys.sorted().compactMap { index -> DirectHTTPToolInvocation? in
                guard let entry = anthropicToolCallsByIndex[index], !entry.name.isEmpty else { return nil }
                return DirectHTTPToolInvocation(
                    id: entry.id,
                    name: entry.name,
                    argumentsJSON: entry.arguments.isEmpty ? "{}" : entry.arguments
                )
            }
            toolCalls.append(contentsOf: built)
            anthropicToolCallsByIndex.removeAll()
        }
        if !openAIResponseCallsByItemID.isEmpty {
            let built = openAIResponseCallsByItemID.values.compactMap { entry -> DirectHTTPToolInvocation? in
                guard !entry.name.isEmpty else { return nil }
                return DirectHTTPToolInvocation(
                    id: entry.callID,
                    name: entry.name,
                    argumentsJSON: entry.arguments.isEmpty ? "{}" : entry.arguments
                )
            }
            toolCalls.append(contentsOf: built)
            openAIResponseCallsByItemID.removeAll()
        }
        return toolCalls
    }

    private mutating func parseOpenAIResponsesEvent(
        _ json: [String: Any],
        assistantItemID: String,
        reasoningItemID: String
    ) -> [AIAgentStreamEvent] {
        let type = (json["type"] as? String) ?? currentSSEEventName ?? ""
        switch type {
        case "response.output_text.delta":
            guard let delta = json["delta"] as? String, !delta.isEmpty else { return [] }
            assistantText.append(delta)
            return [.assistantTextDelta(itemID: assistantItemID, text: delta, isReplacement: false)]

        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            guard let delta = json["delta"] as? String, !delta.isEmpty else { return [] }
            reasoningText.append(delta)
            return [.reasoningDelta(itemID: reasoningItemID, text: delta, isReplacement: false)]

        case "response.output_item.added":
            if let item = json["item"] as? [String: Any],
               (item["type"] as? String) == "function_call",
               let itemID = item["id"] as? String {
                let callID = (item["call_id"] as? String) ?? itemID
                let name = (item["name"] as? String) ?? ""
                openAIResponseCallsByItemID[itemID] = (callID: callID, name: name, arguments: "")
            }
            return []

        case "response.function_call_arguments.delta":
            if let itemID = json["item_id"] as? String,
               let delta = json["delta"] as? String {
                var entry = openAIResponseCallsByItemID[itemID] ?? (callID: itemID, name: "", arguments: "")
                entry.arguments.append(delta)
                openAIResponseCallsByItemID[itemID] = entry
            }
            return []

        case "response.output_item.done":
            if let item = json["item"] as? [String: Any],
               (item["type"] as? String) == "function_call" {
                let itemID = (item["id"] as? String) ?? UUID().uuidString
                let callID = (item["call_id"] as? String) ?? itemID
                let name = (item["name"] as? String) ?? openAIResponseCallsByItemID[itemID]?.name ?? ""
                let args = (item["arguments"] as? String) ?? openAIResponseCallsByItemID[itemID]?.arguments ?? "{}"
                openAIResponseCallsByItemID.removeValue(forKey: itemID)
                if !name.isEmpty {
                    toolCalls.append(DirectHTTPToolInvocation(id: callID, name: name, argumentsJSON: args))
                }
            }
            return []

        case "response.completed":
            if let response = json["response"] as? [String: Any],
               let usageDict = response["usage"] as? [String: Any] {
                let input = (usageDict["input_tokens"] as? NSNumber)?.intValue ?? 0
                let output = (usageDict["output_tokens"] as? NSNumber)?.intValue ?? 0
                let parsed = AIAgentTokenUsage(inputTokens: input, outputTokens: output)
                usage = parsed
                return [.usage(parsed)]
            }
            return []

        case "error", "response.failed":
            let message = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? (json["message"] as? String)
                ?? "API stream failed."
            errorMessage = message
            return [.failed(message)]

        default:
            return []
        }
    }

    private mutating func parseOpenAIChatEvent(
        _ json: [String: Any],
        assistantItemID: String,
        reasoningItemID: String
    ) -> [AIAgentStreamEvent] {
        var events: [AIAgentStreamEvent] = []
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            errorMessage = message
            return [.failed(message)]
        }
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let delta = first["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                assistantText.append(content)
                events.append(.assistantTextDelta(itemID: assistantItemID, text: content, isReplacement: false))
            }
            if let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String),
               !reasoning.isEmpty {
                reasoningText.append(reasoning)
                events.append(.reasoningDelta(itemID: reasoningItemID, text: reasoning, isReplacement: false))
            }
            if let rawCalls = delta["tool_calls"] as? [[String: Any]] {
                for call in rawCalls {
                    let index = (call["index"] as? NSNumber)?.intValue ?? 0
                    var entry = openAIChatToolCallBuilders[index] ?? (id: "", name: "", arguments: "")
                    if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
                    if let function = call["function"] as? [String: Any] {
                        if let name = function["name"] as? String, !name.isEmpty { entry.name = name }
                        if let args = function["arguments"] as? String { entry.arguments.append(args) }
                    }
                    openAIChatToolCallBuilders[index] = entry
                }
            }
        }
        if let usageDict = json["usage"] as? [String: Any] {
            let input = (usageDict["prompt_tokens"] as? NSNumber)?.intValue ?? 0
            let output = (usageDict["completion_tokens"] as? NSNumber)?.intValue ?? 0
            if input > 0 || output > 0 {
                let parsed = AIAgentTokenUsage(inputTokens: input, outputTokens: output)
                usage = parsed
                events.append(.usage(parsed))
            }
        }
        return events
    }

    private mutating func parseAnthropicEvent(
        _ json: [String: Any],
        assistantItemID: String,
        reasoningItemID: String
    ) -> [AIAgentStreamEvent] {
        let type = (json["type"] as? String) ?? currentSSEEventName ?? ""
        switch type {
        case "content_block_start":
            let index = (json["index"] as? NSNumber)?.intValue ?? 0
            if let block = json["content_block"] as? [String: Any],
               (block["type"] as? String) == "tool_use" {
                let id = (block["id"] as? String) ?? "tool_\(index)"
                let name = (block["name"] as? String) ?? ""
                anthropicToolCallsByIndex[index] = (id: id, name: name, arguments: "")
            }
            return []

        case "content_block_delta":
            let index = (json["index"] as? NSNumber)?.intValue ?? 0
            guard let delta = json["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return [] }
            switch deltaType {
            case "text_delta":
                guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                assistantText.append(text)
                return [.assistantTextDelta(itemID: assistantItemID, text: text, isReplacement: false)]
            case "thinking_delta":
                guard let thinking = delta["thinking"] as? String, !thinking.isEmpty else { return [] }
                reasoningText.append(thinking)
                return [.reasoningDelta(itemID: reasoningItemID, text: thinking, isReplacement: false)]
            case "input_json_delta":
                if let partial = delta["partial_json"] as? String,
                   var entry = anthropicToolCallsByIndex[index] {
                    entry.arguments.append(partial)
                    anthropicToolCallsByIndex[index] = entry
                }
                return []
            default:
                return []
            }

        case "message_delta":
            if let usageDict = json["usage"] as? [String: Any] {
                let input = (usageDict["input_tokens"] as? NSNumber)?.intValue ?? 0
                let output = (usageDict["output_tokens"] as? NSNumber)?.intValue ?? 0
                if input > 0 || output > 0 {
                    let parsed = AIAgentTokenUsage(inputTokens: input, outputTokens: output)
                    usage = parsed
                    return [.usage(parsed)]
                }
            }
            return []

        case "error":
            let message = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? "Anthropic API stream error."
            errorMessage = message
            return [.failed(message)]

        default:
            return []
        }
    }
}

public enum AIAgentPromptBuilder {
    private static let maxAttachedFileCharacters = 24_000

    @MainActor
    public static func buildPrompt(
        userPrompt: String,
        attachments: [AIAgentContextAttachment],
        customInstructions: String,
        permissionMode: AIAgentPermissionMode,
        rootPath: String,
        host: any AIAgentWorkspaceHost
    ) async -> String {
        var sections: [String] = []
        let trimmedInstructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstructions.isEmpty {
            sections.append("User project instructions:\n\(trimmedInstructions)")
        }
        if permissionMode == .plan {
            sections.append("Mode: PLAN ONLY. Inspect the codebase and propose a clear step-by-step implementation plan. Do not modify files or run mutating commands.")
        }

        if !attachments.isEmpty {
            var contextParts: [String] = []
            for attachment in attachments {
                switch attachment.kind {
                case .file(let relativePath):
                    if let content = try? await host.readFile(relativePath: relativePath, rootPath: rootPath) {
                        let clipped = content.count > maxAttachedFileCharacters
                            ? String(content.prefix(maxAttachedFileCharacters)) + "\n... [truncated]"
                            : content
                        contextParts.append("File: \(relativePath)\n```\n\(clipped)\n```")
                    } else {
                        contextParts.append("Referenced file: \(relativePath)")
                    }
                case .selection(let relativePath, let startLine, let endLine, let snippet):
                    contextParts.append("Selection from \(relativePath) (lines \(startLine)-\(endLine)):\n```\n\(snippet)\n```")
                }
            }
            if !contextParts.isEmpty {
                sections.append("Attached context:\n" + contextParts.joined(separator: "\n\n"))
            }
        }

        sections.append(userPrompt)
        return sections.joined(separator: "\n\n")
    }
}
