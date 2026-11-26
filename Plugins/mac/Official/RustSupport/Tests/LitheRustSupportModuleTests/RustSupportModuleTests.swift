import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheLanguageExtensionSupport
import LitheModuleAPI
import LitheRustSupportModule
import Testing

@MainActor
struct RustSupportModuleTests {
    @Test
    func manifestMatchesOfficialCatalogAndEntrypointCreatesLazyFactories() throws {
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(contentsOf: packageURL.appendingPathComponent("plugin.json"))
        )
        #expect(OfficialPluginCatalog.manifests.contains(manifest))
        let factories = try RustSupportPluginEntrypoint().moduleFactories(context: .empty)
        #expect(factories.map(\.manifest) == manifest.modules.map(\.manifest))
        #expect(factories.map(\.contributions) == manifest.modules.map(\.contributions))
    }

    @Test
    func lspExecutionDebugAndProjectToolsActivateAndReleaseCleanly() async throws {
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            RustTestWorkspaceModule(manifest: workspace)
        })
        let resolver = RustTestServiceResolver()
        for factory in try RustSupportPluginEntrypoint().moduleFactories(context: PluginHostContext(resolver: resolver)) {
            try runtime.register(factory)
        }
        try runtime.validateGraph()
        defer { Task { @MainActor in await runtime.shutdownAll() } }

        let lsp = try #require(
            try await runtime.activateCapability(.languageServerExtension("rust"))
                as? any LanguageServerExtensionProviding
        )
        #expect(lsp.configuration.executableNames == ["rust-analyzer"])
        #expect(lsp.configuration.validationArguments == ["--version"])
        let syntax = try #require(lsp as? any LanguageSyntaxExtensionProviding)
        #expect(syntax.syntaxProfile.languageID == "rust")
        #expect(syntax.syntaxProfile.supportsRustSyntax)

        let run = try #require(
            try await runtime.activateCapability(.languageExecutionExtension("rust"))
                as? any LanguageRunExtensionProviding
        )
        let test = try #require(
            try await runtime.activateCapability(.languageTestingExtension("rust"))
                as? any LanguageTestExtensionProviding
        )
        let debug = try #require(
            try await runtime.activateCapability(.languageDebugExtension("rust"))
                as? any LanguageDebugExtensionProviding
        )
        let tools = try #require(
            try await runtime.activateCapability(.languageProjectTools("rust"))
                as? any LanguageProjectToolsProviding
        )

        let launch = try run.launchPlan(for: LanguageRunExtensionRequest(
            relativeFilePath: "src/main.rs",
            arguments: ["--", "--port", "8080"]
        ))
        #expect(launch.executable == .toolchain("project-cargo"))
        #expect(launch.arguments == ["run", "--", "--port", "8080"])

        let casePlan = try test.testPlan(for: LanguageTestExtensionRequest(
            scope: .testCase(identifier: "tests::adds_numbers", relativeFilePath: "tests/integration.rs"),
            relativeProjectFilePaths: ["Cargo.toml", "tests/integration.rs"]
        ))
        #expect(casePlan.frameworkID == "cargo")
        #expect(casePlan.launchPlan.arguments == ["test", "--test", "integration", "tests::adds_numbers", "--", "--exact", "--nocapture"])

        #expect(debug.debugAdapterLaunch.adapterID == "lldb")
        #expect(debug.debugAdapterLaunch.executableNames == ["lldb-dap"])
        #expect(debug.debugAdapterLaunch.fallbacks.first?.executableName == "xcrun")

        // Active run lease blocks sleep; stopping releases the lease and resources.
        let session = run.makeExecutionSession()
        try session.start(LanguageExecutionProcessRequest(
            operationID: "rust-run",
            executablePath: "/fixture/cargo",
            arguments: ["run"]
        ))
        await #expect(throws: ModuleRuntimeError.activeLeasesPreventSleep(
            module: .languageExecutionExtension("rust"),
            reasons: ["Language execution rust-run"]
        )) {
            try await runtime.sleep(.languageExecutionExtension("rust"))
        }

        let capture = await tools.makeProjectToolSession().capture(LanguageProjectToolRequest(
            operationID: "cargo-metadata",
            executablePath: "/fixture/cargo",
            arguments: ["metadata", "--no-deps"],
            workingDirectory: "/fixture/ws",
            environment: [:]
        ))
        #expect(capture.status == .succeeded)

        try await runtime.setEnabled(false, for: .languageExecutionExtension("rust"))
        #expect(!session.isRunning)
        #expect(try runtime.snapshot(for: .languageExecutionExtension("rust")).activity.activeResourceCount == 0)
        #expect(try runtime.snapshot(for: .languageExecutionExtension("rust")).activity.activeLeaseCount == 0)
        let retiredCapture = await tools.makeProjectToolSession().capture(LanguageProjectToolRequest(
            operationID: "cargo-after-disable",
            executablePath: "/fixture/cargo",
            arguments: ["metadata"],
            workingDirectory: "/fixture/ws",
            environment: [:]
        ))
        #expect(retiredCapture.status == .unavailable)

        await runtime.shutdownAll()
    }
}

@MainActor
private final class RustTestServiceResolver: PluginHostServiceResolving {
    let execution = RustTestExecutionHost()
    let projectTools = RustTestProjectToolHost()
    func service(_ id: PluginHostServiceID) -> AnyObject? {
        if id == .languageExecution { return execution }
        if id == .languageProjectTools { return projectTools }
        return nil
    }
}

@MainActor
private final class RustTestExecutionHost: LanguageExecutionHostProviding {
    func makeSession(ownerModuleID _: ModuleID) -> any LanguageExecutionSession {
        RustTestExecutionSession()
    }
}

@MainActor
private final class RustTestExecutionSession: LanguageExecutionSession {
    var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?
    func start(_ request: LanguageExecutionProcessRequest) throws { isRunning = true }
    func stop() { isRunning = false }
    func stopAndWait() async -> Bool { stop(); return true }
}

@MainActor
private final class RustTestProjectToolHost: LanguageProjectToolHostProviding {
    func makeProjectToolSession(ownerModuleID _: ModuleID) -> any LanguageProjectToolSession {
        RustTestProjectToolSession()
    }
}

@MainActor
private final class RustTestProjectToolSession: LanguageProjectToolSession {
    var state: LanguageProjectToolState = .idle
    var onStateChange: (@MainActor @Sendable (LanguageProjectToolState) -> Void)?
    func capture(_ request: LanguageProjectToolRequest) async -> LanguageProjectToolResult {
        state = .finished
        onStateChange?(state)
        return LanguageProjectToolResult(
            operationID: request.operationID,
            status: .succeeded,
            stdout: Data("{}".utf8),
            exitCode: 0,
            stdoutReachedEOF: true,
            stderrReachedEOF: true,
            cleanupConfirmed: true
        )
    }
    func stopAndWait() async -> Bool { state = .finished; return true }
}

@MainActor
private final class RustTestWorkspaceModule: LitheModule {
    let manifest: ModuleManifest
    init(manifest: ModuleManifest) { self.manifest = manifest }
    func activate(context _: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [.workspaceFoundation: self] }
}
