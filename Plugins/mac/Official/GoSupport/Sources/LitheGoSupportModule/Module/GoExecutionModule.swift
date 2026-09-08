import Foundation
import LitheCoreContracts
import LitheLanguageExtensionSupport
import LitheModuleAPI

@MainActor
public final class GoExecutionModule: LitheModule {
    public static let moduleManifest = OfficialPluginCatalog.moduleManifestV2(
        for: .languageExecutionExtension(goLanguageID)
    )!

    /// The Go Tools sidebar entry. One source of truth lives in the host
    /// catalog so the packaged manifest declaration, the plugin factory and
    /// the module instance all present the same contribution to the runtime's
    /// equality checks.
    public static let moduleContributions: [ModuleContribution] =
        OfficialPluginCatalog.projectToolsContributions

    public let manifest = moduleManifest
    private let executionHost: (any LanguageExecutionHostProviding)?
    private let projectToolHost: (any LanguageProjectToolHostProviding)?
    private var capability: GoExecutionCapability?
    private var executionResource: GoExecutionResource?
    private var projectToolResource: LanguageProjectToolResource?
    private var projectToolCapability: LanguageProjectToolsCapability?

    public init(
        executionHost: (any LanguageExecutionHostProviding)? = nil,
        projectToolHost: (any LanguageProjectToolHostProviding)? = nil
    ) {
        self.executionHost = executionHost
        self.projectToolHost = projectToolHost
    }

    public func activate(context: ModuleContext) async throws {
        guard let executionHost else {
            throw LanguageExtensionHostError.missingExecutionHost(languageID: goLanguageID)
        }
        guard let projectToolHost else {
            throw LanguageProjectToolHostError.missingHost(languageID: goLanguageID)
        }
        // A sleep-blocked runtime may reactivate this same instance. Retire its
        // idle capabilities as well as active sessions before replacing the epoch.
        await releaseCapabilities()
        guard executionResource == nil else { throw GoExecutionLifecycleError.cleanupIncomplete }
        guard !context.resources.resourceSnapshots().contains(where: {
            $0.kind == GoExecutionResource.resourceKind && $0.isActive
        }) else {
            throw ModuleRuntimeError.activeResourcesRemain(module: context.moduleID, kinds: [GoExecutionResource.resourceKind])
        }
        // Registration rejects a previous activation's unresolved owner, even
        // when the runtime discarded that module instance after cleanup failed.
        let projectTools = try LanguageProjectToolResource.register(
            host: projectToolHost, context: context
        )
        projectToolResource = projectTools
        projectToolCapability = projectTools.makeCapability(languageID: goLanguageID)
        let sessions = GoExecutionResource(
            executionHost: executionHost,
            ownerModuleID: manifest.id,
            leases: context.leases,
            events: context.events
        )
        executionResource = sessions
        sessions.register(in: context.resources)
        capability = GoExecutionCapability(sessionFactory: { sessions.makeSession() })
    }

    public func prepareForSleep() async throws {}
    public func sleep() async { await releaseCapabilities() }
    public func shutdown() async { await releaseCapabilities() }

    public func contributions() -> [ModuleContribution] {
        Self.moduleContributions
    }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        var values: [ModuleCapabilityID: AnyObject] = [:]
        if let capability {
            values[.languageExecutionExtension(goLanguageID)] = capability
            values[.languageTestingExtension(goLanguageID)] = capability
        }
        if let projectToolCapability {
            values[.languageProjectTools(goLanguageID)] = projectToolCapability
        }
        return values
    }

    private func releaseCapabilities() async {
        executionResource?.retire()
        projectToolResource?.retire()
        projectToolCapability = nil
        capability = nil
        if let resource = executionResource {
            await resource.stopModuleResource()
            if executionResource === resource, !resource.isModuleResourceActive { executionResource = nil }
        }
        if let resource = projectToolResource {
            await resource.stopModuleResource()
            if projectToolResource === resource, !resource.isModuleResourceActive {
                projectToolResource = nil
            }
        }
    }
}

@MainActor
private final class GoExecutionResource: ModuleResource {
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
        let session = GoOwnedExecutionSession(
            makeUnderlying: { [executionHost, ownerModuleID] in executionHost.makeSession(ownerModuleID: ownerModuleID) },
            canStart: { [weak self] in self?.retired == false },
            onFinished: { [weak self] in self?.unregisterIfRetiredAndStopped() },
            ownerModuleID: ownerModuleID, leases: leases, events: events
        )
        if !retired { sessions.append(session) }
        return session
    }

    func stopModuleResource() async {
        retire()
        if let stopAttempt { await stopAttempt.value; return }
        let owned = sessions
        let task = Task { @MainActor [self] in
            // Ask every process to stop before waiting on any one cleanup.
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
private final class GoOwnedExecutionSession: LanguageExecutionSession {
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
        guard canStart() else { throw GoExecutionLifecycleError.unavailable }
        guard !isRunning else { throw GoExecutionLifecycleError.alreadyRunning }
        isStarting = true
        defer { isStarting = false; onFinished() }
        generation += 1
        beginActivity(operationID: request.operationID)
        // Activity observers may synchronously retire this activation.
        guard canStart() else { endActivity(); throw GoExecutionLifecycleError.unavailable }
        let native = underlying ?? makeUnderlying()
        underlying = native
        installCallbacks(native, generation: generation)
        guard canStart() else { endActivity(); throw GoExecutionLifecycleError.unavailable }
        do {
            try native.start(request)
        } catch {
            if !native.isRunning { endActivity() }
            throw error
        }
    }

    func stop() {
        underlying?.stop()
        // A stop request is not process completion. Keep the plugin awake
        // until native termination or a successful stopAndWait confirms exit.
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
                // Native exit may be queued before stop() observes completion,
                // followed by a new run on this same wrapper. The old callback
                // still belongs to its old consumer and must not release a new lease.
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

private enum GoExecutionLifecycleError: LocalizedError {
    case unavailable, alreadyRunning, cleanupIncomplete
    var errorDescription: String? {
        switch self {
        case .unavailable: "Go execution is no longer active. Enable Go Support and retry."
        case .alreadyRunning: "This Go session is still running or stopping."
        case .cleanupIncomplete: "The previous Go process has not finished stopping."
        }
    }
}
