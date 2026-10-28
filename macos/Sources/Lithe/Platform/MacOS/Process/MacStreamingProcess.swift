import Darwin
import Foundation
import LitheCoreContracts
import LitheModuleAPI

final class MacStreamingProcess: StreamingProcess, @unchecked Sendable {
    private static let forcedTerminationDelay: Duration = .milliseconds(200)

    var isRunning: Bool { process?.isRunning == true }
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)?

    private var isStarting = false
    private var process: MacManagedProcess?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var outputBatcher: MacProcessOutputBatcher?
    /// Reads, decoding, batch admission and teardown share one queue. Delivery
    /// may reenter stop(), so never hold a separate lock across its callback.
    private let outputQueue = DispatchQueue(label: "com.openres.Lithe.process-output", qos: .userInitiated)
    private let outputQueueKey = DispatchSpecificKey<UInt8>()
    private var outputDecoder = StreamingUTF8Decoder()
    private var timeoutTask: Task<Void, Never>?
    private var activeOperationID: String?
    private let processRegistry: ManagedProcessRegistry?
    private let category: ManagedProcessCategory
    private let moduleID: ModuleID?
    private var registeredPID: Int32?

    init(
        processRegistry: ManagedProcessRegistry? = nil,
        category: ManagedProcessCategory = .service,
        moduleID: ModuleID? = nil
    ) {
        self.processRegistry = processRegistry
        self.category = category
        self.moduleID = moduleID
        outputQueue.setSpecific(key: outputQueueKey, value: 1)
    }

    func start(_ request: ProcessRequest) throws {
        // Teardown delivers pending output. Reject a nested launch from that
        // callback rather than overwrite its process and lose cleanup ownership.
        guard withOutputQueue({
            guard !isStarting else { return false }
            isStarting = true
            return true
        }) else { throw POSIXError(.EBUSY) }
        defer { withOutputQueue { isStarting = false } }
        stop()
        activeOperationID = request.operationID
        onStateChange?(ProcessLifecycleEvent(
            operationID: request.operationID,
            state: .starting,
            exitCode: nil,
            message: nil
        ))

        let outputPipe = Pipe()
        let outputBatcher = MacProcessOutputBatcher(queue: outputQueue) { [weak self] output in
            self?.onOutput?(output)
        }
        let inputPipe = (request.standardInput != nil || request.keepsStandardInputOpen)
            ? Pipe()
            : nil
        let process = MacManagedProcess(
            executableURL: URL(fileURLWithPath: request.executablePath),
            arguments: request.arguments,
            currentDirectoryURL: request.workingDirectory.map(URL.init(fileURLWithPath:)),
            environment: request.environment,
            standardInput: inputPipe?.fileHandleForReading ?? FileHandle.nullDevice,
            standardOutput: outputPipe.fileHandleForWriting,
            standardError: outputPipe.fileHandleForWriting
        )
        if let inputPipe {
            // A timed-out child can close stdin while a write is in flight.
            // Convert SIGPIPE into a write error instead of terminating Lithe.
            _ = Darwin.fcntl(
                inputPipe.fileHandleForWriting.fileDescriptor,
                F_SETNOSIGPIPE,
                1
            )
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            guard let self, let process else { return }
            self.withOutputQueue {
                guard self.process === process else { return }
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let output = self.outputDecoder.decode(data)
                if !output.isEmpty {
                    outputBatcher.append(output)
                }
            }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            self.withOutputQueue {
                guard self.process === terminatedProcess else { return }
                var output = ""
                if let handle = self.outputPipe?.fileHandleForReading {
                    handle.readabilityHandler = nil
                    do {
                        output = self.outputDecoder.decode(try Self.drainAvailableOutput(from: handle))
                    } catch {
                        NSLog("Lithe process output drain failed: %@", error.localizedDescription)
                    }
                }
                output += self.outputDecoder.finish()
                outputBatcher.append(output)
                outputBatcher.finish()
                // Delivery can synchronously stop or restart this owner.
                guard self.process === terminatedProcess else { return }
                self.process = nil
                self.closePipes()
                self.outputBatcher = nil
                self.timeoutTask?.cancel()
                self.timeoutTask = nil
                self.activeOperationID = nil
                self.unregisterProcess()
                self.onStateChange?(ProcessLifecycleEvent(
                    operationID: request.operationID,
                    state: .finished,
                    exitCode: terminatedProcess.terminationStatus,
                    message: nil
                ))
                self.onTermination?(terminatedProcess.terminationStatus)
            }
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.outputBatcher = outputBatcher
        do {
            try process.run { [self] processIdentifier in
                registeredPID = processIdentifier
                processRegistry?.register(
                    pid: processIdentifier,
                    category: category,
                    moduleID: moduleID
                )
            }
            try? inputPipe?.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
        } catch {
            withOutputQueue {
                outputDecoder.reset()
            }
            outputBatcher.finish()
            closePipes()
            self.process = nil
            self.outputBatcher = nil
            onStateChange?(ProcessLifecycleEvent(
                operationID: request.operationID,
                state: .failed,
                exitCode: nil,
                message: error.localizedDescription
            ))
            activeOperationID = nil
            throw error
        }
        scheduleTimeout(request.timeoutMilliseconds, for: process, operationID: request.operationID)
        if let input = request.standardInput, let inputPipe {
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            if !request.keepsStandardInputOpen {
                try inputPipe.fileHandleForWriting.close()
            }
        }
        onStateChange?(ProcessLifecycleEvent(
            operationID: request.operationID,
            state: .running,
            exitCode: nil,
            message: nil
        ))
    }

    /// Captures only bytes already available after process exit. An escaped
    /// writer must not keep EOF or a continuously readable pipe alive forever.
    static func drainAvailableOutput(from handle: FileHandle, maximumBytes: Int = 1_048_576) throws -> Data {
        let descriptor = handle.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags != -1, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.fcntl(descriptor, F_SETFL, flags) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // Bound interrupted reads too, not only successfully captured bytes.
        for _ in 0..<128 where result.count < maximumBytes {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumBytes - result.count))
            if count > 0 { result.append(contentsOf: buffer.prefix(count)); continue }
            if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { break }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return result
    }

    private func withOutputQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: outputQueueKey) != nil { return try body() }
        return try outputQueue.sync(execute: body)
    }

    func send(_ input: Data) throws {
        try inputPipe?.fileHandleForWriting.write(contentsOf: input)
    }

    func stop() {
        _ = stopProcessGroup()
    }

    func stopAndWait() async -> Bool {
        guard let terminationTask = stopProcessGroup() else { return true }
        return await terminationTask.value
    }

    private func stopProcessGroup() -> Task<Bool, Never>? {
        withOutputQueue {
            timeoutTask?.cancel()
            timeoutTask = nil
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            let finalOutput = outputDecoder.finish()
            let batcher = outputBatcher
            let stoppedProcess = process
            let operationID = activeOperationID
            // Detach old resources before delivery can reenter start/stop.
            process = nil
            outputBatcher = nil
            activeOperationID = nil
            closePipes()
            unregisterProcess()
            let terminationTask = stoppedProcess?.isRunning == true ? stoppedProcess?.terminate() : nil
            if terminationTask != nil {
                onStateChange?(ProcessLifecycleEvent(
                    operationID: operationID, state: .stopping,
                    exitCode: nil, message: "Process stopped"
                ))
            }
            batcher?.append(finalOutput)
            batcher?.finish()
            return terminationTask
        }
    }

    private func closePipes() {
        try? inputPipe?.fileHandleForReading.close()
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        try? outputPipe?.fileHandleForWriting.close()
        inputPipe = nil
        outputPipe = nil
    }

    private func unregisterProcess() {
        guard let registeredPID else { return }
        processRegistry?.unregister(pid: registeredPID, category: category, moduleID: moduleID)
        self.registeredPID = nil
    }

    private func scheduleTimeout(
        _ milliseconds: Int?,
        for process: MacManagedProcess,
        operationID: String?
    ) {
        guard let milliseconds, milliseconds > 0 else { return }
        timeoutTask = Task { [weak self, weak process] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled,
                  let self,
                  let process,
                  self.process === process,
                  process.isRunning else { return }
            self.onStateChange?(ProcessLifecycleEvent(
                operationID: operationID,
                state: .stopping,
                exitCode: nil,
                message: "Process timed out"
            ))
            _ = process.terminate(gracePeriod: Self.forcedTerminationDelay)
        }
    }
}
