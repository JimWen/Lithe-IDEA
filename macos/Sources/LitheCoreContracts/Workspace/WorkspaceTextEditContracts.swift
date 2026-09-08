import Foundation

/// A workspace-relative text change frozen before a transaction starts.
package struct WorkspaceTextEdit: Equatable, Sendable {
    package let path: String
    package let sourceText: String
    package let replacementText: String
    package let sourceIdentity: String

    package init(path: String, sourceText: String, replacementText: String, sourceIdentity: String) {
        self.path = path
        self.sourceText = sourceText
        self.replacementText = replacementText
        self.sourceIdentity = sourceIdentity
    }
}

/// The immutable file snapshot used to verify and compensate one edit.
package struct WorkspaceTextEditSnapshot: Equatable, Sendable {
    package let path: String
    package let text: String
    package let identity: String

    package init(path: String, text: String, identity: String) {
        self.path = path
        self.text = text
        self.identity = identity
    }
}

package enum WorkspaceTextEditTransactionState: Equatable, Sendable {
    case preparing
    case committing
    case rollingBack
    case applied
    case cancelled
    case failed
    case recoveryRequired
}

package struct WorkspaceTextEditTransactionResult: Equatable, Sendable {
    package let transactionID: UUID
    package let state: WorkspaceTextEditTransactionState
    package let changedPaths: [String]
    package let failedPaths: [String]
    package let recoveryPaths: [String]

    package init(
        transactionID: UUID,
        state: WorkspaceTextEditTransactionState,
        changedPaths: [String] = [],
        failedPaths: [String] = [],
        recoveryPaths: [String] = []
    ) {
        self.transactionID = transactionID
        self.state = state
        self.changedPaths = changedPaths.sorted()
        self.failedPaths = failedPaths.sorted()
        self.recoveryPaths = recoveryPaths.sorted()
    }
}

/// Platform-owned file operations used by the shared transaction workflow.
package protocol WorkspaceTextEditFileOperations: Sendable {
    func capture(
        _ paths: [String],
        at workspaceURL: URL
    ) async throws -> [WorkspaceTextEditSnapshot]
    func replace(
        _ edit: WorkspaceTextEdit,
        expected snapshot: WorkspaceTextEditSnapshot,
        at workspaceURL: URL
    ) async throws
    func restore(
        _ snapshot: WorkspaceTextEditSnapshot,
        at workspaceURL: URL
    ) async throws
}

package struct UnavailableWorkspaceTextEditFileOperations: WorkspaceTextEditFileOperations {
    package init() {}
    package func capture(_ paths: [String], at workspaceURL: URL) async throws -> [WorkspaceTextEditSnapshot] {
        throw NSError(domain: "WorkspaceTextEdit", code: 10)
    }
    package func replace(_ edit: WorkspaceTextEdit, expected snapshot: WorkspaceTextEditSnapshot, at workspaceURL: URL) async throws {
        throw NSError(domain: "WorkspaceTextEdit", code: 10)
    }
    package func restore(_ snapshot: WorkspaceTextEditSnapshot, at workspaceURL: URL) async throws {
        throw NSError(domain: "WorkspaceTextEdit", code: 10)
    }
}
