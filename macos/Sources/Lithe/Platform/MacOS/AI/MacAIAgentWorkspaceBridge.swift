import Foundation
import LitheCoreContracts

struct MacAIAgentWorkspaceHostBuilder: AIAgentWorkspaceHostBuilding, @unchecked Sendable {
    let processRunner: any ProcessRunner
    let runtimeService: ProjectRuntimeService
    let fileStorage: any FileStorage

    @MainActor
    func makeHost(callbacks: AIAgentHostCallbacks) -> any AIAgentWorkspaceHost {
        MacAIAgentWorkspaceBridge(
            callbacks: callbacks,
            processRunner: processRunner,
            runtimeService: runtimeService,
            fileStorage: fileStorage
        )
    }
}

/// macOS workspace/Git/worktree bridge for `LitheAIAgentModule`.
///
/// Enforces strict canonical root containment for every file operation, runs
/// bounded shell/Git commands inside the thread's active workspace or isolated
/// worktree, and forwards UI actions cleanly back to `AppModel`.
@MainActor
final class MacAIAgentWorkspaceBridge: AIAgentWorkspaceHost {
    private let callbacks: AIAgentHostCallbacks
    private let processRunner: any ProcessRunner
    private let runtimeService: ProjectRuntimeService
    private let fileStorage: any FileStorage
    private let fileManager: FileManager

    init(
        callbacks: AIAgentHostCallbacks,
        processRunner: any ProcessRunner,
        runtimeService: ProjectRuntimeService,
        fileStorage: any FileStorage,
        fileManager: FileManager = .default
    ) {
        self.callbacks = callbacks
        self.processRunner = processRunner
        self.runtimeService = runtimeService
        self.fileStorage = fileStorage
        self.fileManager = fileManager
    }

    var workspacePath: String? { callbacks.workspacePath() }
    var agentSettings: AIAgentSettings { callbacks.agentSettings() }
    var commitMessageAISettings: CommitMessageAISettings { callbacks.commitMessageAISettings() }

    func projectRelativeFiles(in rootPath: String) -> [String] {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let skippedDirs: Set<String> = [".git", ".build", "node_modules", "target", ".venv", "__pycache__", "dist"]
        var results: [String] = []
        results.reserveCapacity(256)
        while let item = enumerator.nextObject() as? URL {
            let name = item.lastPathComponent
            if skippedDirs.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let path = item.standardizedFileURL.path
                if path.hasPrefix(rootPrefix) {
                    results.append(String(path.dropFirst(rootPrefix.count)))
                }
                if results.count >= 2000 { break }
            }
        }
        return results.sorted()
    }

    func readFile(relativePath: String, rootPath: String) async throws -> String {
        let targetURL = try resolveContainedURL(relativePath: relativePath, rootPath: rootPath)
        if let openText = callbacks.readOpenDocumentText(targetURL) {
            return openText
        }
        guard fileStorage.fileExists(at: targetURL) else {
            throw AIAgentWorkspaceHostError.fileNotFound(relativePath)
        }
        let data = try fileStorage.readData(from: targetURL, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    func writeFile(
        relativePath: String,
        content: String,
        expectedSourceText: String?,
        rootPath: String
    ) async throws {
        let targetURL = try resolveContainedURL(relativePath: relativePath, rootPath: rootPath)
        let canonicalRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        let normalizedRelative = targetURL.path.hasPrefix(rootPrefix)
            ? String(targetURL.path.dropFirst(rootPrefix.count))
            : relativePath

        let activeWorkspaceCanonical = callbacks.workspacePath().map {
            URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        }
        let existsOnDiskOrBuffer = fileStorage.fileExists(at: targetURL)
            || callbacks.readOpenDocumentText(targetURL) != nil

        // Route existing-file mutations inside the active workspace through the
        // document transaction owner so open dirty buffers, mutation leases,
        // freshness validation, disk compensation, and shared Undo/Redo hold.
        if existsOnDiskOrBuffer,
           let activeWorkspaceCanonical,
           activeWorkspaceCanonical == canonicalRoot,
           !normalizedRelative.isEmpty {
            let sourceText: String
            if let expectedSourceText {
                sourceText = expectedSourceText
            } else {
                sourceText = try await readFile(relativePath: normalizedRelative, rootPath: rootPath)
            }
            let applied = try await callbacks.applyWorkspaceTextEdit(
                normalizedRelative,
                sourceText,
                content,
                URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
            )
            guard applied else {
                throw AIAgentWorkspaceHostError.commandFailed(
                    "File '\(normalizedRelative)' changed or became read-only before the edit could be applied."
                )
            }
            return
        }

        let parent = targetURL.deletingLastPathComponent()
        try fileStorage.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileStorage.writeData(Data(content.utf8), to: targetURL, options: .atomic)
    }

    func deleteFile(relativePath: String, rootPath: String) async throws {
        let targetURL = try resolveContainedURL(relativePath: relativePath, rootPath: rootPath)
        if fileStorage.fileExists(at: targetURL) {
            try fileStorage.removeItem(at: targetURL)
        }
    }

    func fileExists(relativePath: String, rootPath: String) -> Bool {
        guard let targetURL = try? resolveContainedURL(relativePath: relativePath, rootPath: rootPath) else {
            return false
        }
        return fileStorage.fileExists(at: targetURL)
    }

    func searchFiles(query: String, rootPath: String, maxResults: Int) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let env = runtimeService.processEnvironment()
        let runner = processRunner
        let rgPath = runtimeService.executableOnPath("rg")?.path
        let grepPath = "/usr/bin/grep"
        let limit = max(1, min(maxResults, 200))

        return await Task.detached(priority: .utility) {
            let result: ProcessResult
            if let rgPath {
                result = runner.run(ProcessRequest(
                    executablePath: rgPath,
                    arguments: ["-n", "--no-heading", "--color=never", "-m", "5", "--", trimmed, "."],
                    workingDirectory: rootPath,
                    environment: env,
                    timeoutMilliseconds: 5000
                ))
            } else {
                result = runner.run(ProcessRequest(
                    executablePath: grepPath,
                    arguments: ["-rn", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=target", "--", trimmed, "."],
                    workingDirectory: rootPath,
                    environment: env,
                    timeoutMilliseconds: 5000
                ))
            }
            return result.output
                .split(whereSeparator: \.isNewline)
                .prefix(limit)
                .map(String.init)
        }.value
    }

    func runShellCommand(_ command: String, rootPath: String) async -> (exitCode: Int32, output: String) {
        let env = runtimeService.processEnvironment()
        let runner = processRunner
        return await Task.detached(priority: .utility) {
            let result = runner.run(ProcessRequest(
                executablePath: "/bin/zsh",
                arguments: ["-lc", command],
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 30_000
            ))
            return (result.exitCode, result.output)
        }.value
    }

    func workingTreeDiff(in rootPath: String) async -> AIAgentWorkingTreeDiff {
        let gitPath = runtimeService.executableOnPath("git")?.path ?? "/usr/bin/git"
        let env = runtimeService.processEnvironment()
        let runner = processRunner

        return await Task.detached(priority: .utility) {
            let insideRes = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["rev-parse", "--is-inside-work-tree"],
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 3000
            ))
            guard insideRes.succeeded,
                  insideRes.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
                return AIAgentWorkingTreeDiff(rootPath: rootPath)
            }

            let branchRes = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["rev-parse", "--abbrev-ref", "HEAD"],
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 3000
            ))
            let branchName: String
            if branchRes.succeeded {
                branchName = branchRes.output.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let symRes = runner.run(ProcessRequest(
                    executablePath: gitPath,
                    arguments: ["symbolic-ref", "--short", "HEAD"],
                    workingDirectory: rootPath,
                    environment: env,
                    timeoutMilliseconds: 3000
                ))
                branchName = symRes.succeeded
                    ? symRes.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    : "HEAD"
            }

            let headRes = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["rev-parse", "--verify", "HEAD"],
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 3000
            ))
            let headHash = headRes.succeeded ? headRes.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil

            let statusRes = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["-c", "core.quotePath=false", "status", "--porcelain=v1", "-uall"],
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 4000
            ))
            let diffTargetArgs = headHash != nil ? ["HEAD"] : ["--cached"]
            let numstatRes = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["-c", "core.quotePath=false", "diff", "--numstat"] + diffTargetArgs,
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 4000
            ))
            let diffRes = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["-c", "core.quotePath=false", "diff"] + diffTargetArgs,
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 5000
            ))

            var statsByPath: [String: (Int, Int)] = [:]
            for line in numstatRes.output.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 3 else { continue }
                let adds = Int(parts[0]) ?? 0
                let dels = Int(parts[1]) ?? 0
                let path = String(parts[2])
                statsByPath[path] = (adds, dels)
            }

            let patchByFile = Self.splitUnifiedDiffByFile(diffRes.output)
            var files: [AIAgentFileChangeSummary] = []
            for rawLine in statusRes.output.split(whereSeparator: \.isNewline) {
                let line = String(rawLine)
                guard line.count >= 4 else { continue }
                let code = String(line.prefix(2))
                var path = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if let arrowRange = path.range(of: " -> ") {
                    path = String(path[arrowRange.upperBound...])
                }
                path = Self.unquoteGitPath(path)
                let kind: AIAgentFileChangeKind
                if code.contains("?") || code.contains("A") {
                    kind = .added
                } else if code.contains("D") {
                    kind = .deleted
                } else if code.contains("R") {
                    kind = .renamed
                } else {
                    kind = .modified
                }
                let counts = statsByPath[path] ?? (0, 0)
                files.append(AIAgentFileChangeSummary(
                    path: path,
                    kind: kind,
                    additions: counts.0,
                    deletions: counts.1,
                    diffText: patchByFile[path] ?? ""
                ))
            }

            return AIAgentWorkingTreeDiff(
                rootPath: rootPath,
                branchName: branchName,
                headHash: headHash,
                files: files,
                unifiedPatch: String(diffRes.output.prefix(200_000))
            )
        }.value
    }

    func createIsolatedWorktree(branchName: String, from workspaceRoot: String) async throws -> AIAgentWorktreeInfo {
        let sanitizedBranch = branchName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        guard !sanitizedBranch.isEmpty,
              !sanitizedBranch.hasPrefix("-"),
              !sanitizedBranch.contains("..") else {
            throw AIAgentWorkspaceHostError.gitUnavailable("Invalid branch name '\(branchName)'.")
        }

        let repoURL = URL(fileURLWithPath: workspaceRoot, isDirectory: true).standardizedFileURL
        let parentDir = repoURL.deletingLastPathComponent()
            .appendingPathComponent("\(repoURL.lastPathComponent)-worktrees", isDirectory: true)
        let folderSlug = sanitizedBranch.replacingOccurrences(of: "/", with: "-")
        let destinationURL = parentDir.appendingPathComponent(folderSlug, isDirectory: true)

        try fileStorage.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let gitPath = runtimeService.executableOnPath("git")?.path ?? "/usr/bin/git"
        let env = runtimeService.processEnvironment()
        let runner = processRunner
        let result = await Task.detached(priority: .utility) {
            runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["worktree", "add", "-b", sanitizedBranch, "--", destinationURL.path, "HEAD"],
                workingDirectory: workspaceRoot,
                environment: env,
                timeoutMilliseconds: 15_000
            ))
        }.value

        guard result.succeeded else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AIAgentWorkspaceHostError.gitUnavailable(detail.isEmpty ? "Failed to create Git worktree." : detail)
        }
        return AIAgentWorktreeInfo(path: destinationURL.standardizedFileURL.path, branchName: sanitizedBranch)
    }

    func removeIsolatedWorktree(path: String, from workspaceRoot: String) async throws {
        let gitPath = runtimeService.executableOnPath("git")?.path ?? "/usr/bin/git"
        let env = runtimeService.processEnvironment()
        let runner = processRunner
        let result = await Task.detached(priority: .utility) {
            runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["worktree", "remove", "--force", "--", path],
                workingDirectory: workspaceRoot,
                environment: env,
                timeoutMilliseconds: 15_000
            ))
        }.value
        guard result.succeeded else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AIAgentWorkspaceHostError.gitUnavailable(detail.isEmpty ? "Failed to remove Git worktree." : detail)
        }
    }

    func commitChanges(message: String, in rootPath: String) async throws -> String {
        let gitPath = runtimeService.executableOnPath("git")?.path ?? "/usr/bin/git"
        let env = runtimeService.processEnvironment()
        let runner = processRunner
        let result = await Task.detached(priority: .utility) { () -> ProcessResult in
            let addResult = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["add", "-A"],
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 10_000
            ))
            guard addResult.succeeded else { return addResult }
            return runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["commit", "-m", message],
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 15_000
            ))
        }.value

        guard result.succeeded else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AIAgentWorkspaceHostError.gitUnavailable(detail.isEmpty ? "Git commit failed." : detail)
        }
        return result.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Committed changes"
    }

    func pushCurrentBranch(in rootPath: String) async throws -> String {
        let gitPath = runtimeService.executableOnPath("git")?.path ?? "/usr/bin/git"
        let env = runtimeService.processEnvironment()
        let runner = processRunner
        let result = await Task.detached(priority: .utility) {
            runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["push", "-u", "origin", "HEAD"],
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 30_000
            ))
        }.value
        guard result.succeeded else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AIAgentWorkspaceHostError.gitUnavailable(detail.isEmpty ? "Git push failed." : detail)
        }
        return "Pushed branch to origin"
    }

    func openFile(relativePath: String, rootPath: String) {
        guard let url = try? resolveContainedURL(relativePath: relativePath, rootPath: rootPath) else { return }
        callbacks.openFile(url)
    }

    func openDiff(relativePath: String, rootPath: String) {
        callbacks.openDiffForRelativePath(relativePath, rootPath)
    }

    func refreshWorkspaceAndGit() async {
        await callbacks.refreshWorkspaceAndGit()
    }

    func notify(_ message: String) {
        callbacks.notify(message)
    }

    // MARK: - Helpers

    private func resolveContainedURL(relativePath: String, rootPath: String) throws -> URL {
        let cleanRel = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRel.isEmpty else {
            throw AIAgentWorkspaceHostError.pathOutsideWorkspace(relativePath)
        }
        let canonicalRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate: URL
        if cleanRel.hasPrefix("/") {
            candidate = URL(fileURLWithPath: cleanRel).standardizedFileURL
        } else {
            candidate = canonicalRoot.appendingPathComponent(cleanRel).standardizedFileURL
        }
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard resolvedCandidate.path == canonicalRoot.path || resolvedCandidate.path.hasPrefix(rootPrefix) else {
            throw AIAgentWorkspaceHostError.pathOutsideWorkspace(relativePath)
        }
        return resolvedCandidate
    }

    nonisolated static func splitUnifiedDiffByFile(_ patch: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentHeaderPath: String?
        var currentPlusPath: String?
        var currentMinusPath: String?
        var currentLines: [String] = []

        func flush() {
            let resolved = currentPlusPath ?? currentMinusPath ?? currentHeaderPath
            if let path = resolved, !path.isEmpty, !currentLines.isEmpty {
                result[path] = currentLines.joined(separator: "\n")
            }
            currentHeaderPath = nil
            currentPlusPath = nil
            currentMinusPath = nil
            currentLines.removeAll(keepingCapacity: true)
        }

        for rawLine in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("diff --git ") {
                flush()
                currentHeaderPath = parseDiffGitHeaderDestination(line)
                currentLines.append(line)
                continue
            }
            guard !currentLines.isEmpty else { continue }
            if currentPlusPath == nil, line.hasPrefix("+++ ") {
                let raw = String(line.dropFirst(4))
                if raw != "/dev/null" {
                    let unquoted = unquoteGitPath(raw)
                    currentPlusPath = unquoted.hasPrefix("b/") ? String(unquoted.dropFirst(2)) : unquoted
                }
            } else if currentMinusPath == nil, line.hasPrefix("--- ") {
                let raw = String(line.dropFirst(4))
                if raw != "/dev/null" {
                    let unquoted = unquoteGitPath(raw)
                    currentMinusPath = unquoted.hasPrefix("a/") ? String(unquoted.dropFirst(2)) : unquoted
                }
            }
            currentLines.append(line)
        }
        flush()
        return result
    }

    nonisolated static func unquoteGitPath(_ raw: String) -> String {
        guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else { return raw }
        let inner = String(raw.dropFirst().dropLast())
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private nonisolated static func parseDiffGitHeaderDestination(_ line: String) -> String? {
        let rest = String(line.dropFirst("diff --git ".count))
        if let range = rest.range(of: " b/", options: .backwards) {
            return unquoteGitPath(String(rest[range.upperBound...]))
        }
        if let range = rest.range(of: " \"b/", options: .backwards) {
            let quoted = "\"" + String(rest[range.upperBound...])
            return unquoteGitPath(quoted)
        }
        return nil
    }
}
