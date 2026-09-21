import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
import LitheTerminalModule
import Testing
@testable import Lithe

@Suite("Terminal activation context", .serialized)
@MainActor
struct TerminalActivationTests {
    @Test
    func displaySettingsUseLatestValueAndOneOwnedSubscription() async throws {
        try await withFixture { fixture in
            fixture.settings.terminalDisplayConfiguration.fontSize = 14
            #expect(!fixture.module.entered.isOpen)
            #expect(fixture.module.transports.isEmpty)
            fixture.model.toggleTerminal()
            try #require(await fixture.module.entered.waitUntilOpen())
            fixture.settings.terminalDisplayConfiguration.fontSize = 17
            fixture.module.release.open()
            try #require(await fixture.awaitTerminalBinding())
            let transport = try #require(fixture.module.transports.first)
            #expect(transport.displayConfigurations.last?.fontSize == 17)
            let initialCount = transport.displayConfigurations.count
            #expect(await fixture.model.activateTerminalModule())
            fixture.settings.terminalDisplayConfiguration.fontSize = 19
            #expect(transport.displayConfigurations.count == initialCount + 1)
            #expect(transport.displayConfigurations.last?.fontSize == 19)
            fixture.model.clearModuleBindings(for: .terminal)
            fixture.settings.terminalDisplayConfiguration.fontSize = 21
            #expect(transport.displayConfigurations.count == initialCount + 1)
            #expect(await fixture.model.activateTerminalModule())
            #expect(transport.displayConfigurations.count == initialCount + 2)
            #expect(transport.displayConfigurations.last?.fontSize == 21)
            #expect(transport.launches.count == 1)
            #expect(transport.isRunning)
        }
    }

    @Test
    func firstToggleKeepsTheConfigurationCapturedBeforeActivation() async throws {
        try await withFixture { fixture in
            var original = TerminalShellConfiguration()
            original.shell = .bash
            original.loginShell = false
            original.arguments = ["--norc", "original argument"]
            original.environment = [.init(name: "CAPTURED", value: "original value")]
            fixture.settings.terminalConfiguration = original

            // The production toggle owns the first asynchronous module activation.
            // Settings change only after that activation reaches its explicit gate.
            fixture.model.toggleTerminal()
            try #require(await fixture.module.entered.waitUntilOpen(), "Terminal activation never started")
            #expect(fixture.module.transports.isEmpty)
            fixture.settings.terminalConfiguration.shell = .zsh
            fixture.settings.terminalConfiguration.arguments = ["changed argument"]
            fixture.settings.terminalConfiguration.environment = [.init(name: "CAPTURED", value: "changed value")]
            fixture.module.release.open()

            try #require(await fixture.awaitTerminalBinding(), "The original activation did not finish")
            let transport = try #require(fixture.module.transports.first)
            let launch = try #require(transport.launches.first)
            #expect(fixture.module.transports.count == 1)
            #expect(launch.process.executablePath == "/bin/bash")
            #expect(launch.process.arguments == original.arguments)
            #expect(launch.process.workingDirectory == fixture.root.standardizedFileURL.path)
            #expect(launch.environment["CAPTURED"] == "original value")
            #expect(fixture.model.terminalSessions.count == 1)
        }
    }

    @Test(arguments: [false, true])
    func staleActivationCannotLaunchAfterProjectSwitchOrSamePathReopen(reopenSamePath: Bool) async throws {
        try await withFixture { fixture in
            let originalIdentity = try #require(fixture.model.currentWorkspaceIdentity)
            #expect(fixture.model.createTerminalSession() == nil)
            try #require(await fixture.module.entered.waitUntilOpen(), "Terminal activation never started")

            fixture.model.closeProject()
            let nextRoot = reopenSamePath ? fixture.root : fixture.otherRoot
            fixture.model.openProjectDirectly(nextRoot)
            await fixture.model.awaitModuleRuntimeShutdown()
            let currentIdentity = try #require(fixture.model.currentWorkspaceIdentity)
            #expect(currentIdentity != originalIdentity)
            if reopenSamePath {
                #expect(currentIdentity.url == originalIdentity.url)
                #expect(currentIdentity.generation != originalIdentity.generation)
            }

            fixture.module.release.open()
            // Capability binding occurs after the gate and before the caller's
            // synchronous identity guard. Observing the following publication
            // therefore proves that the stale request has reached that guard.
            try #require(await fixture.awaitTerminalBinding(), "The stale activation did not finish")
            #expect(fixture.module.transports.isEmpty)
            #expect(fixture.model.terminalSessions.isEmpty)
            #expect(fixture.model.workspaceURL == nextRoot.standardizedFileURL)
            #expect(!fixture.model.isTerminalVisible)
        }
    }

    @Test
    func unreadableSettingsPreventActivationAndKeepTheirStoredPayload() async throws {
        let payload = Data("{\"version\":99,\"configuration\":{}}".utf8)
        try await withFixture(storedPayload: payload) { fixture in
            #expect(fixture.settings.terminalConfigurationLoadError != nil)
            #expect(fixture.model.createTerminalSession() == nil)
            #expect(!fixture.module.entered.isOpen)
            #expect(fixture.module.transports.isEmpty)
            #expect(fixture.model.terminalSessions.isEmpty)
            #expect(fixture.model.isSettingsPresented)
            #expect(fixture.model.requestedSettingsCategory == .terminal)
            #expect(fixture.store.data(forKey: "settings.terminalConfiguration") == payload)
            let snapshot = try fixture.runtime.snapshot(for: .terminal)
            #expect(snapshot.state == .inactive)
        }
    }

    private func withFixture(
        storedPayload: Data? = nil,
        _ operation: @MainActor (TerminalActivationFixture) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-activation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let otherRoot = root.appendingPathComponent("other-project")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let fixture = try TerminalActivationFixture(root: root, otherRoot: otherRoot, storedPayload: storedPayload)
        fixture.model.openProjectDirectly(root)
        await fixture.model.awaitModuleRuntimeShutdown()
        do { try await operation(fixture) }
        catch { await fixture.cleanUp(); throw error }
        await fixture.cleanUp()
    }
}

@MainActor
private final class TerminalActivationFixture {
    let root: URL
    let otherRoot: URL
    let store: TerminalConfigurationTestStore
    let settings: AppSettings
    let runtime: ModuleRuntime
    let module: GatedTerminalActivationModule
    let model: AppModel
    private let backingContainer: MacServiceContainer

    init(root: URL, otherRoot: URL, storedPayload: Data?) throws {
        self.root = root
        self.otherRoot = otherRoot
        let store = TerminalConfigurationTestStore()
        self.store = store
        if let storedPayload { store.set(storedPayload, forKey: "settings.terminalConfiguration") }
        let settings = AppSettings(store: store)
        self.settings = settings
        let module = GatedTerminalActivationModule()
        self.module = module
        let runtime = ModuleRuntime()
        self.runtime = runtime
        try runtime.register(ModuleFactory(manifest: module.manifest) { module })
        let backingContainer = MacServiceContainer(
            store: store, settings: settings,
            workspaceOperations: TerminalActivationWorkspaceOperations()
        )
        // Reuse native service composition without starting a real terminal,
        // idle timer, workspace watcher, language server, or run configuration.
        self.backingContainer = backingContainer
        backingContainer.moduleLifecycleCoordinator.stop()
        model = AppModel(settings: settings, services: Self.services(
            copying: backingContainer.services, moduleRuntime: runtime
        ))
    }

    func awaitTerminalBinding() async -> Bool {
        await awaitChange(on: model, timeout: .seconds(2)) { [model] in model.terminalFeature != nil }
    }

    func cleanUp() async {
        module.release.open()
        if module.entered.isOpen {
            #expect(await module.finished.waitUntilOpen(), "Activation did not leave its gate during cleanup")
            if !module.didTimeOut {
                #expect(await awaitTerminalBinding(), "AppModel did not consume the completed activation")
            }
        }
        model.clearNotifications()
        model.isSettingsPresented = false
        model.closeProject()
        await model.shutdownProjectSession()
        backingContainer.moduleLifecycleCoordinator.stop()
        await backingContainer.services.moduleRuntime.shutdownAll()
        #expect(module.transports.allSatisfy { !$0.isRunning })
    }

    private static func services(copying base: AppServices, moduleRuntime: ModuleRuntime) -> AppServices {
        AppServices(
            moduleRuntime: moduleRuntime,
            pluginManager: base.pluginManager,
            pluginCatalog: base.pluginCatalog,
            languageProviderCatalogSource: base.languageProviderCatalogSource,
            workspaceLanguageServerPreferences: base.workspaceLanguageServerPreferences,
            languageProviderCatalogSnapshot: base.languageProviderCatalogSnapshot,
            debugLaunchConfigurationResolver: base.debugLaunchConfigurationResolver,
            debugPortAvailabilityChecker: base.debugPortAvailabilityChecker,
            javaTestResultServerFactory: { MacJavaTestResultServer() },
            debugBreakpointPersistence: nil,
            workspaceOperations: base.workspaceOperations,
            documentLifecycleDecider: base.documentLifecycleDecider,
            lineEditing: base.lineEditing,
            javaOperations: base.javaOperations,
            markdownRenderer: base.markdownRenderer,
            markdownImageImporter: base.markdownImageImporter,
            store: base.store,
            fileStorage: base.fileStorage,
            fileOperations: base.fileOperations,
            binaryFileViewerRegistry: base.binaryFileViewerRegistry,
            projectRuntimeService: base.projectRuntimeService,
            gitWatchContextProvider: base.gitWatchContextProvider,
            githubService: base.githubService,
            secureStore: base.secureStore,
            databaseSecureStore: base.databaseSecureStore,
            credentialResolver: base.credentialResolver,
            aiConfigurationSources: [],
            recentProjectsStore: base.recentProjectsStore,
            workspaceSessionStore: base.workspaceSessionStore,
            directoryMarkStore: base.directoryMarkStore,
            workbenchLayoutStore: base.workbenchLayoutStore,
            workbenchBackgroundPlatform: base.workbenchBackgroundPlatform,
            directoryWatcherFactory: base.directoryWatcherFactory,
            platformUI: base.platformUI,
            shortcutDetectorFactory: base.shortcutDetectorFactory,
            commandProjectionScheduler: base.commandProjectionScheduler
        )
    }
}

@MainActor
private final class GatedTerminalActivationModule: LitheModule {
    let manifest = ModuleManifest(id: .terminal, displayName: "Terminal activation fixture", scope: .workspace,
                                  providedCapabilities: [.terminalWorkspace])
    let entered = TestGate()
    let release = TestGate()
    let finished = TestGate()
    private(set) var didTimeOut = false
    private let factory = TerminalActivationTransportFactory()
    private var capability: TerminalModuleCapability?
    var transports: [ConfigurationTestTransport] { factory.transports }

    func activate(context: ModuleContext) async throws {
        entered.open()
        defer { finished.open() }
        guard await release.waitUntilOpen() else {
            didTimeOut = true
            throw TerminalActivationFixtureError.activationTimedOut
        }
        let factory = self.factory
        capability = TerminalModuleCapability(feature: TerminalFeatureModel(terminalFactory: { factory.make() }))
    }

    func prepareForSleep() async throws {}
    func sleep() async { releaseFeature() }
    func shutdown() async { releaseFeature() }
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        capability.map { [.terminalWorkspace: $0] } ?? [:]
    }
    private func releaseFeature() {
        capability?.feature.stopAllSessions()
        capability = nil
    }
}

@MainActor
private final class TerminalActivationTransportFactory {
    private(set) var transports: [ConfigurationTestTransport] = []
    func make() -> any TerminalTransport {
        let transport = ConfigurationTestTransport()
        transports.append(transport)
        return transport
    }
}

private enum TerminalActivationFixtureError: Error { case activationTimedOut }

/// No inventory is needed to test the captured terminal context. Returning no
/// snapshot prevents unrelated filesystem watchers and project-service loads.
private struct TerminalActivationWorkspaceOperations: WorkspaceOperations {
    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? { nil }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}
