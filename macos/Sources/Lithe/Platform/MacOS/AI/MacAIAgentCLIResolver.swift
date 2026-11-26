import Foundation
import LitheCoreContracts

/// Locates `codex` and `claude` CLI executables and probes versions with bounded timeouts.
final class MacAIAgentCLIResolver: AIAgentCLIResolving, @unchecked Sendable {
    private let runtimeService: ProjectRuntimeService
    private let processRunner: any ProcessRunner
    private let fileManager: FileManager

    init(
        runtimeService: ProjectRuntimeService,
        processRunner: any ProcessRunner,
        fileManager: FileManager = .default
    ) {
        self.runtimeService = runtimeService
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    func processEnvironment() async -> [String: String] {
        await MainActor.run {
            var env = runtimeService.processEnvironment()
            // Include user-local tool locations commonly missed in Finder-launched apps.
            let home = fileManager.homeDirectoryForCurrentUser.path
            var extraPaths = [
                "\(home)/.local/bin",
                "/opt/homebrew/bin",
                "/usr/local/bin"
            ]
            if let nvmBin = Self.latestNVMNodeBinDirectory(home: home, fileManager: fileManager) {
                extraPaths.insert(nvmBin, at: 0)
            }
            let currentPath = env["PATH"] ?? ""
            let parts = currentPath.split(separator: ":").map(String.init)
            let merged = (extraPaths + parts).reduce(into: [String]()) { result, entry in
                if !entry.isEmpty && !result.contains(entry) {
                    result.append(entry)
                }
            }
            env["PATH"] = merged.joined(separator: ":")
            return env
        }
    }

    func resolveExecutable(for backend: AIAgentBackendKind, settings: AIAgentSettings) async -> String? {
        switch backend {
        case .codexCLI:
            return await resolveBinary(named: "codex", overridePath: settings.codexCLIPath)
        case .claudeCLI:
            return await resolveBinary(named: "claude", overridePath: settings.claudeCLIPath)
        case .directHTTP:
            return nil
        }
    }

    func detectCLIs(settings: AIAgentSettings) async -> [AIAgentCLIDetection] {
        let env = await processEnvironment()
        async let codex = detectCLI(backend: .codexCLI, binary: "codex", overridePath: settings.codexCLIPath, env: env)
        async let claude = detectCLI(backend: .claudeCLI, binary: "claude", overridePath: settings.claudeCLIPath, env: env)
        let direct = AIAgentCLIDetection(
            backend: .directHTTP,
            isAvailable: true,
            executablePath: nil,
            version: nil,
            statusDetail: "Uses the active AI Provider profile in Settings."
        )
        return await [codex, claude, direct]
    }

    private func detectCLI(
        backend: AIAgentBackendKind,
        binary: String,
        overridePath: String,
        env: [String: String]
    ) async -> AIAgentCLIDetection {
        guard let executable = await resolveBinary(named: binary, overridePath: overridePath) else {
            return AIAgentCLIDetection(
                backend: backend,
                isAvailable: false,
                executablePath: nil,
                version: nil,
                statusDetail: "\(binary) not found on PATH"
            )
        }

        let runner = processRunner
        let result = await Task.detached(priority: .utility) {
            runner.run(ProcessRequest(
                executablePath: executable,
                arguments: ["--version"],
                workingDirectory: "/",
                environment: env,
                timeoutMilliseconds: 2500
            ))
        }.value
        let versionLine = result.output
            .split(whereSeparator: \.isNewline)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        let authNote = authHint(for: backend, env: env)
        let detail: String
        if let versionLine, !versionLine.isEmpty {
            detail = authNote.isEmpty ? versionLine : "\(versionLine) · \(authNote)"
        } else {
            detail = authNote.isEmpty ? "Ready" : authNote
        }

        return AIAgentCLIDetection(
            backend: backend,
            isAvailable: true,
            executablePath: executable,
            version: versionLine,
            statusDetail: detail
        )
    }

    private func resolveBinary(named binary: String, overridePath: String) async -> String? {
        let trimmed = overridePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }

        if let onPath = await MainActor.run(body: { runtimeService.executableOnPath(binary)?.path }),
           fileManager.isExecutableFile(atPath: onPath) {
            return onPath
        }

        let env = await processEnvironment()
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(binary)"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func authHint(for backend: AIAgentBackendKind, env: [String: String]) -> String {
        let home = fileManager.homeDirectoryForCurrentUser
        switch backend {
        case .codexCLI:
            let authFile = home.appendingPathComponent(".codex/auth.json").path
            if fileManager.fileExists(atPath: authFile) || !(env["OPENAI_API_KEY"] ?? "").isEmpty {
                return "Auth detected"
            }
            return "Run `codex login`"
        case .claudeCLI:
            let credsFile = home.appendingPathComponent(".claude/.credentials.json").path
            let settingsFile = home.appendingPathComponent(".claude/settings.json").path
            if fileManager.fileExists(atPath: credsFile)
                || !(env["ANTHROPIC_API_KEY"] ?? "").isEmpty
                || !(env["ANTHROPIC_AUTH_TOKEN"] ?? "").isEmpty {
                return "Auth detected"
            }
            if fileManager.fileExists(atPath: settingsFile) {
                return "Config found"
            }
            return "Run `claude /login`"
        case .directHTTP:
            return ""
        }
    }

    private static func latestNVMNodeBinDirectory(home: String, fileManager: FileManager) -> String? {
        let versionsDir = "\(home)/.nvm/versions/node"
        guard let entries = try? fileManager.contentsOfDirectory(atPath: versionsDir) else { return nil }
        let sorted = entries.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        for entry in sorted {
            let binPath = "\(versionsDir)/\(entry)/bin"
            if fileManager.fileExists(atPath: binPath) {
                return binPath
            }
        }
        return nil
    }
}
