import Foundation
import LitheCoreContracts
import LitheLanguageExtensionSupport
import LitheModuleAPI

@MainActor
public final class RustExecutionModule: LitheModule {
    public static let moduleManifest = OfficialPluginCatalog.moduleManifestV2(
        for: .languageExecutionExtension(rustLanguageID)
    )!

    public static let moduleContributions: [ModuleContribution] =
        OfficialPluginCatalog.cargoProjectToolsContributions

    public let manifest = moduleManifest
    private let executionHost: (any LanguageExecutionHostProviding)?
    private let projectToolHost: (any LanguageProjectToolHostProviding)?
    private var capability: RustExecutionCapability?
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
            throw LanguageExtensionHostError.missingExecutionHost(languageID: rustLanguageID)
        }
        guard let projectToolHost else {
            throw LanguageProjectToolHostError.missingHost(languageID: rustLanguageID)
        }
        await releaseCapabilities()
        guard executionResource == nil else {
            throw LanguageExecutionLifecycleError.cleanupIncomplete(displayName: "Rust")
        }
        let projectTools = try LanguageProjectToolResource.register(
            host: projectToolHost,
            context: context
        )
        projectToolResource = projectTools
        projectToolCapability = projectTools.makeCapability(languageID: rustLanguageID)
        let sessions = try LanguageExecutionResource.register(
            executionHost: executionHost,
            displayName: "Rust",
            context: context
        )
        executionResource = sessions
        capability = RustExecutionCapability(sessionFactory: { sessions.makeSession() })
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
            values[.languageExecutionExtension(rustLanguageID)] = capability
            values[.languageTestingExtension(rustLanguageID)] = capability
            values[.languageDebugExtension(rustLanguageID)] = capability
        }
        if let projectToolCapability {
            values[.languageProjectTools(rustLanguageID)] = projectToolCapability
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
