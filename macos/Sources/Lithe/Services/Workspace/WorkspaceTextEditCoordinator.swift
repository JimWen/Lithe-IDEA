import Foundation
import LitheCoreContracts

/// Coordinates an all-or-nothing text edit batch over a platform file port.
/// The coordinator owns ordering and compensation; it never performs native I/O.
package actor WorkspaceTextEditCoordinator {
    private(set) var state: WorkspaceTextEditTransactionState = .preparing

    package init() {}

    package func apply(
        _ edits: [WorkspaceTextEdit],
        at workspaceURL: URL,
        operations: any WorkspaceTextEditFileOperations,
        transactionID: UUID = UUID()
    ) async -> WorkspaceTextEditTransactionResult {
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
            snapshots = try await operations.capture(paths, at: workspaceURL)
            guard snapshots.count == uniqueEdits.count,
                  Dictionary(uniqueKeysWithValues: snapshots.map { ($0.path, $0) }).count == uniqueEdits.count,
                  uniqueEdits.allSatisfy({ edit in
                      snapshots.first(where: { $0.path == edit.path })?.text.utf8.elementsEqual(edit.sourceText.utf8) == true &&
                          edit.sourceIdentity.isEmpty || snapshots.first(where: { $0.path == edit.path })?.identity == edit.sourceIdentity
                  }) else {
                state = .failed
                return WorkspaceTextEditTransactionResult(transactionID: transactionID, state: state, failedPaths: paths)
            }
        } catch {
            state = .failed
            return WorkspaceTextEditTransactionResult(transactionID: transactionID, state: state, failedPaths: paths)
        }

        state = .committing
        var applied: [WorkspaceTextEdit] = []
        for edit in uniqueEdits {
            do {
                guard let snapshot = snapshots.first(where: { $0.path == edit.path }) else {
                    throw NSError(domain: "WorkspaceTextEdit", code: 1)
                }
                try await operations.replace(edit, expected: snapshot, at: workspaceURL)
                applied.append(edit)
            } catch {
                state = .rollingBack
                var recovery: [String] = []
                for previous in applied.reversed() {
                    guard let snapshot = snapshots.first(where: { $0.path == previous.path }) else {
                        recovery.append(previous.path)
                        continue
                    }
                    do { try await operations.restore(snapshot, at: workspaceURL) }
                    catch { recovery.append(previous.path) }
                }
                state = recovery.isEmpty ? .failed : .recoveryRequired
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

    private static func isValidPath(_ edit: WorkspaceTextEdit) -> Bool {
        !edit.path.isEmpty && !edit.path.hasPrefix("/")
            && !edit.path.split(separator: "/").contains("..")
            && !edit.path.contains("\\")
    }
}
