import Darwin
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Streams stdout/stderr from a CLI agent process inside an owned process group.
///
/// Uses `MacManagedProcess` + `ManagedProcessRegistry` so cancellation, thread
/// deletion, module sleep, or workspace close reaps the entire CLI process tree
/// without leaving orphan `codex`, `claude`, or subshell processes behind.
final class MacAIAgentProcessSession: AIAgentProcessSession, @unchecked Sendable {
    private let processRegistry: ManagedProcessRegistry
    private let ownerModuleID: ModuleID
    private let lock = NSLock()
    private var process: MacManagedProcess?
    private var registryToken: UUID?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var isStopped = false

    init(
        processRegistry: ManagedProcessRegistry,
        ownerModuleID: ModuleID = .aiAgent
    ) {
        self.processRegistry = processRegistry
        self.ownerModuleID = ownerModuleID
    }

    func start(
        _ request: AIAgentProcessLaunchRequest,
        onEvent: @escaping @Sendable (AIAgentProcessEvent) -> Void
    ) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        _ = Darwin.fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let managedProcess = MacManagedProcess(
            executableURL: URL(fileURLWithPath: request.executablePath),
            arguments: request.arguments,
            currentDirectoryURL: URL(fileURLWithPath: request.workingDirectory, isDirectory: true),
            environment: request.environment,
            standardInput: inputPipe.fileHandleForReading,
            standardOutput: outputPipe.fileHandleForWriting,
            standardError: errorPipe.fileHandleForWriting
        )

        let drainGroup = DispatchGroup()
        let outRead = outputPipe.fileHandleForReading
        let errRead = errorPipe.fileHandleForReading

        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { drainGroup.leave() }
            while true {
                let data = outRead.availableData
                if data.isEmpty { break }
                onEvent(.stdout(data))
            }
        }

        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { drainGroup.leave() }
            while true {
                let data = errRead.availableData
                if data.isEmpty { break }
                onEvent(.stderr(data))
            }
        }

        managedProcess.terminationHandler = { [weak self] terminated in
            drainGroup.notify(queue: DispatchQueue.global(qos: .utility)) {
                guard let self else { return }
                let shouldEmit = self.lock.withLock { () -> Bool in
                    self.unregisterLocked()
                    self.closePipesLocked()
                    self.process = nil
                    return !self.isStopped
                }
                if shouldEmit {
                    onEvent(.terminated(terminated.terminationStatus))
                }
            }
        }

        lock.withLock {
            self.process = managedProcess
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            self.isStopped = false
        }

        do {
            try managedProcess.run { [weak self] pid in
                guard let self, pid > 0 else { return }
                self.lock.withLock {
                    self.registryToken = self.processRegistry.registerOwnedProcess(
                        pid: pid,
                        category: .service,
                        moduleID: self.ownerModuleID
                    )
                }
            }
            try? inputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
        } catch {
            lock.withLock {
                self.unregisterLocked()
                self.closePipesLocked()
                self.process = nil
            }
            throw error
        }

        if let stdinData = request.standardInput {
            let writeHandle = inputPipe.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    try? writeHandle.close()
                    return
                }
                let stopped = self.lock.withLock { self.isStopped }
                guard !stopped else {
                    try? writeHandle.close()
                    return
                }
                var offset = 0
                let chunkSize = 16_384
                while offset < stdinData.count {
                    if self.lock.withLock({ self.isStopped }) { break }
                    let end = min(offset + chunkSize, stdinData.count)
                    let slice = stdinData[offset..<end]
                    do {
                        try writeHandle.write(contentsOf: slice)
                    } catch {
                        break
                    }
                    offset = end
                }
                try? writeHandle.close()
            }
        }
    }

    func writeStandardInput(_ data: Data) throws {
        let handle = lock.withLock { inputPipe?.fileHandleForWriting }
        guard let handle else { return }
        try handle.write(contentsOf: data)
    }

    func closeStandardInput() {
        let handle = lock.withLock { inputPipe?.fileHandleForWriting }
        try? handle?.close()
    }

    func stopAndWait() async -> Bool {
        let activeProcess: MacManagedProcess? = lock.withLock {
            isStopped = true
            let current = process
            process = nil
            closePipesLocked()
            return current
        }

        guard let activeProcess else {
            lock.withLock { unregisterLocked() }
            return true
        }

        let stopped = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = activeProcess.terminateAndWait(
                    gracePeriod: 0.2,
                    forcedTerminationTimeout: 1.0
                )
                continuation.resume(returning: result)
            }
        }
        lock.withLock { unregisterLocked() }
        return stopped
    }

    private func unregisterLocked() {
        if let token = registryToken {
            registryToken = nil
            processRegistry.unregisterOwnedProcess(token)
        }
    }

    private func closePipesLocked() {
        try? inputPipe?.fileHandleForReading.close()
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        try? outputPipe?.fileHandleForWriting.close()
        try? errorPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForWriting.close()
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
    }
}

struct MacAIAgentProcessSessionFactory: AIAgentProcessSessionFactory {
    let processRegistry: ManagedProcessRegistry

    func makeSession() -> any AIAgentProcessSession {
        MacAIAgentProcessSession(processRegistry: processRegistry)
    }
}
