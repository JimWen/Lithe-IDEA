import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

@MainActor
enum MacProjectToolTaskComposition {
    static func makeFeature(runtime: ProjectRuntimeService, moduleRuntime: ModuleRuntime) -> ProjectToolTaskFeatureModel {
        ProjectToolTaskFeatureModel(activateProvider: { [weak moduleRuntime] in
            guard let moduleRuntime else { throw ProjectToolFailure(message: "The project is closed.") }
            let capability = try await moduleRuntime.activateCapability(.languageExecutionExtension("go"))
            guard let provider = capability as? any ProjectToolActionProviding, provider.languageID == "go" else {
                throw ProjectToolFailure(message: "Enable or update Go Support to run Go tools.")
            }
            return provider
        }, makePreparation: { owner, plan, id in
            guard runtime.projectURL?.standardizedFileURL == owner.workspaceURL else {
                throw ProjectToolFailure(message: "The project changed. Run the tool again.")
            }
            let selected = runtime.customExecutablePath(for: "go").map { URL(fileURLWithPath: $0) }
            let candidates = selected.map { [$0] } ?? runtime.executableCandidates("go").map(\.executableURL)
            let environment = runtime.processEnvironment()
            let validateSelection: @MainActor @Sendable () throws -> Void = {
                let current = runtime.customExecutablePath(for: "go").map { URL(fileURLWithPath: $0) }
                guard runtime.projectURL?.standardizedFileURL == owner.workspaceURL, current == selected,
                      runtime.processEnvironment() == environment else {
                    throw ProjectToolFailure(message: "The project or toolchain settings changed. Run the tool again.")
                }
            }
            return {
                let prepared = try MacProjectToolTaskPreparer.prepare(owner: owner, plan: plan, id: id,
                    candidates: candidates, environment: environment)
                return PreparedProjectToolTask(request: prepared.request, validate: prepared.validate,
                    validateSelection: validateSelection)
            }
        })
    }
}

/// Resolves a real selected toolchain and a contained working directory. Tool
/// actions intentionally use the user's normal Go environment (unlike the
/// isolated, read-only metadata workflow). Every launch remains direct argv.
enum MacProjectToolTaskPreparer {
    static func prepare(owner: ProjectToolTaskOwner, plan: ProjectToolTaskPlan, id: UUID,
                        candidates: [URL], environment: [String: String]) throws -> PreparedProjectToolTask {
        guard let goURL = candidates.first else { throw ProjectToolFailure(message: "Select a Go toolchain in project settings.") }
        let workspace = owner.workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        let relative = plan.workingDirectory
        guard relative == "." || (!relative.isEmpty && !relative.hasPrefix("/") && !relative.contains("\\")
            && !relative.contains(":") && !relative.contains("\0")
            && !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })) else {
            throw ProjectToolFailure(message: "The tool working directory must be inside the project.")
        }
        let requestedDirectory = relative == "." ? owner.workspaceURL : owner.workspaceURL.appendingPathComponent(relative)
        let directory = requestedDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard directory == workspace || directory.path.hasPrefix(workspace.path + "/") else {
            throw ProjectToolFailure(message: "The tool working directory resolves outside the project.")
        }
        let workspaceIdentity = try ProjectToolFileIdentity.existing(at: workspace, role: "Workspace")
        let directoryIdentity = try ProjectToolFileIdentity.existing(at: directory, role: "Tool working directory")
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw ProjectToolFailure(message: "The tool working directory no longer exists.")
        }
        let go = try ProjectToolFileIdentity.nativeExecutable(at: goURL, role: "Go toolchain")
        let executable: ProjectToolFileIdentity
        switch plan.executable {
        case .languageToolchain: executable = go
        case .companion(let name):
            guard name == "gofmt" else { throw ProjectToolFailure(message: "Unsupported Go companion tool.") }
            executable = try ProjectToolFileIdentity.nativeExecutable(
                at: go.resolvedURL.deletingLastPathComponent().appendingPathComponent(name), role: "Go formatting checker")
        }
        return PreparedProjectToolTask(request: LanguageExecutionProcessRequest(operationID: id.uuidString,
            executablePath: executable.resolvedURL.path, arguments: plan.arguments,
            workingDirectory: directory.path, environment: environment), validate: {
            guard owner.workspaceURL.resolvingSymlinksInPath().standardizedFileURL == workspace,
                  requestedDirectory.resolvingSymlinksInPath().standardizedFileURL == directory,
                  try ProjectToolFileIdentity.existing(at: workspace, role: "Workspace").isSameFile(as: workspaceIdentity),
                  try ProjectToolFileIdentity.existing(at: directory, role: "Tool working directory").isSameFile(as: directoryIdentity),
                  goURL.resolvingSymlinksInPath().standardizedFileURL == go.resolvedURL else {
                throw ProjectToolFailure(message: "The project or Go toolchain changed. Run the tool again.")
            }
            try go.validate(role: "Go toolchain")
            try executable.validate(role: "Go tool")
        })
    }
}
