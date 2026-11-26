import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
@objc(LitheRustSupportPluginEntrypoint)
public final class RustSupportPluginEntrypoint: NSObject, LithePluginEntrypoint {
    public override init() { super.init() }

    public func moduleFactories(context: PluginHostContext) throws -> [ModuleFactory] {
        let executionHost = context.service(.languageExecution) as? any LanguageExecutionHostProviding
        let projectToolHost = context.service(.languageProjectTools) as? any LanguageProjectToolHostProviding
        return [
            ModuleFactory(
                manifest: RustExecutionModule.moduleManifest,
                contributions: RustExecutionModule.moduleContributions
            ) {
                RustExecutionModule(executionHost: executionHost, projectToolHost: projectToolHost)
            },
            ModuleFactory(manifest: RustLanguageServerModule.moduleManifest) {
                RustLanguageServerModule()
            }
        ]
    }
}
