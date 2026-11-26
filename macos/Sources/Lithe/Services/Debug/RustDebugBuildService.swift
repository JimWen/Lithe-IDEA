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

    init(
        processRunner: any ProcessRunner,
        runtimeService: ProjectRuntimeService
    ) {
        self.processRunner = processRunner
        self.runtimeService = runtimeService
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
