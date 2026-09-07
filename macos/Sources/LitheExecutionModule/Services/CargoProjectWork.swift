import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
package protocol CargoProjectDeadline: AnyObject {
    func cancel()
}

@MainActor
package protocol CargoProjectScheduling: AnyObject {
    var now: ContinuousClock.Instant { get }
    func schedule(at deadline: ContinuousClock.Instant, _ action: @escaping @MainActor @Sendable () -> Void) -> any CargoProjectDeadline
}

@MainActor
package final class CargoProjectClock: CargoProjectScheduling {
    package var now: ContinuousClock.Instant { ContinuousClock.now }
    package func schedule(at deadline: ContinuousClock.Instant, _ action: @escaping @MainActor @Sendable () -> Void) -> any CargoProjectDeadline {
        CargoProjectTimer(deadline: deadline, action: action)
    }
}

@MainActor
private final class CargoProjectTimer: CargoProjectDeadline {
    private var task: Task<Void, Never>?
    init(deadline: ContinuousClock.Instant, action: @escaping @MainActor @Sendable () -> Void) {
        task = Task { @MainActor in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }
    func cancel() { task?.cancel(); task = nil }
}

/// Native preparation and synchronous Core calls share one non-cooperative
/// worker. Cancelling the caller never mistakes a still-running call for cleanup.
final class CargoProjectWorker: Sendable {
    private let queue = DispatchQueue(label: "dev.lithe.cargo-metadata", qos: .utility)

    func perform<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }
}

@MainActor
final class CargoProjectCompletion {
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !completed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func complete() {
        guard !completed else { return }
        completed = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

@MainActor
final class CargoProjectCapture {
    let session: any LanguageProjectToolSession
    var inFlight = true
    var cleanupConfirmed = false
    var stopTask: Task<Void, Never>?
    init(_ session: any LanguageProjectToolSession) { self.session = session }
    var isOwned: Bool { inFlight || !cleanupConfirmed || stopTask != nil }
}

@MainActor
final class CargoProjectRefreshOperation {
    let id = UUID()
    let workspaceURL: URL
    let workspaceGeneration: Int
    let manifestURL: URL
    let providerGeneration: Int
    let deadline: ContinuousClock.Instant
    let result = CargoProjectCompletion()
    var pipelineTask: Task<Void, Never>?
    var pipelineFinished = false
    var captures: [CargoProjectCapture] = []
    var coreOperationID: String?
    var cancellationMessage: String?
    var stdoutRemaining = 16 * 1_024 * 1_024
    var stderrRemaining = 1_024 * 1_024
    var deadlineTimer: (any CargoProjectDeadline)?
    var stopTimer: (any CargoProjectDeadline)?
    var stopWaiters: [CheckedContinuation<Bool, Never>] = []
    var lease: ModuleLease?

    init(workspaceURL: URL, workspaceGeneration: Int, manifestURL: URL, providerGeneration: Int, deadline: ContinuousClock.Instant) {
        self.workspaceURL = workspaceURL
        self.workspaceGeneration = workspaceGeneration
        self.manifestURL = manifestURL
        self.providerGeneration = providerGeneration
        self.deadline = deadline
    }

    var isOwned: Bool { !pipelineFinished || captures.contains(where: \.isOwned) }

    func finishStopWaiters(_ success: Bool) {
        stopTimer?.cancel(); stopTimer = nil
        let waiting = stopWaiters
        stopWaiters.removeAll()
        waiting.forEach { $0.resume(returning: success) }
    }
}

struct CargoProjectFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
