import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheGoSupportModule
import LitheLanguageExtensionSupport
import LitheModuleAPI
import Testing

@MainActor
struct GoProjectToolsTests {
    private let moduleID = ModuleID.languageExecutionExtension("go")

    @Test
    func installedV1ManifestRemainsFrozenWhileCurrentPackageAddsCapture() throws {
        let legacy = ModuleManifest(
            id: moduleID, displayName: "Go Execution", scope: .workspace,
            defaultState: .disabled, activationPolicy: .onDemand,
            sleepPolicy: .whenIdle(afterSeconds: 600), dependencies: [.module(.workspace)],
            providedCapabilities: [.languageExecutionExtension("go"), .languageTestingExtension("go")]
        )
        #expect(OfficialPluginCatalog.moduleManifest(for: moduleID) == legacy)
        #expect(OfficialPluginCatalog.moduleManifest(for: .languageServerExtension("go"))?.defaultState == .disabled)
        #expect(GoExecutionModule.moduleManifest.defaultState == .enabled)
        #expect(GoLanguageServerModule.moduleManifest.defaultState == .enabled)
        #expect(GoExecutionModule.moduleManifest.providedCapabilities == legacy.providedCapabilities.union([
            .languageProjectTools("go")
        ]))
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            PluginManifest.self, from: Data(contentsOf: packageURL.appendingPathComponent("plugin.json"))
        )
        #expect(OfficialPluginCatalog.manifests.contains(manifest))
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.apiVersion == 1)
        #expect(manifest.version == PluginVersion(major: 0, minor: 3, patch: 1))
        #expect(manifest.hostCompatibility.minimum == PluginVersion(major: 0, minor: 3, patch: 1))
        #expect(!manifest.hostCompatibility.contains(PluginVersion(major: 0, minor: 3, patch: 0)))
        #expect(manifest.hostCompatibility.contains(BuiltInPluginCatalog.hostVersion))
    }

    @Test
    func emptyHostContextCreatesLazyFactoriesWithoutStartingCapture() throws {
        let factories = try GoSupportPluginEntrypoint().moduleFactories(context: .empty)
        let manifest = try #require(OfficialPluginCatalog.manifest(forModule: moduleID))
        #expect(factories.map(\.manifest) == manifest.modules.map(\.manifest))
    }

    @Test
    func newPluginRequiresCaptureHostOnlyWhenExecutionActivates() async throws {
        let runtime = try makeRuntime(host: nil)
        do {
            try await runtime.setEnabled(true, for: moduleID)
            await #expect(throws: LanguageProjectToolHostError.self) {
                _ = try await runtime.activateCapability(.languageExecutionExtension("go"))
            }
            #expect(try runtime.snapshot(for: moduleID).activity.activeResourceCount == 0)
        } catch {
            await runtime.shutdownAll()
            throw error
        }
        await runtime.shutdownAll()
    }

    @Test
    func captureUsesInjectedHostAndIdleReferencesCannotStartAfterDisable() async throws {
        let host = GoProjectToolTestHost()
        let runtime = try makeRuntime(host: host)
        do {
            try await runtime.setEnabled(true, for: moduleID)
            let capability = try #require(
                try await runtime.activateCapability(.languageProjectTools("go"))
                    as? any LanguageProjectToolsProviding
            )
            #expect(capability.languageID == "go")
            #expect(host.sessions.isEmpty)
            let idleSession = capability.makeProjectToolSession()
            let result = await capability.makeProjectToolSession().capture(Self.request)
            #expect(result.status == .succeeded)
            #expect(result.stdout == Data("{\"fixture\":true}".utf8))
            #expect(result.cleanupConfirmed)
            #expect(host.ownerModuleIDs == [moduleID])
            #expect(host.sessions.first?.requests.first?.environment == ["FIXTURE": "complete-environment"])
            #expect(try runtime.snapshot(for: moduleID).activity.activeLeaseCount == 0)

            try await runtime.setEnabled(false, for: moduleID)
            let oldIdle = await idleSession.capture(Self.request)
            let oldCapability = await capability.makeProjectToolSession().capture(Self.request)
            #expect(oldIdle.status == .unavailable)
            #expect(oldCapability.status == .unavailable)
            #expect(host.sessions.count == 1)
            #expect(try runtime.snapshot(for: moduleID).activity.activeResourceCount == 0)
        } catch {
            await runtime.shutdownAll()
            throw error
        }
        await runtime.shutdownAll()
    }

    @Test
    func reactivatingSleepBlockedInstanceRetiresItsIdleCaptureReferences() async throws {
        let host = GoProjectToolTestHost()
        let runtime = try makeRuntime(host: host)
        do {
            try await runtime.setEnabled(true, for: moduleID)
            let oldTools = try #require(
                try await runtime.activateCapability(.languageProjectTools("go"))
                    as? any LanguageProjectToolsProviding
            )
            let oldSession = oldTools.makeProjectToolSession()
            let run = try #require(
                runtime.capability(.languageExecutionExtension("go")) as? any LanguageRunExtensionProviding
            ).makeExecutionSession()
            try run.start(LanguageExecutionProcessRequest(
                operationID: "sleep-blocker", executablePath: "/fixture/go"
            ))
            await #expect(throws: ModuleRuntimeError.activeLeasesPreventSleep(
                module: moduleID, reasons: ["Language execution sleep-blocker"]
            )) {
                try await runtime.sleep(moduleID)
            }

            _ = try await runtime.activate(moduleID)
            let oldIdle = await oldSession.capture(Self.request)
            let oldCapability = await oldTools.makeProjectToolSession().capture(Self.request)
            #expect(oldIdle.status == .unavailable)
            #expect(oldCapability.status == .unavailable)
            #expect(host.sessions.isEmpty)
            let fresh = try #require(
                runtime.capability(.languageProjectTools("go")) as? any LanguageProjectToolsProviding
            )
            let result = await fresh.makeProjectToolSession().capture(Self.request)
            #expect(result.status == .succeeded)
            #expect(host.sessions.count == 1)
        } catch {
            await runtime.shutdownAll()
            throw error
        }
        await runtime.shutdownAll()
        #expect(try runtime.snapshot(for: moduleID).activity.activeLeaseCount == 0)
    }

    @Test
    func failedCleanupBlocksBothReusedAndRecreatedModuleActivations() async throws {
        let host = GoProjectToolTestHost()
        host.captureCleanupConfirmed = false
        host.stopSucceeds = false
        let runtime = try makeRuntime(host: host)
        do {
            try await runtime.setEnabled(true, for: moduleID)
            let capability = try #require(
                try await runtime.activateCapability(.languageProjectTools("go"))
                    as? any LanguageProjectToolsProviding
            )
            let result = await capability.makeProjectToolSession().capture(Self.request)
            #expect(result.status == .cleanupFailed)
            #expect(try runtime.snapshot(for: moduleID).activity.activeLeaseCount == 1)
            let expectedError = ModuleRuntimeError.activeResourcesRemain(
                module: moduleID, kinds: [LanguageProjectToolResource.resourceKind]
            )
            await #expect(throws: expectedError) {
                try await runtime.setEnabled(false, for: moduleID)
            }
            // The first attempt reuses the failed instance. Its failure then
            // discards that instance while leaving the scope's owner retained.
            for _ in 0..<2 {
                await #expect(throws: expectedError) {
                    _ = try await runtime.activate(moduleID)
                }
                #expect(try runtime.snapshot(for: moduleID).activity.activeResourceCount == 1)
            }
            let stale = await capability.makeProjectToolSession().capture(Self.request)
            #expect(stale.status == .unavailable)
            #expect(host.sessions.count == 1)

            host.stopSucceeds = true
            try await runtime.shutdown(moduleID)
            #expect(try runtime.snapshot(for: moduleID).activity.activeLeaseCount == 0)
            host.captureCleanupConfirmed = true
            let fresh = try #require(
                try await runtime.activateCapability(.languageProjectTools("go"))
                    as? any LanguageProjectToolsProviding
            )
            let freshResult = await fresh.makeProjectToolSession().capture(Self.request)
            #expect(freshResult.status == .succeeded)
            #expect(host.sessions.count == 2)
        } catch {
            host.stopSucceeds = true
            await runtime.shutdownAll()
            throw error
        }
        host.stopSucceeds = true
        await runtime.shutdownAll()
    }

    private func makeRuntime(host: GoProjectToolTestHost?) throws -> ModuleRuntime {
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            GoProjectToolWorkspaceModule(manifest: workspace)
        })
        let resolver = GoProjectToolServiceResolver(host: host)
        for factory in try GoSupportPluginEntrypoint().moduleFactories(context: PluginHostContext(resolver: resolver)) {
            try runtime.register(factory)
        }
        try runtime.validateGraph()
        return runtime
    }

    private static var request: LanguageProjectToolRequest {
        LanguageProjectToolRequest(
            operationID: "go-metadata-fixture", executablePath: "/fixture/go",
            arguments: ["list", "-json"], workingDirectory: "/fixture/workspace",
            environment: ["FIXTURE": "complete-environment"]
        )
    }
}

@MainActor
final class GoProjectToolTestHost: LanguageProjectToolHostProviding {
    var captureCleanupConfirmed = true
    var stopSucceeds = true
    private(set) var sessions: [GoProjectToolTestSession] = []
    private(set) var ownerModuleIDs: [ModuleID] = []

    func makeProjectToolSession(ownerModuleID: ModuleID) -> any LanguageProjectToolSession {
        let session = GoProjectToolTestSession(host: self)
        sessions.append(session)
        ownerModuleIDs.append(ownerModuleID)
        return session
    }
}

@MainActor
final class GoProjectToolTestSession: LanguageProjectToolSession {
    private unowned let host: GoProjectToolTestHost
    private(set) var requests: [LanguageProjectToolRequest] = []
    private(set) var state: LanguageProjectToolState = .idle
    var onStateChange: (@MainActor @Sendable (LanguageProjectToolState) -> Void)?

    init(host: GoProjectToolTestHost) { self.host = host }

    func capture(_ request: LanguageProjectToolRequest) async -> LanguageProjectToolResult {
        requests.append(request)
        state = host.captureCleanupConfirmed ? .finished : .cleanupFailed
        onStateChange?(state)
        return LanguageProjectToolResult(
            operationID: request.operationID,
            status: host.captureCleanupConfirmed ? .succeeded : .cleanupFailed,
            stdout: Data("{\"fixture\":true}".utf8), exitCode: 0,
            stdoutReachedEOF: true, stderrReachedEOF: true,
            cleanupConfirmed: host.captureCleanupConfirmed
        )
    }

    func stopAndWait() async -> Bool {
        if host.stopSucceeds {
            state = .finished
            onStateChange?(state)
        }
        return host.stopSucceeds
    }
}

@MainActor
private final class GoProjectToolServiceResolver: PluginHostServiceResolving {
    private let host: GoProjectToolTestHost?
    private let executionHost = GoProjectToolExecutionHost()

    init(host: GoProjectToolTestHost?) { self.host = host }

    func service(_ id: PluginHostServiceID) -> AnyObject? {
        if id == .languageProjectTools { return host }
        if id == .languageExecution { return executionHost }
        return nil
    }
}

@MainActor
private final class GoProjectToolExecutionHost: LanguageExecutionHostProviding {
    func makeSession(ownerModuleID: ModuleID) -> any LanguageExecutionSession {
        GoProjectToolExecutionSession()
    }
}

@MainActor
private final class GoProjectToolExecutionSession: LanguageExecutionSession {
    private(set) var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?
    func start(_ request: LanguageExecutionProcessRequest) throws { isRunning = true }
    func stop() { isRunning = false }
    func stopAndWait() async -> Bool { stop(); return true }
}

@MainActor
private final class GoProjectToolWorkspaceModule: LitheModule {
    let manifest: ModuleManifest
    init(manifest: ModuleManifest) { self.manifest = manifest }
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        [.workspaceFoundation: self]
    }
}
