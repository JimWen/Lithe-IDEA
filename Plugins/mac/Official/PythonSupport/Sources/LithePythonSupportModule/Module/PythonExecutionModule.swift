import Foundation
import LitheCoreContracts
import LitheLanguageExtensionSupport
import LitheModuleAPI

@MainActor
public final class PythonExecutionModule: LitheModule {
    public static let moduleManifest = OfficialPluginCatalog.moduleManifestV2(
        for: .languageExecutionExtension(pythonLanguageID)
    )!

    public let manifest = moduleManifest
    private let executionHost: (any LanguageExecutionHostProviding)?
    private var capability: PythonExecutionCapability?
    private var executionResource: LanguageExecutionResource?

    public init(executionHost: (any LanguageExecutionHostProviding)? = nil) {
        self.executionHost = executionHost
    }

    public func activate(context: ModuleContext) async throws {
        guard let executionHost else {
            throw LanguageExtensionHostError.missingExecutionHost(languageID: pythonLanguageID)
        }
        await releaseCapabilities()
        guard executionResource == nil else {
            throw LanguageExecutionLifecycleError.cleanupIncomplete(displayName: "Python")
        }
        let sessions = try LanguageExecutionResource.register(
            executionHost: executionHost,
            displayName: "Python",
            context: context
        )
        executionResource = sessions
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
