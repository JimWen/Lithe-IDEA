import Darwin
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
        try await writeFile(
            relativePath: relativePath,
            content: content,
            expectedSourceText: expectedSourceText,
            rootPath: rootPath,
            persistOpenBufferToDisk: false
        )
    }

    private func writeFile(
        relativePath: String,
        content: String,
        expectedSourceText: String?,
        rootPath: String,
        persistOpenBufferToDisk: Bool
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
                URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL,
                persistOpenBufferToDisk
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

    private struct GitRepositoryLayout: Sendable {
        let topLevel: String
        /// Trailing-slash repo-relative prefix for the opened workspace (e.g. `""` or `"src/"`).
        let workspacePrefix: String

        func repoRelativePath(for workspaceRelativePath: String) -> String {
            workspacePrefix.isEmpty ? workspaceRelativePath : workspacePrefix + workspaceRelativePath
        }

        func workspaceRelativePath(for repoRelativePath: String) -> String? {
            guard !workspacePrefix.isEmpty else { return repoRelativePath }
            guard repoRelativePath.hasPrefix(workspacePrefix) else { return nil }
            let trimmed = String(repoRelativePath.dropFirst(workspacePrefix.count))
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    func workingTreeDiff(in rootPath: String) async -> AIAgentWorkingTreeDiff {
        let gitPath = runtimeService.executableOnPath("git")?.path ?? "/usr/bin/git"
        let env = runtimeService.processEnvironment()
        let runner = processRunner

        return await Task.detached(priority: .utility) {
            guard let layout = Self.gitRepositoryLayout(gitPath: gitPath, env: env, runner: runner, rootPath: rootPath) else {
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

            var aheadCount = 0
            var behindCount = 0
            if headHash != nil {
                let abRes = runner.run(ProcessRequest(
                    executablePath: gitPath,
                    arguments: ["rev-list", "--left-right", "--count", "@{u}...HEAD"],
                    workingDirectory: rootPath,
                    environment: env,
                    timeoutMilliseconds: 2500
                ))
                if abRes.succeeded {
                    let parts = abRes.output
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(whereSeparator: \.isWhitespace)
                    if parts.count == 2 {
                        behindCount = Int(parts[0]) ?? 0
                        aheadCount = Int(parts[1]) ?? 0
                    }
                }
            }

            let statusRes = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["-c", "core.quotePath=false", "status", "--porcelain=v1", "-uall", "--", "."],
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 4000
            ))
            let diffTargetArgs = headHash != nil ? ["HEAD", "--", "."] : ["--cached", "--", "."]
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
                let repoPath = Self.unquoteGitPath(String(parts[2]))
                if let wsPath = layout.workspaceRelativePath(for: repoPath) {
                    statsByPath[wsPath] = (adds, dels)
                }
            }

            let rawPatchByRepoFile = Self.splitUnifiedDiffByFile(diffRes.output)
            var patchByPath: [String: String] = [:]
            for (repoPath, patch) in rawPatchByRepoFile {
                if let wsPath = layout.workspaceRelativePath(for: repoPath) {
                    patchByPath[wsPath] = patch
                }
            }

            var files: [AIAgentFileChangeSummary] = []
            var combinedPatch = diffRes.output
            for rawLine in statusRes.output.split(whereSeparator: \.isNewline) {
                let line = String(rawLine)
                guard line.count >= 4 else { continue }
                let code = String(line.prefix(2))
                var repoPath = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if let arrowRange = repoPath.range(of: " -> ") {
                    repoPath = String(repoPath[arrowRange.upperBound...])
                }
                repoPath = Self.unquoteGitPath(repoPath)
                guard let path = layout.workspaceRelativePath(for: repoPath) else { continue }
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
                var counts = statsByPath[path] ?? (0, 0)
                var fileDiff = patchByPath[path] ?? ""
                if code == "??", fileDiff.isEmpty,
                   let synthesized = Self.synthesizeUntrackedDiff(relativePath: path, rootPath: rootPath) {
                    counts = (synthesized.lineCount, 0)
                    fileDiff = synthesized.diffText
                    if combinedPatch.count < 200_000 {
                        if !combinedPatch.isEmpty && !combinedPatch.hasSuffix("\n") {
                            combinedPatch.append("\n")
                        }
                        combinedPatch.append(synthesized.diffText)
                    }
                }
                files.append(AIAgentFileChangeSummary(
                    path: path,
                    kind: kind,
                    additions: counts.0,
                    deletions: counts.1,
                    diffText: fileDiff
                ))
            }

            return AIAgentWorkingTreeDiff(
                rootPath: rootPath,
                branchName: branchName,
                headHash: headHash,
                aheadCount: aheadCount,
                behindCount: behindCount,
                files: files,
                unifiedPatch: String(combinedPatch.prefix(200_000))
            )
        }.value
    }

    func captureGitCheckpointTree(in rootPath: String) async -> String? {
        let gitPath = runtimeService.executableOnPath("git")?.path ?? "/usr/bin/git"
        let env = runtimeService.processEnvironment()
        let runner = processRunner

        return await Task.detached(priority: .utility) {
            Self.captureTempGitTree(gitPath: gitPath, env: env, runner: runner, rootPath: rootPath)
        }.value
    }

    func diffGitTrees(from preTree: String, to postTree: String, in rootPath: String) async -> [AIAgentFileChangeSummary] {
        guard Self.isValidGitOID(preTree), Self.isValidGitOID(postTree), preTree != postTree else {
            return []
        }
        let gitPath = runtimeService.executableOnPath("git")?.path ?? "/usr/bin/git"
        let env = runtimeService.processEnvironment()
        let runner = processRunner

        return await Task.detached(priority: .utility) {
            guard let layout = Self.gitRepositoryLayout(gitPath: gitPath, env: env, runner: runner, rootPath: rootPath) else {
                return []
            }
            let statusRes = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["-c", "core.quotePath=false", "diff", "--no-renames", "--name-status", preTree, postTree, "--", "."],
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 4000
            ))
            guard statusRes.succeeded else { return [] }
            let numstatRes = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["-c", "core.quotePath=false", "diff", "--no-renames", "--numstat", preTree, postTree, "--", "."],
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 4000
            ))
            let diffRes = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["-c", "core.quotePath=false", "diff", "--no-renames", preTree, postTree, "--", "."],
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
                let repoPath = Self.unquoteGitPath(String(parts[2]))
                if let wsPath = layout.workspaceRelativePath(for: repoPath) {
                    statsByPath[wsPath] = (adds, dels)
                }
            }
            let rawPatchByRepo = Self.splitUnifiedDiffByFile(diffRes.output)
            var patchByPath: [String: String] = [:]
            for (repoPath, patch) in rawPatchByRepo {
                if let wsPath = layout.workspaceRelativePath(for: repoPath) {
                    patchByPath[wsPath] = patch
                }
            }

            var summaries: [AIAgentFileChangeSummary] = []
            for rawLine in statusRes.output.split(whereSeparator: \.isNewline) {
                let parts = rawLine.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let statusCode = String(parts[0])
                let repoPath = Self.unquoteGitPath(String(parts[1]))
                guard let path = layout.workspaceRelativePath(for: repoPath) else { continue }
                let kind: AIAgentFileChangeKind
                if statusCode.hasPrefix("A") {
                    kind = .added
                } else if statusCode.hasPrefix("D") {
                    kind = .deleted
                } else if statusCode.hasPrefix("R") {
                    kind = .renamed
                } else {
                    kind = .modified
                }
                let counts = statsByPath[path] ?? (0, 0)
                summaries.append(AIAgentFileChangeSummary(
                    path: path,
                    kind: kind,
                    additions: counts.0,
                    deletions: counts.1,
                    diffText: patchByPath[path] ?? ""
                ))
            }
            return summaries
        }.value
    }

    nonisolated private static let maxSafeTextBlobBytes = 16 * 1024 * 1024

    func openDirtyFileSnapshots(in rootPath: String) -> [AIAgentFileSnapshot] {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        return callbacks.dirtyOpenDocumentSnapshots(rootURL).map {
            AIAgentFileSnapshot(relativePath: $0.relativePath, previousContent: $0.text)
        }
    }

    private struct GitRawDiffEntry: Sendable {
        let oldMode: String
        let newMode: String
        let oldHash: String
        let status: String
        let repoPath: String
    }

    private struct StagedTextRestore: Sendable {
        let workspacePath: String
        let repoPath: String
        let content: String
        let targetMode: String
        let modeChanged: Bool
    }

    private struct StagedRawCheckout: Sendable {
        let workspacePath: String
        let repoPath: String
        let replaceExisting: Bool
    }

    func restoreGitCheckpointTree(_ treeHash: String, in rootPath: String) async throws -> Int {
        guard Self.isValidGitOID(treeHash) else {
            throw AIAgentWorkspaceHostError.gitUnavailable("Invalid Git checkpoint tree identifier.")
        }
        let gitPath = runtimeService.executableOnPath("git")?.path ?? "/usr/bin/git"
        let env = runtimeService.processEnvironment()
        let runner = processRunner

        // Stage 1 (Preflight): rebase Git paths to the opened workspace, preserve pre-existing
        // ignored files when .gitignore changed, materialize working-tree representations via
        // Git checkout-index (honoring .gitattributes / eol / filters), and strictly validate UTF-8
        // BEFORE mutating a single file in the workspace.
        let staged = try await Task.detached(priority: .utility) { () throws -> (
            layout: GitRepositoryLayout,
            preRevertTree: String,
            toDelete: [(workspacePath: String, repoPath: String)],
            toRestoreText: [StagedTextRestore],
            toCheckoutRaw: [StagedRawCheckout]
        ) in
            guard let layout = Self.gitRepositoryLayout(gitPath: gitPath, env: env, runner: runner, rootPath: rootPath) else {
                throw AIAgentWorkspaceHostError.gitUnavailable("Workspace is not inside a Git repository.")
            }
            let typeRes = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["cat-file", "-t", treeHash],
                workingDirectory: layout.topLevel,
                environment: env,
                timeoutMilliseconds: 3000
            ))
            guard typeRes.succeeded,
                  typeRes.output.trimmingCharacters(in: .whitespacesAndNewlines) == "tree" else {
                throw AIAgentWorkspaceHostError.gitUnavailable("Git checkpoint object \(treeHash.prefix(8)) is no longer available.")
            }

            guard let currentTree = Self.captureTempGitTree(gitPath: gitPath, env: env, runner: runner, rootPath: rootPath) else {
                throw AIAgentWorkspaceHostError.gitUnavailable("Could not inspect current Git working tree.")
            }
            if currentTree == treeHash {
                return (layout, currentTree, [], [], [])
            }

            // Inspect all repo entries using NUL-delimited (-z) output so filenames with
            // tabs, quotes, or newlines are parsed verbatim with zero C-escaping ambiguity.
            let allRawRes = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["diff", "--raw", "--no-renames", "-z", treeHash, currentTree],
                workingDirectory: layout.topLevel,
                environment: env,
                timeoutMilliseconds: 5000
            ))
            guard allRawRes.succeeded else {
                throw AIAgentWorkspaceHostError.gitUnavailable("Failed to compute checkpoint diff.")
            }
            let allEntries = Self.parseGitRawDiffZ(allRawRes.output)
            let ignoreRulesChanged = allEntries.contains { entry in
                (entry.repoPath as NSString).lastPathComponent == ".gitignore"
            }

            let numstatRes = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["diff", "--no-renames", "--numstat", "-z", treeHash, currentTree, "--", "."],
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 5000
            ))
            var binaryRepoPaths: Set<String> = []
            for entry in Self.parseGitNumstatZ(numstatRes.output) where entry.isBinary {
                binaryRepoPaths.insert(entry.repoPath)
            }

            // Restrict mutations strictly to entries inside the opened workspace.
            let workspaceEntries = allEntries.compactMap { entry -> (entry: GitRawDiffEntry, workspacePath: String)? in
                guard let wsPath = layout.workspaceRelativePath(for: entry.repoPath) else { return nil }
                return (entry, wsPath)
            }

            var toDelete: [(workspacePath: String, repoPath: String)] = []
            var candidateTextEntries: [(entry: GitRawDiffEntry, workspacePath: String)] = []
            var toCheckoutRaw: [StagedRawCheckout] = []

            // If .gitignore changed, identify any `A` paths that were ignored under preTree's
            // ignore rules so we NEVER delete a pre-existing ignored user file (e.g. private.env).
            var ignoredInPreTree: Set<String> = []
            if ignoreRulesChanged {
                let addedRepoPaths = workspaceEntries
                    .filter { $0.entry.status.hasPrefix("A") }
                    .map(\.entry.repoPath)
                if !addedRepoPaths.isEmpty {
                    ignoredInPreTree = Self.pathsIgnoredUnderTree(
                        treeHash: treeHash,
                        candidateRepoPaths: addedRepoPaths,
                        gitPath: gitPath,
                        env: env,
                        runner: runner,
                        repoTopLevel: layout.topLevel
                    )
                }
            }

            for (entry, wsPath) in workspaceEntries {
                if entry.oldMode == "160000" || entry.newMode == "160000" {
                    throw AIAgentWorkspaceHostError.gitUnavailable("Cannot automatically revert submodule entry '\(wsPath)'.")
                }
                if entry.status.hasPrefix("A") {
                    if ignoredInPreTree.contains(entry.repoPath) {
                        // File matched pre-turn .gitignore rules and may have pre-existed; preserve it.
                        continue
                    }
                    toDelete.append((workspacePath: wsPath, repoPath: entry.repoPath))
                    continue
                }

                let involvesSymlink = entry.oldMode == "120000" || entry.newMode == "120000"
                let isRegularFile = entry.oldMode == "100644" || entry.oldMode == "100755"
                if involvesSymlink || !isRegularFile || binaryRepoPaths.contains(entry.repoPath) {
                    toCheckoutRaw.append(StagedRawCheckout(
                        workspacePath: wsPath,
                        repoPath: entry.repoPath,
                        replaceExisting: involvesSymlink
                    ))
                    continue
                }
                candidateTextEntries.append((entry: entry, workspacePath: wsPath))
            }

            // Materialize candidate regular files into an isolated staging directory via Git's own
            // checkout-index so .gitattributes (eol=crlf, smudge filters) apply identically to a
            // real Git checkout, then strictly validate raw UTF-8 bytes without lossy decoding.
            var toRestoreText: [StagedTextRestore] = []
            if !candidateTextEntries.isEmpty {
                let materialized = try Self.materializeWorkingTreeFiles(
                    treeHash: treeHash,
                    repoPaths: candidateTextEntries.map(\.entry.repoPath),
                    gitPath: gitPath,
                    env: env,
                    runner: runner,
                    repoTopLevel: layout.topLevel
                )
                defer { try? FileManager.default.removeItem(at: materialized.stagingDirectory) }

                for (entry, wsPath) in candidateTextEntries {
                    let stagedFileURL = materialized.stagingDirectory.appendingPathComponent(entry.repoPath)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: stagedFileURL.path),
                       let size = (attrs[.size] as? NSNumber)?.intValue,
                       size <= Self.maxSafeTextBlobBytes,
                       let rawData = try? Data(contentsOf: stagedFileURL),
                       !rawData.contains(0),
                       let strictText = String(bytes: rawData, encoding: .utf8) {
                        toRestoreText.append(StagedTextRestore(
                            workspacePath: wsPath,
                            repoPath: entry.repoPath,
                            content: strictText,
                            targetMode: entry.oldMode,
                            modeChanged: entry.oldMode != entry.newMode
                        ))
                    } else {
                        toCheckoutRaw.append(StagedRawCheckout(
                            workspacePath: wsPath,
                            repoPath: entry.repoPath,
                            replaceExisting: false
                        ))
                    }
                }
            }
            return (layout, currentTree, toDelete, toRestoreText, toCheckoutRaw)
        }.value

        let totalPlanned = staged.toDelete.count + staged.toRestoreText.count + staged.toCheckoutRaw.count
        guard totalPlanned > 0 else { return 0 }

        // Validate containment for EVERY path and snapshot pre-revert open buffers BEFORE mutating.
        var savedOpenBuffers: [(workspacePath: String, text: String)] = []
        for item in staged.toDelete {
            let url = try resolveContainedURLWithoutFollowingLeafSymlink(relativePath: item.workspacePath, rootPath: rootPath)
            if let openText = callbacks.readOpenDocumentText(url) {
                savedOpenBuffers.append((item.workspacePath, openText))
            }
        }
        for item in staged.toRestoreText {
            let url = try resolveContainedURL(relativePath: item.workspacePath, rootPath: rootPath)
            if let openText = callbacks.readOpenDocumentText(url) {
                savedOpenBuffers.append((item.workspacePath, openText))
            }
        }
        for item in staged.toCheckoutRaw {
            _ = try resolveContainedURLWithoutFollowingLeafSymlink(relativePath: item.workspacePath, rootPath: rootPath)
        }

        // Stage 2 (Apply) with Stage 3 (Full Batch Compensation on failure back to preRevertTree).
        // Partition deletions so BOTH:
        //   1. files blocking a directory path needed by a restored descendant (`pkg` blocking `pkg/child`), AND
        //   2. descendants inside a directory blocking restoration of a former file (`pkg/child` blocking `pkg`)
        // are removed first, while still tracked for rollback.
        let restoredWorkspacePaths = Set(
            staged.toRestoreText.map(\.workspacePath) + staged.toCheckoutRaw.map(\.workspacePath)
        )
        let restorePathPrefixes = Set(
            restoredWorkspacePaths.flatMap { Self.ancestorDirectoryPaths(of: $0) }
        )
        let blockerDeletions = staged.toDelete.filter { item in
            restorePathPrefixes.contains(item.workspacePath)
                || Self.ancestorDirectoryPaths(of: item.workspacePath).contains(where: { restoredWorkspacePaths.contains($0) })
        }
        let trailingDeletions = staged.toDelete.filter { item in
            !restorePathPrefixes.contains(item.workspacePath)
                && !Self.ancestorDirectoryPaths(of: item.workspacePath).contains(where: { restoredWorkspacePaths.contains($0) })
        }

        // Preflight-reject any directory occupying a file/symlink restoration target if it
        // contains untracked or ignored entries not scheduled for deletion (e.g. `pkg/private.log`).
        let scheduledBlockerDeletionPaths = Set(blockerDeletions.map(\.workspacePath))
        for wsPath in restoredWorkspacePaths {
            let leafURL = try resolveContainedURLWithoutFollowingLeafSymlink(relativePath: wsPath, rootPath: rootPath)
            if let attrs = try? fileManager.attributesOfItem(atPath: leafURL.path),
               (attrs[.type] as? FileAttributeType) == .typeDirectory,
               directoryHasPreservedEntries(
                   at: leafURL,
                   workspaceRelativePrefix: wsPath,
                   scheduledDeletions: scheduledBlockerDeletionPaths
               ) {
                throw AIAgentWorkspaceHostError.commandFailed(
                    "Cannot restore '\(wsPath)': directory contains untracked or ignored files."
                )
            }
        }

        var mutatedRepoPaths: Set<String> = []
        var mutatedWorkspacePaths: Set<String> = []
        var createdDuringRestore: [(workspacePath: String, repoPath: String)] = []
        do {
            for item in blockerDeletions {
                let leafURL = try resolveContainedURLWithoutFollowingLeafSymlink(relativePath: item.workspacePath, rootPath: rootPath)
                if (try? fileManager.attributesOfItem(atPath: leafURL.path)) != nil {
                    try removeNonDirectoryLeaf(at: leafURL)
                    mutatedRepoPaths.insert(item.repoPath)
                    mutatedWorkspacePaths.insert(item.workspacePath)
                }
            }

            // If any restored file path is currently occupied by a directory (e.g. former file
            // `pkg` was replaced by `pkg/child` during the turn), prune empty subdirectories
            // bottom-up so the restored file can be written without deleting untracked/ignored files.
            for wsPath in restoredWorkspacePaths {
                let leafURL = try resolveContainedURLWithoutFollowingLeafSymlink(relativePath: wsPath, rootPath: rootPath)
                if let attrs = try? fileManager.attributesOfItem(atPath: leafURL.path),
                   (attrs[.type] as? FileAttributeType) == .typeDirectory {
                    guard pruneEmptyDirectoryTree(at: leafURL) else {
                        throw AIAgentWorkspaceHostError.commandFailed(
                            "Cannot restore '\(wsPath)': directory contains untracked or ignored files."
                        )
                    }
                }
            }

            for item in staged.toRestoreText {
                let existedBefore = fileExists(relativePath: item.workspacePath, rootPath: rootPath)
                // Record mutation intent BEFORE calling writeFile so a partial failure (e.g.
                // open buffer updated, then disk save fails) is always included in compensation.
                mutatedRepoPaths.insert(item.repoPath)
                mutatedWorkspacePaths.insert(item.workspacePath)
                if !existedBefore { createdDuringRestore.append((item.workspacePath, item.repoPath)) }
                try await writeFile(
                    relativePath: item.workspacePath,
                    content: item.content,
                    expectedSourceText: nil,
                    rootPath: rootPath,
                    persistOpenBufferToDisk: true
                )
                if item.modeChanged {
                    let targetURL = try resolveContainedURL(relativePath: item.workspacePath, rootPath: rootPath)
                    let posixMode: Int = item.targetMode == "100755" ? 0o755 : 0o644
                    try fileManager.setAttributes([.posixPermissions: posixMode], ofItemAtPath: targetURL.path)
                }
            }

            if !staged.toCheckoutRaw.isEmpty {
                for item in staged.toCheckoutRaw {
                    let leafURL = try resolveContainedURLWithoutFollowingLeafSymlink(relativePath: item.workspacePath, rootPath: rootPath)
                    let existedBefore = (try? fileManager.attributesOfItem(atPath: leafURL.path)) != nil
                    if !existedBefore { createdDuringRestore.append((item.workspacePath, item.repoPath)) }
                    if item.replaceExisting && existedBefore {
                        try removeNonDirectoryLeaf(at: leafURL)
                    }
                    mutatedRepoPaths.insert(item.repoPath)
                    mutatedWorkspacePaths.insert(item.workspacePath)
                }
                let rawRepoPaths = staged.toCheckoutRaw.map(\.repoPath)
                let topLevel = staged.layout.topLevel
                _ = try await Task.detached(priority: .utility) { () throws -> Int in
                    try Self.checkoutFilesFromGitTree(
                        treeHash: treeHash,
                        repoPaths: rawRepoPaths,
                        gitPath: gitPath,
                        env: env,
                        runner: runner,
                        repoTopLevel: topLevel
                    )
                }.value
            }

            for item in trailingDeletions {
                let leafURL = try resolveContainedURLWithoutFollowingLeafSymlink(relativePath: item.workspacePath, rootPath: rootPath)
                if (try? fileManager.attributesOfItem(atPath: leafURL.path)) != nil {
                    try removeNonDirectoryLeaf(at: leafURL)
                    mutatedRepoPaths.insert(item.repoPath)
                    mutatedWorkspacePaths.insert(item.workspacePath)
                }
            }
            return totalPlanned
        } catch let applyError {
            await compensateFailedRestore(
                layout: staged.layout,
                preRevertTree: staged.preRevertTree,
                mutatedRepoPaths: Array(mutatedRepoPaths),
                mutatedWorkspacePaths: mutatedWorkspacePaths,
                createdDuringRestore: createdDuringRestore,
                savedOpenBuffers: savedOpenBuffers,
                gitPath: gitPath,
                env: env,
                runner: runner,
                rootPath: rootPath
            )
            throw applyError
        }
    }

    private func compensateFailedRestore(
        layout: GitRepositoryLayout,
        preRevertTree: String,
        mutatedRepoPaths: [String],
        mutatedWorkspacePaths: Set<String>,
        createdDuringRestore: [(workspacePath: String, repoPath: String)],
        savedOpenBuffers: [(workspacePath: String, text: String)],
        gitPath: String,
        env: [String: String],
        runner: any ProcessRunner,
        rootPath: String
    ) async {
        let createdRepoSet = Set(createdDuringRestore.map(\.repoPath))
        for item in createdDuringRestore {
            if let leafURL = try? resolveContainedURLWithoutFollowingLeafSymlink(relativePath: item.workspacePath, rootPath: rootPath) {
                try? removeNonDirectoryLeaf(at: leafURL)
            }
        }
        let repoPathsToRestore = mutatedRepoPaths.filter { !createdRepoSet.contains($0) }
        if !repoPathsToRestore.isEmpty {
            for repoPath in repoPathsToRestore {
                if let wsPath = layout.workspaceRelativePath(for: repoPath),
                   let leafURL = try? resolveContainedURLWithoutFollowingLeafSymlink(relativePath: wsPath, rootPath: rootPath),
                   (try? fileManager.attributesOfItem(atPath: leafURL.path)) != nil {
                    try? removeNonDirectoryLeaf(at: leafURL)
                }
            }
            _ = await Task.detached(priority: .utility) {
                try? Self.checkoutFilesFromGitTree(
                    treeHash: preRevertTree,
                    repoPaths: repoPathsToRestore,
                    gitPath: gitPath,
                    env: env,
                    runner: runner,
                    repoTopLevel: layout.topLevel
                )
            }.value
        }
        for saved in savedOpenBuffers where mutatedWorkspacePaths.contains(saved.workspacePath) {
            try? await writeFile(
                relativePath: saved.workspacePath,
                content: saved.text,
                expectedSourceText: nil,
                rootPath: rootPath
            )
        }
    }

    private func removeNonDirectoryLeaf(at url: URL) throws {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else {
            return
        }
        if (attrs[.type] as? FileAttributeType) == .typeDirectory {
            throw AIAgentWorkspaceHostError.commandFailed(
                "Refused recursive removal of directory '\(url.lastPathComponent)'."
            )
        }
        try fileManager.removeItem(at: url)
    }

    /// Returns `true` if `directoryURL` contains any regular file, symlink, or special entry
    /// whose workspace-relative path is NOT in `scheduledDeletions` (e.g. ignored or untracked files).
    private func directoryHasPreservedEntries(
        at directoryURL: URL,
        workspaceRelativePrefix: String,
        scheduledDeletions: Set<String>
    ) -> Bool {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return true
        }
        for child in children {
            let childRel = "\(workspaceRelativePrefix)/\(child.lastPathComponent)"
            guard let attrs = try? fileManager.attributesOfItem(atPath: child.path) else {
                return true
            }
            if (attrs[.type] as? FileAttributeType) == .typeDirectory {
                if directoryHasPreservedEntries(
                    at: child,
                    workspaceRelativePrefix: childRel,
                    scheduledDeletions: scheduledDeletions
                ) {
                    return true
                }
            } else if !scheduledDeletions.contains(childRel) {
                return true
            }
        }
        return false
    }

    /// Recursively removes a directory tree ONLY if it contains no regular files or symlinks
    /// (i.e. purely empty directories left behind after removing tracked/blocker descendants).
    private func pruneEmptyDirectoryTree(at directoryURL: URL) -> Bool {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return false
        }
        for child in children {
            guard let attrs = try? fileManager.attributesOfItem(atPath: child.path),
                  (attrs[.type] as? FileAttributeType) == .typeDirectory else {
                return false
            }
            if !pruneEmptyDirectoryTree(at: child) {
                return false
            }
        }
        do {
            try fileManager.removeItem(at: directoryURL)
            return true
        } catch {
            return false
        }
    }

    func discardFileChange(relativePath: String, in rootPath: String) async throws {
        _ = try resolveContainedURLWithoutFollowingLeafSymlink(relativePath: relativePath, rootPath: rootPath)
        let gitPath = runtimeService.executableOnPath("git")?.path ?? "/usr/bin/git"
        let env = runtimeService.processEnvironment()
        let runner = processRunner

        let plan = try await Task.detached(priority: .utility) { () throws -> (
            layout: GitRepositoryLayout,
            targetRepoPath: String,
            renameSourceRepoPath: String?,
            renameSourceWorkspacePath: String?,
            isUntracked: Bool,
            headMode: String?,
            restoreText: String?
        ) in
            guard let layout = Self.gitRepositoryLayout(gitPath: gitPath, env: env, runner: runner, rootPath: rootPath) else {
                throw AIAgentWorkspaceHostError.gitUnavailable("Workspace is not inside a Git repository.")
            }
            let targetRepoPath = layout.repoRelativePath(for: relativePath)

            let fullStatus = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["status", "--porcelain=v1", "-uall", "-z"],
                workingDirectory: layout.topLevel,
                environment: env,
                timeoutMilliseconds: 4000
            ))
            guard fullStatus.succeeded else {
                throw AIAgentWorkspaceHostError.gitUnavailable("Failed to inspect Git status before discarding '\(relativePath)'.")
            }

            var renameSourceRepoPath: String?
            var isUntracked = false
            for statusEntry in Self.parseGitStatusPorcelainZ(fullStatus.output) {
                if statusEntry.path == targetRepoPath {
                    if let oldPath = statusEntry.renameSource {
                        renameSourceRepoPath = oldPath
                    } else if statusEntry.code == "??" {
                        isUntracked = true
                    }
                    break
                }
            }

            if isUntracked {
                return (layout, targetRepoPath, nil, nil, true, nil, nil)
            }

            let renameSourceWSPath: String?
            if let renameSourceRepoPath {
                guard let ws = layout.workspaceRelativePath(for: renameSourceRepoPath) else {
                    throw AIAgentWorkspaceHostError.pathOutsideWorkspace(renameSourceRepoPath)
                }
                renameSourceWSPath = ws
            } else {
                renameSourceWSPath = nil
            }

            let headVerify = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["rev-parse", "--verify", "HEAD"],
                workingDirectory: layout.topLevel,
                environment: env,
                timeoutMilliseconds: 3000
            ))
            let headHash = headVerify.succeeded
                ? headVerify.output.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            if !headVerify.succeeded && headVerify.exitCode != 128 {
                throw AIAgentWorkspaceHostError.gitUnavailable("Failed to resolve Git HEAD before discarding '\(relativePath)'.")
            }

            let headTargetRepoPath = renameSourceRepoPath ?? targetRepoPath
            var headMode: String?
            var verifiedText: String?
            if let headHash, Self.isValidGitOID(headHash) {
                let lsTree = runner.run(ProcessRequest(
                    executablePath: gitPath,
                    arguments: ["--literal-pathspecs", "-c", "core.quotePath=false", "ls-tree", "HEAD", "--", headTargetRepoPath],
                    workingDirectory: layout.topLevel,
                    environment: env,
                    timeoutMilliseconds: 4000
                ))
                // Never treat a timed-out or failed Git lookup as a missing file (prevents accidental deletion).
                guard lsTree.succeeded else {
                    throw AIAgentWorkspaceHostError.gitUnavailable("Git lookup failed while inspecting HEAD for '\(relativePath)'.")
                }
                let firstEntry = lsTree.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                headMode = firstEntry.split(separator: " ").first.map(String.init)

                if headMode == "100644" || headMode == "100755" {
                    let materialized = try Self.materializeWorkingTreeFiles(
                        treeHash: headHash,
                        repoPaths: [headTargetRepoPath],
                        gitPath: gitPath,
                        env: env,
                        runner: runner,
                        repoTopLevel: layout.topLevel
                    )
                    defer { try? FileManager.default.removeItem(at: materialized.stagingDirectory) }
                    let stagedFileURL = materialized.stagingDirectory.appendingPathComponent(headTargetRepoPath)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: stagedFileURL.path),
                       let size = (attrs[.size] as? NSNumber)?.intValue,
                       size <= Self.maxSafeTextBlobBytes,
                       let rawData = try? Data(contentsOf: stagedFileURL),
                       !rawData.contains(0),
                       let strictText = String(bytes: rawData, encoding: .utf8) {
                        verifiedText = strictText
                    }
                }
            }
            return (layout, targetRepoPath, renameSourceRepoPath, renameSourceWSPath, false, headMode, verifiedText)
        }.value

        if plan.isUntracked {
            let leafURL = try resolveContainedURLWithoutFollowingLeafSymlink(relativePath: relativePath, rootPath: rootPath)
            if (try? fileManager.attributesOfItem(atPath: leafURL.path)) != nil {
                try fileManager.removeItem(at: leafURL)
            }
            return
        }

        if let renameSourceRepo = plan.renameSourceRepoPath,
           let renameSourceWS = plan.renameSourceWorkspacePath {
            _ = try resolveContainedURLWithoutFollowingLeafSymlink(relativePath: renameSourceWS, rootPath: rootPath)
            let topLevel = plan.layout.topLevel
            let destRepo = plan.targetRepoPath
            let destExistsInHead = try await Task.detached(priority: .utility) { () throws -> Bool in
                let resetRes = runner.run(ProcessRequest(
                    executablePath: gitPath,
                    arguments: ["--literal-pathspecs", "reset", "-q", "HEAD", "--", renameSourceRepo, destRepo],
                    workingDirectory: topLevel,
                    environment: env,
                    timeoutMilliseconds: 4000
                ))
                guard resetRes.succeeded else {
                    throw AIAgentWorkspaceHostError.gitUnavailable(resetRes.output.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let lsDest = runner.run(ProcessRequest(
                    executablePath: gitPath,
                    arguments: ["--literal-pathspecs", "ls-tree", "HEAD", "--", destRepo],
                    workingDirectory: topLevel,
                    environment: env,
                    timeoutMilliseconds: 4000
                ))
                guard lsDest.succeeded else {
                    throw AIAgentWorkspaceHostError.gitUnavailable("Failed to inspect HEAD for '\(relativePath)'.")
                }
                return !lsDest.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.value

            if !destExistsInHead {
                let destLeaf = try resolveContainedURLWithoutFollowingLeafSymlink(relativePath: relativePath, rootPath: rootPath)
                if (try? fileManager.attributesOfItem(atPath: destLeaf.path)) != nil {
                    try fileManager.removeItem(at: destLeaf)
                }
            }
            try await restoreSinglePathFromHead(
                workspacePath: renameSourceWS,
                repoPath: renameSourceRepo,
                repoTopLevel: topLevel,
                headMode: plan.headMode,
                verifiedText: plan.restoreText,
                gitPath: gitPath,
                env: env,
                runner: runner,
                rootPath: rootPath
            )
            return
        }

        guard let headMode = plan.headMode else {
            // Staged new file verified genuinely absent from HEAD (unborn HEAD or newly added).
            let topLevel = plan.layout.topLevel
            let targetRepo = plan.targetRepoPath
            let rmRes = await Task.detached(priority: .utility) {
                runner.run(ProcessRequest(
                    executablePath: gitPath,
                    arguments: ["--literal-pathspecs", "rm", "-f", "--cached", "--", targetRepo],
                    workingDirectory: topLevel,
                    environment: env,
                    timeoutMilliseconds: 4000
                ))
            }.value
            guard rmRes.succeeded else {
                throw AIAgentWorkspaceHostError.gitUnavailable(rmRes.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let leafURL = try resolveContainedURLWithoutFollowingLeafSymlink(relativePath: relativePath, rootPath: rootPath)
            if (try? fileManager.attributesOfItem(atPath: leafURL.path)) != nil {
                try fileManager.removeItem(at: leafURL)
            }
            return
        }

        let topLevel = plan.layout.topLevel
        let targetRepo = plan.targetRepoPath
        let resetRes = await Task.detached(priority: .utility) {
            runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["--literal-pathspecs", "reset", "-q", "HEAD", "--", targetRepo],
                workingDirectory: topLevel,
                environment: env,
                timeoutMilliseconds: 4000
            ))
        }.value
        guard resetRes.succeeded else {
            throw AIAgentWorkspaceHostError.gitUnavailable(resetRes.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        try await restoreSinglePathFromHead(
            workspacePath: relativePath,
            repoPath: targetRepo,
            repoTopLevel: topLevel,
            headMode: headMode,
            verifiedText: plan.restoreText,
            gitPath: gitPath,
            env: env,
            runner: runner,
            rootPath: rootPath
        )
    }

    private func restoreSinglePathFromHead(
        workspacePath: String,
        repoPath: String,
        repoTopLevel: String,
        headMode: String?,
        verifiedText: String?,
        gitPath: String,
        env: [String: String],
        runner: any ProcessRunner,
        rootPath: String
    ) async throws {
        let leafURL = try resolveContainedURLWithoutFollowingLeafSymlink(relativePath: workspacePath, rootPath: rootPath)
        let leafIsCurrentlySymlink = ((try? fileManager.attributesOfItem(atPath: leafURL.path)[.type] as? FileAttributeType) == .typeSymbolicLink)
        if let verifiedText,
           let headMode,
           (headMode == "100644" || headMode == "100755"),
           !leafIsCurrentlySymlink {
            try await writeFile(
                relativePath: workspacePath,
                content: verifiedText,
                expectedSourceText: nil,
                rootPath: rootPath,
                persistOpenBufferToDisk: true
            )
            let posixMode: Int = headMode == "100755" ? 0o755 : 0o644
            try fileManager.setAttributes([.posixPermissions: posixMode], ofItemAtPath: leafURL.path)
            return
        }
        if leafIsCurrentlySymlink || headMode == "120000" {
            if (try? fileManager.attributesOfItem(atPath: leafURL.path)) != nil {
                try fileManager.removeItem(at: leafURL)
            }
        }
        let checkoutRes = await Task.detached(priority: .utility) {
            runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["--literal-pathspecs", "checkout", "HEAD", "--", repoPath],
                workingDirectory: repoTopLevel,
                environment: env,
                timeoutMilliseconds: 5000
            ))
        }.value
        guard checkoutRes.succeeded else {
            throw AIAgentWorkspaceHostError.gitUnavailable(checkoutRes.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func generateCommitMessage(in rootPath: String) async throws -> String {
        let diff = await workingTreeDiff(in: rootPath)
        guard !diff.files.isEmpty else {
            throw AIAgentWorkspaceHostError.gitUnavailable("Working tree has no changes to summarize.")
        }
        if let aiGenerated = try await callbacks.generateAICommitMessage(diff) {
            let trimmed = aiGenerated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        // Deterministic fallback when no Direct HTTP AI provider is configured.
        if diff.files.count == 1, let single = diff.files.first {
            let verb: String = {
                switch single.kind {
                case .added: "add"
                case .deleted: "remove"
                case .renamed: "rename"
                case .modified: "update"
                }
            }()
            let name = (single.path as NSString).lastPathComponent
            return "chore: \(verb) \(name)"
        }
        let added = diff.files.filter { $0.kind == .added }.count
        let modified = diff.files.filter { $0.kind == .modified }.count
        let deleted = diff.files.filter { $0.kind == .deleted }.count
        var parts: [String] = []
        if added > 0 { parts.append("add \(added)") }
        if modified > 0 { parts.append("update \(modified)") }
        if deleted > 0 { parts.append("remove \(deleted)") }
        let summary = parts.isEmpty ? "update \(diff.files.count)" : parts.joined(separator: ", ")
        return "chore: \(summary) files"
    }

    func readImageData(at path: String, maxBytes: Int) -> (mimeType: String, data: Data)? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let ext = url.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "png": mimeType = "image/png"
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "webp": mimeType = "image/webp"
        case "gif": mimeType = "image/gif"
        default: return nil
        }
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? NSNumber,
              fileSize.intValue > 0,
              fileSize.intValue <= maxBytes,
              let data = try? fileStorage.readData(from: url, options: []) else {
            return nil
        }
        return (mimeType, data)
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
            let layout = Self.gitRepositoryLayout(gitPath: gitPath, env: env, runner: runner, rootPath: rootPath)
            let isSubdirectoryWorkspace = !(layout?.workspacePrefix.isEmpty ?? true)
            let addResult = runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: ["add", "-A", "--", "."],
                workingDirectory: rootPath,
                environment: env,
                timeoutMilliseconds: 10_000
            ))
            guard addResult.succeeded else { return addResult }
            let commitArgs = isSubdirectoryWorkspace
                ? ["commit", "-m", message, "--", "."]
                : ["commit", "-m", message]
            return runner.run(ProcessRequest(
                executablePath: gitPath,
                arguments: commitArgs,
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
        guard !relativePath.isEmpty, !relativePath.contains("\0") else {
            throw AIAgentWorkspaceHostError.pathOutsideWorkspace(relativePath)
        }
        let canonicalRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate: URL
        if relativePath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: relativePath).standardizedFileURL
        } else {
            candidate = canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL
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

    private func resolveContainedURLWithoutFollowingLeafSymlink(relativePath: String, rootPath: String) throws -> URL {
        // Preserve leading/trailing whitespace verbatim so Git filenames like `"link "` never
        // alias an unrelated file `"link"` during destructive operations.
        guard !relativePath.isEmpty, !relativePath.contains("\0") else {
            throw AIAgentWorkspaceHostError.pathOutsideWorkspace(relativePath)
        }
        let canonicalRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate: URL = relativePath.hasPrefix("/")
            ? URL(fileURLWithPath: relativePath).standardizedFileURL
            : canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL
        let parentResolved = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard parentResolved.path == canonicalRoot.path || parentResolved.path.hasPrefix(rootPrefix) else {
            throw AIAgentWorkspaceHostError.pathOutsideWorkspace(relativePath)
        }
        let leafName = candidate.lastPathComponent
        guard !leafName.isEmpty && leafName != "." && leafName != ".." else {
            throw AIAgentWorkspaceHostError.pathOutsideWorkspace(relativePath)
        }
        return parentResolved.appendingPathComponent(leafName)
    }

    private nonisolated static func ancestorDirectoryPaths(of relativePath: String) -> [String] {
        let components = relativePath.split(separator: "/")
        guard components.count > 1 else { return [] }
        var ancestors: [String] = []
        var prefix = ""
        for part in components.dropLast() {
            prefix = prefix.isEmpty ? String(part) : "\(prefix)/\(part)"
            ancestors.append(prefix)
        }
        return ancestors
    }

    private nonisolated static func parseGitRawDiffZ(_ output: String) -> [GitRawDiffEntry] {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var entries: [GitRawDiffEntry] = []
        var index = 0
        while index + 1 < tokens.count {
            let header = tokens[index]
            guard header.hasPrefix(":") else {
                index += 1
                continue
            }
            let parts = header.dropFirst().split(whereSeparator: \.isWhitespace).map(String.init)
            let path = tokens[index + 1]
            index += 2
            guard parts.count >= 5, !path.isEmpty else { continue }
            entries.append(GitRawDiffEntry(
                oldMode: parts[0],
                newMode: parts[1],
                oldHash: parts[2],
                status: parts[4],
                repoPath: path
            ))
        }
        return entries
    }

    private nonisolated static func parseGitNumstatZ(_ output: String) -> [(repoPath: String, isBinary: Bool)] {
        var results: [(String, Bool)] = []
        for token in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let parts = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let isBinary = parts[0] == "-" && parts[1] == "-"
            results.append((String(parts[2]), isBinary))
        }
        return results
    }

    private nonisolated static func parseGitStatusPorcelainZ(_ output: String) -> [(code: String, path: String, renameSource: String?)] {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var results: [(String, String, String?)] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard token.count >= 4 else { continue }
            let code = String(token.prefix(2))
            let path = String(token.dropFirst(3))
            let isRenameOrCopy = code.first == "R" || code.first == "C"
            if isRenameOrCopy && index < tokens.count {
                let source = tokens[index]
                index += 1
                results.append((code, path, source))
            } else {
                results.append((code, path, nil))
            }
        }
        return results
    }

    private nonisolated static func gitRepositoryLayout(
        gitPath: String,
        env: [String: String],
        runner: any ProcessRunner,
        rootPath: String
    ) -> GitRepositoryLayout? {
        let insideRes = runner.run(ProcessRequest(
            executablePath: gitPath,
            arguments: ["rev-parse", "--is-inside-work-tree"],
            workingDirectory: rootPath,
            environment: env,
            timeoutMilliseconds: 3000
        ))
        guard insideRes.succeeded,
              insideRes.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return nil
        }
        let topRes = runner.run(ProcessRequest(
            executablePath: gitPath,
            arguments: ["rev-parse", "--show-toplevel"],
            workingDirectory: rootPath,
            environment: env,
            timeoutMilliseconds: 3000
        ))
        guard topRes.succeeded else { return nil }
        let topLevel = topRes.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topLevel.isEmpty else { return nil }

        let prefixRes = runner.run(ProcessRequest(
            executablePath: gitPath,
            arguments: ["rev-parse", "--show-prefix"],
            workingDirectory: rootPath,
            environment: env,
            timeoutMilliseconds: 3000
        ))
        let rawPrefix = prefixRes.succeeded
            ? prefixRes.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let normalizedPrefix: String
        if rawPrefix.isEmpty {
            normalizedPrefix = ""
        } else {
            normalizedPrefix = rawPrefix.hasSuffix("/") ? rawPrefix : rawPrefix + "/"
        }
        return GitRepositoryLayout(topLevel: topLevel, workspacePrefix: normalizedPrefix)
    }

    /// Materializes files from `treeHash` into an isolated staging directory via Git's own
    /// `checkout-index --prefix=...` so `.gitattributes` (eol=crlf, smudge/clean filters) and
    /// raw binary bytes are preserved faithfully without touching the real index or workspace.
    private nonisolated static func materializeWorkingTreeFiles(
        treeHash: String,
        repoPaths: [String],
        gitPath: String,
        env: [String: String],
        runner: any ProcessRunner,
        repoTopLevel: String
    ) throws -> (stagingDirectory: URL, count: Int) {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("lithe-agent-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let tempIndexURL = fm.temporaryDirectory
            .appendingPathComponent("lithe-agent-stage-idx-\(UUID().uuidString).index")
        defer { try? fm.removeItem(at: tempIndexURL) }

        var tempEnv = env
        tempEnv["GIT_INDEX_FILE"] = tempIndexURL.path
        let readTree = runner.run(ProcessRequest(
            executablePath: gitPath,
            arguments: ["read-tree", treeHash],
            workingDirectory: repoTopLevel,
            environment: tempEnv,
            timeoutMilliseconds: 5000
        ))
        guard readTree.succeeded else {
            try? fm.removeItem(at: stagingDir)
            throw AIAgentWorkspaceHostError.gitUnavailable("Failed to load Git tree \(treeHash.prefix(8)).")
        }

        let prefixPath = stagingDir.path.hasSuffix("/") ? stagingDir.path : stagingDir.path + "/"
        // Read .gitattributes from `treeHash` via --attr-source so attribute changes made
        // during the turn never alter how the checkpoint's working-tree bytes materialize.
        let checkout = runner.run(ProcessRequest(
            executablePath: gitPath,
            arguments: ["--attr-source=\(treeHash)", "--literal-pathspecs", "checkout-index", "-f", "--prefix=\(prefixPath)", "--"] + repoPaths,
            workingDirectory: repoTopLevel,
            environment: tempEnv,
            timeoutMilliseconds: 10_000
        ))
        guard checkout.succeeded else {
            try? fm.removeItem(at: stagingDir)
            throw AIAgentWorkspaceHostError.gitUnavailable(checkout.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (stagingDir, repoPaths.count)
    }

    /// Evaluates which `candidateRepoPaths` were ignored under the `.gitignore` rules recorded in
    /// `treeHash`, preventing checkpoint revert from deleting pre-existing ignored user files when
    /// a turn modifies `.gitignore`.
    private nonisolated static func pathsIgnoredUnderTree(
        treeHash: String,
        candidateRepoPaths: [String],
        gitPath: String,
        env: [String: String],
        runner: any ProcessRunner,
        repoTopLevel: String
    ) -> Set<String> {
        let listRes = runner.run(ProcessRequest(
            executablePath: gitPath,
            arguments: ["ls-tree", "-r", "-z", "--name-only", treeHash],
            workingDirectory: repoTopLevel,
            environment: env,
            timeoutMilliseconds: 4000
        ))
        guard listRes.succeeded else { return Set(candidateRepoPaths) }
        let gitignorePaths = listRes.output
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { ($0 as NSString).lastPathComponent == ".gitignore" }
        guard !gitignorePaths.isEmpty else { return [] }

        guard let materialized = try? materializeWorkingTreeFiles(
            treeHash: treeHash,
            repoPaths: gitignorePaths,
            gitPath: gitPath,
            env: env,
            runner: runner,
            repoTopLevel: repoTopLevel
        ) else {
            // Fail closed: if we cannot inspect pre-turn .gitignore rules, avoid deleting candidates.
            return Set(candidateRepoPaths)
        }
        let fm = FileManager.default
        defer { try? fm.removeItem(at: materialized.stagingDirectory) }

        // Initialize a tiny temporary git repo containing ONLY preTree's .gitignore files and run
        // `git check-ignore --no-index --stdin -z` so Git evaluates nested .gitignore rules verbatim.
        let initRes = runner.run(ProcessRequest(
            executablePath: gitPath,
            arguments: ["init", "-q"],
            workingDirectory: materialized.stagingDirectory.path,
            environment: env,
            timeoutMilliseconds: 3000
        ))
        guard initRes.succeeded else { return Set(candidateRepoPaths) }

        let checkRes = runner.run(ProcessRequest(
            executablePath: gitPath,
            arguments: ["check-ignore", "--no-index", "--stdin", "-z"],
            workingDirectory: materialized.stagingDirectory.path,
            environment: env,
            standardInput: Data((candidateRepoPaths.joined(separator: "\0") + "\0").utf8),
            timeoutMilliseconds: 4000
        ))
        // Exit code 0 = some paths ignored, 1 = none ignored, anything else = error (fail closed).
        if checkRes.exitCode != 0 && checkRes.exitCode != 1 {
            return Set(candidateRepoPaths)
        }
        var ignored: Set<String> = []
        for rawToken in checkRes.output.split(separator: "\0", omittingEmptySubsequences: true) {
            ignored.insert(String(rawToken))
        }
        return ignored
    }

    private nonisolated static func isValidGitOID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 40 || trimmed.count == 64 else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
                || (scalar.value >= 65 && scalar.value <= 70)
        }
    }

    /// Captures a complete non-ignored working-tree snapshot into an immutable Git tree
    /// object using an isolated temporary `GIT_INDEX_FILE` so the user's real index, HEAD,
    /// and stash remain completely untouched.
    private nonisolated static func captureTempGitTree(
        gitPath: String,
        env: [String: String],
        runner: any ProcessRunner,
        rootPath: String
    ) -> String? {
        let insideRes = runner.run(ProcessRequest(
            executablePath: gitPath,
            arguments: ["rev-parse", "--is-inside-work-tree"],
            workingDirectory: rootPath,
            environment: env,
            timeoutMilliseconds: 3000
        ))
        guard insideRes.succeeded,
              insideRes.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return nil
        }

        let fm = FileManager.default
        let tempIndexURL = fm.temporaryDirectory
            .appendingPathComponent("lithe-agent-ckpt-\(UUID().uuidString).index")
        defer { try? fm.removeItem(at: tempIndexURL) }

        let indexPathRes = runner.run(ProcessRequest(
            executablePath: gitPath,
            arguments: ["rev-parse", "--git-path", "index"],
            workingDirectory: rootPath,
            environment: env,
            timeoutMilliseconds: 3000
        ))
        if indexPathRes.succeeded {
            let rawIndexPath = indexPathRes.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawIndexPath.isEmpty {
                let realIndexURL = rawIndexPath.hasPrefix("/")
                    ? URL(fileURLWithPath: rawIndexPath)
                    : URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent(rawIndexPath)
                if fm.fileExists(atPath: realIndexURL.path) {
                    try? fm.copyItem(at: realIndexURL, to: tempIndexURL)
                }
            }
        }

        var tempEnv = env
        tempEnv["GIT_INDEX_FILE"] = tempIndexURL.path
        let addRes = runner.run(ProcessRequest(
            executablePath: gitPath,
            arguments: ["add", "-A"],
            workingDirectory: rootPath,
            environment: tempEnv,
            timeoutMilliseconds: 10_000
        ))
        guard addRes.succeeded else { return nil }

        let treeRes = runner.run(ProcessRequest(
            executablePath: gitPath,
            arguments: ["write-tree"],
            workingDirectory: rootPath,
            environment: tempEnv,
            timeoutMilliseconds: 5000
        ))
        guard treeRes.succeeded else { return nil }
        let hash = treeRes.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidGitOID(hash) ? hash : nil
    }

    private nonisolated static func checkoutFilesFromGitTree(
        treeHash: String,
        repoPaths: [String],
        gitPath: String,
        env: [String: String],
        runner: any ProcessRunner,
        repoTopLevel: String
    ) throws -> Int {
        let fm = FileManager.default
        let tempIndexURL = fm.temporaryDirectory
            .appendingPathComponent("lithe-agent-restore-\(UUID().uuidString).index")
        defer { try? fm.removeItem(at: tempIndexURL) }

        var tempEnv = env
        tempEnv["GIT_INDEX_FILE"] = tempIndexURL.path
        let readTree = runner.run(ProcessRequest(
            executablePath: gitPath,
            arguments: ["read-tree", treeHash],
            workingDirectory: repoTopLevel,
            environment: tempEnv,
            timeoutMilliseconds: 5000
        ))
        guard readTree.succeeded else {
            throw AIAgentWorkspaceHostError.gitUnavailable("Failed to load checkpoint tree \(treeHash.prefix(8)).")
        }
        let checkout = runner.run(ProcessRequest(
            executablePath: gitPath,
            arguments: ["--attr-source=\(treeHash)", "--literal-pathspecs", "checkout-index", "-f", "--"] + repoPaths,
            workingDirectory: repoTopLevel,
            environment: tempEnv,
            timeoutMilliseconds: 10_000
        ))
        guard checkout.succeeded else {
            throw AIAgentWorkspaceHostError.gitUnavailable(checkout.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return repoPaths.count
    }

    private nonisolated static func synthesizeUntrackedDiff(
        relativePath: String,
        rootPath: String
    ) -> (lineCount: Int, diffText: String)? {
        let fm = FileManager.default
        let canonicalRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        let rawLeafURL = canonicalRoot.appendingPathComponent(relativePath)
        let canonicalParent = rawLeafURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard canonicalParent.path == canonicalRoot.path || canonicalParent.path.hasPrefix(rootPrefix) else {
            return nil
        }
        let leafURL = canonicalParent.appendingPathComponent(rawLeafURL.lastPathComponent)
        guard let attrs = try? fm.attributesOfItem(atPath: leafURL.path),
              let fileType = attrs[.type] as? FileAttributeType else {
            return nil
        }

        // Render symlinks by link destination WITHOUT opening or following external targets.
        if fileType == .typeSymbolicLink {
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: leafURL.path) else {
                return nil
            }
            let diff = [
                "diff --git a/\(relativePath) b/\(relativePath)",
                "new file mode 120000",
                "--- /dev/null",
                "+++ b/\(relativePath)",
                "@@ -0,0 +1 @@",
                "+\(destination)",
                "\\ No newline at end of file"
            ].joined(separator: "\n")
            return (1, diff)
        }

        guard fileType == .typeRegular else {
            return nil
        }

        let fd = Darwin.open(leafURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: 65_536), !data.isEmpty else {
            return (0, "diff --git a/\(relativePath) b/\(relativePath)\nnew file mode 100644\n--- /dev/null\n+++ b/\(relativePath)\n")
        }
        // Skip binary files containing NUL bytes in the leading probe slice.
        if data.prefix(8192).contains(0) {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let boundedLines = rawLines.prefix(400)
        var out: [String] = [
            "diff --git a/\(relativePath) b/\(relativePath)",
            "new file mode 100644",
            "--- /dev/null",
            "+++ b/\(relativePath)",
            "@@ -0,0 +1,\(boundedLines.count) @@"
        ]
        for line in boundedLines {
            out.append("+\(line)")
        }
        if rawLines.count > 400 || data.count >= 65_536 {
            out.append("… [preview truncated]")
        }
        return (rawLines.count, out.joined(separator: "\n"))
    }
}
