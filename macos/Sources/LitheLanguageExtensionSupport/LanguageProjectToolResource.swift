import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Module-owned capture sessions shared by native plugins and bundled languages.
/// Native processes and their global concurrency limit remain in the host.
@MainActor
public final class LanguageProjectToolResource: ModuleResource {
    public static let resourceKind = "language-project-tools-capture-v1"
    public var moduleResourceKind: String { Self.resourceKind }

    private let host: any LanguageProjectToolHostProviding
    private let ownerModuleID: ModuleID
    private let leases: any ModuleLeaseManaging
    private let events: any ModuleEventPublishing
    private weak var resources: (any ModuleResourceManaging)?
    private var registrationID: UUID?
    private let activation = LanguageProjectToolActivation()
    private var sessions: [OwnedLanguageProjectToolSession] = []
    private var stopAttempt: (id: UUID, task: Task<Void, Never>)?

    private init(host: any LanguageProjectToolHostProviding, context: ModuleContext) {
        self.host = host
        ownerModuleID = context.moduleID
        leases = context.leases
        events = context.events
        resources = context.resources
    }

    /// A failed activation can leave resources in the scope after its module
    /// instance was discarded. Never establish a new epoch over that owner.
    public static func register(
        host: any LanguageProjectToolHostProviding,
        context: ModuleContext
    ) throws -> LanguageProjectToolResource {
        guard !context.resources.resourceSnapshots().contains(where: {
            $0.kind == resourceKind && $0.isActive
        }) else {
            throw ModuleRuntimeError.activeResourcesRemain(module: context.moduleID, kinds: [resourceKind])
        }
        let resource = LanguageProjectToolResource(host: host, context: context)
        resource.registrationID = context.resources.register(resource)
        return resource
    }

    public var isModuleResourceActive: Bool {
        sessions.contains(where: \.isOwned)
    }

    public func makeCapability(languageID: String) -> LanguageProjectToolsCapability {
        LanguageProjectToolsCapability(languageID: languageID, resource: self)
    }

    /// Call before sleep/shutdown drops the module's capability, including when
    /// no capture is active and the runtime would skip stopModuleResource().
    public func retire() {
        guard activation.isOpen else { return }
        activation.isOpen = false
        unregisterIfRetiredAndStopped()
        events.publish(ModuleEvent(source: ownerModuleID, name: ModuleEvent.languageProjectToolsRetiredName))
    }

    public func stopModuleResource() async {
        retire()
        if let stopAttempt {
            await stopAttempt.task.value
            return
        }
        let id = UUID()
        let ownedSessions = sessions
        let task = Task { @MainActor in
            // Request every stop before awaiting any one native cleanup. A
            // slow first session must not leave the others running meanwhile.
            let stops = ownedSessions.map { session in
                Task { @MainActor in await session.stopAndWait() }
            }
            for stop in stops { _ = await stop.value }
        }
        stopAttempt = (id, task)
        await task.value
        if stopAttempt?.id == id { stopAttempt = nil }
    }

    func makeSession() -> any LanguageProjectToolSession {
        OwnedLanguageProjectToolSession(owner: self, activation: activation)
    }

    func begin(_ session: OwnedLanguageProjectToolSession, epoch: UUID) -> Bool {
        guard activation.isOpen, activation.epoch == epoch else { return false }
        sessions.append(session)
        return true
    }

    func makeNativeSession() -> any LanguageProjectToolSession {
        host.makeProjectToolSession(ownerModuleID: ownerModuleID)
    }

    func acquireActivity() -> ModuleLease {
        leases.acquireLease(reason: "Language project tool capture")
    }

    func publishActivityStarted() {
        events.publish(ModuleEvent(source: ownerModuleID, name: ModuleEvent.activityStartedName))
    }

    func finish(_ session: OwnedLanguageProjectToolSession) {
        sessions.removeAll { $0 === session }
        unregisterIfRetiredAndStopped()
        events.publish(ModuleEvent(source: ownerModuleID, name: ModuleEvent.activityEndedName))
    }

    private func unregisterIfRetiredAndStopped() {
        guard !activation.isOpen, !isModuleResourceActive, let registrationID else { return }
        // Only this owner can prove that its otherwise-idle factory is closed.
        // Do not remove arbitrary inactive snapshots belonging to other epochs.
        resources?.unregisterResource(id: registrationID)
        self.registrationID = nil
    }
}

/// A retained capability cannot resurrect a retired activation or its sessions.
@MainActor
public final class LanguageProjectToolsCapability: LanguageProjectToolsProviding {
    public let languageID: String
    private let resource: LanguageProjectToolResource

    init(languageID: String, resource: LanguageProjectToolResource) {
        self.languageID = languageID
        self.resource = resource
    }

    public func makeProjectToolSession() -> any LanguageProjectToolSession {
        resource.makeSession()
    }
}

@MainActor
final class LanguageProjectToolActivation {
    let epoch = UUID()
    var isOpen = true
}
