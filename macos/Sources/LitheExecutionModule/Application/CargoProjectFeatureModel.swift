import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

package enum CargoProjectState: Sendable {
    case idle, loading, stopping, ready, failed
}

/// Owns one refresh through preparation, plugin capture, normalization and late
/// cleanup. Run/Test sessions remain independent of this feature.
@MainActor
package final class CargoProjectFeatureModel: ObservableObject {
    @Published package private(set) var state: CargoProjectState = .idle
    @Published package private(set) var snapshot: ProjectMetadataSnapshot?
    @Published package private(set) var errorMessage: String?
    @Published package private(set) var isActive = false

    private let nativePreparer: any ProjectMetadataNativePreparing
    private let normalizer: any ProjectMetadataNormalizing
    private let makeInput: @MainActor (URL, Int, URL, ContinuousClock.Instant) throws -> CargoMetadataPreparationRequest
    private let providerModuleID: ModuleID
    private let activateProvider: @MainActor () async throws -> any LanguageProjectToolsProviding
    private let scheduler: any ProjectToolScheduling
    private let worker = ProjectToolWorker()
    private var operation: ProjectToolRefreshOperation?
    private var providerGeneration = 0
    private var retired = false
    private var context: ModuleContext?
    package var onOwnershipEnded: (@MainActor () -> Void)?

    package init(
        nativePreparer: any ProjectMetadataNativePreparing,
        normalizer: any ProjectMetadataNormalizing,
        makeInput: @escaping @MainActor (URL, Int, URL, ContinuousClock.Instant) throws -> CargoMetadataPreparationRequest,
        providerModuleID: ModuleID,
        activateProvider: @escaping @MainActor () async throws -> any LanguageProjectToolsProviding,
        scheduler: (any ProjectToolScheduling)? = nil
    ) {
        self.nativePreparer = nativePreparer
        self.normalizer = normalizer
        self.makeInput = makeInput
        self.providerModuleID = providerModuleID
        self.activateProvider = activateProvider
        self.scheduler = scheduler ?? ProjectToolClock()
    }

    package func activate(context: ModuleContext) { self.context = context }

    package func refresh(workspaceURL: URL, workspaceGeneration: Int, manifestURL: URL) async {
        guard !retired else { return }
        guard operation == nil else {
            errorMessage = "Cargo metadata is still running or cleaning up. Stop it before refreshing."
            return
        }
        let owner = ProjectToolRefreshOperation(
            workspaceURL: workspaceURL.standardizedFileURL,
            workspaceGeneration: workspaceGeneration,
            manifestURL: manifestURL.standardizedFileURL,
            providerGeneration: providerGeneration,
            deadline: scheduler.now.advanced(by: .seconds(30))
        )
        operation = owner
        owner.lease = context?.leases.acquireLease(reason: "Cargo project metadata refresh")
        isActive = true
        context?.events.publish(ModuleEvent(source: .execution, name: ModuleEvent.activityStartedName))
        errorMessage = nil
        state = .loading
        owner.deadlineTimer = scheduler.schedule(at: owner.deadline) { [weak self, weak owner] in
            guard let self, let owner else { return }
            self.requestStop(owner, message: "Cargo metadata refresh timed out.")
        }
        owner.pipelineTask = Task { @MainActor [self, owner] in await run(owner) }
        await withTaskCancellationHandler {
            await owner.result.wait()
        } onCancel: {
            Task { @MainActor [weak self, weak owner] in
                guard let self, let owner else { return }
                self.requestStop(owner, message: "Cargo metadata refresh was cancelled.")
            }
        }
    }

    package func cancel() async {
        guard let owner = operation else { return }
        requestStop(owner, message: "Cargo metadata refresh was cancelled.")
        _ = await awaitStopped(owner)
    }

    package func invalidateProvider(moduleID: ModuleID) {
        guard moduleID == providerModuleID else { return }
        providerGeneration += 1
        if let owner = operation { requestStop(owner, message: "Rust support stopped. Enable it before refreshing Cargo metadata.") }
    }

    package func invalidateWorkspace() {
        snapshot = nil
        errorMessage = nil
        if let owner = operation { requestStop(owner, message: "The project or Cargo settings changed. Refresh Cargo metadata again.") }
        else { state = .idle }
    }

    package func retire() {
        retired = true
        if let owner = operation { requestStop(owner, message: "Cargo metadata refresh was stopped.") }
        else { context = nil }
    }

    @discardableResult
    package func stopAndWait() async -> Bool {
        guard let owner = operation else { return true }
        requestStop(owner, message: "Cargo metadata refresh was stopped.")
        return await awaitStopped(owner)
    }

    private func run(_ owner: ProjectToolRefreshOperation) async {
        defer {
            owner.pipelineFinished = true
            owner.pipelineTask = nil
            owner.coreOperationID = nil
            updateOwnership(owner)
        }
        do {
            try checkCurrent(owner)
            let input = try makeInput(owner.workspaceURL, owner.workspaceGeneration, owner.manifestURL, owner.deadline)
            let preparer = nativePreparer
            let (native, current) = try await worker.perform {
                let session = try preparer.prepare(input)
                return (session, session.initialStage)
            }
            try checkCurrent(owner)
            let provider = try await activateProvider()
            try checkCurrent(owner)
            guard provider.languageID == "rust" else {
                throw ProjectToolFailure(message: "The selected provider does not support Cargo metadata.")
            }
            // Staged capture: each round runs its planned commands in order and
            // hands the stdouts back to the session, which decides the next
            // round or finishes. The bounds are defensive; a session that
            // exceeds them is broken and fails the refresh instead of looping.
            var stage = current
            var doneSource: ProjectMetadataNormalizationSource?
            var lastRoundResults: [LanguageProjectToolResult] = []
            var rounds = 0
            while doneSource == nil {
                rounds += 1
                guard rounds <= 4 else {
                    throw ProjectToolFailure(message: "Project metadata capture exceeded the staged round limit.")
                }
                guard stage.commands.count <= 512 else {
                    throw ProjectToolFailure(message: "Project metadata capture issued an oversized command plan.")
                }
                var outputs: [Data] = []
                var roundResults: [LanguageProjectToolResult] = []
                for command in stage.commands {
                    try await worker.perform { try native.validate() }
                    try checkCurrent(owner)
                    let result = try await capture(command, provider: provider, owner: owner)
                    outputs.append(result.stdout)
                    roundResults.append(result)
                }
                try checkCurrent(owner)
                let completed = stage
                let collected = outputs
                let outcome = try await worker.perform {
                    try native.validate()
                    return try native.advance(stage: completed, outputs: collected)
                }
                try checkCurrent(owner)
                switch outcome {
                case .more(let next):
                    stage = next
                case .done(let done):
                    doneSource = done
                    lastRoundResults = roundResults
                }
            }
            guard let source = doneSource, let finalResult = lastRoundResults.last else {
                throw ProjectToolFailure(message: "Project metadata capture produced no result.")
            }
            let nativeInput = try await worker.perform {
                try native.validate()
                return try native.normalizationInput(source)
            }
            try checkCurrent(owner)
            let normalizeID = UUID().uuidString
            owner.coreOperationID = normalizeID
            let timeout = try remainingMilliseconds(owner)
            let core = normalizer
            let normalized = try await worker.perform {
                let value = try core.normalize(.cargo(finalResult), workspaceDirectory: nativeInput.workspaceDirectory,
                    roots: nativeInput.roots, operationID: normalizeID, timeoutMilliseconds: timeout)
                try native.validate()
                return value
            }
            owner.coreOperationID = nil
            try checkCurrent(owner)
            let currentInput = try makeInput(owner.workspaceURL, owner.workspaceGeneration, owner.manifestURL, owner.deadline)
            guard sameSelection(input, currentInput), normalized.operationID == normalizeID,
                  normalized.snapshot.language == .rust, normalized.snapshot.version == 1 else {
                throw ProjectToolFailure(message: "The Cargo project or toolchain selection changed during refresh.")
            }
            try checkCurrent(owner)
            snapshot = normalized.snapshot
            errorMessage = nil
            state = .ready
            owner.result.complete()
        } catch {
            if operation === owner {
                errorMessage = owner.cancellationMessage ?? error.localizedDescription
                state = .failed
            }
            owner.result.complete()
        }
    }

    private func capture(_ command: ProjectMetadataCommand, provider: any LanguageProjectToolsProviding,
                         owner: ProjectToolRefreshOperation) async throws -> LanguageProjectToolResult {
        try checkCurrent(owner)
        guard owner.stdoutRemaining > 0, owner.stderrRemaining > 0 else {
            throw ProjectToolFailure(message: "Cargo metadata exceeded the refresh output limit.")
        }
        let stageID = UUID().uuidString
        let request = LanguageProjectToolRequest(operationID: stageID,
            executablePath: command.executablePath, arguments: command.arguments,
            workingDirectory: command.workingDirectory, environment: command.environment,
            timeoutMilliseconds: try remainingMilliseconds(owner),
            stdoutByteLimit: owner.stdoutRemaining, stderrByteLimit: owner.stderrRemaining)
        let record = ProjectToolCapture(provider.makeProjectToolSession())
        owner.captures.append(record)
        record.session.onStateChange = { [weak self, weak owner, weak record] state in
            guard let self, let owner, let record else { return }
            if state == .finished { record.cleanupConfirmed = true }
            self.updateOwnership(owner)
        }
        // A provider factory can synchronously retire itself. Do not enter its
        // native session after an invalidation delivered by that callback.
        do { try checkCurrent(owner) } catch {
            record.inFlight = false
            stopCapture(record, owner: owner)
            throw error
        }
        let result = await record.session.capture(request)
        record.inFlight = false
        record.cleanupConfirmed = record.cleanupConfirmed || result.cleanupConfirmed
        updateOwnership(owner)
        try checkCurrent(owner)
        guard result.operationID == stageID, result.status == .succeeded, result.cause == nil,
              result.exitCode == 0, result.stdoutReachedEOF, result.stderrReachedEOF,
              result.cleanupConfirmed else {
            throw ProjectToolFailure(message: result.message ?? "Cargo metadata command failed (\(result.cause?.rawValue ?? result.status.rawValue)).")
        }
        guard result.stdout.count <= owner.stdoutRemaining, result.stderr.count <= owner.stderrRemaining else {
            throw ProjectToolFailure(message: "Cargo metadata exceeded the refresh output limit.")
        }
        owner.stdoutRemaining -= result.stdout.count
        owner.stderrRemaining -= result.stderr.count
        return result
    }

    private func checkCurrent(_ owner: ProjectToolRefreshOperation) throws {
        guard operation === owner, !retired, owner.cancellationMessage == nil,
              providerGeneration == owner.providerGeneration, !Task.isCancelled else {
            throw ProjectToolFailure(message: owner.cancellationMessage ?? "Cargo metadata refresh is no longer current.")
        }
        _ = try remainingMilliseconds(owner)
    }

    private func remainingMilliseconds(_ owner: ProjectToolRefreshOperation) throws -> Int {
        let remaining = scheduler.now.duration(to: owner.deadline).components
        let milliseconds = remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000
        guard milliseconds > 0 else { throw ProjectToolFailure(message: "Cargo metadata refresh timed out.") }
        return Int(min(30_000, milliseconds))
    }

    private func sameSelection(_ first: CargoMetadataPreparationRequest, _ last: CargoMetadataPreparationRequest) -> Bool {
        first.workspaceURL == last.workspaceURL && first.workspaceGeneration == last.workspaceGeneration
            && first.manifestURL == last.manifestURL && first.cargoCandidates == last.cargoCandidates
            && first.rustupCandidates == last.rustupCandidates && first.customCargoURL == last.customCargoURL
            && first.environment == last.environment
    }

    private func requestStop(_ owner: ProjectToolRefreshOperation, message: String) {
        guard operation === owner else { return }
        if owner.cancellationMessage == nil { owner.cancellationMessage = message }
        owner.deadlineTimer?.cancel(); owner.deadlineTimer = nil
        owner.pipelineTask?.cancel()
        if let id = owner.coreOperationID { normalizer.cancel(operationID: id) }
        state = .stopping
        for record in owner.captures where !record.cleanupConfirmed { stopCapture(record, owner: owner) }
        ensureStopDeadline(owner)
        updateOwnership(owner)
    }

    private func stopCapture(_ record: ProjectToolCapture, owner: ProjectToolRefreshOperation) {
        guard record.stopTask == nil, !record.cleanupConfirmed else { return }
        record.stopTask = Task { @MainActor [self, owner, record] in
            let stopped = await record.session.stopAndWait()
            record.cleanupConfirmed = record.cleanupConfirmed || stopped
            record.stopTask = nil
            updateOwnership(owner)
        }
    }

    private func ensureStopDeadline(_ owner: ProjectToolRefreshOperation) {
        guard owner.stopTimer == nil else { return }
        owner.stopTimer = scheduler.schedule(at: scheduler.now.advanced(by: .seconds(3))) { [weak self, weak owner] in
            guard let self, let owner, self.operation === owner else { return }
            owner.finishStopWaiters(false)
            self.errorMessage = "\(owner.cancellationMessage ?? "Cargo metadata failed.") Cleanup is still pending."
            self.state = .failed
            owner.result.complete()
        }
    }

    private func awaitStopped(_ owner: ProjectToolRefreshOperation) async -> Bool {
        guard owner.isOwned else { return true }
        ensureStopDeadline(owner)
        return await withCheckedContinuation { owner.stopWaiters.append($0) }
    }

    private func updateOwnership(_ owner: ProjectToolRefreshOperation) {
        guard operation === owner, !owner.isOwned else { return }
        owner.deadlineTimer?.cancel(); owner.deadlineTimer = nil
        owner.finishStopWaiters(true)
        owner.lease?.release(); owner.lease = nil
        for record in owner.captures { record.session.onStateChange = nil }
        operation = nil
        isActive = false
        context?.events.publish(ModuleEvent(source: .execution, name: ModuleEvent.activityEndedName))
        if retired { context = nil }
        if owner.cancellationMessage != nil {
            errorMessage = owner.cancellationMessage
            state = .failed
        }
        owner.result.complete()
        onOwnershipEnded?()
    }
}
