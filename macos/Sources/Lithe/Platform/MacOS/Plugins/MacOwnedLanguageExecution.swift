import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Streaming sibling of metadata capture, using the same native process-group
/// and descriptor driver. A failed stop retains admission and the actual owner;
/// completion requires root reap, group cleanup, and both closed readers.
final class MacOwnedLanguageExecution: @unchecked Sendable {
    typealias DriverFactory = MacProjectToolCapture.DriverFactory
    private static let admission = MacProjectToolCoordinator(maximumActive: 16)
    private let queue = DispatchQueue(label: "dev.lithe.language-execution", qos: .utility)
    private let lock = NSLock()
    private var active = false
    private var consumed = false
    private let coordinator: MacProjectToolCoordinator
    private let scheduler: any MacProjectToolScheduling
    private let makeDriver: DriverFactory
    private let output: @Sendable (String) -> Void
    private let termination: @Sendable (Int32) -> Void
    private let stateChange: @Sendable (LanguageExecutionLifecycleEvent) -> Void
    private var request: LanguageExecutionProcessRequest?
    private var driver: (any MacProjectToolDriver)?
    private var permit: UUID?
    private var spawnReturned = false
    private var writersClosed = false
    private var launched = false
    private var rootReaped = false
    private var groupStopped = false
    private var stdoutEOF = false
    private var stderrEOF = false
    private var stdoutClosed = false
    private var stderrClosed = false
    private var stdoutDecoder = MacStreamingUTF8Decoder()
    private var stderrDecoder = MacStreamingUTF8Decoder()
    private var exitCode: Int32?
    private var stopping = false
    private var failure: String?
    private var cleanupGeneration: UInt64 = 0
    private var startupTimer: (any MacProjectToolDeadline)?
    private var cleanupTimer: (any MacProjectToolDeadline)?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    init(registry: ManagedProcessRegistry, moduleID: ModuleID,
         coordinator: MacProjectToolCoordinator? = nil,
         scheduler: any MacProjectToolScheduling = MacProjectToolScheduler(), driverFactory: DriverFactory? = nil,
         output: @escaping @Sendable (String) -> Void,
         termination: @escaping @Sendable (Int32) -> Void,
         stateChange: @escaping @Sendable (LanguageExecutionLifecycleEvent) -> Void) {
        self.coordinator = coordinator ?? Self.admission; self.scheduler = scheduler
        self.output = output; self.termination = termination; self.stateChange = stateChange
        makeDriver = driverFactory ?? { request, queue, emit in
            MacNativeProjectToolDriver(request: request, queue: queue, registry: registry, moduleID: moduleID, emit: emit)
        }
    }
    var isRunning: Bool { lock.withLock { active } }

    func start(_ request: LanguageExecutionProcessRequest) throws {
        let directory = request.workingDirectory ?? FileManager.default.currentDirectoryPath
        let environment = request.environment ?? ProcessInfo.processInfo.environment
        let strings = [request.executablePath, directory] + request.arguments + environment.flatMap { [$0.key, $0.value] }
        guard request.executablePath.hasPrefix("/"), directory.hasPrefix("/"),
              request.arguments.count <= 4_096, environment.count <= 1_024,
              strings.allSatisfy({ !$0.contains("\0") }),
              strings.reduce(0, { $0 + $1.utf8.count }) <= 128 * 1_024 else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        guard lock.withLock({
            guard !consumed else { return false }
            consumed = true
            return true
        }) else { throw CocoaError(.executableLoad) }
        guard let permit = coordinator.acquire(owner: self) else { throw CocoaError(.executableLoad) }
        lock.withLock { active = true }
        let native = LanguageProjectToolRequest(operationID: request.operationID ?? UUID().uuidString,
            executablePath: request.executablePath, arguments: request.arguments, workingDirectory: directory,
            environment: environment, timeoutMilliseconds: 30_000, stdoutByteLimit: 1, stderrByteLimit: 1)
        queue.async { [self] in
            self.permit = permit; self.request = request
            publish(.starting)
            startupTimer = scheduler.schedule(afterMilliseconds: 30_000, queue: queue) { [weak self] in
                self?.fail("Process startup timed out.")
            }
            do {
                driver = try makeDriver(native, queue) { [weak self] in self?.receive($0) }
                driver?.start()
            } catch {
                spawnReturned = true; writersClosed = true; groupStopped = true
                stdoutClosed = true; stderrClosed = true
                fail(error.localizedDescription)
            }
        }
    }
    func stop() { queue.async { [self] in requestStop() } }
    func stopAndWait() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard permit != nil else { continuation.resume(returning: true); return }
                waiters.append(continuation)
                requestStop()
            }
        }
    }
    private func receive(_ event: MacProjectToolEvent) {
        guard permit != nil else { return }
        switch event {
        case .launched:
            launched = true
            if stopping { stopDriver() } else if !rootReaped { publish(.running) }
        case .spawnFinished(let error, let closed):
            spawnReturned = true; writersClosed = closed
            startupTimer?.cancel(); startupTimer = nil
            if let error {
                if !launched { groupStopped = true }
                fail(error)
            } else {
                launched = true
                if stopping { stopDriver() }
            }
            if !closed { fail("The process pipe writer could not be closed.") }
        case .writersClosed: writersClosed = true
        case .bytes(let stream, let bytes):
            let text = stream == .stdout ? stdoutDecoder.decode(bytes) : stderrDecoder.decode(bytes)
            if !text.isEmpty { output(text) }
        case .eof(let stream):
            let tail: String
            if stream == .stdout { stdoutEOF = true; tail = stdoutDecoder.finish() }
            else { stderrEOF = true; tail = stderrDecoder.finish() }
            if !tail.isEmpty { output(tail) }
        case .readerClosed(let stream):
            if stream == .stdout { stdoutClosed = true } else { stderrClosed = true }
        case .readerCloseFailed:
            fail("A process output descriptor could not be closed.")
            cleanupFailed()
        case .readFailed: fail("Could not read process output.")
        case .rootReaped(let code):
            rootReaped = true; exitCode = code
            ensureCleanupDeadline()
        case .cleanupFinished(let generation, let stopped):
            if stopped { groupStopped = true }
            else if generation >= cleanupGeneration, !groupStopped { cleanupFailed() }
        }
        settle()
    }
    private var released: Bool {
        spawnReturned && writersClosed && stdoutClosed && stderrClosed && groupStopped && (!launched || rootReaped)
    }
    private func fail(_ message: String) {
        if failure == nil { failure = message; output("\n\(message)\n") }
        requestStop()
    }
    private func requestStop() {
        guard permit != nil else { return }
        stopping = true
        startupTimer?.cancel(); startupTimer = nil
        publish(.stopping)
        driver?.closeReaders()
        guard permit != nil else { return }
        ensureCleanupDeadline()
        stopDriver()
        settle()
    }
    private func stopDriver() {
        if let generation = driver?.requestStop() { cleanupGeneration = max(cleanupGeneration, generation) }
    }
    private func ensureCleanupDeadline() {
        guard cleanupTimer == nil else { return }
        cleanupTimer = scheduler.schedule(afterMilliseconds: 2_500, queue: queue) { [weak self] in self?.cleanupFailed() }
    }
    private func cleanupFailed() {
        guard permit != nil, !released else { settle(); return }
        cleanupTimer?.cancel(); cleanupTimer = nil
        // Even a reaped root can leave a surviving descendant or pipe owner.
        // Keep admission until an explicit retry or late native event proves exit.
        failure = failure ?? "Process cleanup is still pending. Retry Stop."
        stopping = true
        driver?.closeReaders()
        guard permit != nil else { return }
        publish(.failed)
        completeWaiters(false)
    }
    private func settle() {
        guard let permit, released, stopping || (stdoutEOF && stderrEOF) else { return }
        startupTimer?.cancel(); startupTimer = nil
        cleanupTimer?.cancel(); cleanupTimer = nil
        let tail = stdoutDecoder.finish() + stderrDecoder.finish()
        if !tail.isEmpty { output(tail) }
        driver?.dispose(); driver = nil
        self.permit = nil
        lock.withLock { active = false }
        coordinator.release(permit)
        publish(.finished)
        // A stream/cleanup failure is not a successful command merely because
        // the root exited zero. Completion callbacks can reach the UI before
        // queued lifecycle notifications, so the exit signal carries failure.
        termination(failure == nil ? (exitCode ?? -1) : (exitCode == 0 ? -1 : exitCode ?? -1))
        completeWaiters(true)
    }
    private func completeWaiters(_ stopped: Bool) {
        let waiting = waiters; waiters.removeAll()
        waiting.forEach { $0.resume(returning: stopped) }
    }
    private func publish(_ state: LanguageExecutionLifecycleState) {
        stateChange(.init(operationID: request?.operationID, state: state, exitCode: exitCode, message: failure))
    }
}

/// A pipe read can split a UTF-8 scalar. Retain at most three trailing bytes;
/// malformed complete sequences use the same replacement decoding as before.
struct MacStreamingUTF8Decoder {
    private var pending = Data()
    mutating func decode(_ bytes: Data) -> String {
        pending.append(bytes)
        let values = Array(pending.suffix(4))
        var retained = 0
        for index in values.indices.reversed() {
            let byte = values[index]
            if byte & 0xC0 == 0x80 { continue }
            let length = byte >= 0xF0 && byte <= 0xF4 ? 4 : (byte >= 0xE0 && byte <= 0xEF ? 3 : (byte >= 0xC2 && byte <= 0xDF ? 2 : 1))
            let available = values.count - index
            if available < length { retained = available }
            break
        }
        let result = String(decoding: pending.dropLast(retained), as: UTF8.self)
        pending = Data(pending.suffix(retained))
        return result
    }
    mutating func finish() -> String {
        let result = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return result
    }
}
