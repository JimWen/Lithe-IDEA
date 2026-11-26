import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
@objc(LithePythonSupportPluginEntrypoint)
public final class PythonSupportPluginEntrypoint: NSObject, LithePluginEntrypoint {
    public override init() { super.init() }

    public func moduleFactories(context: PluginHostContext) throws -> [ModuleFactory] {
        let executionHost = context.service(.languageExecution) as? any LanguageExecutionHostProviding
        return [
            ModuleFactory(manifest: PythonExecutionModule.moduleManifest) {
                PythonExecutionModule(executionHost: executionHost)
            },
            ModuleFactory(manifest: PythonLanguageServerModule.moduleManifest) {
                PythonLanguageServerModule()
            }
        ]
    }
}
