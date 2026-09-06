import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
@objc(LitheGoSupportPluginEntrypoint)
public final class GoSupportPluginEntrypoint: NSObject, LithePluginEntrypoint {
    public override init() { super.init() }

    public func moduleFactories(context: PluginHostContext) throws -> [ModuleFactory] {
        let executionHost = context.service(.languageExecution) as? any LanguageExecutionHostProviding
        let projectToolHost = context.service(.languageProjectTools) as? any LanguageProjectToolHostProviding
        return [
            ModuleFactory(manifest: GoExecutionModule.moduleManifest) {
                GoExecutionModule(executionHost: executionHost, projectToolHost: projectToolHost)
            },
            ModuleFactory(manifest: GoLanguageServerModule.moduleManifest) {
                GoLanguageServerModule()
            }
        ]
    }
}
