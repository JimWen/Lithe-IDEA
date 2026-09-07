import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

/// Resolves workspace settings at the native composition boundary. Metadata
/// captures stay owned by the enabled Rust language module.
@MainActor
enum MacCargoProjectComposition {
    static func makeFeature(
        runtime: ProjectRuntimeService, moduleRuntime: ModuleRuntime, core: RustCoreBridge
    ) -> CargoProjectFeatureModel {
        CargoProjectFeatureModel(
            nativePreparer: MacCargoMetadataPreparer(),
            normalizer: RustProjectMetadataOperations(core: core),
            makeInput: { workspaceURL, generation, manifestURL, deadline in
                guard runtime.projectURL?.standardizedFileURL == workspaceURL.standardizedFileURL else {
                    throw ProjectMetadataFailure.invalidInput(message: "The project changed. Refresh Cargo again.")
                }
                return CargoMetadataPreparationRequest(
                    workspaceURL: workspaceURL, manifestURL: manifestURL,
                    workspaceGeneration: generation,
                    cargoCandidates: runtime.executableCandidates("cargo").map(\.executableURL),
                    rustupCandidates: runtime.executableCandidates("rustup").map(\.executableURL),
                    customCargoURL: runtime.customExecutablePath(for: "cargo").map { URL(fileURLWithPath: $0) },
                    environment: runtime.processEnvironment(), deadline: deadline
                )
            },
            providerModuleID: .languageExecutionExtension("rust"),
            activateProvider: { [weak moduleRuntime] in
                guard let moduleRuntime else {
                    throw ProjectMetadataFailure.invalidInput(message: "The project is closed.")
                }
                let capability = try await moduleRuntime.activateCapability(.languageProjectTools("rust"))
                guard let provider = capability as? any LanguageProjectToolsProviding,
                      provider.languageID == "rust" else {
                    throw ProjectMetadataFailure.invalidInput(message: "Enable Rust Support to read Cargo projects.")
                }
                return provider
            }
        )
    }
}
