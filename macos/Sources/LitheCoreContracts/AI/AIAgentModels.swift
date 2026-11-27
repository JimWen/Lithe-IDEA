import Foundation

public enum AIAgentBackendKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case antigravityCLI
    case codexCLI
    case claudeCLI
    case directHTTP

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .antigravityCLI: "Antigravity"
        case .codexCLI: "Codex"
        case .claudeCLI: "Claude Code"
        case .directHTTP: "Direct API"
        }
    }

    public var shortTitle: String {
        switch self {
        case .antigravityCLI: "AGY"
        case .codexCLI: "Codex"
        case .claudeCLI: "Claude"
        case .directHTTP: "API"
        }
    }

    public var iconName: String {
        switch self {
        case .antigravityCLI: "atom"
        case .codexCLI: "terminal.fill"
        case .claudeCLI: "sparkles"
        case .directHTTP: "network"
        }
    }

    public var suggestedModels: [String] {
        [""] + AIAgentModelCatalog.families(for: self).map(\.id)
    }
}

public enum AIAgentEffortWireStrategy: String, Codable, Equatable, Hashable, Sendable {
    /// Fixed single-tier or non-reasoning model; reasoning effort control is hidden.
    case none
    /// Antigravity ACP models where effort is encoded in the wire model ID suffix (`<family>-<effort>`).
    case modelIDSuffix
    /// CLI backends where model ID and reasoning effort are forwarded as separate arguments.
    case cliConfigOption
}

public struct AIAgentModelDescriptor: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let shortName: String
    public let backend: AIAgentBackendKind
    public let supportedEfforts: [AIAgentReasoningEffort]
    public let defaultEffort: AIAgentReasoningEffort?
    public let wireStrategy: AIAgentEffortWireStrategy

    public init(
        id: String,
        displayName: String,
        shortName: String? = nil,
        backend: AIAgentBackendKind,
        supportedEfforts: [AIAgentReasoningEffort],
        defaultEffort: AIAgentReasoningEffort? = nil,
        wireStrategy: AIAgentEffortWireStrategy
    ) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName ?? displayName
        self.backend = backend
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort ?? supportedEfforts.last
        self.wireStrategy = wireStrategy
    }
}

/// Single source of truth uniting model families, supported reasoning effort tiers,
/// legacy suffixed model migration, and backend wire ID resolution.
public enum AIAgentModelCatalog {
    public static let antigravityFamilies: [AIAgentModelDescriptor] = [
        AIAgentModelDescriptor(
            id: "gemini-4-neon",
            displayName: "Gemini 4 Neon",
            shortName: "Gemini 4 Neon",
            backend: .antigravityCLI,
            supportedEfforts: [.low, .medium, .high, .xhigh],
            defaultEffort: .high,
            wireStrategy: .modelIDSuffix
        ),
        AIAgentModelDescriptor(
            id: "gemini-4-hydrogen",
            displayName: "Gemini 4 Hydrogen",
            shortName: "Gemini 4 H",
            backend: .antigravityCLI,
            supportedEfforts: [.low, .medium, .high, .xhigh],
            defaultEffort: .high,
            wireStrategy: .modelIDSuffix
        ),
        AIAgentModelDescriptor(
            id: "gemini-4-carbon",
            displayName: "Gemini 4 Carbon",
            shortName: "Gemini 4 Carbon",
            backend: .antigravityCLI,
            supportedEfforts: [.low, .medium, .high],
            defaultEffort: .high,
            wireStrategy: .modelIDSuffix
        ),
        AIAgentModelDescriptor(
            id: "gemini-4-argon",
            displayName: "Gemini 4 Argon",
            shortName: "Gemini 4 Argon",
            backend: .antigravityCLI,
            supportedEfforts: [.low, .medium, .high],
            defaultEffort: .high,
            wireStrategy: .modelIDSuffix
        ),
        AIAgentModelDescriptor(
            id: "gemini-3.8-flash",
            displayName: "Gemini 3.8 Flash",
            shortName: "3.8 Flash",
            backend: .antigravityCLI,
            supportedEfforts: [.low, .medium, .high],
            defaultEffort: .high,
            wireStrategy: .modelIDSuffix
        ),
        AIAgentModelDescriptor(
            id: "claude-opus-5-5",
            displayName: "Claude Opus 5.5",
            shortName: "Opus 5.5",
            backend: .antigravityCLI,
            supportedEfforts: [.low, .medium, .high],
            defaultEffort: .high,
            wireStrategy: .modelIDSuffix
        ),
        AIAgentModelDescriptor(
            id: "claude-sonnet-5-5",
            displayName: "Claude Sonnet 5.5",
            shortName: "Sonnet 5.5",
            backend: .antigravityCLI,
            supportedEfforts: [.low, .medium, .high],
            defaultEffort: .high,
            wireStrategy: .modelIDSuffix
        ),
        AIAgentModelDescriptor(
            id: "gemini-pro-orchestrator-neon",
            displayName: "Orchestrator Neon",
            shortName: "Orch Neon",
            backend: .antigravityCLI,
            supportedEfforts: [],
            defaultEffort: nil,
            wireStrategy: .none
        ),
        AIAgentModelDescriptor(
            id: "gemini-pro-orchestrator",
            displayName: "Orchestrator",
            shortName: "Orchestrator",
            backend: .antigravityCLI,
            supportedEfforts: [],
            defaultEffort: nil,
            wireStrategy: .none
        ),
        AIAgentModelDescriptor(
            id: "gemini-pro-orchestrator-argon",
            displayName: "Orchestrator Argon",
            shortName: "Orch Argon",
            backend: .antigravityCLI,
            supportedEfforts: [],
            defaultEffort: nil,
            wireStrategy: .none
        ),
        AIAgentModelDescriptor(
            id: "gpt-oss-120b-medium",
            displayName: "GPT-OSS 120B",
            shortName: "GPT-OSS 120B",
            backend: .antigravityCLI,
            supportedEfforts: [],
            defaultEffort: nil,
            wireStrategy: .none
        )
    ]

    public static let codexFamilies: [AIAgentModelDescriptor] = [
        AIAgentModelDescriptor(
            id: "gpt-5.4",
            displayName: "GPT-5.4",
            backend: .codexCLI,
            supportedEfforts: [.low, .medium, .high, .xhigh],
            defaultEffort: .high,
            wireStrategy: .cliConfigOption
        ),
        AIAgentModelDescriptor(
            id: "gpt-5.3-codex",
            displayName: "GPT-5.3 Codex",
            backend: .codexCLI,
            supportedEfforts: [.low, .medium, .high, .xhigh],
            defaultEffort: .high,
            wireStrategy: .cliConfigOption
        ),
        AIAgentModelDescriptor(
            id: "o3",
            displayName: "o3",
            backend: .codexCLI,
            supportedEfforts: [.low, .medium, .high],
            defaultEffort: .medium,
            wireStrategy: .cliConfigOption
        ),
        AIAgentModelDescriptor(
            id: "gpt-6.1-sol",
            displayName: "GPT-6.1 Sol",
            backend: .codexCLI,
            supportedEfforts: [.low, .medium, .high, .xhigh],
            defaultEffort: .high,
            wireStrategy: .cliConfigOption
        )
    ]

    public static let claudeFamilies: [AIAgentModelDescriptor] = [
        AIAgentModelDescriptor(
            id: "sonnet",
            displayName: "Claude Sonnet",
            shortName: "Sonnet",
            backend: .claudeCLI,
            supportedEfforts: [.low, .medium, .high],
            defaultEffort: .medium,
            wireStrategy: .cliConfigOption
        ),
        AIAgentModelDescriptor(
            id: "opus",
            displayName: "Claude Opus",
            shortName: "Opus",
            backend: .claudeCLI,
            supportedEfforts: [.low, .medium, .high],
            defaultEffort: .high,
            wireStrategy: .cliConfigOption
        ),
        AIAgentModelDescriptor(
            id: "haiku",
            displayName: "Claude Haiku",
            shortName: "Haiku",
            backend: .claudeCLI,
            supportedEfforts: [],
            defaultEffort: nil,
            wireStrategy: .none
        )
    ]

    public static func families(for backend: AIAgentBackendKind) -> [AIAgentModelDescriptor] {
        switch backend {
        case .antigravityCLI: antigravityFamilies
        case .codexCLI: codexFamilies
        case .claudeCLI: claudeFamilies
        case .directHTTP: []
        }
    }

    public static func descriptor(
        for rawModel: String,
        backend: AIAgentBackendKind
    ) -> AIAgentModelDescriptor? {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let list = families(for: backend)
        // Exact match first so fixed single-tier models like `gpt-oss-120b-medium`
        // are never misparsed as a suffixed effort variant.
        if let exact = list.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact
        }
        if backend == .antigravityCLI {
            for family in list where family.wireStrategy == .modelIDSuffix {
                for effort in family.supportedEfforts {
                    let wire = "\(family.id)-\(effort.rawValue)"
                    if wire.caseInsensitiveCompare(trimmed) == .orderedSame {
                        return family
                    }
                }
            }
        }
        return nil
    }

    public static func supportedEfforts(
        for rawModel: String,
        backend: AIAgentBackendKind
    ) -> [AIAgentReasoningEffort] {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        switch backend {
        case .directHTTP:
            return []
        case .antigravityCLI:
            if trimmed.isEmpty {
                return [.low, .medium, .high, .xhigh]
            }
            if let descriptor = descriptor(for: trimmed, backend: backend) {
                return descriptor.supportedEfforts
            }
            // Custom Antigravity wire IDs are sent verbatim without double-suffixing.
            return []
        case .codexCLI:
            if let descriptor = descriptor(for: trimmed, backend: backend) {
                return descriptor.supportedEfforts
            }
            return [.low, .medium, .high, .xhigh]
        case .claudeCLI:
            if let descriptor = descriptor(for: trimmed, backend: backend) {
                return descriptor.supportedEfforts
            }
            return [.low, .medium, .high]
        }
    }

    public static func clampEffort(
        _ effort: AIAgentReasoningEffort,
        supported: [AIAgentReasoningEffort],
        fallback: AIAgentReasoningEffort? = nil
    ) -> AIAgentReasoningEffort {
        guard !supported.isEmpty else { return effort }
        if supported.contains(effort) { return effort }
        if effort == .xhigh, supported.contains(.high) { return .high }
        if let fallback, supported.contains(fallback) { return fallback }
        return supported.last ?? effort
    }

    /// Normalizes a `(model, effort)` pair into canonical family ID + supported effort,
    /// migrating legacy suffixed Antigravity IDs such as `gemini-4-neon-xhigh` cleanly.
    public static func normalize(
        model rawModel: String,
        effort: AIAgentReasoningEffort,
        backend: AIAgentBackendKind
    ) -> (model: String, effort: AIAgentReasoningEffort) {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let allowed = supportedEfforts(for: "", backend: backend)
            return ("", clampEffort(effort, supported: allowed))
        }
        let list = families(for: backend)
        if let exact = list.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            let clamped = clampEffort(
                effort,
                supported: exact.supportedEfforts,
                fallback: exact.defaultEffort
            )
            return (exact.id, clamped)
        }
        if backend == .antigravityCLI {
            for family in list where family.wireStrategy == .modelIDSuffix {
                for candidateEffort in family.supportedEfforts {
                    let wire = "\(family.id)-\(candidateEffort.rawValue)"
                    if wire.caseInsensitiveCompare(trimmed) == .orderedSame {
                        return (family.id, candidateEffort)
                    }
                }
            }
        }
        let allowed = supportedEfforts(for: trimmed, backend: backend)
        return (trimmed, clampEffort(effort, supported: allowed))
    }

    /// Resolves the wire model identifier sent to the backend (e.g., composing
    /// `gemini-4-neon` + `.xhigh` into `"gemini-4-neon-xhigh"` for Antigravity ACP).
    public static func wireModelID(
        model rawModel: String,
        effort: AIAgentReasoningEffort,
        backend: AIAgentBackendKind
    ) -> String {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let normalized = normalize(model: trimmed, effort: effort, backend: backend)
        guard let descriptor = descriptor(for: normalized.model, backend: backend) else {
            return normalized.model
        }
        switch descriptor.wireStrategy {
        case .modelIDSuffix:
            let effectiveEffort = clampEffort(
                normalized.effort,
                supported: descriptor.supportedEfforts,
                fallback: descriptor.defaultEffort
            )
            return "\(descriptor.id)-\(effectiveEffort.rawValue)"
        case .none, .cliConfigOption:
            return descriptor.id
        }
    }

    public static func displayLabel(
        for rawModel: String,
        backend: AIAgentBackendKind,
        compact: Bool = false
    ) -> String {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Default" }
        if let descriptor = descriptor(for: trimmed, backend: backend) {
            return compact ? descriptor.shortName : descriptor.displayName
        }
        return trimmed
    }
}

public enum AIAgentPermissionMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case plan
    case supervised
    case autoEdit
    case fullAuto

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plan: "Plan"
        case .supervised: "Supervised"
        case .autoEdit: "Auto-Edit"
        case .fullAuto: "Full Auto"
        }
    }

    public var summary: String {
        switch self {
        case .plan: "Read-only exploration and implementation planning without editing files."
        case .supervised: "Ask approval before editing files or running shell commands."
        case .autoEdit: "Allow workspace edits and sandboxed commands automatically."
        case .fullAuto: "Bypass sandbox and approval prompts (use only in trusted workspaces)."
        }
    }

    public var iconName: String {
        switch self {
        case .plan: "map"
        case .supervised: "checkmark.shield"
        case .autoEdit: "pencil.and.outline"
        case .fullAuto: "bolt.shield"
        }
    }
}

public enum AIAgentReasoningEffort: String, CaseIterable, Codable, Identifiable, Sendable {
    case low
    case medium
    case high
    case xhigh

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "XHigh"
        }
    }
}

public struct AIAgentSettings: Codable, Equatable, Sendable {
    public var defaultBackend: AIAgentBackendKind
    public var antigravityCLIPath: String
    public var codexCLIPath: String
    public var claudeCLIPath: String
    public var defaultAntigravityModel: String
    public var defaultCodexModel: String
    public var defaultClaudeModel: String
    public var defaultReasoningEffort: AIAgentReasoningEffort
    public var defaultPermissionMode: AIAgentPermissionMode
    public var preferIsolatedWorktree: Bool
    public var autoOpenDiffOnChanges: Bool
    public var includeActiveFileContextByDefault: Bool
    public var customSystemInstructions: String

    public static var `default`: Self {
        Self(
            defaultBackend: .antigravityCLI,
            antigravityCLIPath: "",
            codexCLIPath: "",
            claudeCLIPath: "",
            defaultAntigravityModel: "",
            defaultCodexModel: "",
            defaultClaudeModel: "",
            defaultReasoningEffort: .medium,
            defaultPermissionMode: .supervised,
            preferIsolatedWorktree: false,
            autoOpenDiffOnChanges: false,
            includeActiveFileContextByDefault: true,
            customSystemInstructions: ""
        )
    }

    public init(
        defaultBackend: AIAgentBackendKind = .antigravityCLI,
        antigravityCLIPath: String = "",
        codexCLIPath: String = "",
        claudeCLIPath: String = "",
        defaultAntigravityModel: String = "",
        defaultCodexModel: String = "",
        defaultClaudeModel: String = "",
        defaultReasoningEffort: AIAgentReasoningEffort = .medium,
        defaultPermissionMode: AIAgentPermissionMode = .supervised,
        preferIsolatedWorktree: Bool = false,
        autoOpenDiffOnChanges: Bool = false,
        includeActiveFileContextByDefault: Bool = true,
        customSystemInstructions: String = ""
    ) {
        self.defaultBackend = defaultBackend
        self.antigravityCLIPath = antigravityCLIPath
        self.codexCLIPath = codexCLIPath
        self.claudeCLIPath = claudeCLIPath
        self.defaultAntigravityModel = defaultAntigravityModel
        self.defaultCodexModel = defaultCodexModel
        self.defaultClaudeModel = defaultClaudeModel
        self.defaultReasoningEffort = defaultReasoningEffort
        self.defaultPermissionMode = defaultPermissionMode
        self.preferIsolatedWorktree = preferIsolatedWorktree
        self.autoOpenDiffOnChanges = autoOpenDiffOnChanges
        self.includeActiveFileContextByDefault = includeActiveFileContextByDefault
        self.customSystemInstructions = customSystemInstructions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultBackend = try container.decodeIfPresent(AIAgentBackendKind.self, forKey: .defaultBackend) ?? .antigravityCLI
        antigravityCLIPath = try container.decodeIfPresent(String.self, forKey: .antigravityCLIPath) ?? ""
        codexCLIPath = try container.decodeIfPresent(String.self, forKey: .codexCLIPath) ?? ""
        claudeCLIPath = try container.decodeIfPresent(String.self, forKey: .claudeCLIPath) ?? ""
        defaultAntigravityModel = try container.decodeIfPresent(String.self, forKey: .defaultAntigravityModel) ?? ""
        defaultCodexModel = try container.decodeIfPresent(String.self, forKey: .defaultCodexModel) ?? ""
        defaultClaudeModel = try container.decodeIfPresent(String.self, forKey: .defaultClaudeModel) ?? ""
        defaultReasoningEffort = try container.decodeIfPresent(AIAgentReasoningEffort.self, forKey: .defaultReasoningEffort) ?? .medium
        defaultPermissionMode = try container.decodeIfPresent(AIAgentPermissionMode.self, forKey: .defaultPermissionMode) ?? .supervised
        preferIsolatedWorktree = try container.decodeIfPresent(Bool.self, forKey: .preferIsolatedWorktree) ?? false
        autoOpenDiffOnChanges = try container.decodeIfPresent(Bool.self, forKey: .autoOpenDiffOnChanges) ?? false
        includeActiveFileContextByDefault = try container.decodeIfPresent(Bool.self, forKey: .includeActiveFileContextByDefault) ?? true
        customSystemInstructions = try container.decodeIfPresent(String.self, forKey: .customSystemInstructions) ?? ""
    }

    public func defaultModel(for backend: AIAgentBackendKind) -> String {
        switch backend {
        case .antigravityCLI: defaultAntigravityModel
        case .codexCLI: defaultCodexModel
        case .claudeCLI: defaultClaudeModel
        case .directHTTP: ""
        }
    }
}

public struct AIAgentCLIDetection: Identifiable, Equatable, Sendable {
    public let backend: AIAgentBackendKind
    public let isAvailable: Bool
    public let executablePath: String?
    public let version: String?
    public let statusDetail: String

    public var id: String { backend.rawValue }

    public init(
        backend: AIAgentBackendKind,
        isAvailable: Bool,
        executablePath: String?,
        version: String?,
        statusDetail: String
    ) {
        self.backend = backend
        self.isAvailable = isAvailable
        self.executablePath = executablePath
        self.version = version
        self.statusDetail = statusDetail
    }
}

public enum AIAgentContextAttachmentKind: Codable, Equatable, Hashable, Sendable {
    case file(relativePath: String)
    case selection(relativePath: String, startLine: Int, endLine: Int, snippet: String)
    case image(path: String, displayName: String)
}

public struct AIAgentContextAttachment: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let kind: AIAgentContextAttachmentKind

    public init(id: UUID = UUID(), kind: AIAgentContextAttachmentKind) {
        self.id = id
        self.kind = kind
    }

    public var relativePath: String {
        switch kind {
        case .file(let path): path
        case .selection(let path, _, _, _): path
        case .image(let path, _): path
        }
    }

    public var imageFilePath: String? {
        if case .image(let path, _) = kind { return path }
        return nil
    }

    public var displayLabel: String {
        switch kind {
        case .file(let path):
            return (path as NSString).lastPathComponent
        case .selection(let path, let startLine, let endLine, _):
            let name = (path as NSString).lastPathComponent
            if startLine == endLine {
                return "\(name):\(startLine)"
            }
            return "\(name):\(startLine)-\(endLine)"
        case .image(_, let displayName):
            return displayName
        }
    }
}

public enum AIAgentToolCallStatus: String, Codable, Equatable, Sendable {
    case running
    case waitingApproval
    case completed
    case failed
    case denied
}

public enum AIAgentFileChangeKind: String, Codable, Equatable, Sendable {
    case added
    case modified
    case deleted
    case renamed

    public var badge: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        }
    }
}

public struct AIAgentFileChangeSummary: Identifiable, Codable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let kind: AIAgentFileChangeKind
    public let additions: Int
    public let deletions: Int
    public let diffText: String

    public init(
        path: String,
        kind: AIAgentFileChangeKind,
        additions: Int = 0,
        deletions: Int = 0,
        diffText: String = ""
    ) {
        self.path = path
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
        self.diffText = diffText
    }
}

public enum AIAgentApprovalKind: String, Codable, Equatable, Sendable {
    case command
    case fileWrite
    case fileDelete
}

public enum AIAgentApprovalDecision: String, Codable, Equatable, Sendable {
    case allowOnce
    case allowAlways
    case deny
}

public struct AIAgentApprovalRequest: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: AIAgentApprovalKind
    public let title: String
    public let detail: String
    public let command: String?
    public let filePath: String?
    public let diffPreview: String?
    public var allowsAllowOnce: Bool
    public var allowsAllowAlways: Bool
    /// When `false` (e.g. ACP server-scoped approvals), clicking "Allow Always" forwards
    /// `allow_always` to the server without auto-approving future requests of the same kind.
    public var cacheAlwaysAllowByKind: Bool
    public var decision: AIAgentApprovalDecision?

    public init(
        id: UUID = UUID(),
        kind: AIAgentApprovalKind,
        title: String,
        detail: String,
        command: String? = nil,
        filePath: String? = nil,
        diffPreview: String? = nil,
        allowsAllowOnce: Bool = true,
        allowsAllowAlways: Bool = true,
        cacheAlwaysAllowByKind: Bool = true,
        decision: AIAgentApprovalDecision? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.command = command
        self.filePath = filePath
        self.diffPreview = diffPreview
        self.allowsAllowOnce = allowsAllowOnce
        self.allowsAllowAlways = allowsAllowAlways
        self.cacheAlwaysAllowByKind = cacheAlwaysAllowByKind
        self.decision = decision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(AIAgentApprovalKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decode(String.self, forKey: .detail)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        diffPreview = try container.decodeIfPresent(String.self, forKey: .diffPreview)
        allowsAllowOnce = try container.decodeIfPresent(Bool.self, forKey: .allowsAllowOnce) ?? true
        allowsAllowAlways = try container.decodeIfPresent(Bool.self, forKey: .allowsAllowAlways) ?? true
        cacheAlwaysAllowByKind = try container.decodeIfPresent(Bool.self, forKey: .cacheAlwaysAllowByKind) ?? true
        decision = try container.decodeIfPresent(AIAgentApprovalDecision.self, forKey: .decision)
    }
}

public enum AIAgentTimelineItemKind: String, Codable, Equatable, Sendable {
    case assistantText
    case reasoning
    case commandExecution
    case toolCall
    case fileChanges
    case approval
    case error
    case systemNotice
}

public struct AIAgentTimelineItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: AIAgentTimelineItemKind
    public var title: String
    public var content: String
    public var output: String
    public var status: AIAgentToolCallStatus
    public var exitCode: Int32?
    public var fileChanges: [AIAgentFileChangeSummary]
    public var approval: AIAgentApprovalRequest?
    public var isCollapsed: Bool
    public let timestamp: Date

    public init(
        id: String = UUID().uuidString,
        kind: AIAgentTimelineItemKind,
        title: String = "",
        content: String = "",
        output: String = "",
        status: AIAgentToolCallStatus = .completed,
        exitCode: Int32? = nil,
        fileChanges: [AIAgentFileChangeSummary] = [],
        approval: AIAgentApprovalRequest? = nil,
        isCollapsed: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.output = output
        self.status = status
        self.exitCode = exitCode
        self.fileChanges = fileChanges
        self.approval = approval
        self.isCollapsed = isCollapsed
        self.timestamp = timestamp
    }
}

public struct AIAgentTokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var costUSD: Double?

    public init(
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningTokens: Int = 0,
        costUSD: Double? = nil
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.costUSD = costUSD
    }

    public var totalTokens: Int { inputTokens + outputTokens }

    public mutating func add(_ other: AIAgentTokenUsage) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        outputTokens += other.outputTokens
        reasoningTokens += other.reasoningTokens
        if let otherCost = other.costUSD {
            costUSD = (costUSD ?? 0) + otherCost
        }
    }
}

public struct AIAgentFileSnapshot: Codable, Equatable, Sendable {
    public let relativePath: String
    /// `nil` indicates the file did not exist before the turn (reverting deletes it).
    public let previousContent: String?

    public init(relativePath: String, previousContent: String?) {
        self.relativePath = relativePath
        self.previousContent = previousContent
    }
}

public struct AIAgentCheckpoint: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let turnID: UUID
    public let label: String
    public let createdAt: Date
    public let workingDirectoryPath: String
    public var gitHeadHash: String?
    /// Immutable Git tree object captured via an isolated temporary index before the turn.
    public var gitTreeHash: String?
    /// Immutable Git tree object captured after the turn completes (for exact per-turn diffing).
    public var gitPostTurnTreeHash: String?
    public var fileSnapshots: [AIAgentFileSnapshot]
    /// Unsaved open-editor buffer contents captured immediately before the turn began so
    /// reverting a CLI/Git checkpoint never overwrites pre-existing unsaved user edits.
    public var preTurnDirtyBufferSnapshots: [AIAgentFileSnapshot]

    public init(
        id: UUID = UUID(),
        turnID: UUID,
        label: String,
        createdAt: Date = Date(),
        workingDirectoryPath: String,
        gitHeadHash: String? = nil,
        gitTreeHash: String? = nil,
        gitPostTurnTreeHash: String? = nil,
        fileSnapshots: [AIAgentFileSnapshot] = [],
        preTurnDirtyBufferSnapshots: [AIAgentFileSnapshot] = []
    ) {
        self.id = id
        self.turnID = turnID
        self.label = label
        self.createdAt = createdAt
        self.workingDirectoryPath = workingDirectoryPath
        self.gitHeadHash = gitHeadHash
        self.gitTreeHash = gitTreeHash
        self.gitPostTurnTreeHash = gitPostTurnTreeHash
        self.fileSnapshots = fileSnapshots
        self.preTurnDirtyBufferSnapshots = preTurnDirtyBufferSnapshots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        turnID = try container.decode(UUID.self, forKey: .turnID)
        label = try container.decode(String.self, forKey: .label)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        workingDirectoryPath = try container.decode(String.self, forKey: .workingDirectoryPath)
        gitHeadHash = try container.decodeIfPresent(String.self, forKey: .gitHeadHash)
        gitTreeHash = try container.decodeIfPresent(String.self, forKey: .gitTreeHash)
        gitPostTurnTreeHash = try container.decodeIfPresent(String.self, forKey: .gitPostTurnTreeHash)
        fileSnapshots = try container.decodeIfPresent([AIAgentFileSnapshot].self, forKey: .fileSnapshots) ?? []
        preTurnDirtyBufferSnapshots = try container.decodeIfPresent(
            [AIAgentFileSnapshot].self,
            forKey: .preTurnDirtyBufferSnapshots
        ) ?? []
    }

    public var hasTreeDiffChanges: Bool {
        guard let pre = gitTreeHash, !pre.isEmpty else { return false }
        if let post = gitPostTurnTreeHash, !post.isEmpty {
            return pre != post
        }
        return false
    }

    public var canRevert: Bool {
        !fileSnapshots.isEmpty || hasTreeDiffChanges
    }
}

public enum AIAgentTurnStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case waitingApproval
    case completed
    case cancelled
    case failed
}

public struct AIAgentTurn: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let prompt: String
    public let attachments: [AIAgentContextAttachment]
    public let permissionMode: AIAgentPermissionMode
    public let startedAt: Date
    public var completedAt: Date?
    public var status: AIAgentTurnStatus
    public var items: [AIAgentTimelineItem]
    public var usage: AIAgentTokenUsage?
    public var checkpoint: AIAgentCheckpoint?
    public var changedFiles: [AIAgentFileChangeSummary]
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        prompt: String,
        attachments: [AIAgentContextAttachment] = [],
        permissionMode: AIAgentPermissionMode = .supervised,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        status: AIAgentTurnStatus = .running,
        items: [AIAgentTimelineItem] = [],
        usage: AIAgentTokenUsage? = nil,
        checkpoint: AIAgentCheckpoint? = nil,
        changedFiles: [AIAgentFileChangeSummary] = [],
        errorMessage: String? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.attachments = attachments
        self.permissionMode = permissionMode
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.items = items
        self.usage = usage
        self.checkpoint = checkpoint
        self.changedFiles = changedFiles
        self.errorMessage = errorMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        prompt = try container.decode(String.self, forKey: .prompt)
        attachments = try container.decodeIfPresent([AIAgentContextAttachment].self, forKey: .attachments) ?? []
        permissionMode = try container.decodeIfPresent(AIAgentPermissionMode.self, forKey: .permissionMode) ?? .supervised
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        status = try container.decode(AIAgentTurnStatus.self, forKey: .status)
        items = try container.decodeIfPresent([AIAgentTimelineItem].self, forKey: .items) ?? []
        usage = try container.decodeIfPresent(AIAgentTokenUsage.self, forKey: .usage)
        checkpoint = try container.decodeIfPresent(AIAgentCheckpoint.self, forKey: .checkpoint)
        changedFiles = try container.decodeIfPresent([AIAgentFileChangeSummary].self, forKey: .changedFiles) ?? []
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    public var isInFlight: Bool {
        status == .running || status == .waitingApproval
    }

    public var durationSeconds: TimeInterval? {
        guard let completedAt else { return nil }
        return max(0, completedAt.timeIntervalSince(startedAt))
    }

    public var assistantResponseText: String {
        items.filter { $0.kind == .assistantText }
            .map(\.content)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isCompletedPlanProposal: Bool {
        permissionMode == .plan && status == .completed && !assistantResponseText.isEmpty
    }

    public var canRevertCheckpoint: Bool {
        guard let checkpoint else { return false }
        return checkpoint.canRevert || (checkpoint.gitTreeHash != nil && !changedFiles.isEmpty)
    }
}

public struct AIAgentQueuedPrompt: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let prompt: String
    public let attachments: [AIAgentContextAttachment]
    public let queuedAt: Date

    public init(
        id: UUID = UUID(),
        prompt: String,
        attachments: [AIAgentContextAttachment] = [],
        queuedAt: Date = Date()
    ) {
        self.id = id
        self.prompt = prompt
        self.attachments = attachments
        self.queuedAt = queuedAt
    }
}

public struct AIAgentThread: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public let workspacePath: String
    public var worktreePath: String?
    public var worktreeBranch: String?
    public var backend: AIAgentBackendKind
    public var model: String
    public var reasoningEffort: AIAgentReasoningEffort
    public var permissionMode: AIAgentPermissionMode
    public var providerSessionID: String?
    public var turns: [AIAgentTurn]
    public var queuedPrompts: [AIAgentQueuedPrompt]
    public var isPinned: Bool
    public var isArchived: Bool
    public let createdAt: Date
    public var updatedAt: Date
    public var totalUsage: AIAgentTokenUsage

    public init(
        id: UUID = UUID(),
        title: String = "New Thread",
        workspacePath: String,
        worktreePath: String? = nil,
        worktreeBranch: String? = nil,
        backend: AIAgentBackendKind = .codexCLI,
        model: String = "",
        reasoningEffort: AIAgentReasoningEffort = .medium,
        permissionMode: AIAgentPermissionMode = .supervised,
        providerSessionID: String? = nil,
        turns: [AIAgentTurn] = [],
        queuedPrompts: [AIAgentQueuedPrompt] = [],
        isPinned: Bool = false,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        totalUsage: AIAgentTokenUsage = AIAgentTokenUsage()
    ) {
        self.id = id
        self.title = title
        self.workspacePath = workspacePath
        self.worktreePath = worktreePath
        self.worktreeBranch = worktreeBranch
        self.backend = backend
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.permissionMode = permissionMode
        self.providerSessionID = providerSessionID
        self.turns = turns
        self.queuedPrompts = queuedPrompts
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.totalUsage = totalUsage
    }

    public var effectiveRootPath: String {
        worktreePath ?? workspacePath
    }

    public var isRunning: Bool {
        turns.contains(where: \.isInFlight)
    }

    public var hasPendingApproval: Bool {
        turns.contains { turn in
            turn.items.contains { $0.approval != nil && $0.approval?.decision == nil }
        }
    }
}

public struct AIAgentWorkingTreeDiff: Equatable, Sendable {
    public let rootPath: String
    public let branchName: String
    public let headHash: String?
    public let aheadCount: Int
    public let behindCount: Int
    public let files: [AIAgentFileChangeSummary]
    public let unifiedPatch: String

    public init(
        rootPath: String,
        branchName: String = "",
        headHash: String? = nil,
        aheadCount: Int = 0,
        behindCount: Int = 0,
        files: [AIAgentFileChangeSummary] = [],
        unifiedPatch: String = ""
    ) {
        self.rootPath = rootPath
        self.branchName = branchName
        self.headHash = headHash
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.files = files
        self.unifiedPatch = unifiedPatch
    }

    public var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    public var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

public struct AIAgentWorktreeInfo: Equatable, Sendable {
    public let path: String
    public let branchName: String

    public init(path: String, branchName: String) {
        self.path = path
        self.branchName = branchName
    }
}

public struct AIAgentSlashCommand: Identifiable, Equatable, Sendable {
    public let id: String
    public let command: String
    public let title: String
    public let subtitle: String
    public let iconName: String

    public init(command: String, title: String, subtitle: String, iconName: String) {
        self.id = command
        self.command = command
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
    }

    public static let builtIn: [AIAgentSlashCommand] = [
        AIAgentSlashCommand(command: "/plan", title: "Switch to Plan Mode", subtitle: "Read-only exploration and planning", iconName: "map"),
        AIAgentSlashCommand(command: "/supervised", title: "Switch to Supervised Mode", subtitle: "Approve edits and commands before execution", iconName: "checkmark.shield"),
        AIAgentSlashCommand(command: "/auto", title: "Switch to Auto-Edit Mode", subtitle: "Apply workspace edits automatically", iconName: "pencil.and.outline"),
        AIAgentSlashCommand(command: "/diff", title: "Toggle Diff Review", subtitle: "Inspect changed files, commit, or push", iconName: "doc.text.magnifyingglass"),
        AIAgentSlashCommand(command: "/review", title: "Review Local Changes", subtitle: "Ask the agent to review current git diff", iconName: "eye"),
        AIAgentSlashCommand(command: "/worktree", title: "Create Isolated Worktree", subtitle: "Run this thread in a dedicated Git worktree", iconName: "arrow.triangle.branch"),
        AIAgentSlashCommand(command: "/revert", title: "Revert Last Checkpoint", subtitle: "Restore files to the latest pre-turn checkpoint", iconName: "arrow.uturn.backward"),
        AIAgentSlashCommand(command: "/model", title: "Set Thread Model", subtitle: "Usage: /model <model-name>", iconName: "cpu"),
        AIAgentSlashCommand(command: "/fork", title: "Fork Current Thread", subtitle: "Duplicate conversation history into a new thread", iconName: "arrow.branch"),
        AIAgentSlashCommand(command: "/new", title: "New Thread", subtitle: "Start a fresh agent conversation", iconName: "plus.bubble"),
        AIAgentSlashCommand(command: "/clear", title: "Clear Thread History", subtitle: "Clear turns and reset provider session", iconName: "trash")
    ]
}
