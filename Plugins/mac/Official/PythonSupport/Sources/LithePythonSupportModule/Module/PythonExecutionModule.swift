import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
public final class PythonExecutionModule: LitheModule {
    public static let moduleManifest = OfficialPluginCatalog.moduleManifestV2(
        for: .languageExecutionExtension(pythonLanguageID)
    )!

    public let manifest = moduleManifest
    private let executionHost: (any LanguageExecutionHostProviding)?
    private var capability: PythonExecutionCapability?
    private var executionResource: PythonExecutionResource?

    public init(executionHost: (any LanguageExecutionHostProviding)? = nil) {
        self.executionHost = executionHost
    }

    public func activate(context: ModuleContext) async throws {
        guard let executionHost else {
            throw LanguageExtensionHostError.missingExecutionHost(languageID: pythonLanguageID)
        }
        await releaseCapabilities()
        guard executionResource == nil else { throw PythonExecutionLifecycleError.cleanupIncomplete }
        guard !context.resources.resourceSnapshots().contains(where: {
            $0.kind == PythonExecutionResource.resourceKind && $0.isActive
        }) else {
            throw ModuleRuntimeError.activeResourcesRemain(
                module: context.moduleID,
                kinds: [PythonExecutionResource.resourceKind]
            )
        }
        let sessions = PythonExecutionResource(
            executionHost: executionHost,
            ownerModuleID: manifest.id,
            leases: context.leases,
            events: context.events
        )
        executionResource = sessions
        sessions.register(in: context.resources)
        capability = PythonExecutionCapability(sessionFactory: { sessions.makeSession() })
    }

    public func prepareForSleep() async throws {}
    public func sleep() async { await releaseCapabilities() }
    public func shutdown() async { await releaseCapabilities() }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        var values: [ModuleCapabilityID: AnyObject] = [:]
        if let capability {
            values[.languageExecutionExtension(pythonLanguageID)] = capability
            values[.languageTestingExtension(pythonLanguageID)] = capability
            values[.languageDebugExtension(pythonLanguageID)] = capability
        }
        return values
    }

    private func releaseCapabilities() async {
        executionResource?.retire()
        capability = nil
        if let resource = executionResource {
            await resource.stopModuleResource()
            if executionResource === resource, !resource.isModuleResourceActive { executionResource = nil }
        }
    }
}

@MainActor
private final class PythonExecutionResource: ModuleResource {
    static let resourceKind = "language-execution-process"
    var moduleResourceKind: String { Self.resourceKind }
    private weak var resources: (any ModuleResourceManaging)?
    private var registrationID: UUID?
    private let executionHost: any LanguageExecutionHostProviding
    private let ownerModuleID: ModuleID
    private let leases: any ModuleLeaseManaging
    private let events: any ModuleEventPublishing
    private var sessions: [any LanguageExecutionSession] = []
    private var retired = false
    private var stopAttempt: Task<Void, Never>?

    init(
        executionHost: any LanguageExecutionHostProviding,
        ownerModuleID: ModuleID,
        leases: any ModuleLeaseManaging,
        events: any ModuleEventPublishing
    ) {
        self.executionHost = executionHost
        self.ownerModuleID = ownerModuleID
        self.leases = leases
        self.events = events
    }

    var isModuleResourceActive: Bool {
        stopAttempt != nil || sessions.contains(where: \.isRunning)
    }

    func register(in resources: any ModuleResourceManaging) {
        self.resources = resources
        registrationID = resources.register(self)
    }

    func retire() {
        retired = true
        unregisterIfRetiredAndStopped()
    }

    private func unregisterIfRetiredAndStopped() {
        guard retired, !isModuleResourceActive, let registrationID else { return }
        resources?.unregisterResource(id: registrationID)
        self.registrationID = nil
    }

    func makeSession() -> any LanguageExecutionSession {
        let session = PythonOwnedExecutionSession(
            makeUnderlying: { [executionHost, ownerModuleID] in executionHost.makeSession(ownerModuleID: ownerModuleID) },
            canStart: { [weak self] in self?.retired == false },
            onFinished: { [weak self] in self?.unregisterIfRetiredAndStopped() },
            ownerModuleID: ownerModuleID,
            leases: leases,
            events: events
        )
        if !retired { sessions.append(session) }
        return session
    }

    func stopModuleResource() async {
        retire()
        if let stopAttempt { await stopAttempt.value; return }
        let owned = sessions
        let task = Task { @MainActor [self] in
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
private final class PythonOwnedExecutionSession: LanguageExecutionSession {
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
    private let leases: any ModuleLeaseManaging
    private let events: any ModuleEventPublishing
    private var activityLease: ModuleLease?

    init(
        makeUnderlying: @escaping @MainActor () -> any LanguageExecutionSession,
        canStart: @escaping @MainActor () -> Bool,
        onFinished: @escaping @MainActor () -> Void,
        ownerModuleID: ModuleID,
        leases: any ModuleLeaseManaging,
        events: any ModuleEventPublishing
    ) {
        self.makeUnderlying = makeUnderlying
        self.canStart = canStart
        self.onFinished = onFinished
        self.ownerModuleID = ownerModuleID
        self.leases = leases
        self.events = events
    }

    func start(_ request: LanguageExecutionProcessRequest) throws {
        guard canStart() else { throw PythonExecutionLifecycleError.unavailable }
        guard !isRunning else { throw PythonExecutionLifecycleError.alreadyRunning }
        isStarting = true
        defer { isStarting = false; onFinished() }
        generation += 1
        beginActivity(operationID: request.operationID)
        guard canStart() else { endActivity(); throw PythonExecutionLifecycleError.unavailable }
        let native = underlying ?? makeUnderlying()
        underlying = native
        installCallbacks(native, generation: generation)
        guard canStart() else { endActivity(); throw PythonExecutionLifecycleError.unavailable }
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

private enum PythonExecutionLifecycleError: LocalizedError {
    case unavailable, alreadyRunning, cleanupIncomplete
    var errorDescription: String? {
        switch self {
        case .unavailable: "Python execution is no longer active. Enable Python Support and retry."
        case .alreadyRunning: "This Python session is still running or stopping."
        case .cleanupIncomplete: "The previous Python process has not finished stopping."
        }
    }
}
