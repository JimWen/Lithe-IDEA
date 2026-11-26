import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
import LithePythonSupportModule
import Testing

@MainActor
struct PythonSupportModuleTests {
    @Test
    func manifestMatchesOfficialCatalogAndEntrypointCreatesLazyFactories() throws {
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(contentsOf: packageURL.appendingPathComponent("plugin.json"))
        )
        #expect(OfficialPluginCatalog.manifests.contains(manifest))
        let factories = try PythonSupportPluginEntrypoint().moduleFactories(context: .empty)
        #expect(factories.map(\.manifest) == manifest.modules.map(\.manifest))
        #expect(factories.map(\.contributions) == manifest.modules.map(\.contributions))
    }

    @Test
    func lspExecutionTestAndDebugActivateAndReleaseCleanly() async throws {
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            PythonTestWorkspaceModule(manifest: workspace)
        })
        let resolver = PythonTestServiceResolver()
        for factory in try PythonSupportPluginEntrypoint().moduleFactories(context: PluginHostContext(resolver: resolver)) {
            try runtime.register(factory)
        }
        try runtime.validateGraph()
        defer { Task { @MainActor in await runtime.shutdownAll() } }

        let lsp = try #require(
            try await runtime.activateCapability(.languageServerExtension("python"))
                as? any LanguageServerExtensionProviding
        )
        #expect(lsp.configuration.executableNames == ["basedpyright-langserver", "pyright-langserver"])
        #expect(lsp.configuration.arguments == ["--stdio"])
        let syntax = try #require(lsp as? any LanguageSyntaxExtensionProviding)
        #expect(syntax.syntaxProfile.languageID == "python")
        #expect(syntax.syntaxProfile.supportsTripleQuotedStrings)

        let run = try #require(
            try await runtime.activateCapability(.languageExecutionExtension("python"))
                as? any LanguageRunExtensionProviding
        )
        let test = try #require(
            try await runtime.activateCapability(.languageTestingExtension("python"))
                as? any LanguageTestExtensionProviding
        )
        let debug = try #require(
            try await runtime.activateCapability(.languageDebugExtension("python"))
                as? any LanguageDebugExtensionProviding
        )

        let launch = try run.launchPlan(for: LanguageRunExtensionRequest(
            relativeFilePath: "scripts/app.py",
            arguments: ["--verbose"]
        ))
        #expect(launch.executable == .toolchain("project-python"))
        #expect(launch.arguments == ["scripts/app.py", "--verbose"])

        let casePlan = try test.testPlan(for: LanguageTestExtensionRequest(
            scope: .testCase(identifier: "test_compute", relativeFilePath: "tests/test_math.py"),
            relativeProjectFilePaths: ["pyproject.toml", "tests/test_math.py"]
        ))
        #expect(casePlan.frameworkID == "pytest")
        #expect(casePlan.launchPlan.arguments == ["-m", "pytest", "tests/test_math.py::test_compute"])

        #expect(debug.debugAdapterLaunch.adapterID == "python")
        #expect(debug.debugAdapterLaunch.executableNames == ["python3", "python"])
        #expect(debug.debugAdapterLaunch.arguments == ["-m", "debugpy.adapter"])

        let session = run.makeExecutionSession()
        try session.start(LanguageExecutionProcessRequest(
            operationID: "python-run",
            executablePath: "/fixture/python3",
            arguments: ["main.py"]
        ))
        await #expect(throws: ModuleRuntimeError.activeLeasesPreventSleep(
            module: .languageExecutionExtension("python"),
            reasons: ["Language execution python-run"]
        )) {
            try await runtime.sleep(.languageExecutionExtension("python"))
        }

        try await runtime.setEnabled(false, for: .languageExecutionExtension("python"))
        #expect(!session.isRunning)
        #expect(try runtime.snapshot(for: .languageExecutionExtension("python")).activity.activeResourceCount == 0)
        #expect(try runtime.snapshot(for: .languageExecutionExtension("python")).activity.activeLeaseCount == 0)

        await runtime.shutdownAll()
    }
}

@MainActor
private final class PythonTestServiceResolver: PluginHostServiceResolving {
    let execution = PythonTestExecutionHost()
    func service(_ id: PluginHostServiceID) -> AnyObject? {
        id == .languageExecution ? execution : nil
    }
}

@MainActor
private final class PythonTestExecutionHost: LanguageExecutionHostProviding {
    func makeSession(ownerModuleID _: ModuleID) -> any LanguageExecutionSession {
        PythonTestExecutionSession()
    }
}

@MainActor
private final class PythonTestExecutionSession: LanguageExecutionSession {
    var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?
    func start(_ request: LanguageExecutionProcessRequest) throws { isRunning = true }
    func stop() { isRunning = false }
    func stopAndWait() async -> Bool { stop(); return true }
}

@MainActor
private final class PythonTestWorkspaceModule: LitheModule {
    let manifest: ModuleManifest
    init(manifest: ModuleManifest) { self.manifest = manifest }
    func activate(context _: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [.workspaceFoundation: self] }
}
