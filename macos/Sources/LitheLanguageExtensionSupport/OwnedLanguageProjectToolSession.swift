import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Keeps activity until native cleanup is confirmed, even after capture has
/// returned an error. A later finished notification can release that ownership.
@MainActor
final class OwnedLanguageProjectToolSession: LanguageProjectToolSession {
    private(set) var state: LanguageProjectToolState = .idle
    var onStateChange: (@MainActor @Sendable (LanguageProjectToolState) -> Void)?

    private weak var owner: LanguageProjectToolResource?
    private let activation: LanguageProjectToolActivation
    private var underlying: (any LanguageProjectToolSession)?
    private var lease: ModuleLease?
    private var used = false
    private var captureInFlight = false
    private var cleanupConfirmed = false
    private var activityStarted = false
    private var stopRequested = false
    private var stopAttempt: (id: UUID, task: Task<Bool, Never>)?

    init(owner: LanguageProjectToolResource, activation: LanguageProjectToolActivation) {
        self.owner = owner
        self.activation = activation
    }

    var isOwned: Bool { captureInFlight || (activityStarted && !cleanupConfirmed) }

    func capture(_ request: LanguageProjectToolRequest) async -> LanguageProjectToolResult {
        guard !used else {
            return LanguageProjectToolResult(
                operationID: request.operationID, status: .invalidRequest,
                cleanupConfirmed: cleanupConfirmed && !captureInFlight,
                message: "A project tool session can only capture once."
            )
        }
        used = true
        guard activation.isOpen, let owner,
              owner.begin(self, epoch: activation.epoch) else {
            return reject(request, status: .unavailable)
        }
        captureInFlight = true
        activityStarted = true
        lease = owner.acquireActivity()
        owner.publishActivityStarted()
        publish(.starting)

        // Activity and state observers may retire the module synchronously.
        // Recheck before creating a native session or invoking its capture.
        guard activation.isOpen, !stopRequested, !Task.isCancelled else {
            return finishWithoutLaunch(request, status: Task.isCancelled ? .cancelled : .unavailable)
        }
        let native = owner.makeNativeSession()
        underlying = native
        native.onStateChange = { [weak self] state in self?.receive(state) }
        guard activation.isOpen, !stopRequested, !Task.isCancelled else {
            return finishWithoutLaunch(request, status: Task.isCancelled ? .cancelled : .unavailable)
        }

        // Await directly so cancellation reaches the host's owned capture.
        let result = await native.capture(request)
        captureInFlight = false
        cleanupConfirmed = cleanupConfirmed || result.cleanupConfirmed
        if cleanupConfirmed {
            finishActivityIfPossible()
        } else {
            publish(.cleanupFailed)
        }
        return result
    }

    func stopAndWait() async -> Bool {
        stopRequested = true
        if let stopAttempt { return await stopAttempt.task.value }
        if !used {
            used = true
            cleanupConfirmed = true
            publish(.finished)
            return true
        }
        if cleanupConfirmed { return true }
        guard let underlying else {
            // Before native capture there is nothing to stop. The synchronous
            // preflight rechecks stopRequested before it can create a process.
            cleanupConfirmed = true
            finishActivityIfPossible()
            return true
        }

        let id = UUID()
        let task = Task { @MainActor [self] in
            let stopped = await underlying.stopAndWait()
            cleanupConfirmed = cleanupConfirmed || stopped
            if cleanupConfirmed {
                finishActivityIfPossible()
            } else {
                publish(.cleanupFailed)
            }
            return cleanupConfirmed
        }
        stopAttempt = (id, task)
        let result = await task.value
        if stopAttempt?.id == id { stopAttempt = nil }
        return result
    }

    private func receive(_ state: LanguageProjectToolState) {
        guard !cleanupConfirmed else { return }
        if state == .finished {
            cleanupConfirmed = true
            finishActivityIfPossible()
        } else {
            publish(state)
        }
    }

    private func reject(
        _ request: LanguageProjectToolRequest, status: LanguageProjectToolStatus
    ) -> LanguageProjectToolResult {
        cleanupConfirmed = true
        publish(.finished)
        return LanguageProjectToolResult(
            operationID: request.operationID, status: status, cleanupConfirmed: true
        )
    }

    private func finishWithoutLaunch(
        _ request: LanguageProjectToolRequest, status: LanguageProjectToolStatus
    ) -> LanguageProjectToolResult {
        captureInFlight = false
        cleanupConfirmed = true
        finishActivityIfPossible()
        return LanguageProjectToolResult(
            operationID: request.operationID, status: status, cleanupConfirmed: true
        )
    }

    private func finishActivityIfPossible() {
        guard cleanupConfirmed, !captureInFlight else { return }
        lease?.release()
        lease = nil
        if activityStarted {
            activityStarted = false
            owner?.finish(self)
        }
        publish(.finished)
    }

    private func publish(_ next: LanguageProjectToolState) {
        guard state != next else { return }
        state = next
        onStateChange?(next)
    }
}
