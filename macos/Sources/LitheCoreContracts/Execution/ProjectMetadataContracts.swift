import Foundation

/// Frozen native mapping for one workspace incarnation, supplied by its owner.
package struct ProjectMetadataRoot: Codable, Equatable, Sendable {
    package let id: String
    package let path: String

    package init(id: String, path: String) {
        self.id = id
        self.path = path
    }
}

package enum ProjectMetadataCaptures: Sendable {
    case cargo(LanguageProjectToolResult)
    /// One complete result per planned package-list stage; never partial chunks.
    case go(modules: LanguageProjectToolResult, packages: [LanguageProjectToolResult])
}

package enum ProjectMetadataCaptureStage: Equatable, Sendable {
    case cargo, goModules
    /// Zero-based index in the caller's frozen package stage list.
    case goPackages(Int)
}

package enum ProjectMetadataFailure: LocalizedError, Sendable {
    case captureRejected(stage: ProjectMetadataCaptureStage, result: LanguageProjectToolResult)
    case invalidInput(message: String)
    case core(code: String, message: String, details: String?)

    package var errorDescription: String? {
        switch self {
        case .captureRejected: "Project metadata requires a successful, fully drained tool result."
        case .invalidInput(let message), .core(_, let message, _): message
        }
    }
}

package struct ProjectMetadataNormalization: Sendable {
    package let operationID: String
    package let snapshot: ProjectMetadataSnapshot

    package init(operationID: String, snapshot: ProjectMetadataSnapshot) {
        self.operationID = operationID
        self.snapshot = snapshot
    }
}

/// Synchronous bounded CPU work. Call off the UI actor, then recheck the outer
/// deadline and workspace/provider generation before publishing the result.
package protocol ProjectMetadataNormalizing: Sendable {
    /// operationID must identify this normalization globally, not a reusable
    /// project name. The Core deadline excludes host encoding and decoding.
    func normalize(
        _ captures: ProjectMetadataCaptures, workspaceDirectory: String,
        roots: [ProjectMetadataRoot], operationID: String, timeoutMilliseconds: Int
    ) throws -> ProjectMetadataNormalization

    /// false means no active Core operation was found; it does not cancel a
    /// future call or confirm that the caller's native processes have stopped.
    @discardableResult func cancel(operationID: String) -> Bool
}
