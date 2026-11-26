import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
public final class AIAgentCapability: NSObject {
    public let feature: AIAgentFeatureModel
    private weak var resources: (any ModuleResourceManaging)?
    private weak var leases: (any ModuleLeaseManaging)?

    init(
        feature: AIAgentFeatureModel,
        resources: any ModuleResourceManaging,
        leases: any ModuleLeaseManaging
    ) {
        self.feature = feature
        self.resources = resources
        self.leases = leases
    }

    public func bind(host: any AIAgentWorkspaceHost) {
        feature.configure(host: host) { [weak self] threadID, stopHandler in
            guard let self, let resources = self.resources, let leases = self.leases else {
                return {}
            }
            let resource = AIAgentTurnResource(threadID: threadID, onStop: stopHandler)
            let resourceID = resources.register(resource)
            let lease = leases.acquireLease(reason: "AI Agent turn running")
            return { [weak resources] in
                lease.release()
                resource.markCompleted()
                resources?.unregisterResource(id: resourceID)
            }
        }
    }
}

@MainActor
public final class AIAgentModule: LitheModule {
    public static let moduleContributions = BuiltInModuleCatalog.contributions(for: .aiAgent)
    public static let moduleManifest = BuiltInModuleCatalog.manifest(for: .aiAgent)!

    public let manifest = moduleManifest
    private let processFactory: any AIAgentProcessSessionFactory
    private let cliResolver: any AIAgentCLIResolving
    private let streamingTransportFactory: @MainActor () -> any AIHTTPStreamingTransport
    private let credentialResolver: any AIProviderCredentialResolver
    private let threadStore: any AIAgentThreadStoring
    private var capability: AIAgentCapability?

    public init(
        processFactory: any AIAgentProcessSessionFactory,
        cliResolver: any AIAgentCLIResolving,
        streamingTransportFactory: @escaping @MainActor () -> any AIHTTPStreamingTransport,
        credentialResolver: any AIProviderCredentialResolver,
        threadStore: any AIAgentThreadStoring
    ) {
        self.processFactory = processFactory
        self.cliResolver = cliResolver
        self.streamingTransportFactory = streamingTransportFactory
        self.credentialResolver = credentialResolver
        self.threadStore = threadStore
    }

    public func activate(context: ModuleContext) async throws {
        guard capability == nil else { return }
        let runner = AIAgentTurnRunner(
            processFactory: processFactory,
            cliResolver: cliResolver,
            streamingTransport: streamingTransportFactory(),
            credentialResolver: credentialResolver
        )
        let feature = AIAgentFeatureModel(
            runner: runner,
            cliResolver: cliResolver,
            threadStore: threadStore
        )
        capability = AIAgentCapability(
            feature: feature,
            resources: context.resources,
            leases: context.leases
        )
    }

    public func prepareForSleep() async throws {}

    public func sleep() async {
        await capability?.feature.stopAllActiveTurns()
        capability = nil
    }

    public func shutdown() async {
        await capability?.feature.stopAllActiveTurns()
        capability = nil
    }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [.aiAgentWorkspace: capability]
    }

    public func contributions() -> [ModuleContribution] {
        Self.moduleContributions
    }
}

@MainActor
private final class AIAgentTurnResource: ModuleResource {
    private let threadID: UUID
    private let onStop: @MainActor () async -> Void
    private var isActive = true

    init(threadID: UUID, onStop: @escaping @MainActor () async -> Void) {
        self.threadID = threadID
        self.onStop = onStop
    }

    var moduleResourceKind: String { "ai-agent-turn-\(threadID.uuidString.prefix(8))" }
    var isModuleResourceActive: Bool { isActive }

    func markCompleted() {
        isActive = false
    }

    func stopModuleResource() async {
        guard isActive else { return }
        await onStop()
        isActive = false
    }
}
