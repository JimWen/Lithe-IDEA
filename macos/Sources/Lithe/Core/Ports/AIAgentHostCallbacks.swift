import Foundation
import LitheCoreContracts

/// Platform-neutral callbacks injected by `AppModel` into the macOS AI Agent workspace bridge.
@MainActor
struct AIAgentHostCallbacks {
    let workspacePath: () -> String?
    let agentSettings: () -> AIAgentSettings
    let commitMessageAISettings: () -> CommitMessageAISettings
    let readOpenDocumentText: (URL) -> String?
    let applyWorkspaceTextEdit: (String, String, String, URL) async throws -> Bool
    let openFile: (URL) -> Void
    let openDiffForRelativePath: (String, String) -> Void
    let refreshWorkspaceAndGit: () async -> Void
    let notify: (String) -> Void
}

protocol AIAgentWorkspaceHostBuilding: Sendable {
    @MainActor
    func makeHost(callbacks: AIAgentHostCallbacks) -> any AIAgentWorkspaceHost
}

struct UnavailableAIAgentWorkspaceHostBuilder: AIAgentWorkspaceHostBuilding {
    @MainActor
    func makeHost(callbacks: AIAgentHostCallbacks) -> any AIAgentWorkspaceHost {
        UnavailableAIAgentWorkspaceHost(callbacks: callbacks)
    }
}

@MainActor
private final class UnavailableAIAgentWorkspaceHost: AIAgentWorkspaceHost {
    private let callbacks: AIAgentHostCallbacks
    init(callbacks: AIAgentHostCallbacks) { self.callbacks = callbacks }
    var workspacePath: String? { callbacks.workspacePath() }
    var agentSettings: AIAgentSettings { callbacks.agentSettings() }
    var commitMessageAISettings: CommitMessageAISettings { callbacks.commitMessageAISettings() }
    func projectRelativeFiles(in rootPath: String) -> [String] { [] }
    func readFile(relativePath: String, rootPath: String) async throws -> String {
        throw AIAgentWorkspaceHostError.fileNotFound(relativePath)
    }
    func writeFile(relativePath: String, content: String, expectedSourceText: String?, rootPath: String) async throws {
        throw AIAgentWorkspaceHostError.commandFailed("Unavailable")
    }
    func deleteFile(relativePath: String, rootPath: String) async throws {
        throw AIAgentWorkspaceHostError.commandFailed("Unavailable")
    }
    func fileExists(relativePath: String, rootPath: String) -> Bool { false }
    func searchFiles(query: String, rootPath: String, maxResults: Int) async -> [String] { [] }
    func runShellCommand(_ command: String, rootPath: String) async -> (exitCode: Int32, output: String) {
        (1, "Unavailable")
    }
    func workingTreeDiff(in rootPath: String) async -> AIAgentWorkingTreeDiff {
        AIAgentWorkingTreeDiff(rootPath: rootPath)
    }
    func createIsolatedWorktree(branchName: String, from workspaceRoot: String) async throws -> AIAgentWorktreeInfo {
        throw AIAgentWorkspaceHostError.gitUnavailable("Unavailable")
    }
    func removeIsolatedWorktree(path: String, from workspaceRoot: String) async throws {
        throw AIAgentWorkspaceHostError.gitUnavailable("Unavailable")
    }
    func commitChanges(message: String, in rootPath: String) async throws -> String {
        throw AIAgentWorkspaceHostError.gitUnavailable("Unavailable")
    }
    func pushCurrentBranch(in rootPath: String) async throws -> String {
        throw AIAgentWorkspaceHostError.gitUnavailable("Unavailable")
    }
    func openFile(relativePath: String, rootPath: String) {}
    func openDiff(relativePath: String, rootPath: String) {}
    func refreshWorkspaceAndGit() async { await callbacks.refreshWorkspaceAndGit() }
    func notify(_ message: String) { callbacks.notify(message) }
}
