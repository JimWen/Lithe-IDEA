import Foundation

/// Explicit user-invoked tool actions. Metadata refresh never invokes them.
public enum ProjectToolAction: String, CaseIterable, Codable, Sendable {
    case build, test, vet, checkFormatting, moduleTidy, moduleDownload, moduleVerify
}

/// A directory is relative to the original workspace; "." denotes its root.
public struct ProjectToolActionRequest: Hashable, Sendable {
    public let action: ProjectToolAction
    public let directory: String

    public init(action: ProjectToolAction, directory: String) {
        self.action = action
        self.directory = directory
    }
}

public enum ProjectToolExecutable: Hashable, Sendable {
    case languageToolchain
    /// A companion next to the selected toolchain, e.g. gofmt next to go.
    case companion(String)
}

/// An in-memory argv plan, never a persisted Run configuration or shell script.
public struct ProjectToolTaskPlan: Hashable, Sendable {
    public let title: String
    public let executable: ProjectToolExecutable
    public let arguments: [String]
    public let workingDirectory: String
    public let diagnosticSource: String

    public init(title: String, executable: ProjectToolExecutable, arguments: [String],
                workingDirectory: String, diagnosticSource: String) {
        self.title = title
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.diagnosticSource = diagnosticSource
    }
}

/// Optional extension of the existing execution capability. Older signed
/// plugins retain their Run ABI and report this additional feature unavailable.
@MainActor
public protocol ProjectToolActionProviding: LanguageRunExtensionProviding {
    func toolPlan(for request: ProjectToolActionRequest) throws -> ProjectToolTaskPlan
}

public enum ProjectToolTaskState: String, Sendable {
    case preparing, running, stopping, succeeded, failed, cancelled, cleanupRequired
    public var isTerminal: Bool {
        self == .succeeded || self == .failed || self == .cancelled
    }
}

public struct ProjectToolTaskOwner: Hashable, Sendable {
    public let workspaceURL: URL
    public let workspaceGeneration: Int
    public let providerGeneration: Int

    public init(workspaceURL: URL, workspaceGeneration: Int, providerGeneration: Int) {
        self.workspaceURL = workspaceURL
        self.workspaceGeneration = workspaceGeneration
        self.providerGeneration = providerGeneration
    }
}

/// Output belongs to one tool invocation and has a distinct diagnostic source.
/// The host resolves paths against workingDirectory, never the current project.
public struct ProjectToolTaskSnapshot: Identifiable, Sendable {
    public let id: UUID
    public let owner: ProjectToolTaskOwner
    public let action: ProjectToolActionRequest
    public let title: String
    public let state: ProjectToolTaskState
    public let output: String
    public let outputTruncated: Bool
    public let workingDirectory: URL
    public let diagnosticSource: String
    public let exitCode: Int32?
    public let message: String?

    public init(id: UUID, owner: ProjectToolTaskOwner, action: ProjectToolActionRequest, title: String,
                state: ProjectToolTaskState, output: String, outputTruncated: Bool,
                workingDirectory: URL, diagnosticSource: String, exitCode: Int32?, message: String?) {
        self.id = id
        self.owner = owner
        self.action = action
        self.title = title
        self.state = state
        self.output = output
        self.outputTruncated = outputTruncated
        self.workingDirectory = workingDirectory
        self.diagnosticSource = diagnosticSource
        self.exitCode = exitCode
        self.message = message
    }
}
