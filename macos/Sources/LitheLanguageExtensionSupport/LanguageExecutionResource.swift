import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Lifecycle errors surfaced when a language execution session is started
/// against a retired, busy, or uncleaned module activation.
public enum LanguageExecutionLifecycleError: LocalizedError, Equatable, Sendable {
    case unavailable(displayName: String)
    case alreadyRunning(displayName: String)
    case cleanupIncomplete(displayName: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let name):
            "\(name) execution is no longer active. Enable \(name) Support and retry."
        case .alreadyRunning(let name):
            "This \(name) session is still running or stopping."
        case .cleanupIncomplete(let name):
            "The previous \(name) process has not finished stopping."
        }
    }
}

/// Module-owned execution session resource shared by official native language
/// bundles (`GoSupport`, `RustSupport`, `PythonSupport`) so process leases,
/// retirement, and bounded shutdown semantics live in one auditable place.
@MainActor
public final class LanguageExecutionResource: ModuleResource {
    public static let resourceKind = "language-execution-process"
    public var moduleResourceKind: String { Self.resourceKind }

    private weak var resources: (any ModuleResourceManaging)?
    private var registrationID: UUID?
    private let executionHost: any LanguageExecutionHostProviding
    private let ownerModuleID: ModuleID
    private let displayName: String
    private let leases: any ModuleLeaseManaging
    private let events: any ModuleEventPublishing
    private var sessions: [any LanguageExecutionSession] = []
    private var retired = false
    private var stopAttempt: Task<Void, Never>?

    public init(
        executionHost: any LanguageExecutionHostProviding,
        ownerModuleID: ModuleID,
        displayName: String,
        leases: any ModuleLeaseManaging,
        events: any ModuleEventPublishing
    ) {
        self.executionHost = executionHost
        self.ownerModuleID = ownerModuleID
        self.displayName = displayName
        self.leases = leases
        self.events = events
    }

    public static func register(
        executionHost: any LanguageExecutionHostProviding,
        displayName: String,
        context: ModuleContext
    ) throws -> LanguageExecutionResource {
        guard !context.resources.resourceSnapshots().contains(where: {
            $0.kind == resourceKind && $0.isActive
        }) else {
            throw ModuleRuntimeError.activeResourcesRemain(
                module: context.moduleID,
                kinds: [resourceKind]
            )
        }
        let resource = LanguageExecutionResource(
            executionHost: executionHost,
            ownerModuleID: context.moduleID,
            displayName: displayName,
            leases: context.leases,
            events: context.events
        )
        resource.register(in: context.resources)
        return resource
    }

    public var isModuleResourceActive: Bool {
        stopAttempt != nil || sessions.contains(where: \.isRunning)
    }

    public func register(in resources: any ModuleResourceManaging) {
        self.resources = resources
        registrationID = resources.register(self)
    }

    public func retire() {
        retired = true
        unregisterIfRetiredAndStopped()
    }

    private func unregisterIfRetiredAndStopped() {
        guard retired, !isModuleResourceActive, let registrationID else { return }
        resources?.unregisterResource(id: registrationID)
        self.registrationID = nil
    }

    public func makeSession() -> any LanguageExecutionSession {
        let session = OwnedLanguageExecutionSession(
            makeUnderlying: { [executionHost, ownerModuleID] in
                executionHost.makeSession(ownerModuleID: ownerModuleID)
            },
            canStart: { [weak self] in self?.retired == false },
            onFinished: { [weak self] in self?.unregisterIfRetiredAndStopped() },
            ownerModuleID: ownerModuleID,
            displayName: displayName,
            leases: leases,
            events: events
        )
        if !retired { sessions.append(session) }
        return session
    }

    public func stopModuleResource() async {
        retire()
        if let stopAttempt {
            await stopAttempt.value
            return
        }
        let owned = sessions
        let task = Task { @MainActor [self] in
            // Request every active process to stop before awaiting any single
            // cleanup so a slow first session cannot keep siblings alive.
            let stops = owned.filter(\.isRunning).map { session in
                Task { @MainActor in _ = await session.stopAndWait() }
            }
            for stop in stops { await stop.value }
            sessions.removeAll { !$0.isRunning }
        }
        stopAttempt = task
        await task.value
        stopAttempt = nil
        unregisterIfRetiredAndStopped()
    }
}

@MainActor
private final class OwnedLanguageExecutionSession: LanguageExecutionSession {
    var isRunning: Bool { isStarting || underlying?.isRunning == true || activityLease != nil }
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?

    private let makeUnderlying: @MainActor () -> any LanguageExecutionSession
    private let canStart: @MainActor () -> Bool
    private let onFinished: @MainActor () -> Void
    private var underlying: (any LanguageExecutionSession)?
    private var generation = 0
    private var isStarting = false
    private let ownerModuleID: ModuleID
    private let displayName: String
    private let leases: any ModuleLeaseManaging
    private let events: any ModuleEventPublishing
    private var activityLease: ModuleLease?

    init(
        makeUnderlying: @escaping @MainActor () -> any LanguageExecutionSession,
        canStart: @escaping @MainActor () -> Bool,
        onFinished: @escaping @MainActor () -> Void,
        ownerModuleID: ModuleID,
        displayName: String,
        leases: any ModuleLeaseManaging,
        events: any ModuleEventPublishing
    ) {
        self.makeUnderlying = makeUnderlying
        self.canStart = canStart
        self.onFinished = onFinished
        self.ownerModuleID = ownerModuleID
        self.displayName = displayName
        self.leases = leases
        self.events = events
    }

    func start(_ request: LanguageExecutionProcessRequest) throws {
        guard canStart() else { throw LanguageExecutionLifecycleError.unavailable(displayName: displayName) }
        guard !isRunning else { throw LanguageExecutionLifecycleError.alreadyRunning(displayName: displayName) }
        isStarting = true
        defer { isStarting = false; onFinished() }
        generation += 1
        beginActivity(operationID: request.operationID)
        // Activity observers may synchronously retire this activation.
        guard canStart() else {
            endActivity()
            throw LanguageExecutionLifecycleError.unavailable(displayName: displayName)
        }
        let native = underlying ?? makeUnderlying()
        underlying = native
        installCallbacks(native, generation: generation)
        guard canStart() else {
            endActivity()
            throw LanguageExecutionLifecycleError.unavailable(displayName: displayName)
        }
        do {
            try native.start(request)
        } catch {
            if !native.isRunning { endActivity() }
            throw error
        }
    }

    func stop() {
        underlying?.stop()
        if underlying?.isRunning != true { endActivity() }
    }

    func stopAndWait() async -> Bool {
        guard let underlying else { return true }
        let currentGeneration = generation
        let stopped = await underlying.stopAndWait()
        if stopped, generation == currentGeneration { endActivity() }
        return stopped
    }

    private func installCallbacks(_ native: any LanguageExecutionSession, generation: Int) {
        let output = onOutput
        native.onOutput = { chunk in output?(chunk) }

        let termination = onTermination
        native.onTermination = { [weak self] exitCode in
            Task { @MainActor in
                if let self, self.generation == generation, self.underlying?.isRunning != true {
                    self.endActivity()
                }
                termination?(exitCode)
            }
        }

        let stateChange = onStateChange
        native.onStateChange = { event in stateChange?(event) }
    }

    private func beginActivity(operationID: String?) {
        guard activityLease == nil else { return }
        let detail = operationID.map { "Language execution \($0)" } ?? "Language execution"
        activityLease = leases.acquireLease(reason: detail)
        events.publish(ModuleEvent(source: ownerModuleID, name: ModuleEvent.activityStartedName))
    }

    private func endActivity() {
        guard let activityLease else { return }
        activityLease.release()
        self.activityLease = nil
        events.publish(ModuleEvent(source: ownerModuleID, name: ModuleEvent.activityEndedName))
        onFinished()
    }
}
