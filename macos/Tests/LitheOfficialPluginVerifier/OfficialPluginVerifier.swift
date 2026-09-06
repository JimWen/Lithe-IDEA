import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheLanguageExtensionSupport
import LitheModuleAPI

@main
@MainActor
struct OfficialPluginVerifier {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let legacy: Bool
        let packagePath: String
        switch arguments {
        case let values where values.count == 1:
            legacy = false
            packagePath = values[0]
        case let values where values.count == 2 && values[0] == "--legacy-go-0.3.0":
            legacy = true
            packagePath = values[1]
        default: throw VerificationError.usage
        }
        // All hosts below are in-memory fixtures. No child process needs to be
        // killed if a broken plugin lifecycle exceeds this local deadline.
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + .seconds(10))
        watchdog.setEventHandler {
            FileHandle.standardError.write(Data("Official plugin verification exceeded 10 seconds.\n".utf8))
            exit(1)
        }
        watchdog.resume()
        defer { watchdog.cancel() }

        let started = ContinuousClock.now
        let packageURL = URL(fileURLWithPath: packagePath, isDirectory: true)
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(contentsOf: packageURL.appendingPathComponent("plugin.json"))
        )
        let accepted = legacy
            ? manifest == (try legacyGoManifest())
            : OfficialPluginCatalog.manifests.contains(manifest)
        guard accepted else {
            throw VerificationError.manifestMismatch
        }

        // As in the production startup loader, compatibility is checked before
        // Bundle loads code or resolves symbols from the newer SDK.
        _ = try ValidatedPluginCatalog(
            manifests: BuiltInPluginCatalog.manifests + [manifest],
            hostVersion: BuiltInPluginCatalog.hostVersion
        )
        if !legacy { try verifyOldHostRejects(manifest) }

        guard let bundlePath = manifest.entrypoint.bundlePath,
              let bundle = Bundle(
                  url: packageURL.appendingPathComponent(bundlePath, isDirectory: true)
              ) else {
            throw VerificationError.invalidBundle
        }
        try bundle.loadAndReturnError()
        guard let principalClass: AnyClass = bundle.principalClass,
              let entrypointType = principalClass as? LithePluginEntrypoint.Type else {
            throw VerificationError.invalidEntrypoint
        }

        let emptyFactories = try entrypointType.init().moduleFactories(context: .empty)
        try verifyFactories(emptyFactories, match: manifest)
        let services = VerificationHostServices()
        let factories = try entrypointType.init().moduleFactories(context: PluginHostContext(resolver: services))
        try verifyFactories(factories, match: manifest)
        guard services.execution.sessions.isEmpty, services.projectTools.sessions.isEmpty else {
            throw VerificationError.behavior("Constructing lazy factories started a session")
        }

        let runtime = ModuleRuntime()
        for declaration in BuiltInPluginCatalog.manifests.flatMap(\.modules) {
            try runtime.register(ModuleFactory(
                manifest: declaration.manifest,
                contributions: declaration.contributions
            ) {
                guard declaration.manifest.id == .workspace else {
                    throw VerificationError.factoryMustNotBeInvoked
                }
                return VerificationWorkspaceModule(manifest: declaration.manifest)
            })
        }
        for factory in factories { try runtime.register(factory) }
        try runtime.validateGraph()
        do {
            try await exerciseGo(runtime: runtime, services: services, legacy: legacy)
        } catch {
            await runtime.shutdownAll()
            throw error
        }
        await runtime.shutdownAll()
        for declaration in manifest.modules {
            let activity = try runtime.snapshot(for: declaration.manifest.id).activity
            guard activity.activeLeaseCount == 0, activity.activeResourceCount == 0 else {
                throw VerificationError.behavior("Plugin retained resources after shutdown")
            }
        }
        print("Verified \(legacy ? "legacy 0.3.0" : "current") \(manifest.id): native Bundle, Run/LSP\(legacy ? "" : "/capture"), shutdown (\(started.duration(to: .now)))")
    }

    private static func verifyFactories(_ factories: [ModuleFactory], match manifest: PluginManifest) throws {
        guard factories.count == manifest.modules.count,
              zip(factories, manifest.modules).allSatisfy({ pair in
                  pair.0.manifest == pair.1.manifest
                      && pair.0.contributions == pair.1.contributions
              }) else {
            throw VerificationError.factoryMismatch
        }
    }

    private static func legacyGoManifest() throws -> PluginManifest {
        // Explicit QA mode accepts only the released Go package's full static
        // declaration. Production loading retains its strict catalog equality.
        let executionID = ModuleID.languageExecutionExtension("go")
        let lspID = ModuleID.languageServerExtension("go")
        guard let current = OfficialPluginCatalog.manifest(forModule: executionID),
              let execution = OfficialPluginCatalog.moduleManifest(for: executionID),
              let lsp = OfficialPluginCatalog.moduleManifest(for: lspID) else {
            throw VerificationError.manifestMismatch
        }
        return PluginManifest(
            schemaVersion: 1, id: current.id, displayName: current.displayName,
            version: PluginVersion(major: 0, minor: 3, patch: 0), apiVersion: 1,
            hostCompatibility: PluginHostCompatibility(
                minimum: PluginVersion(major: 0, minor: 3, patch: 0),
                maximumExclusive: PluginVersion(major: 0, minor: 4, patch: 0)
            ),
            vendor: current.vendor, entrypoint: current.entrypoint,
            modules: [PluginModuleDeclaration(manifest: execution), PluginModuleDeclaration(manifest: lsp)],
            languageSupports: current.languageSupports ?? []
        )
    }

    private static func verifyOldHostRejects(_ manifest: PluginManifest) throws {
        let oldHost = PluginVersion(major: 0, minor: 3, patch: 0)
        do {
            _ = try ValidatedPluginCatalog(manifests: [manifest], hostVersion: oldHost)
        } catch PluginCatalogError.incompatibleHost(let pluginID, let hostVersion) {
            guard pluginID == manifest.id, hostVersion == oldHost else {
                throw VerificationError.manifestMismatch
            }
            return
        }
        throw VerificationError.behavior("The current package was accepted by host 0.3.0")
    }

    @MainActor
    private static func exerciseGo(
        runtime: ModuleRuntime, services: VerificationHostServices, legacy: Bool
    ) async throws {
        let executionID = ModuleID.languageExecutionExtension("go")
        let lspID = ModuleID.languageServerExtension("go")
        try await runtime.setEnabled(true, for: executionID)
        try await runtime.setEnabled(true, for: lspID)
        guard let execution = try await runtime.activateCapability(.languageExecutionExtension("go"))
            as? any LanguageRunExtensionProviding,
              let lsp = try await runtime.activateCapability(.languageServerExtension("go"))
            as? any LanguageServerExtensionProviding else {
            throw VerificationError.behavior("Run or LSP capability is unavailable")
        }
        let plan = try execution.launchPlan(for: LanguageRunExtensionRequest(
            relativeFilePath: "cmd/example/main.go", arguments: ["--fixture"],
            environment: ["FIXTURE": "run"]
        ))
        guard plan.executable == .toolchain("project-go"),
              plan.arguments == ["run", "cmd/example/main.go", "--fixture"],
              plan.environment == ["FIXTURE": "run"] else {
            throw VerificationError.behavior("Run plan changed across the native Bundle boundary")
        }
        let runSession = execution.makeExecutionSession()
        try runSession.start(LanguageExecutionProcessRequest(
            operationID: "bundle-run", executablePath: "/fixture/go", arguments: plan.arguments
        ))
        guard runSession.isRunning, services.execution.owners == [executionID],
              await runSession.stopAndWait(), !runSession.isRunning else {
            throw VerificationError.behavior("Run session could not start and stop through the host")
        }
        guard lsp.configuration.languageID == "go", lsp.configuration.executableNames == ["gopls"] else {
            throw VerificationError.behavior("LSP configuration changed across the native Bundle boundary")
        }
        let lspState = VerificationLSPState()
        lsp.lifecycle.attach(isRunning: { lspState.isRunning }, stop: {
            lspState.isRunning = false
            lspState.stopCalls += 1
        })
        try await runtime.setEnabled(false, for: lspID)
        guard !lspState.isRunning, lspState.stopCalls > 0 else {
            throw VerificationError.behavior("Disabling LSP did not stop its owned lifecycle")
        }

        if legacy {
            guard runtime.capability(.languageProjectTools("go")) == nil else {
                throw VerificationError.behavior("The legacy bundle unexpectedly exported project tools")
            }
            try await runtime.setEnabled(false, for: executionID)
            return
        }
        guard let tools = try await runtime.activateCapability(.languageProjectTools("go"))
            as? any LanguageProjectToolsProviding, tools.languageID == "go" else {
            throw VerificationError.behavior("The new capture capability is unavailable")
        }
        // This reference and the actual capture call exercise host-linked Support
        // symbols that the separately compiled plugin resolves dynamically.
        let resourceKind = LanguageProjectToolResource.resourceKind
        guard !resourceKind.isEmpty else { throw VerificationError.manifestMismatch }
        let idleSession = tools.makeProjectToolSession()
        let request = LanguageProjectToolRequest(
            operationID: "bundle-capture", executablePath: "/fixture/go",
            arguments: ["list", "-json"], workingDirectory: "/fixture/workspace",
            environment: ["FIXTURE": "capture"]
        )
        let result = await tools.makeProjectToolSession().capture(request)
        guard result.operationID == request.operationID, result.status == .succeeded,
              result.stdout == VerificationProjectToolSession.output,
              result.stderr == VerificationProjectToolSession.diagnostics,
              result.stdoutReachedEOF, result.stderrReachedEOF, result.cleanupConfirmed,
              services.projectTools.owners == [executionID],
              services.projectTools.sessions.first?.request?.environment == request.environment else {
            throw VerificationError.behavior("Capture result or host ownership changed across the native Bundle boundary")
        }
        try await runtime.setEnabled(false, for: executionID)
        let oldIdle = await idleSession.capture(request)
        let oldCapability = await tools.makeProjectToolSession().capture(request)
        guard oldIdle.status == .unavailable, oldCapability.status == .unavailable,
              services.projectTools.sessions.count == 1 else {
            throw VerificationError.behavior("A retired plugin reference started capture")
        }
    }
}

private enum VerificationError: Error {
    case usage
    case manifestMismatch
    case invalidBundle
    case invalidEntrypoint
    case factoryMismatch
    case factoryMustNotBeInvoked
    case behavior(String)
}

@MainActor
private final class VerificationHostServices: PluginHostServiceResolving {
    let execution = VerificationExecutionHost()
    let projectTools = VerificationProjectToolHost()
    func service(_ id: PluginHostServiceID) -> AnyObject? {
        if id == .languageExecution { return execution }
        if id == .languageProjectTools { return projectTools }
        return nil
    }
}

@MainActor
private final class VerificationExecutionHost: LanguageExecutionHostProviding {
    private(set) var owners: [ModuleID] = []
    private(set) var sessions: [VerificationExecutionSession] = []
    func makeSession(ownerModuleID: ModuleID) -> any LanguageExecutionSession {
        let session = VerificationExecutionSession()
        owners.append(ownerModuleID)
        sessions.append(session)
        return session
    }
}

@MainActor
private final class VerificationExecutionSession: LanguageExecutionSession {
    var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?
    func start(_ request: LanguageExecutionProcessRequest) throws { isRunning = true }
    func stop() { isRunning = false }
    func stopAndWait() async -> Bool { stop(); return true }
}

@MainActor
private final class VerificationProjectToolHost: LanguageProjectToolHostProviding {
    private(set) var owners: [ModuleID] = []
    private(set) var sessions: [VerificationProjectToolSession] = []
    func makeProjectToolSession(ownerModuleID: ModuleID) -> any LanguageProjectToolSession {
        let session = VerificationProjectToolSession()
        owners.append(ownerModuleID)
        sessions.append(session)
        return session
    }
}

@MainActor
private final class VerificationProjectToolSession: LanguageProjectToolSession {
    static let output = Data("{\"fixture\":\"Go λ\"}".utf8)
    static let diagnostics = Data("fixture diagnostic\n".utf8)
    var state: LanguageProjectToolState = .idle
    var onStateChange: (@MainActor @Sendable (LanguageProjectToolState) -> Void)?
    private(set) var request: LanguageProjectToolRequest?

    func capture(_ request: LanguageProjectToolRequest) async -> LanguageProjectToolResult {
        self.request = request
        for next in [LanguageProjectToolState.starting, .running, .draining, .finished] {
            state = next
            onStateChange?(next)
        }
        return LanguageProjectToolResult(
            operationID: request.operationID, status: .succeeded,
            stdout: Self.output, stderr: Self.diagnostics, exitCode: 0,
            stdoutReachedEOF: true, stderrReachedEOF: true, cleanupConfirmed: true
        )
    }

    func stopAndWait() async -> Bool {
        state = .finished
        onStateChange?(state)
        return true
    }
}

@MainActor
private final class VerificationLSPState {
    var isRunning = true
    var stopCalls = 0
}

@MainActor
private final class VerificationWorkspaceModule: LitheModule {
    let manifest: ModuleManifest
    init(manifest: ModuleManifest) { self.manifest = manifest }
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [.workspaceFoundation: self] }
}
