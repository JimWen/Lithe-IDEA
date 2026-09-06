import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// A single operation. Mutable I/O state lives on one native serial queue;
/// callers see only a small locked snapshot, never output chunks on MainActor.
final class MacProjectToolCapture: @unchecked Sendable {
    typealias DriverFactory = @Sendable (
        LanguageProjectToolRequest, DispatchQueue, @escaping @Sendable (MacProjectToolEvent) -> Void
    ) throws -> any MacProjectToolDriver

    private let queue = DispatchQueue(label: "dev.lithe.project-tool.capture", qos: .utility)
    private let coordinator: MacProjectToolCoordinator
    private let scheduler: any MacProjectToolScheduling
    private let makeDriver: DriverFactory
    private let snapshotLock = NSLock()
    private var publishedState: LanguageProjectToolState = .idle
    private var stateObserver: (@Sendable (UInt64, LanguageProjectToolState) -> Void)?
    private var revision: UInt64 = 0
    private var admittedCaptureID: UUID?
    private var consumed = false
    private var cancelledBeforeStart = false
    private var request: LanguageProjectToolRequest?
    private var driver: (any MacProjectToolDriver)?
    private var permit: UUID?
    private var captureCompletion: CheckedContinuation<LanguageProjectToolResult, Never>?
    private var stopWaiters: [CheckedContinuation<Bool, Never>] = []
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutEOF = false
    private var stderrEOF = false
    private var stdoutClosed = false
    private var stderrClosed = false
    private var spawnReturned = false
    private var writersClosed = false
    private var launched = false
    private var rootReaped = false
    private var groupStopped = false
    private var cleanupGeneration: UInt64 = 0
    private var exitCode: Int32?
    private var firstFailure: LanguageProjectToolStatus?
    private var failureMessage: String?
    private var operationDeadline: (UUID, any MacProjectToolDeadline)?
    private var cleanupDeadline: (UUID, any MacProjectToolDeadline)?

    init(
        registry: ManagedProcessRegistry, moduleID: ModuleID,
        coordinator: MacProjectToolCoordinator = .shared,
        scheduler: any MacProjectToolScheduling = MacProjectToolScheduler(),
        driverFactory: DriverFactory? = nil
    ) {
        self.coordinator = coordinator
        self.scheduler = scheduler
        self.makeDriver = driverFactory ?? { request, queue, emit in
            MacNativeProjectToolDriver(request: request, queue: queue, registry: registry, moduleID: moduleID, emit: emit)
        }
    }

    var state: LanguageProjectToolState { snapshotLock.withLock { publishedState } }
    var onStateChange: (@Sendable (UInt64, LanguageProjectToolState) -> Void)? {
        get { snapshotLock.withLock { stateObserver } }
        set { snapshotLock.withLock { stateObserver = newValue } }
    }

    func capture(_ request: LanguageProjectToolRequest) async -> LanguageProjectToolResult {
        let invocationID = UUID()
        let admitted = snapshotLock.withLock { () -> Bool in
            guard admittedCaptureID == nil else { return false }
            admittedCaptureID = invocationID
            return true
        }
        guard admitted else {
            return LanguageProjectToolResult(
                operationID: request.operationID, status: .invalidRequest,
                cleanupConfirmed: !state.isActive, message: "This project tool session has already been used."
            )
        }
        return await withTaskCancellationHandler {
            let alreadyCancelled = Task.isCancelled
            return await withCheckedContinuation { continuation in
                queue.async { [self] in begin(request, continuation: continuation, alreadyCancelled: alreadyCancelled) }
            }
        } onCancel: {
            queue.async { [self] in
                if !consumed { cancelledBeforeStart = true }
                else { fail(.cancelled) }
            }
        }
    }

    func stopAndWait() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !consumed {
                    consumed = true
                    cancelledBeforeStart = true
                    publish(.finished)
                    continuation.resume(returning: true)
                    return
                }
                guard permit != nil else { continuation.resume(returning: true); return }
                stopWaiters.append(continuation)
                fail(.cancelled, retry: true)
            }
        }
    }

    private func begin(
        _ value: LanguageProjectToolRequest,
        continuation: CheckedContinuation<LanguageProjectToolResult, Never>, alreadyCancelled: Bool
    ) {
        guard !consumed else {
            continuation.resume(returning: LanguageProjectToolResult(
                operationID: value.operationID, status: cancelledBeforeStart ? .cancelled : .invalidRequest,
                cleanupConfirmed: permit == nil, message: "This project tool session has already been used."
            ))
            return
        }
        consumed = true
        request = value
        captureCompletion = continuation
        if alreadyCancelled || cancelledBeforeStart {
            finishWithoutResources(.cancelled)
            return
        }
        guard Self.valid(value) else { finishWithoutResources(.invalidRequest); return }
        guard let permit = coordinator.acquire(owner: self) else {
            finishWithoutResources(.capacityUnavailable)
            return
        }
        self.permit = permit
        publish(.starting)
        let deadlineID = UUID()
        operationDeadline = (deadlineID, scheduler.schedule(
            afterMilliseconds: value.timeoutMilliseconds, queue: queue
        ) { [weak self] in
            guard let self, self.operationDeadline?.0 == deadlineID else { return }
            self.fail(.timedOut)
        })
        do {
            driver = try makeDriver(value, queue) { [weak self] event in self?.receive(event) }
            driver?.start()
        } catch {
            spawnReturned = true
            writersClosed = true
            groupStopped = true
            stdoutClosed = true
            stderrClosed = true
            fail(.startFailed, message: error.localizedDescription)
        }
    }

    private func receive(_ event: MacProjectToolEvent) {
        guard permit != nil else { return }
        switch event {
        case .launched:
            launched = true
            if firstFailure != nil {
                armCleanupDeadline()
                requestProcessStop()
            } else if !rootReaped { publish(.running) }
        case .spawnFinished(let error, let closed):
            spawnReturned = true
            writersClosed = closed
            if let error {
                if !launched { groupStopped = true }
                fail(.startFailed, message: error)
            } else {
                launched = true
                if firstFailure != nil { requestProcessStop() }
            }
            if !closed { fail(.readFailed) }
        case .writersClosed:
            writersClosed = true
        case .bytes(let stream, let bytes):
            guard firstFailure == nil else { return }
            let limit = stream == .stdout ? request!.stdoutByteLimit : request!.stderrByteLimit
            let remaining = limit - (stream == .stdout ? stdout.count : stderr.count)
            if stream == .stdout { stdout.append(bytes.prefix(remaining)) }
            else { stderr.append(bytes.prefix(remaining)) }
            if bytes.count > remaining { fail(.outputLimit) }
        case .eof(let stream):
            if stream == .stdout { stdoutEOF = true } else { stderrEOF = true }
        case .readerClosed(let stream):
            if stream == .stdout { stdoutClosed = true } else { stderrClosed = true }
        case .readFailed:
            fail(.readFailed)
        case .readerCloseFailed:
            fail(.readFailed)
            cleanupFailed()
        case .rootReaped(let code):
            rootReaped = true
            exitCode = code
            if firstFailure == nil { publish(.draining) }
        case .cleanupFinished(let generation, let stopped):
            if stopped { groupStopped = true }
            else if generation >= cleanupGeneration, !groupStopped { cleanupFailed() }
        }
        settle()
    }

    private var resourcesReleased: Bool {
        spawnReturned && writersClosed && stdoutClosed && stderrClosed && groupStopped && (!launched || rootReaped)
    }

    private func fail(_ cause: LanguageProjectToolStatus, message: String? = nil, retry: Bool = false) {
        guard permit != nil else { return }
        if firstFailure == nil { firstFailure = cause; failureMessage = message }
        cancelOperationDeadline()
        driver?.closeReaders()
        if resourcesReleased { settle(); return }
        // Repeated callers join the same cleanup deadline. An explicit retry
        // after a completed failure starts a new bounded attempt.
        if cleanupDeadline == nil || retry { armCleanupDeadline() }
        publish(.stopping)
        requestProcessStop()
    }

    private func requestProcessStop() {
        if let generation = driver?.requestStop() {
            cleanupGeneration = max(cleanupGeneration, generation)
        }
    }

    private func armCleanupDeadline() {
        guard cleanupDeadline == nil else { return }
        let id = UUID()
        cleanupDeadline = (id, scheduler.schedule(afterMilliseconds: 2_500, queue: queue) { [weak self] in
            guard let self, self.cleanupDeadline?.0 == id else { return }
            self.cleanupFailed()
        })
    }

    private func cleanupFailed() {
        guard permit != nil, !resourcesReleased else { settle(); return }
        if firstFailure == nil { firstFailure = .cleanupFailed }
        cancelOperationDeadline()
        cancelCleanupDeadline()
        driver?.closeReaders()
        publish(.cleanupFailed)
        completeCapture(status: .cleanupFailed, cleanupConfirmed: false)
        completeStops(false)
    }

    private func settle() {
        guard permit != nil, resourcesReleased else { return }
        let completeOutput = rootReaped && stdoutEOF && stderrEOF
        guard firstFailure != nil || completeOutput else { return }
        cancelOperationDeadline()
        cancelCleanupDeadline()
        driver?.dispose()
        driver = nil
        if let permit { coordinator.release(permit); self.permit = nil }
        publish(.finished)
        let status = firstFailure ?? (exitCode == 0 ? .succeeded : .processFailed)
        completeCapture(status: status, cleanupConfirmed: true)
        completeStops(true)
    }

    private func finishWithoutResources(_ status: LanguageProjectToolStatus) {
        publish(.finished)
        completeCapture(status: status, cleanupConfirmed: true)
    }

    private func completeCapture(status: LanguageProjectToolStatus, cleanupConfirmed: Bool) {
        guard let completion = captureCompletion, let request else { return }
        captureCompletion = nil
        completion.resume(returning: LanguageProjectToolResult(
            operationID: request.operationID, status: status,
            cause: status == .cleanupFailed && firstFailure != .cleanupFailed ? firstFailure : nil,
            stdout: stdout, stderr: stderr, exitCode: exitCode,
            stdoutReachedEOF: stdoutEOF, stderrReachedEOF: stderrEOF,
            cleanupConfirmed: cleanupConfirmed, message: failureMessage
        ))
    }

    private func completeStops(_ result: Bool) {
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume(returning: result) }
    }

    private func cancelOperationDeadline() {
        operationDeadline?.1.cancel()
        operationDeadline = nil
    }
    private func cancelCleanupDeadline() {
        cleanupDeadline?.1.cancel()
        cleanupDeadline = nil
    }

    private func publish(_ state: LanguageProjectToolState) {
        let callback = snapshotLock.withLock { () -> (@Sendable (UInt64, LanguageProjectToolState) -> Void)? in
            guard publishedState != state else { return nil }
            publishedState = state
            revision &+= 1
            return stateObserver
        }
        callback?(revision, state)
    }

    private static func valid(_ value: LanguageProjectToolRequest) -> Bool {
        guard !value.operationID.isEmpty, value.operationID.utf8.count <= 128,
              value.executablePath.hasPrefix("/"), value.workingDirectory.hasPrefix("/"),
              (1...300_000).contains(value.timeoutMilliseconds),
              (1...16 * 1_024 * 1_024).contains(value.stdoutByteLimit),
              (1...1_024 * 1_024).contains(value.stderrByteLimit),
              value.arguments.count <= 4_096, value.environment.count <= 1_024 else { return false }
        let strings = [value.operationID, value.executablePath, value.workingDirectory]
            + value.arguments + value.environment.flatMap { [$0.key, $0.value] }
        guard strings.allSatisfy({ !$0.utf8.contains(0) }),
              strings.reduce(0, { $0 + $1.utf8.count }) <= 128 * 1_024 else { return false }
        return value.environment.keys.allSatisfy { !$0.isEmpty && !$0.contains("=") }
    }
}
