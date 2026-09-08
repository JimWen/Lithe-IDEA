import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

/// Resolves workspace settings at the native composition boundary. Metadata
/// captures stay owned by the enabled Go language module.
@MainActor
enum MacGoProjectComposition {
    static func makeFeature(
        runtime: ProjectRuntimeService, moduleRuntime: ModuleRuntime, core: RustCoreBridge
    ) -> GoProjectFeatureModel {
        GoProjectFeatureModel(
            nativePreparer: MacGoMetadataPreparer(),
            normalizer: RustProjectMetadataOperations(core: core),
            makeInput: { workspaceURL, generation, manifestURL, deadline in
                guard runtime.projectURL?.standardizedFileURL == workspaceURL.standardizedFileURL else {
                    throw ProjectMetadataFailure.invalidInput(message: "The project changed. Refresh Go again.")
                }
                return CargoMetadataPreparationRequest(
                    workspaceURL: workspaceURL, manifestURL: manifestURL,
                    workspaceGeneration: generation,
                    cargoCandidates: runtime.executableCandidates("go").map(\.executableURL),
                    rustupCandidates: [],
                    customCargoURL: runtime.customExecutablePath(for: "go").map { URL(fileURLWithPath: $0) },
                    environment: runtime.processEnvironment(), deadline: deadline
                )
            },
            providerModuleID: .languageExecutionExtension("go"),
            activateProvider: { [weak moduleRuntime] in
                guard let moduleRuntime else {
                    throw ProjectMetadataFailure.invalidInput(message: "The project is closed.")
                }
                let capability = try await moduleRuntime.activateCapability(.languageProjectTools("go"))
                guard let provider = capability as? any LanguageProjectToolsProviding,
                      provider.languageID == "go" else {
                    throw ProjectMetadataFailure.invalidInput(message: "Enable Go Support to read Go projects.")
                }
                return provider
            }
        )
    }
}
