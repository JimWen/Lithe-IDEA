import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Independent, bounded jobs. Each owns its preparation and plugin process;
/// no ordinary Run service or configuration persistence participates here.
@MainActor
package final class ProjectToolTaskFeatureModel: ObservableObject {
    package static let activeTaskLimit = 4
    package static let completedTaskLimit = 32
    package static let outputByteLimit = 4 * 1_024 * 1_024
    @Published package private(set) var tasks: [ProjectToolTaskSnapshot] = []
    @Published package private(set) var errorMessage: String?
    package var isActive: Bool { operations.contains { !$0.state.isTerminal } }
    private let activateProvider: @MainActor () async throws -> any ProjectToolActionProviding
    private let makePreparation: @MainActor (ProjectToolTaskOwner, ProjectToolTaskPlan, UUID) throws
        -> @Sendable () throws -> PreparedProjectToolTask
    private let scheduler: any ProjectToolScheduling
    private let worker = ProjectToolWorker()
    private var operations: [ProjectToolTaskOperation] = []
    private var context: ModuleContext?
    private var providerGeneration = 0
    private var epoch = 0
    private var retired = false

    package init(
        activateProvider: @escaping @MainActor () async throws -> any ProjectToolActionProviding,
        makePreparation: @escaping @MainActor (ProjectToolTaskOwner, ProjectToolTaskPlan, UUID) throws
            -> @Sendable () throws -> PreparedProjectToolTask,
        scheduler: (any ProjectToolScheduling)? = nil
    ) {
        self.activateProvider = activateProvider; self.makePreparation = makePreparation
        self.scheduler = scheduler ?? ProjectToolClock()
    }
    package func activate(context: ModuleContext) { self.context = context }

    @discardableResult
    package func start(_ action: ProjectToolActionRequest, workspaceURL: URL, workspaceGeneration: Int) -> UUID? {
        guard !retired else { errorMessage = "Execution is unavailable."; return nil }
        guard operations.filter({ !$0.state.isTerminal }).count < Self.activeTaskLimit else {
            errorMessage = "Stop an active tool task before starting another (maximum 4)."; return nil
        }
        let owner = ProjectToolTaskOwner(workspaceURL: workspaceURL.standardizedFileURL,
            workspaceGeneration: workspaceGeneration, providerGeneration: providerGeneration)
        let operation = ProjectToolTaskOperation(owner: owner, epoch: epoch, action: action)
        operations.append(operation)
        operation.lease = context?.leases.acquireLease(reason: "Go tool task")
        context?.events.publish(ModuleEvent(source: .execution, name: ModuleEvent.activityStartedName))
        errorMessage = nil
        operation.preparationTimer = scheduler.schedule(at: scheduler.now.advanced(by: .seconds(30))) { [weak self, weak operation] in
            guard let self, let operation else { return }
            self.requestStop(operation, message: "Tool preparation timed out.")
        }
        operation.pipeline = Task { @MainActor [self, operation] in await prepareAndStart(operation) }
        publish()
        return operation.id
    }

    package func stop(_ id: UUID) {
        guard let operation = operations.first(where: { $0.id == id }), !operation.state.isTerminal else { return }
        requestStop(operation, message: "Tool task was cancelled.")
    }
    package func clearOutput(_ id: UUID) {
        guard let operation = operations.first(where: { $0.id == id }) else { return }
        flush(operation)
        operation.output = ""
        publish()
    }
    package func invalidateWorkspace() {
        epoch += 1
        for operation in operations where !operation.state.isTerminal {
            requestStop(operation, message: "The project or toolchain changed.")
        }
    }
    package func invalidateProvider(moduleID: ModuleID) {
        guard moduleID == .languageExecutionExtension("go") else { return }
        providerGeneration += 1
        for operation in operations where !operation.state.isTerminal {
            requestStop(operation, message: "Go Support is unavailable.")
        }
    }
    package func retire() {
        retired = true
        invalidateWorkspace()
    }
    /// Stop every job before awaiting any one. A deadline reports incomplete
    /// cleanup while retaining the operation and lease until native exit.
    package func stopAndWait() async -> Bool {
        let active = operations.filter { !$0.state.isTerminal }
        for operation in active { requestStop(operation, message: "Tool task was stopped.") }
        var success = true
        for operation in active where !operation.state.isTerminal {
            ensureStopDeadline(operation)
            let stopped = await withCheckedContinuation { operation.stopWaiters.append($0) }
            success = success && stopped
        }
        return success
    }

    private func prepareAndStart(_ operation: ProjectToolTaskOperation) async {
        defer {
            operation.pipeline = nil; operation.pipelineFinished = true
            operation.preparationTimer?.cancel(); operation.preparationTimer = nil
            finishIfStopped(operation)
        }
        do {
            try checkCurrent(operation)
            let provider = try await activateProvider()
            try checkCurrent(operation)
            guard provider.languageID == "go" else { throw ProjectToolFailure(message: "Enable Go Support to run Go tools.") }
            let plan = try provider.toolPlan(for: operation.action)
            operation.title = plan.title + (plan.workingDirectory == "." ? "" : " · " + plan.workingDirectory)
            operation.source = plan.diagnosticSource
            let prepare = try makePreparation(operation.owner, plan, operation.id)
            let prepared = try await worker.perform(prepare)
            try checkCurrent(operation)
            try await worker.perform { try prepared.validate() }
            try checkCurrent(operation)
            try prepared.validateSelection()
            let session = provider.makeExecutionSession()
            operation.session = session
            try checkCurrent(operation)
            operation.directory = URL(fileURLWithPath: prepared.request.workingDirectory ?? operation.owner.workspaceURL.path)
            let buffer = operation.outputBuffer
            session.onOutput = { [weak self, weak operation] chunk in
                guard buffer.append(chunk) else { return }
                Task { @MainActor [weak self, weak operation] in
                    guard let self, let operation else { return }
                    self.scheduleOutput(operation)
                }
            }
            session.onStateChange = { [weak self, weak operation] event in
                Task { @MainActor [weak self, weak operation] in
                    guard let self, let operation, !operation.state.isTerminal,
                          event.operationID == operation.id.uuidString else { return }
                    if let message = event.message { operation.message = operation.message ?? message }
                    if event.state == .failed {
                        operation.state = .cleanupRequired
                        self.publish()
                    }
                }
            }
            session.onTermination = { [weak self, weak operation] code in
                Task { @MainActor [weak self, weak operation] in
                    guard let self, let operation, !operation.state.isTerminal else { return }
                    operation.exitCode = code
                    self.finishIfStopped(operation)
                }
            }
            try session.start(prepared.request)
            // Native start may synchronously invoke observers which retire us.
            try checkCurrent(operation)
            operation.state = .running
            publish()
        } catch {
            if !operation.cancelled { operation.message = error.localizedDescription }
            if operation.session?.isRunning == true {
                requestStop(operation, message: operation.message ?? error.localizedDescription, cancelled: false)
            }
        }
    }
    private func checkCurrent(_ operation: ProjectToolTaskOperation) throws {
        guard !retired, !operation.cancelled, operation.epoch == epoch,
              operation.owner.providerGeneration == providerGeneration, !Task.isCancelled else {
            throw ProjectToolFailure(message: operation.message ?? "Tool task is no longer current.")
        }
    }
    private func requestStop(_ operation: ProjectToolTaskOperation, message: String, cancelled: Bool = true) {
        guard !operation.state.isTerminal else { return }
        operation.cancelled = operation.cancelled || cancelled
        operation.message = operation.message ?? message
        operation.state = .stopping
        operation.pipeline?.cancel()
        operation.preparationTimer?.cancel(); operation.preparationTimer = nil
        if let session = operation.session, operation.stopTask == nil {
            session.stop()
            operation.stopTask = Task { @MainActor [self, operation, session] in
                _ = await session.stopAndWait()
                operation.stopTask = nil
                if session.isRunning {
                    operation.state = .cleanupRequired
                    operation.message = "The tool process is still stopping. Retry Stop."
                    operation.resolveWaiters(false)
                    publish()
                } else { finishIfStopped(operation) }
            }
        }
        ensureStopDeadline(operation)
        finishIfStopped(operation)
    }
    private func ensureStopDeadline(_ operation: ProjectToolTaskOperation) {
        guard operation.stopTimer == nil else { return }
        operation.stopTimer = scheduler.schedule(at: scheduler.now.advanced(by: .seconds(6))) { [weak self, weak operation] in
            guard let self, let operation, !operation.state.isTerminal else { return }
            operation.state = .cleanupRequired
            operation.message = "Tool cleanup is still pending. Retry Stop."
            operation.resolveWaiters(false)
            self.publish()
        }
    }
    private func finishIfStopped(_ operation: ProjectToolTaskOperation) {
        guard !operation.state.isTerminal else { return }
        guard !operation.ownsWork else { publish(); return }
        // Natural completion is delivered only after native output has drained.
        guard operation.exitCode != nil || operation.cancelled || operation.message != nil else { return }
        flush(operation)
        operation.state = operation.cancelled ? .cancelled
            : (operation.message == nil && operation.exitCode == 0 ? .succeeded : .failed)
        operation.resolveWaiters(true)
        operation.lease?.release(); operation.lease = nil
        operation.session?.onOutput = nil; operation.session?.onTermination = nil
        operation.session?.onStateChange = nil
        operation.session = nil
        context?.events.publish(ModuleEvent(source: .execution, name: ModuleEvent.activityEndedName))
        while operations.filter({ $0.state.isTerminal }).count > Self.completedTaskLimit,
              let index = operations.firstIndex(where: { $0.state.isTerminal }) { operations.remove(at: index) }
        publish()
    }
    private func scheduleOutput(_ operation: ProjectToolTaskOperation) {
        guard !operation.state.isTerminal, operation.outputTimer == nil else { return }
        operation.outputTimer = scheduler.schedule(at: scheduler.now.advanced(by: .milliseconds(40))) { [weak self, weak operation] in
            guard let self, let operation else { return }
            self.flush(operation); self.publish()
        }
    }
    private func flush(_ operation: ProjectToolTaskOperation) {
        operation.outputTimer?.cancel(); operation.outputTimer = nil
        let (text, truncated) = operation.outputBuffer.drain()
        operation.output += text; operation.outputTruncated = truncated
    }
    private func publish() { tasks = operations.map(\.snapshot) }
}
