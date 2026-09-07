import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheExecutionModule
import LitheGoSupportModule
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("Project tool module integration")
@MainActor
struct ProjectToolModuleLifecycleTests {
    @Test(arguments: ["go", "rust"])
    func activatedModuleCapturesWithNativeHostAndDisableRetiresOldCapability(_ language: String) async {
        let runtime = ModuleRuntime()
        let registry = ManagedProcessRegistry()
        let coordinator = MacProjectToolCoordinator()
        let host = MacLanguageProjectToolHost(registry: registry, coordinator: coordinator)
        let execution = MacLanguageExecutionHost(processRegistry: registry)
        do {
            let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
            try runtime.register(ModuleFactory(manifest: workspace) { ProjectToolWorkspaceModule(manifest: workspace) })
            let module: any LitheModule = language == "go"
                ? GoExecutionModule(executionHost: execution, projectToolHost: host)
                : BundledLanguageExecutionModule(languageID: language, executionHost: execution, projectToolHost: host)
            try runtime.register(ModuleFactory(manifest: module.manifest, contributions: module.contributions()) { module })
            try await runtime.setEnabled(true, for: module.manifest.id)
            let capability = try #require(try await runtime.activateCapability(.languageProjectTools(language)) as? any LanguageProjectToolsProviding)
            let request = LanguageProjectToolRequest(
                operationID: "module-capture", executablePath: "/usr/bin/true",
                workingDirectory: FileManager.default.temporaryDirectory.path, environment: [:], timeoutMilliseconds: 2_000
            )
            let result = await capability.makeProjectToolSession().capture(request)
            #expect(result.status == .succeeded && result.cleanupConfirmed)
            #expect(try runtime.snapshot(for: module.manifest.id).activeLeaseReasons.isEmpty)
            try await runtime.setEnabled(false, for: module.manifest.id)
            let rejected = await capability.makeProjectToolSession().capture(request)
            #expect(rejected.status == .unavailable && rejected.cleanupConfirmed)
            #expect(try runtime.snapshot(for: module.manifest.id).state == .disabled)
        } catch { Issue.record(error) }
        // Also runs after require/activation failures; no test-owned module or
        // subprocess is abandoned by a throwing assertion.
        await runtime.shutdownAll()
        #expect(coordinator.activeCaptureCount == 0)
        #expect(registry.processIDs(for: .service).isEmpty)
    }

    @Test
    func onlyGoAndRustDeclareProjectToolCapture() {
        for language in ["python", "node", "rust"] {
            let manifest = BundledLanguagePluginCatalog.manifests.flatMap(\.modules)
                .first { $0.manifest.id == .languageExecutionExtension(language) }?.manifest
            #expect(manifest?.providedCapabilities.contains(.languageProjectTools(language)) == (language == "rust"))
        }
    }
}

@MainActor
private final class ProjectToolWorkspaceModule: LitheModule {
    let manifest: ModuleManifest
    private let capability = NSObject()
    init(manifest: ModuleManifest) { self.manifest = manifest }
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [.workspaceFoundation: capability] }
}
