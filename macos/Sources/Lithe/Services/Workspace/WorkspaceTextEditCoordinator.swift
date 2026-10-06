import Foundation
import LitheCoreContracts

/// Coordinates an all-or-nothing text edit batch over a platform file port.
/// The coordinator owns ordering and compensation; it never performs native I/O.
package actor WorkspaceTextEditCoordinator {
    private(set) var state: WorkspaceTextEditTransactionState = .preparing

    private var isApplying = false

    package init() {}

    package func apply(
        _ edits: [WorkspaceTextEdit],
        at workspaceURL: URL,
        operations: any WorkspaceTextEditFileOperations,
        transactionID: UUID = UUID(),
        validate: @Sendable () async -> Bool = { true },
        commit: @Sendable () async throws -> Void = {}
    ) async -> WorkspaceTextEditTransactionResult {
        guard !isApplying else {
            return WorkspaceTextEditTransactionResult(transactionID: transactionID, state: .failed,
                                                      failedPaths: edits.map(\.path))
        }
        isApplying = true
        defer { isApplying = false }
        guard !Task.isCancelled else {
            return WorkspaceTextEditTransactionResult(transactionID: transactionID, state: .cancelled)
        }
        let grouped = Dictionary(grouping: edits, by: \.path)
        let duplicatePaths = grouped.filter { $0.value.count > 1 }.map(\.key)
        guard duplicatePaths.isEmpty else {
            state = .failed
            return WorkspaceTextEditTransactionResult(
                transactionID: transactionID,
                state: state,
                failedPaths: duplicatePaths
            )
        }
        let uniqueEdits = grouped.values.compactMap(\.first).sorted { $0.path < $1.path }
        guard uniqueEdits.allSatisfy(Self.isValidPath) else {
            state = .failed
            return WorkspaceTextEditTransactionResult(
                transactionID: transactionID,
                state: state,
                failedPaths: uniqueEdits.filter { !Self.isValidPath($0) }.map(\.path)
            )
        }
        guard !uniqueEdits.isEmpty else {
            do { try await commit(); state = .applied }
            catch { state = error is CancellationError ? .cancelled : .failed }
            return WorkspaceTextEditTransactionResult(transactionID: transactionID, state: state)
        }
        state = .preparing
        let paths = uniqueEdits.map(\.path)
        let snapshots: [WorkspaceTextEditSnapshot]
        do {
            try Task.checkCancellation()
            snapshots = try await operations.capture(paths, at: workspaceURL)
            try Task.checkCancellation()
            guard await validate() else { throw CancellationError() }
            guard snapshots.count == uniqueEdits.count,
                  Set(snapshots.map(\.path)).count == uniqueEdits.count,
                  uniqueEdits.allSatisfy({ edit in
                      snapshots.first(where: { $0.path == edit.path })?.text.utf8.elementsEqual(edit.sourceText.utf8) == true &&
                          (edit.sourceIdentity.isEmpty || snapshots.first(where: { $0.path == edit.path })?.identity == edit.sourceIdentity)
                  }) else {
                state = .failed
                return WorkspaceTextEditTransactionResult(transactionID: transactionID, state: state, failedPaths: paths)
            }
        } catch {
            state = error is CancellationError ? .cancelled : .failed
            return WorkspaceTextEditTransactionResult(transactionID: transactionID, state: state, failedPaths: paths)
        }

        state = .committing
        var applied: [(original: WorkspaceTextEditSnapshot, written: WorkspaceTextEditSnapshot)] = []
        var failedPath: String?
        do {
            for edit in uniqueEdits where edit.changesText {
                failedPath = edit.path
                try Task.checkCancellation()
                guard await validate() else { throw CancellationError() }
                guard let snapshot = snapshots.first(where: { $0.path == edit.path }) else {
                    throw NSError(domain: "WorkspaceTextEdit", code: 1)
                }
                let written = try await operations.replace(edit, expected: snapshot, at: workspaceURL)
                applied.append((snapshot, written))
                try Task.checkCancellation()
            }
            // Read-only preconditions have no guarded replace operation. Check
            // them again after all writes, including batches with no writes.
            let unchanged = uniqueEdits.filter { !$0.changesText }
            if !unchanged.isEmpty {
                let current = try await operations.capture(unchanged.map(\.path), at: workspaceURL)
                try Task.checkCancellation()
                guard current.count == unchanged.count,
                      Set(current.map(\.path)) == Set(unchanged.map(\.path)),
                      current.allSatisfy({ snapshot in
                          guard let original = snapshots.first(where: { $0.path == snapshot.path }) else { return false }
                          return original.identity == snapshot.identity && original.text.utf8.elementsEqual(snapshot.text.utf8)
                      }) else { throw CocoaError(.fileReadUnknown) }
            }
            // The host atomically revalidates and commits its leased buffers
            // here. Keep disk rollback snapshots until that MainActor turn
            // succeeds; a prior async check cannot close the scheduling gap.
            try await commit()
        } catch {
            state = .rollingBack
            var recovery: [String] = []
            for previous in applied.reversed() {
                do {
                    try await operations.restore(previous.original, expected: previous.written, at: workspaceURL)
                } catch { recovery.append(previous.original.path) }
            }
            state = recovery.isEmpty ? (error is CancellationError ? .cancelled : .failed) : .recoveryRequired
            return WorkspaceTextEditTransactionResult(
                transactionID: transactionID, state: state,
                failedPaths: failedPath.map { [$0] } ?? paths, recoveryPaths: recovery
            )
        }
        state = .applied
        return WorkspaceTextEditTransactionResult(transactionID: transactionID, state: state,
                                                  changedPaths: uniqueEdits.filter(\.changesText).map(\.path))
    }

    package static func isValidPath(_ edit: WorkspaceTextEdit) -> Bool {
        !edit.path.isEmpty && !edit.path.hasPrefix("/")
            && !edit.path.split(separator: "/").contains("..")
            && !edit.path.contains("\\")
    }
}
