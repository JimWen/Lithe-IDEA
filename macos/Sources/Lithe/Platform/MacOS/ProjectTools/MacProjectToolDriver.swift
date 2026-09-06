import Darwin
import Foundation
import LitheCoreContracts
import LitheModuleAPI

enum MacProjectToolStream: Sendable { case stdout, stderr }
enum MacProjectToolEvent: Sendable {
    case launched
    case spawnFinished(String?, writersClosed: Bool)
    case writersClosed
    case bytes(MacProjectToolStream, Data)
    case eof(MacProjectToolStream)
    case readerClosed(MacProjectToolStream)
    case readerCloseFailed(MacProjectToolStream, Int32)
    case readFailed(Int32)
    case rootReaped(Int32)
    case cleanupFinished(generation: UInt64, stopped: Bool)
}

/// Events and methods are delivered on the supplied serial owner queue.
protocol MacProjectToolDriver: AnyObject, Sendable {
    func start()
    @discardableResult func requestStop() -> UInt64?
    func closeReaders()
    func dispose()
}

final class MacNativeProjectToolDriver: MacProjectToolDriver, @unchecked Sendable {
    private let preparePipe: @Sendable () -> MacProjectToolPreparedPipe
    private let request: LanguageProjectToolRequest
    private let queue: DispatchQueue
    private let emit: @Sendable (MacProjectToolEvent) -> Void
    private let registry: ManagedProcessRegistry
    private let moduleID: ModuleID
    private let registrationLock = NSLock()
    private var process: MacManagedProcess?
    private var registration: UUID?
    private var stdout: MacProjectToolPipeReader?
    private var stderr: MacProjectToolPipeReader?
    private var stdoutWriter: MacProjectToolWriter?
    private var stderrWriter: MacProjectToolWriter?
    private var stopTask: Task<Void, Never>?
    private var stopGeneration: UInt64 = 0
    private var spawnReturned = false
    private var writersClosed = false

    init(
        request: LanguageProjectToolRequest, queue: DispatchQueue,
        registry: ManagedProcessRegistry, moduleID: ModuleID,
        preparePipe: @escaping @Sendable () -> MacProjectToolPreparedPipe = { MacProjectToolPreparedPipe.make() },
        emit: @escaping @Sendable (MacProjectToolEvent) -> Void
    ) {
        self.request = request
        self.preparePipe = preparePipe
        self.queue = queue
        self.registry = registry
        self.moduleID = moduleID
        self.emit = emit
    }

    func start() {
        // The controller already owns this driver before the first descriptor
        // exists. Preparation failures follow the same confirmed-close events
        // as a launched process; throwing here would lose an ambiguous close.
        let output = preparePipe()
        let errors = output.error == nil ? preparePipe() : MacProjectToolPreparedPipe()
        stdoutWriter = output.write.map { MacProjectToolWriter(descriptor: $0) }
        stderrWriter = errors.write.map { MacProjectToolWriter(descriptor: $0) }
        stdout = makeReader(output.read, stream: .stdout)
        stderr = makeReader(errors.read, stream: .stderr)
        if let code = output.error ?? errors.error {
            closeReaders()
            spawnReturned = true
            writersClosed = closeWriters()
            emit(.spawnFinished(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription, writersClosed: writersClosed))
            return
        }
        let process = MacManagedProcess(
            executableURL: URL(fileURLWithPath: request.executablePath), arguments: request.arguments,
            currentDirectoryURL: URL(fileURLWithPath: request.workingDirectory), environment: request.environment,
            standardInput: .nullDevice, standardOutput: stdoutWriter!.handle, standardError: stderrWriter!.handle
        )
        self.process = process
        installCallbacks(process)
        // Admission bounds these workers globally. The job already owns the
        // writer handles while queued; cancellation cannot close them early.
        DispatchQueue.global(qos: .utility).async { [self] in
            var failure: String?
            do {
                try process.run { pid in
                    registrationLock.withLock {
                        registration = registry.registerOwnedProcess(pid: pid, category: .service, moduleID: moduleID)
                    }
                    queue.async { [emit] in emit(.launched) }
                }
            } catch { failure = error.localizedDescription }
            let closed = closeWriters()
            let result = failure
            queue.async { [self] in
                spawnReturned = true
                writersClosed = closed
                emit(.spawnFinished(result, writersClosed: closed))
            }
        }
    }

    private func makeReader(_ descriptor: Int32?, stream: MacProjectToolStream) -> MacProjectToolPipeReader? {
        guard let descriptor else { emit(.readerClosed(stream)); return nil }
        return MacProjectToolPipeReader(
            descriptor: descriptor, queue: queue,
            onData: { [emit] in emit(.bytes(stream, $0)) }, onEOF: { [emit] in emit(.eof(stream)) },
            onError: { [emit] in emit(.readFailed($0)) }, onClosed: { [emit] in emit(.readerClosed(stream)) },
            onCloseError: { [emit] in emit(.readerCloseFailed(stream, $0)) }
        )
    }

    private func installCallbacks(_ process: MacManagedProcess) {
        process.onRootReaped = { [weak self] owner in
            guard let self else { return }
            // PID monitoring ends at root reap. Long-lived cleanup ownership
            // remains with coordinator/resource tokens, never a reusable PID.
            self.unregisterRoot()
            self.queue.async { [emit] in emit(.rootReaped(owner.terminationStatus)) }
        }
        process.terminationHandler = { [weak self] owner in
            guard let self else { return }
            let firstOutcome = owner.rootExitCleanupSucceeded == true
            self.queue.async { [emit] in emit(.cleanupFinished(generation: 0, stopped: firstOutcome)) }
        }
    }

    @discardableResult
    func requestStop() -> UInt64? {
        if spawnReturned, !writersClosed {
            writersClosed = closeWriters()
            if writersClosed { emit(.writersClosed) }
        }
        guard stopTask == nil else { return stopGeneration }
        guard let attempt = process?.terminate() else { return nil }
        stopGeneration &+= 1
        let generation = stopGeneration
        stopTask = Task { [self] in
            let stopped = await attempt.value
            queue.async { [self] in
                stopTask = nil
                emit(.cleanupFinished(generation: generation, stopped: stopped))
            }
        }
        return generation
    }

    func closeReaders() { stdout?.cancel(); stderr?.cancel() }

    func dispose() {
        // Called only after spawn, root/group and both read cancellation
        // handlers have completed. No live owner is dropped here.
        unregisterRoot()
        process?.onRootReaped = nil
        process?.terminationHandler = nil
        stdout = nil
        stderr = nil
    }

    private func unregisterRoot() {
        let token = registrationLock.withLock { () -> UUID? in
            defer { registration = nil }
            return registration
        }
        if let token { registry.unregisterOwnedProcess(token) }
    }

    private func closeWriters() -> Bool {
        // Always attempt both; a failed wrapper may lose its descriptor without
        // proving closure. Each owner retains that failure across retries.
        let outputClosed = stdoutWriter?.close() ?? true
        let errorsClosed = stderrWriter?.close() ?? true
        return outputClosed && errorsClosed
    }

}
