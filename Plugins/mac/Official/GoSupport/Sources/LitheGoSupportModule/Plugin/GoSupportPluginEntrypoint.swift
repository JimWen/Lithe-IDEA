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
            // The Go Tools sidebar contribution belongs to the current package
            // factory, not the frozen installed manifest: an already
            // distributed plugin.json must keep rendering the older bundle
            // unchanged while this build ships the new tool window.
            ModuleFactory(
                manifest: GoExecutionModule.moduleManifest,
                contributions: GoExecutionModule.moduleContributions
            ) {
                GoExecutionModule(executionHost: executionHost, projectToolHost: projectToolHost)
            },
            ModuleFactory(manifest: GoLanguageServerModule.moduleManifest) {
                GoLanguageServerModule()
            }
        ]
    }
}
