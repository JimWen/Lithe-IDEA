import Foundation

public enum AIAgentBackendKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case codexCLI
    case claudeCLI
    case directHTTP

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codexCLI: "Codex"
        case .claudeCLI: "Claude Code"
        case .directHTTP: "Direct API"
        }
    }

    public var shortTitle: String {
        switch self {
        case .codexCLI: "Codex"
        case .claudeCLI: "Claude"
        case .directHTTP: "API"
        }
    }

    public var iconName: String {
        switch self {
        case .codexCLI: "terminal.fill"
        case .claudeCLI: "sparkles"
        case .directHTTP: "network"
        }
    }

    public var suggestedModels: [String] {
        switch self {
        case .codexCLI:
            ["", "gpt-5.4", "gpt-5.3-codex", "o3", "gpt-6.1-sol"]
        case .claudeCLI:
            ["", "sonnet", "opus", "haiku"]
        case .directHTTP:
            [""]
        }
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
    public var codexCLIPath: String
    public var claudeCLIPath: String
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
            defaultBackend: .codexCLI,
            codexCLIPath: "",
            claudeCLIPath: "",
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
        defaultBackend: AIAgentBackendKind = .codexCLI,
        codexCLIPath: String = "",
        claudeCLIPath: String = "",
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
        self.codexCLIPath = codexCLIPath
        self.claudeCLIPath = claudeCLIPath
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
        defaultBackend = try container.decodeIfPresent(AIAgentBackendKind.self, forKey: .defaultBackend) ?? .codexCLI
        codexCLIPath = try container.decodeIfPresent(String.self, forKey: .codexCLIPath) ?? ""
        claudeCLIPath = try container.decodeIfPresent(String.self, forKey: .claudeCLIPath) ?? ""
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
        }
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
    public var decision: AIAgentApprovalDecision?

    public init(
        id: UUID = UUID(),
        kind: AIAgentApprovalKind,
        title: String,
        detail: String,
        command: String? = nil,
        filePath: String? = nil,
        diffPreview: String? = nil,
        decision: AIAgentApprovalDecision? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.command = command
        self.filePath = filePath
        self.diffPreview = diffPreview
        self.decision = decision
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
    public var fileSnapshots: [AIAgentFileSnapshot]

    public init(
        id: UUID = UUID(),
        turnID: UUID,
        label: String,
        createdAt: Date = Date(),
        workingDirectoryPath: String,
        gitHeadHash: String? = nil,
        fileSnapshots: [AIAgentFileSnapshot] = []
    ) {
        self.id = id
        self.turnID = turnID
        self.label = label
        self.createdAt = createdAt
        self.workingDirectoryPath = workingDirectoryPath
        self.gitHeadHash = gitHeadHash
        self.fileSnapshots = fileSnapshots
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
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.items = items
        self.usage = usage
        self.checkpoint = checkpoint
        self.changedFiles = changedFiles
        self.errorMessage = errorMessage
    }

    public var isInFlight: Bool {
        status == .running || status == .waitingApproval
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
    public let files: [AIAgentFileChangeSummary]
    public let unifiedPatch: String

    public init(
        rootPath: String,
        branchName: String = "",
        headHash: String? = nil,
        files: [AIAgentFileChangeSummary] = [],
        unifiedPatch: String = ""
    ) {
        self.rootPath = rootPath
        self.branchName = branchName
        self.headHash = headHash
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
        AIAgentSlashCommand(command: "/new", title: "New Thread", subtitle: "Start a fresh agent conversation", iconName: "plus.bubble"),
        AIAgentSlashCommand(command: "/clear", title: "Clear Thread History", subtitle: "Clear turns and reset provider session", iconName: "trash")
    ]
}
