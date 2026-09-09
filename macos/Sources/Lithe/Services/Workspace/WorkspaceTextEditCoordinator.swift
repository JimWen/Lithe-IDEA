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
        transactionID: UUID = UUID()
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
            state = .applied
            return WorkspaceTextEditTransactionResult(transactionID: transactionID, state: state)
        }
        state = .preparing
        let paths = uniqueEdits.map(\.path)
        let snapshots: [WorkspaceTextEditSnapshot]
        do {
            try Task.checkCancellation()
            snapshots = try await operations.capture(paths, at: workspaceURL)
            try Task.checkCancellation()
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
        for edit in uniqueEdits {
            do {
                try Task.checkCancellation()
                guard let snapshot = snapshots.first(where: { $0.path == edit.path }) else {
                    throw NSError(domain: "WorkspaceTextEdit", code: 1)
                }
                let written = try await operations.replace(edit, expected: snapshot, at: workspaceURL)
                applied.append((snapshot, written))
                try Task.checkCancellation()
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
                    transactionID: transactionID,
                    state: state,
                    failedPaths: [edit.path],
                    recoveryPaths: recovery
                )
            }
        }
        state = .applied
        return WorkspaceTextEditTransactionResult(transactionID: transactionID, state: state, changedPaths: paths)
    }

    package static func isValidPath(_ edit: WorkspaceTextEdit) -> Bool {
        !edit.path.isEmpty && !edit.path.hasPrefix("/")
            && !edit.path.split(separator: "/").contains("..")
            && !edit.path.contains("\\")
    }
}
