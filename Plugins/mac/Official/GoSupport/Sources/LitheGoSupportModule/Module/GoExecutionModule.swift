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
    private var executionResource: LanguageExecutionResource?
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
        guard executionResource == nil else {
            throw LanguageExecutionLifecycleError.cleanupIncomplete(displayName: "Go")
        }
        // Registration rejects a previous activation's unresolved owner, even
        // when the runtime discarded that module instance after cleanup failed.
        let projectTools = try LanguageProjectToolResource.register(
            host: projectToolHost, context: context
        )
        projectToolResource = projectTools
        projectToolCapability = projectTools.makeCapability(languageID: goLanguageID)
        let sessions = try LanguageExecutionResource.register(
            executionHost: executionHost,
            displayName: "Go",
            context: context
        )
        executionResource = sessions
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
            values[.languageDebugExtension(goLanguageID)] = capability
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
