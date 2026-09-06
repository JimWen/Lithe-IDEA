import Foundation
import LitheCoreContracts

/// Validates the native capture boundary before asking Core to normalize topology.
struct RustProjectMetadataOperations: ProjectMetadataNormalizing {
    let core: RustCoreBridge
    private static let maximumInputBytes = 16 * 1_024 * 1_024
    private static let maximumRoots = 128
    private static let maximumPackageCaptures = 128
    private static let maximumPathBytes = 8 * 1_024

    func normalize(
        _ captures: ProjectMetadataCaptures, workspaceDirectory: String,
        roots: [ProjectMetadataRoot], operationID: String, timeoutMilliseconds: Int
    ) throws -> ProjectMetadataNormalization {
        guard (1...30_000).contains(timeoutMilliseconds), Self.validOperationID(operationID) else {
            throw ProjectMetadataFailure.invalidInput(message: "Invalid project metadata operation or deadline.")
        }
        // Bound native mapping allocations before JSONEncoder; Core still owns
        // path syntax, duplicate mapping and longest-prefix validation.
        guard (1...Self.maximumRoots).contains(roots.count),
              workspaceDirectory.utf8.count <= Self.maximumPathBytes,
              roots.allSatisfy({ $0.id.utf8.count <= 64 && $0.path.utf8.count <= Self.maximumPathBytes }) else {
            throw ProjectMetadataFailure.invalidInput(message: "Project metadata root mapping exceeds its limit.")
        }

        let payload = try makePayload(captures, workspaceDirectory: workspaceDirectory, roots: roots)
        let result: Result<ProjectMetadataSnapshot, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "execution.normalizeProjectMetadata", payload: payload,
            operationID: operationID, timeoutMilliseconds: timeoutMilliseconds
        )
        switch result {
        case .success(let snapshot):
            guard snapshot.version == 1, snapshot.language == payload.language else {
                throw ProjectMetadataFailure.core(
                    code: "parse_failed", message: "Rust Core returned incompatible project metadata.", details: nil
                )
            }
            return ProjectMetadataNormalization(operationID: operationID, snapshot: snapshot)
        case .failure(let error):
            throw ProjectMetadataFailure.core(code: error.code, message: error.message, details: error.details)
        }
    }

    @discardableResult
    func cancel(operationID: String) -> Bool {
        // The C ABI takes a NUL-terminated ID; reject invalid input rather than
        // cancelling an unrelated operation whose ID matches a truncated prefix.
        guard Self.validOperationID(operationID) else { return false }
        return core.cancel(operationID: operationID)
    }

    private static func validOperationID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && !value.contains("\0")
    }

    private func makePayload(
        _ captures: ProjectMetadataCaptures, workspaceDirectory: String, roots: [ProjectMetadataRoot]
    ) throws -> Payload {
        let stages: [(ProjectMetadataCaptureStage, LanguageProjectToolResult)]
        let language: ProjectMetadataLanguage
        switch captures {
        case .cargo(let result):
            language = .rust
            stages = [(.cargo, result)]
        case .go(let modules, let packages):
            guard (1...Self.maximumPackageCaptures).contains(packages.count) else {
                throw ProjectMetadataFailure.invalidInput(message: "Go metadata requires a bounded, nonempty package capture list.")
            }
            language = .go
            stages = [(.goModules, modules)] + packages.enumerated().map { (.goPackages($0.offset), $0.element) }
        }

        for (stage, result) in stages {
            guard result.status == .succeeded, result.cause == nil, result.exitCode == 0,
                  result.stdoutReachedEOF, result.stderrReachedEOF, result.cleanupConfirmed else {
                throw ProjectMetadataFailure.captureRejected(stage: stage, result: result)
            }
        }
        // Charge separators before decoding or joining. Subtraction avoids an
        // overflowing sum and prevents independently bounded captures multiplying
        // the Core's aggregate budget.
        var remaining = Self.maximumInputBytes
        if language == .go { remaining -= stages.count - 2 }
        for (_, result) in stages {
            guard result.stdout.count <= remaining else {
                throw ProjectMetadataFailure.invalidInput(message: "Project metadata exceeds its combined stdout limit.")
            }
            remaining -= result.stdout.count
        }
        let text = try stages.map { _, result in
            guard let text = String(data: result.stdout, encoding: .utf8) else {
                throw ProjectMetadataFailure.invalidInput(message: "Project metadata stdout is not valid UTF-8.")
            }
            return text
        }
        return Payload(
            language: language, workspaceDirectory: workspaceDirectory, roots: roots,
            cargoMetadata: language == .rust ? text[0] : nil,
            goModules: language == .go ? text[0] : nil,
            goPackages: language == .go ? text.dropFirst().joined(separator: "\n") : nil
        )
    }

    private struct Payload: Encodable {
        let language: ProjectMetadataLanguage
        let workspaceDirectory: String
        let roots: [ProjectMetadataRoot]
        let cargoMetadata: String?
        let goModules: String?
        let goPackages: String?
    }
}
