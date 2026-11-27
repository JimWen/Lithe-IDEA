import Foundation

public struct AIAgentProcessLaunchRequest: Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String
    public let environment: [String: String]
    public let standardInput: Data?

    public init(
        executablePath: String,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String],
        standardInput: Data? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardInput = standardInput
    }
}

public enum AIAgentProcessEvent: Sendable {
    case stdout(Data)
    case stderr(Data)
    case terminated(Int32)
}

public protocol AIAgentProcessSession: AnyObject, Sendable {
    func start(
        _ request: AIAgentProcessLaunchRequest,
        onEvent: @escaping @Sendable (AIAgentProcessEvent) -> Void
    ) throws
    func writeStandardInput(_ data: Data) throws
    func closeStandardInput()
    func stopAndWait() async -> Bool
}

public protocol AIAgentProcessSessionFactory: Sendable {
    func makeSession() -> any AIAgentProcessSession
}

public protocol AIHTTPStreamingTransport: Sendable {
    func stream(_ request: AIHTTPRequest) async throws -> AsyncThrowingStream<Data, Error>
}

public enum AIHTTPStreamTransportError: LocalizedError, Sendable {
    case invalidResponse
    case insecureHTTPNotAllowed
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The AI streaming endpoint returned an invalid HTTP response."
        case .insecureHTTPNotAllowed:
            return "HTTP streaming is disabled for this AI provider."
        case .httpStatus(let code, let detail):
            if detail.isEmpty {
                return "AI API request failed with HTTP \(code)."
            }
            return "AI API request failed with HTTP \(code): \(detail)"
        }
    }
}

public protocol AIAgentCLIResolving: Sendable {
    func detectCLIs(settings: AIAgentSettings) async -> [AIAgentCLIDetection]
    func resolveExecutable(for backend: AIAgentBackendKind, settings: AIAgentSettings) async -> String?
    func processEnvironment() async -> [String: String]
}

public protocol AIAgentThreadStoring: Sendable {
    func loadThreads(for workspacePath: String) -> [AIAgentThread]
    func saveThreads(_ threads: [AIAgentThread], for workspacePath: String)
}

public enum AIAgentWorkspaceHostError: LocalizedError, Sendable {
    case pathOutsideWorkspace(String)
    case fileNotFound(String)
    case gitUnavailable(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .pathOutsideWorkspace(let path):
            return "Refused access outside the active workspace: \(path)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .gitUnavailable(let reason):
            return reason
        case .commandFailed(let reason):
            return reason
        }
    }
}

@MainActor
public protocol AIAgentWorkspaceHost: AnyObject {
    var workspacePath: String? { get }
    var agentSettings: AIAgentSettings { get }
    var commitMessageAISettings: CommitMessageAISettings { get }

    func projectRelativeFiles(in rootPath: String) -> [String]
    func readFile(relativePath: String, rootPath: String) async throws -> String
    func writeFile(relativePath: String, content: String, expectedSourceText: String?, rootPath: String) async throws
    func deleteFile(relativePath: String, rootPath: String) async throws
    func fileExists(relativePath: String, rootPath: String) -> Bool
    func searchFiles(query: String, rootPath: String, maxResults: Int) async -> [String]
    func runShellCommand(_ command: String, rootPath: String) async -> (exitCode: Int32, output: String)
    func workingTreeDiff(in rootPath: String) async -> AIAgentWorkingTreeDiff
    func captureGitCheckpointTree(in rootPath: String) async -> String?
    func openDirtyFileSnapshots(in rootPath: String) -> [AIAgentFileSnapshot]
    func diffGitTrees(from preTree: String, to postTree: String, in rootPath: String) async -> [AIAgentFileChangeSummary]
    func restoreGitCheckpointTree(_ treeHash: String, in rootPath: String) async throws -> Int
    func discardFileChange(relativePath: String, in rootPath: String) async throws
    func generateCommitMessage(in rootPath: String) async throws -> String
    func readImageData(at path: String, maxBytes: Int) -> (mimeType: String, data: Data)?
    func createIsolatedWorktree(branchName: String, from workspaceRoot: String) async throws -> AIAgentWorktreeInfo
    func removeIsolatedWorktree(path: String, from workspaceRoot: String) async throws
    func commitChanges(message: String, in rootPath: String) async throws -> String
    func pushCurrentBranch(in rootPath: String) async throws -> String
    func openFile(relativePath: String, rootPath: String)
    func openDiff(relativePath: String, rootPath: String)
    func refreshWorkspaceAndGit() async
    func notify(_ message: String)
}

public extension AIAgentWorkspaceHost {
    func writeFile(relativePath: String, content: String, rootPath: String) async throws {
        try await writeFile(relativePath: relativePath, content: content, expectedSourceText: nil, rootPath: rootPath)
    }

    func captureGitCheckpointTree(in rootPath: String) async -> String? { nil }

    func openDirtyFileSnapshots(in rootPath: String) -> [AIAgentFileSnapshot] { [] }

    func diffGitTrees(from preTree: String, to postTree: String, in rootPath: String) async -> [AIAgentFileChangeSummary] {
        []
    }

    func restoreGitCheckpointTree(_ treeHash: String, in rootPath: String) async throws -> Int {
        throw AIAgentWorkspaceHostError.gitUnavailable("Git checkpoint restore is unavailable.")
    }

    func discardFileChange(relativePath: String, in rootPath: String) async throws {
        throw AIAgentWorkspaceHostError.gitUnavailable("Discard file change is unavailable.")
    }

    func generateCommitMessage(in rootPath: String) async throws -> String {
        throw AIAgentWorkspaceHostError.commandFailed("AI commit message generation is unavailable.")
    }

    func readImageData(at path: String, maxBytes: Int) -> (mimeType: String, data: Data)? { nil }
}
