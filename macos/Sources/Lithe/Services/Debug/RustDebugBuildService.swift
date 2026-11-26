import Foundation
import LitheCoreContracts

enum RustDebugBuildError: LocalizedError, Equatable {
    case cargoUnavailable
    case buildFailed(String)
    case executableNotFound(binary: String)

    var errorDescription: String? {
        switch self {
        case .cargoUnavailable:
            return "Cargo was not found. Install Rust via rustup or configure Cargo in PATH before debugging."
        case .buildFailed(let detail):
            return detail.isEmpty
                ? "Cargo failed to build the Rust binary for debugging."
                : "Cargo build failed:\n\(detail)"
        case .executableNotFound(let binary):
            return "Cargo built successfully, but no debug executable was reported for '\(binary)'."
        }
    }
}

/// Runs `cargo build --message-format=json-render-diagnostics` through the
/// platform-neutral `ProcessRunner` port before launching `lldb-dap`, returning
/// the exact debug binary path reported by Cargo.
@MainActor
final class RustDebugBuildService {
    private static let buildTimeoutMilliseconds = 120_000

    private let processRunner: any ProcessRunner
    private let runtimeService: ProjectRuntimeService
    private let fileExists: @Sendable (String) -> Bool
    private let readFile: @Sendable (String) -> String?

    init(
        processRunner: any ProcessRunner,
        runtimeService: ProjectRuntimeService,
        fileExists: @escaping @Sendable (String) -> Bool = { _ in false },
        readFile: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.processRunner = processRunner
        self.runtimeService = runtimeService
        self.fileExists = fileExists
        self.readFile = readFile
    }

    func buildDebugExecutable(
        binaryName: String,
        workingDirectory: URL,
        environmentOverrides: [String: String]
    ) async throws -> URL {
        guard let cargoURL = runtimeService.executableOnPath("cargo") else {
            throw RustDebugBuildError.cargoUnavailable
        }
        var environment = runtimeService.processEnvironment()
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        var arguments = ["build", "--message-format=json-render-diagnostics"]
        let trimmedBinary = binaryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBinary.isEmpty {
            arguments.append(contentsOf: ["--bin", trimmedBinary])
        }
        let request = ProcessRequest(
            operationID: "rust-debug-build-\(UUID().uuidString)",
            executablePath: cargoURL.path,
            arguments: arguments,
            workingDirectory: workingDirectory.standardizedFileURL.path,
            environment: environment,
            timeoutMilliseconds: Self.buildTimeoutMilliseconds
        )
        let runner = processRunner
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runner.run(request))
            }
        }
        guard result.exitCode == 0 else {
            let summary = Self.extractDiagnosticsSummary(from: result.output)
            throw RustDebugBuildError.buildFailed(summary)
        }
        guard let path = Self.parseBuiltExecutablePath(
            from: result.output,
            binaryName: trimmedBinary.isEmpty ? nil : trimmedBinary
        ) else {
            throw RustDebugBuildError.executableNotFound(binary: trimmedBinary.isEmpty ? "target" : trimmedBinary)
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    func buildDebugTestExecutable(
        fileURL: URL,
        workspaceURL: URL,
        workingDirectory: URL,
        environmentOverrides: [String: String]
    ) async throws -> URL {
        guard let cargoURL = runtimeService.executableOnPath("cargo") else {
            throw RustDebugBuildError.cargoUnavailable
        }
        var environment = runtimeService.processEnvironment()
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        let normalizedFile = fileURL.standardizedFileURL
        let normalizedRoot = workspaceURL.standardizedFileURL.path
        let relativePath: String? = normalizedFile.path.hasPrefix(normalizedRoot + "/")
            ? String(normalizedFile.path.dropFirst(normalizedRoot.count + 1))
            : nil
        var arguments = ["test", "--no-run", "--message-format=json-render-diagnostics"]
        let fileName = normalizedFile.lastPathComponent
        var expectedTargetName: String?
        if let relativePath,
           let target = Self.resolveCargoTestTarget(
               relativePath: relativePath,
               workspaceRootPath: normalizedRoot,
               fileExists: fileExists
           ) {
            arguments.append(contentsOf: [target.flag, target.name])
            expectedTargetName = target.name
        }
        let request = ProcessRequest(
            operationID: "rust-debug-test-build-\(UUID().uuidString)",
            executablePath: cargoURL.path,
            arguments: arguments,
            workingDirectory: workingDirectory.standardizedFileURL.path,
            environment: environment,
            timeoutMilliseconds: Self.buildTimeoutMilliseconds
        )
        let runner = processRunner
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runner.run(request))
            }
        }
        guard result.exitCode == 0 else {
            let summary = Self.extractDiagnosticsSummary(from: result.output)
            throw RustDebugBuildError.buildFailed(summary)
        }
        guard let path = Self.parseBuiltTestExecutablePath(
            from: result.output,
            sourcePath: normalizedFile.path,
            expectedTargetName: expectedTargetName,
            readFile: readFile
        ) else {
            throw RustDebugBuildError.executableNotFound(binary: expectedTargetName ?? fileName)
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Parses Cargo `cargo test --no-run --message-format=json-render-diagnostics` output
    /// and selects the compiled test executable matching the owning target of `sourcePath`.
    nonisolated static func parseBuiltTestExecutablePath(
        from output: String,
        sourcePath: String,
        expectedTargetName: String?,
        readFile: (String) -> String? = { _ in nil }
    ) -> String? {
        struct TestArtifact {
            let executable: String
            let name: String?
            let kinds: [String]
            let srcPath: String?
        }

        let normalizedSource = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
        var artifacts: [TestArtifact] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["reason"] as? String == "compiler-artifact",
                  let executable = object["executable"] as? String,
                  !executable.isEmpty else {
                continue
            }
            let profile = object["profile"] as? [String: Any]
            guard profile?["test"] as? Bool == true else { continue }
            let target = object["target"] as? [String: Any]
            let name = target?["name"] as? String
            let kinds = target?["kind"] as? [String] ?? []
            let srcPath = (target?["src_path"] as? String)
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            if srcPath == normalizedSource {
                return executable
            }
            artifacts.append(TestArtifact(
                executable: executable,
                name: name,
                kinds: kinds,
                srcPath: srcPath
            ))
        }

        if let expectedTargetName,
           let namedMatch = artifacts.first(where: { $0.name == expectedTargetName }) {
            return namedMatch.executable
        }

        // For nested module files (e.g. `src/math.rs`, `src/bin/tool/helper.rs`, `tests/suite/helper.rs`),
        // inspect candidate target roots in the same directory tree to find which root declares the module.
        let targetArtifacts = artifacts.filter {
            $0.kinds.contains("lib") || $0.kinds.contains("bin") || $0.kinds.contains("test")
        }
        let sameTreeCandidates = targetArtifacts.filter { artifact in
            guard let rootSrc = artifact.srcPath else { return false }
            let rootDir = URL(fileURLWithPath: rootSrc).deletingLastPathComponent().standardizedFileURL.path
            return normalizedSource.hasPrefix(rootDir + "/")
        }
        let candidates = sameTreeCandidates.isEmpty ? targetArtifacts : sameTreeCandidates
        if candidates.count > 1 {
            let owningMatches = candidates.filter { artifact in
                guard let rootSrc = artifact.srcPath,
                      let rootContent = readFile(rootSrc) else { return false }
                return Self.targetRoot(rootSrc, content: rootContent, ownsSourcePath: normalizedSource)
            }
            if let preferredOwner = owningMatches.first(where: { $0.kinds.contains("lib") })
                ?? owningMatches.first {
                return preferredOwner.executable
            }
        }

        let isMainOrBinFile = normalizedSource.hasSuffix("/main.rs") || normalizedSource.contains("/src/bin/")
        if isMainOrBinFile {
            if let bin = candidates.first(where: { $0.kinds.contains("bin") }) {
                return bin.executable
            }
        } else if let lib = candidates.first(where: { $0.kinds.contains("lib") }) {
            return lib.executable
        }
        return candidates.first?.executable ?? artifacts.first?.executable
    }

    nonisolated static func resolveCargoTestTarget(
        relativePath: String,
        workspaceRootPath: String,
        fileExists: (String) -> Bool = { _ in false }
    ) -> (flag: String, name: String)? {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let last = parts.last, last.hasSuffix(".rs") else { return nil }
        let rootURL = URL(fileURLWithPath: workspaceRootPath, isDirectory: true).standardizedFileURL

        // Resolve relative to the deepest enclosing crate directory containing `Cargo.toml`
        // (or the workspace root if no nested manifest is found). This guarantees unit-test
        // modules like `src/tests/arithmetic.rs` are never mistaken for integration targets.
        var cratePrefixCount = 0
        if parts.count > 1 {
            for depth in stride(from: parts.count - 1, through: 1, by: -1) {
                let candidateDir = parts[0..<depth].joined(separator: "/")
                let manifestPath = rootURL.appendingPathComponent(candidateDir)
                    .appendingPathComponent("Cargo.toml").path
                if fileExists(manifestPath) {
                    cratePrefixCount = depth
                    break
                }
            }
        }
        let cratePrefixParts = Array(parts.prefix(cratePrefixCount))
        let crateRel = Array(parts.dropFirst(cratePrefixCount))
        guard crateRel.count >= 2 else { return nil }

        if crateRel[0].lowercased() == "tests" {
            let rel = Array(crateRel.dropFirst())
            if rel.count == 1 {
                return ("--test", String(rel[0].dropLast(3)))
            }
            let targetName = rel[0]
            if rel.count == 2 && rel[1] == "main.rs" {
                return ("--test", targetName)
            }
            let entryPath = (cratePrefixParts + [crateRel[0], targetName, "main.rs"]).joined(separator: "/")
            if fileExists(rootURL.appendingPathComponent(entryPath).path) {
                return ("--test", targetName)
            }
            return nil
        }

        if crateRel.count >= 3,
           crateRel[0].lowercased() == "src",
           crateRel[1].lowercased() == "bin" {
            let rel = Array(crateRel.dropFirst(2))
            if rel.count == 1 {
                return ("--bin", String(rel[0].dropLast(3)))
            }
            let targetName = rel[0]
            if rel.count == 2 && rel[1] == "main.rs" {
                return ("--bin", targetName)
            }
            let entryPath = (cratePrefixParts + [crateRel[0], crateRel[1], targetName, "main.rs"]).joined(separator: "/")
            if fileExists(rootURL.appendingPathComponent(entryPath).path) {
                return ("--bin", targetName)
            }
            return nil
        }

        return nil
    }

    private nonisolated static func targetRoot(
        _ rootPath: String,
        content: String,
        ownsSourcePath sourcePath: String
    ) -> Bool {
        let rootDir = URL(fileURLWithPath: rootPath).deletingLastPathComponent().standardizedFileURL.path
        guard sourcePath.hasPrefix(rootDir + "/") else { return false }
        let relative = String(sourcePath.dropFirst(rootDir.count + 1))
        if content.contains("\"\(relative)\"") {
            return true
        }
        guard let firstComponent = relative.split(separator: "/").first.map(String.init) else {
            return false
        }
        let moduleName = firstComponent.hasSuffix(".rs")
            ? String(firstComponent.dropLast(3))
            : firstComponent
        guard !moduleName.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: moduleName)
        guard let regex = try? NSRegularExpression(
            pattern: "(?:^|\\n)[ \\t]*(?:pub(?:\\([^)\\n]*\\))?[ \\t]+)?mod[ \\t]+\(escaped)[ \\t]*;"
        ) else {
            return false
        }
        let range = NSRange(content.startIndex..., in: content)
        return regex.firstMatch(in: content, range: range) != nil
    }

    /// Parses Cargo `--message-format=json-render-diagnostics` output and
    /// selects the compiled binary executable matching `binaryName` when given.
    nonisolated static func parseBuiltExecutablePath(
        from output: String,
        binaryName: String?
    ) -> String? {
        var fallbackExecutable: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["reason"] as? String == "compiler-artifact",
                  let executable = object["executable"] as? String,
                  !executable.isEmpty else {
                continue
            }
            let target = object["target"] as? [String: Any]
            let name = target?["name"] as? String
            let kinds = target?["kind"] as? [String] ?? []
            if let binaryName, name == binaryName {
                return executable
            }
            if kinds.contains("bin") {
                fallbackExecutable = executable
            }
        }
        return fallbackExecutable
    }

    private nonisolated static func extractDiagnosticsSummary(from output: String) -> String {
        let nonJSONLines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("{") }
        return nonJSONLines.suffix(8).joined(separator: "\n")
    }
}
