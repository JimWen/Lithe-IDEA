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

    private let nativePreparer: any CargoMetadataNativePreparing
    private let normalizer: any ProjectMetadataNormalizing
    private let makeInput: @MainActor (URL, Int, URL, ContinuousClock.Instant) throws -> CargoMetadataPreparationRequest
    private let providerModuleID: ModuleID
    private let activateProvider: @MainActor () async throws -> any LanguageProjectToolsProviding
    private let scheduler: any CargoProjectScheduling
    private let worker = CargoProjectWorker()
    private var operation: CargoProjectRefreshOperation?
    private var providerGeneration = 0
    private var retired = false
    private var context: ModuleContext?
    package var onOwnershipEnded: (@MainActor () -> Void)?

    package init(
        nativePreparer: any CargoMetadataNativePreparing,
        normalizer: any ProjectMetadataNormalizing,
        makeInput: @escaping @MainActor (URL, Int, URL, ContinuousClock.Instant) throws -> CargoMetadataPreparationRequest,
        providerModuleID: ModuleID,
        activateProvider: @escaping @MainActor () async throws -> any LanguageProjectToolsProviding,
        scheduler: (any CargoProjectScheduling)? = nil
    ) {
        self.nativePreparer = nativePreparer
        self.normalizer = normalizer
        self.makeInput = makeInput
        self.providerModuleID = providerModuleID
        self.activateProvider = activateProvider
        self.scheduler = scheduler ?? CargoProjectClock()
    }

    package func activate(context: ModuleContext) { self.context = context }

    package func refresh(workspaceURL: URL, workspaceGeneration: Int, manifestURL: URL) async {
        guard !retired else { return }
        guard operation == nil else {
            errorMessage = "Cargo metadata is still running or cleaning up. Stop it before refreshing."
            return
        }
        let owner = CargoProjectRefreshOperation(
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

    private func run(_ owner: CargoProjectRefreshOperation) async {
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
            let (native, commands) = try await worker.perform {
                let session = try preparer.prepare(input)
                return (session, session.resolutionCommands)
            }
            try checkCurrent(owner)
            guard commands.isEmpty || commands.count == 2 else {
                throw CargoProjectFailure(message: "Cargo toolchain resolution returned an invalid command plan.")
            }
            let provider = try await activateProvider()
            try checkCurrent(owner)
            guard provider.languageID == "rust" else {
                throw CargoProjectFailure(message: "The selected provider does not support Cargo metadata.")
            }
            var outputs: [Data] = []
            for command in commands {
                try await worker.perform { try native.validate() }
                try checkCurrent(owner)
                let result = try await capture(command, provider: provider, owner: owner)
                outputs.append(result.stdout)
            }
            let resolved = outputs
            let command = try await worker.perform {
                try native.validate()
                return try native.metadataCommand(resolutionOutputs: resolved)
            }
            try checkCurrent(owner)
            let result = try await capture(command, provider: provider, owner: owner)
            let nativeInput = try await worker.perform {
                try native.validate()
                return try native.normalizationInput(metadata: result.stdout)
            }
            try checkCurrent(owner)
            let normalizeID = UUID().uuidString
            owner.coreOperationID = normalizeID
            let timeout = try remainingMilliseconds(owner)
            let core = normalizer
            let normalized = try await worker.perform {
                let value = try core.normalize(.cargo(result), workspaceDirectory: nativeInput.workspaceDirectory,
                    roots: nativeInput.roots, operationID: normalizeID, timeoutMilliseconds: timeout)
                try native.validate()
                return value
            }
            owner.coreOperationID = nil
            try checkCurrent(owner)
            let currentInput = try makeInput(owner.workspaceURL, owner.workspaceGeneration, owner.manifestURL, owner.deadline)
            guard sameSelection(input, currentInput), normalized.operationID == normalizeID,
                  normalized.snapshot.language == .rust, normalized.snapshot.version == 1 else {
                throw CargoProjectFailure(message: "The Cargo project or toolchain selection changed during refresh.")
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

    private func capture(_ command: CargoMetadataCommand, provider: any LanguageProjectToolsProviding,
                         owner: CargoProjectRefreshOperation) async throws -> LanguageProjectToolResult {
        try checkCurrent(owner)
        guard owner.stdoutRemaining > 0, owner.stderrRemaining > 0 else {
            throw CargoProjectFailure(message: "Cargo metadata exceeded the refresh output limit.")
        }
        let stageID = UUID().uuidString
        let request = LanguageProjectToolRequest(operationID: stageID,
            executablePath: command.executablePath, arguments: command.arguments,
            workingDirectory: command.workingDirectory, environment: command.environment,
            timeoutMilliseconds: try remainingMilliseconds(owner),
            stdoutByteLimit: owner.stdoutRemaining, stderrByteLimit: owner.stderrRemaining)
        let record = CargoProjectCapture(provider.makeProjectToolSession())
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
            throw CargoProjectFailure(message: result.message ?? "Cargo metadata command failed (\(result.cause?.rawValue ?? result.status.rawValue)).")
        }
        guard result.stdout.count <= owner.stdoutRemaining, result.stderr.count <= owner.stderrRemaining else {
            throw CargoProjectFailure(message: "Cargo metadata exceeded the refresh output limit.")
        }
        owner.stdoutRemaining -= result.stdout.count
        owner.stderrRemaining -= result.stderr.count
        return result
    }

    private func checkCurrent(_ owner: CargoProjectRefreshOperation) throws {
        guard operation === owner, !retired, owner.cancellationMessage == nil,
              providerGeneration == owner.providerGeneration, !Task.isCancelled else {
            throw CargoProjectFailure(message: owner.cancellationMessage ?? "Cargo metadata refresh is no longer current.")
        }
        _ = try remainingMilliseconds(owner)
    }

    private func remainingMilliseconds(_ owner: CargoProjectRefreshOperation) throws -> Int {
        let remaining = scheduler.now.duration(to: owner.deadline).components
        let milliseconds = remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000
        guard milliseconds > 0 else { throw CargoProjectFailure(message: "Cargo metadata refresh timed out.") }
        return Int(min(30_000, milliseconds))
    }

    private func sameSelection(_ first: CargoMetadataPreparationRequest, _ last: CargoMetadataPreparationRequest) -> Bool {
        first.workspaceURL == last.workspaceURL && first.workspaceGeneration == last.workspaceGeneration
            && first.manifestURL == last.manifestURL && first.cargoCandidates == last.cargoCandidates
            && first.rustupCandidates == last.rustupCandidates && first.customCargoURL == last.customCargoURL
            && first.environment == last.environment
    }

    private func requestStop(_ owner: CargoProjectRefreshOperation, message: String) {
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

    private func stopCapture(_ record: CargoProjectCapture, owner: CargoProjectRefreshOperation) {
        guard record.stopTask == nil, !record.cleanupConfirmed else { return }
        record.stopTask = Task { @MainActor [self, owner, record] in
            let stopped = await record.session.stopAndWait()
            record.cleanupConfirmed = record.cleanupConfirmed || stopped
            record.stopTask = nil
            updateOwnership(owner)
        }
    }

    private func ensureStopDeadline(_ owner: CargoProjectRefreshOperation) {
        guard owner.stopTimer == nil else { return }
        owner.stopTimer = scheduler.schedule(at: scheduler.now.advanced(by: .seconds(3))) { [weak self, weak owner] in
            guard let self, let owner, self.operation === owner else { return }
            owner.finishStopWaiters(false)
            self.errorMessage = "\(owner.cancellationMessage ?? "Cargo metadata failed.") Cleanup is still pending."
            self.state = .failed
            owner.result.complete()
        }
    }

    private func awaitStopped(_ owner: CargoProjectRefreshOperation) async -> Bool {
        guard owner.isOwned else { return true }
        ensureStopDeadline(owner)
        return await withCheckedContinuation { owner.stopWaiters.append($0) }
    }

    private func updateOwnership(_ owner: CargoProjectRefreshOperation) {
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
