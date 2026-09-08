import Foundation

/// A bounded native queue prevents rapid queries from filling the cooperative
/// executor. Cancelled queued requests still run their completion, without I/O.
final class SearchPreviewWorker: @unchecked Sendable {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "lithe.search.preview"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func perform(_ request: ProjectTextPreviewRequest, operations: any SearchOperations) async -> Result<ProjectTextPreview, ProjectSearchFailure> {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.addOperation {
                    guard !cancellation.isCancelled else {
                        continuation.resume(returning: .failure(ProjectSearchFailure(code: "cancelled", message: "Search was cancelled.")))
                        return
                    }
                    continuation.resume(returning: operations.textPreview(request))
                }
            }
        } onCancel: {
            cancellation.cancel()
            // Core cancellation is cooperative. If cancellation races Core's
            // registration, its request deadline still bounds worker ownership;
            // the awaiting feature rejects the stale result in either case.
            operations.cancelTextPreview(operationID: request.operationID)
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}
