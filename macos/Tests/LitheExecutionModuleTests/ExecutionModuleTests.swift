import Foundation
import LitheApplicationKernel
@testable import LitheExecutionModule
import LitheCoreContracts
import LitheModuleAPI
import Testing

@MainActor
struct ExecutionModuleTests {
    @Test
    func resolvedDefaultTracksTheCurrentProjectAndClearsOnReset() async {
        let configuration = RunConfiguration(
            id: "python:service", name: "Service", kind: .process(provider: "python.script"),
            modulePath: nil, mainClass: nil, debugAdapter: "python", disabled: false
        )
        let service = makeRunService(
            configuration: configuration, options: RunOptions(), fileAccess: TestRunFileAccess()
        )
        defer { service.reset() }
        #expect(service.defaultConfigurationID == nil)
        await service.loadProject(at: URL(fileURLWithPath: "/workspace/default-run"), files: [])
        #expect(service.defaultConfigurationID == configuration.id)
        #expect(service.selectedConfiguration?.id == configuration.id)
        service.reset()
        #expect(service.defaultConfigurationID == nil)
    }

    @Test
    func configuredServerPortUsesExplicitArgumentsAndEnvironmentOnly() async throws {
        let root = URL(fileURLWithPath: "/workspace/service-port", isDirectory: true)
        let properties = root.appendingPathComponent("src/main/resources/application.properties")
        let configuration = RunConfiguration(
            id: "spring:api",
            name: "API",
            kind: .javaMain,
            modulePath: ".",
            mainClass: "example.Application"
        )

        let argumentService = makeRunService(
            configuration: configuration,
            options: RunOptions(
                vmArguments: "-Dserver.port=18081",
                programArguments: "--server.port=18082",
                environment: ["SERVER_PORT": "18083"]
            ),
            fileAccess: TestRunFileAccess(contents: [properties: "server.port=18084"])
        )
        await argumentService.loadProject(at: root, files: [properties])
        #expect(argumentService.configuredServerPort(for: configuration) == 18082)

        let environmentService = makeRunService(
            configuration: configuration,
            options: RunOptions(environment: ["SERVER_PORT": "18083"]),
            fileAccess: TestRunFileAccess(contents: [properties: "server.port=18084"])
        )
        await environmentService.loadProject(at: root, files: [properties])
        #expect(environmentService.configuredServerPort(for: configuration) == 18083)

        let resourceService = makeRunService(
            configuration: configuration,
            options: RunOptions(),
            fileAccess: TestRunFileAccess(contents: [properties: "server.port=18084"])
        )
        await resourceService.loadProject(at: root, files: [properties])
        #expect(resourceService.configuredServerPort(for: configuration) == nil)

        let defaultService = makeRunService(
            configuration: configuration,
            options: RunOptions(),
            fileAccess: TestRunFileAccess()
        )
        await defaultService.loadProject(at: root, files: [])
        #expect(defaultService.configuredServerPort(for: configuration) == nil)
    }

    @Test
    func disabledExecutionDoesNotConstructGraph() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(factory(recorder: recorder), enabled: false)

        await #expect(throws: ModuleRuntimeError.moduleDisabled(.execution)) {
            _ = try await runtime.activateCapability(.executionWorkspace)
        }
        #expect(recorder.factoryCalls == 0)
        #expect(recorder.graphCalls == 0)
    }

    @Test
    func sleepReleasesExecutionGraphAndWakeCreatesNewServices() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(factory(recorder: recorder))

        let first = try #require(
            try await runtime.activateCapability(.executionWorkspace) as? ExecutionModuleCapability
        )
        let firstRunID = ObjectIdentifier(first.runFeature)
        weak var released = recorder.latestGraph
        try await runtime.sleep(.execution)

        #expect(released == nil)
        #expect(runtime.capability(.executionWorkspace) == nil)
        #expect(try runtime.snapshot(for: .execution).activity.activeResourceCount == 0)

        let second = try #require(
            try await runtime.activateCapability(.executionWorkspace) as? ExecutionModuleCapability
        )
        #expect(ObjectIdentifier(second.runFeature) != firstRunID)
        #expect(recorder.factoryCalls == 2)
        #expect(recorder.graphCalls == 2)
    }

    /// Run and Debug can reach identification before the workspace snapshot has
    /// bound a project. Reporting nothing at all made the confirmed dialog look
    /// like a dead button, so the unloaded project must become visible state.
    @Test
    func identificationBeforeProjectLoadReportsUnloadedProjectWithoutGenerating() async throws {
        let operations = RecordingRunConfigurationOperations()
        let service = RunService(
            runtime: TestRuntime(),
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )

        #expect(service.projectLoadState == .idle)
        await service.generateRunConfigurations()

        #expect(service.generationState == .projectNotReady)
        #expect(operations.generateCallCount == 0)
        #expect(service.configurationStatus == .missing)
    }

    @Test
    func selectingBetweenRunningServicesSynchronizesLogIdentityAndControls() async {
        let first = RunConfiguration(id: "service:a", name: "A", kind: .process(provider: "fixture.service"),
                                     execution: .service, modulePath: nil, mainClass: nil)
        let second = RunConfiguration(id: "service:b", name: "B", kind: .process(provider: "fixture.service"),
                                      execution: .service, modulePath: nil, mainClass: nil)
        let service = RunService(
            runtime: TestRuntime(), process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() }, fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            runConfigurationOperations: SelectionRunConfigurationOperations(configurations: [first, second]),
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        defer { service.reset() }
        await service.loadProject(at: URL(fileURLWithPath: "/workspace"), files: [])
        // Model two already-running sessions: changing selection must not need
        // a process transition or a new output event to update the log target.
        service.startConfiguration(first)
        service.startConfiguration(second)
        let feature = RunFeatureModel(service: service)
        for configuration in [second, first, second] {
            feature.select(configuration)
            #expect(feature.selectedProjectSessionID == configuration.id)
            #expect(feature.selectedSessionID == configuration.id)
            #expect(feature.selectedConfigurationID == configuration.id)
            #expect(feature.isSelectedConfigurationRunning)
            #expect(feature.moduleSessions.first { $0.id == feature.selectedProjectSessionID }?.title == configuration.name)
            #expect(feature.moduleSessions.filter(\.isRunning).count == 2)
        }
        // Selecting a tool task does not rewrite the chosen run configuration.
        let taskID = UUID()
        feature.selectedToolTaskID = taskID
        #expect(feature.selectedConfigurationID == second.id)
        #expect(feature.selectedSessionID == second.id)
        feature.select(.currentFile)
        #expect(feature.selectedToolTaskID == nil)
        #expect(feature.selectedSessionID == nil)
        #expect(feature.selectedProjectSessionID == nil)
        #expect(!feature.isSelectedConfigurationRunning)
        // Current File selection must not stop either independent service.
        #expect(feature.moduleSessions.filter(\.isRunning).count == 2)
    }

    /// Once the project is bound, identification must behave exactly as before.
    @Test
    func identificationAfterProjectLoadGeneratesAndClearsTheUnloadedState() async throws {
        let operations = RecordingRunConfigurationOperations()
        let service = RunService(
            runtime: TestRuntime(),
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)

        await service.generateRunConfigurations()
        #expect(service.generationState == .projectNotReady)

        // Binding without a snapshot only unlocks reading existing configuration.
        await service.loadProject(at: root, files: [])
        #expect(service.projectLoadState == .bound(workspace: root))
        #expect(!service.isProjectReady(for: root, snapshotID: UUID()))
        await service.generateRunConfigurations()
        #expect(service.generationState == .projectNotReady)
        #expect(operations.generateCallCount == 0)

        let snapshotID = UUID()
        await service.loadProject(at: root, files: [], snapshotID: snapshotID)
        #expect(service.projectLoadState == .ready(workspace: root, snapshotID: snapshotID))
        #expect(service.isProjectReady(for: root, snapshotID: snapshotID))
        // A superseded snapshot of the same workspace is not ready.
        #expect(!service.isProjectReady(for: root, snapshotID: UUID()))
        await service.generateRunConfigurations()

        #expect(operations.generateCallCount == 1)
        #expect(service.generationState == .succeeded(entryCount: 1))
        #expect(service.configurationStatus == .ready)
    }

    /// Generation scans the inventory the service holds, so a workspace that was
    /// bound before its snapshot arrived must not be scanned with the provisional
    /// list. Doing so writes a configuration that omits real entry points.
    @Test
    func generationScansTheSnapshotInventoryAndNeverAProvisionalOne() async throws {
        let operations = RecordingRunConfigurationOperations()
        let service = RunService(
            runtime: TestRuntime(),
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let source = root.appendingPathComponent("src/main/java/demo/App.java")

        // The workspace snapshot has not arrived, so the inventory is empty.
        await service.loadProject(at: root, files: [])
        await service.generateRunConfigurations()
        #expect(service.generationState == .projectNotReady)
        #expect(operations.generatedInventories.isEmpty, "a provisional inventory must not be scanned")

        await service.loadProject(
            at: root,
            files: [source],
            snapshotID: UUID()
        )
        await service.generateRunConfigurations()

        #expect(service.generationState == .succeeded(entryCount: 1))
        #expect(
            operations.generatedInventories == [[source]],
            "generation must scan exactly the inventory the snapshot reported"
        )
    }

    /// A broken configuration must stay regenerable. Inventory readiness and
    /// configuration validity are separate concerns, so an unreadable
    /// `generated.json` must not make the project un-ready and lock the user out
    /// of the only action that repairs it.
    @Test
    func unreadableConfigurationStillAllowsRegeneration() async throws {
        let operations = FailingInspectionRunConfigurationOperations()
        let service = RunService(
            runtime: TestRuntime(),
            process: TestStreamingProcess(),
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            runConfigurationOperations: operations,
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback)
        )
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let snapshotID = UUID()

        await service.loadProject(at: root, files: [], snapshotID: snapshotID)

        #expect(service.configurationStatus == .invalid("generated.json is invalid"))
        #expect(service.isProjectReady(for: root, snapshotID: snapshotID))

        await service.generateRunConfigurations()
        #expect(service.generationState != .projectNotReady)
    }

    @Test
    func currentGoFileRunsThroughExtensionOwnedSession() async throws {
        let builtInProcess = TestStreamingProcess()
        let extensionSession = TestLanguageExecutionSession()
        let service = RunService(
            runtime: TestRuntime(),
            process: builtInProcess,
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            runConfigurationOperations: TestReadyRunConfigurationOperations(),
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback),
            extensionRequiredLanguageIDs: ["go"]
        )
        let support = LanguageSupportDeclaration(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            executionModuleID: .languageExecutionExtension("go")
        )
        let extensionProvider = TestGoRunExtension(session: extensionSession)
        #expect(service.registerLanguageRunExtension(
            extensionProvider,
            support: support
        ))

        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let source = root.appendingPathComponent("cmd/server/main.go")
        await service.loadProject(at: root, files: [source])
        service.run(configuration: .currentFile, currentFileURL: source)

        #expect(builtInProcess.startRequests.isEmpty)
        #expect(extensionSession.startRequests.count == 1)
        #expect(extensionSession.startRequests.first?.arguments == ["run", "cmd/server/main.go"])
        #expect(extensionSession.isRunning)

        service.stop()
        #expect(!extensionSession.isRunning)
    }

    @Test
    func detectedGoProjectRunsThroughExtensionOwnedSession() async throws {
        let builtInProcess = TestStreamingProcess()
        let extensionSession = TestLanguageExecutionSession()
        let service = RunService(
            runtime: TestRuntime(),
            process: builtInProcess,
            processFactory: { TestStreamingProcess() },
            fileAccess: TestRunFileAccess(),
            preferences: TestRunPreferences(),
            runConfigurationOperations: TestGoProjectRunConfigurationOperations(),
            executableResolver: TestExecutableResolver(),
            languageProviderCatalog: .compatibilityFallback,
            languageRunProviders: .standard(catalog: .compatibilityFallback),
            extensionRequiredLanguageIDs: ["go"]
        )
        let support = LanguageSupportDeclaration(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            projectFileNames: ["go.mod"],
            executionModuleID: .languageExecutionExtension("go")
        )
        let extensionProvider = TestGoRunExtension(session: extensionSession)
        #expect(service.registerLanguageRunExtension(extensionProvider, support: support))

        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        await service.loadProject(
            at: root,
            files: [root.appendingPathComponent("go.mod")]
        )
        let configuration = try #require(
            service.configurations.first { $0.kind.providerID == "go" }
        )
        service.run(configuration: configuration, currentFileURL: nil)

        #expect(builtInProcess.startRequests.isEmpty)
        #expect(extensionSession.startRequests.count == 1)
        #expect(extensionSession.startRequests.first?.arguments == ["run", "./cmd/api"])
        #expect(extensionSession.isRunning)

        service.stop()
        service.unregisterLanguageRunExtension(languageID: "go")
        service.run(configuration: configuration, currentFileURL: nil)
        #expect(builtInProcess.startRequests.isEmpty)
        #expect(service.output.contains("go execution extension is not active"))
    }

    @Test
    func goTestsRunThroughExtensionOwnedSession() throws {
        let builtInProcess = TestStreamingProcess()
        let extensionSession = TestLanguageExecutionSession()
        let service = LanguageTestService(
            catalog: .compatibilityFallback,
            registry: .standard(catalog: .compatibilityFallback),
            executableResolver: TestExecutableResolver(),
            processFactory: { builtInProcess },
            extensionRequiredLanguageIDs: ["go"]
        )
        let support = LanguageSupportDeclaration(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            projectFileNames: ["go.mod"],
            executionModuleID: .languageExecutionExtension("go"),
            testingModuleID: .languageExecutionExtension("go")
        )
        let extensionProvider = TestGoRunExtension(session: extensionSession)
        #expect(service.registerLanguageTestExtension(extensionProvider, support: support))

        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let files = [
            root.appendingPathComponent("go.mod"),
            root.appendingPathComponent("cmd/api/main_test.go")
        ]
        service.discover(workspaceURL: root, files: files)
        #expect(service.itemsByProviderID["go"]?.map(\.id) == [
            "go:workspace", "go:file:cmd/api/main_test.go"
        ])

        #expect(service.run(
            providerID: "go",
            scope: .file(files[1]),
            workspaceURL: root,
            projectFiles: files
        ))
        #expect(builtInProcess.startRequests.isEmpty)
        #expect(extensionSession.startRequests.first?.arguments == ["test", "./cmd/api"])

        service.unregisterLanguageTestExtension(languageID: "go")
        service.discover(workspaceURL: root, files: files)
        #expect(service.itemsByProviderID["go"] == nil)
        #expect(!service.run(
            providerID: "go",
            scope: .workspace,
            workspaceURL: root,
            projectFiles: files
        ))
        #expect(builtInProcess.startRequests.isEmpty)
        #expect(service.errorMessage == "go testing extension is not active.")
    }




    private func factory(recorder: Recorder) -> ModuleFactory {
        ModuleFactory(manifest: ExecutionModule.moduleManifest, contributions: ExecutionModule.moduleContributions) {
            recorder.factoryCalls += 1
            return ExecutionModule(makeGraph: {
                recorder.graphCalls += 1
                let graph = makeTestGraph()
                recorder.latestGraph = graph
                return graph
            })
        }
    }

    private func workspaceFactory() -> ModuleFactory {
        ModuleFactory(manifest: ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)) {
            EmptyWorkspaceModule()
        }
    }
}

private struct SelectionRunConfigurationOperations: RunConfigurationOperations {
    let configurations: [RunConfiguration]
    func inspect(at _: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(at _: URL, files _: [URL], modulePaths _: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: configurations.count)
    }
    func resolve(at _: URL, toolchainCandidates _: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: ([.currentFile] + configurations).map {
                EffectiveRunConfiguration(configuration: $0, options: RunOptions())
            }, diagnostics: [], defaultConfigurationID: configurations.first?.id
        )
    }
    func launchPlan(at _: URL, configurationID: String, currentFile _: String?, classPath _: String?, debugPort _: Int?) throws -> SharedLaunchPlan {
        SharedLaunchPlan(executable: .command("fixture-service"), arguments: [configurationID], workingDirectory: ".")
    }
    func createConfiguration(_ draft: RunConfigurationDraft, at _: URL) throws -> String { draft.name }
    func migrateLegacySettings(at _: URL, configurationIDs _: [String]) throws {}
}

@MainActor
private func makeRunService(
    configuration: RunConfiguration,
    options: RunOptions,
    fileAccess: TestRunFileAccess
) -> RunService {
    RunService(
        runtime: TestRuntime(),
        process: TestStreamingProcess(),
        processFactory: { TestStreamingProcess() },
        fileAccess: fileAccess,
        preferences: TestRunPreferences(),
        runConfigurationOperations: SingleRunConfigurationOperations(
            configuration: configuration,
            options: options
        ),
        executableResolver: TestExecutableResolver(),
        languageProviderCatalog: .compatibilityFallback,
        languageRunProviders: .standard(catalog: .compatibilityFallback)
    )
}

@MainActor private final class Recorder {
    var factoryCalls = 0
    var graphCalls = 0
    weak var latestGraph: ExecutionFeatureGraph?
}

@MainActor
private func makeTestGraph() -> ExecutionFeatureGraph {
    let runtime = TestRuntime()
    let resolver = TestExecutableResolver()
    let run = RunService(
        runtime: runtime,
        process: TestStreamingProcess(),
        processFactory: { TestStreamingProcess() },
        fileAccess: TestRunFileAccess(),
        preferences: TestRunPreferences(),
        runConfigurationOperations: TestRunConfigurationOperations(),
        executableResolver: resolver,
        languageProviderCatalog: .compatibilityFallback,
        languageRunProviders: .standard(catalog: .compatibilityFallback)
    )
    let tests = LanguageTestService(
        catalog: .compatibilityFallback,
        registry: LanguageTestProviderRegistry(providers: []),
        executableResolver: resolver,
        processFactory: { TestStreamingProcess() }
    )
    return ExecutionFeatureGraph(
        run: run, tests: tests, cargoProject: makeTestCargoProject(), goProject: makeTestGoProject(),
        toolTasks: ProjectToolTaskFeatureModel(activateProvider: { throw CocoaError(.featureUnsupported) },
            makePreparation: { _, _, _ in throw CocoaError(.featureUnsupported) })
    )
}

/// The graph only needs a constructed feature here; no refresh is started, so
/// every port fails loudly rather than pretending a toolchain exists.
@MainActor
private func makeTestGoProject() -> GoProjectFeatureModel {
    GoProjectFeatureModel(
        nativePreparer: TestCargoMetadataPreparer(),
        normalizer: TestProjectMetadataNormalizer(),
        makeInput: { workspaceURL, generation, manifestURL, deadline in
            CargoMetadataPreparationRequest(
                workspaceURL: workspaceURL, manifestURL: manifestURL,
                workspaceGeneration: generation, cargoCandidates: [], rustupCandidates: [],
                customCargoURL: nil, environment: [:], deadline: deadline
            )
        },
        providerModuleID: .languageExecutionExtension("go"),
        activateProvider: { throw ProjectMetadataFailure.invalidInput(message: "No provider in tests.") }
    )
}

/// The graph only needs a constructed feature here; no refresh is started, so
/// every port fails loudly rather than pretending a toolchain exists.
@MainActor
private func makeTestCargoProject() -> CargoProjectFeatureModel {
    CargoProjectFeatureModel(
        nativePreparer: TestCargoMetadataPreparer(),
        normalizer: TestProjectMetadataNormalizer(),
        makeInput: { workspaceURL, generation, manifestURL, deadline in
            CargoMetadataPreparationRequest(
                workspaceURL: workspaceURL, manifestURL: manifestURL,
                workspaceGeneration: generation, cargoCandidates: [], rustupCandidates: [],
                customCargoURL: nil, environment: [:], deadline: deadline
            )
        },
        providerModuleID: .languageExecutionExtension("rust"),
        activateProvider: { throw ProjectMetadataFailure.invalidInput(message: "No provider in tests.") }
    )
}

private struct TestCargoMetadataPreparer: ProjectMetadataNativePreparing {
    func prepare(_ request: CargoMetadataPreparationRequest) throws -> any ProjectMetadataNativeSession {
        throw ProjectMetadataFailure.invalidInput(message: "No Cargo in tests.")
    }
}

private struct TestProjectMetadataNormalizer: ProjectMetadataNormalizing {
    func normalize(
        _ captures: ProjectMetadataCaptures, workspaceDirectory: String,
        roots: [ProjectMetadataRoot], operationID: String, timeoutMilliseconds: Int
    ) throws -> ProjectMetadataNormalization {
        throw ProjectMetadataFailure.invalidInput(message: "No normalizer in tests.")
    }
    func cancel(operationID: String) -> Bool { false }
}

@MainActor
private final class TestRuntime: RunRuntimePort {
    func setActiveServiceJavaHomePath(_ path: String) {}
    func javaHomeURL(overridePath: String?) -> URL? { nil }
    func runConfigurationToolchainCandidates(
        projectRoot: URL?,
        javaHomeOverride: String?
    ) -> [ProjectToolchainCandidate] { [] }
}

private final class TestStreamingProcess: StreamingProcess, @unchecked Sendable {
    var isRunning = false
    private(set) var startRequests: [ProcessRequest] = []
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)?
    func start(_ request: ProcessRequest) throws {
        startRequests.append(request)
        isRunning = true
    }
    func send(_ input: Data) throws {}
    func stop() { isRunning = false }
}







private struct TestRunFileAccess: RunFileAccess {
    let contents: [URL: String]

    init(contents: [URL: String] = [:]) {
        self.contents = contents
    }

    func isDirectory(at url: URL) -> Bool { false }
    func readData(from url: URL) throws -> Data {
        Data((contents[url.standardizedFileURL] ?? "").utf8)
    }
}

@MainActor
private final class TestRunPreferences: RunPreferenceStore {
    func data(forKey key: String) -> Data? { nil }
    func string(forKey key: String) -> String? { nil }
    func setData(_ data: Data, forKey key: String) {}
    func setString(_ value: String, forKey key: String) {}
}



private struct SingleRunConfigurationOperations: RunConfigurationOperations {
    let configuration: RunConfiguration
    let options: RunOptions

    func inspect(at _: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(at _: URL, files _: [URL], modulePaths _: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 1)
    }
    func resolve(at _: URL, toolchainCandidates _: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [EffectiveRunConfiguration(configuration: configuration, options: options)],
            diagnostics: [],
            defaultConfigurationID: configuration.id
        )
    }
    func launchPlan(
        at _: URL,
        configurationID _: String,
        currentFile _: String?,
        classPath _: String?,
        debugPort _: Int?
    ) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "Not required by the port resolution test")
    }
    func migrateLegacySettings(at _: URL, configurationIDs _: [String]) throws {}
}

@MainActor
private final class TestExecutableResolver: RunExecutableResolving {
    func resolve(_ plan: SharedLaunchPlan, projectURL: URL, options: RunOptions) throws -> ResolvedRunExecutable {
        ResolvedRunExecutable(executableURL: URL(fileURLWithPath: "/test"), environment: [:])
    }
    func refreshCandidates(projectURL: URL) async {}
    func candidates(projectURL: URL) -> [ProjectToolchainCandidate] { [] }
}

private struct TestRunConfigurationOperations: RunConfigurationOperations {
    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .missing, diagnostics: [])
    }
    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 0)
    }
    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(configurations: [], diagnostics: [], defaultConfigurationID: nil)
    }
    func launchPlan(at projectURL: URL, configurationID: String, currentFile: String?, classPath: String?, debugPort: Int?) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "Unavailable in lifecycle test")
    }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {}
}

/// Records the file inventory each generation attempt was given, so a test can
/// prove both that a pending workspace never reaches the store and that a ready
/// one is scanned with the complete inventory.
private final class RecordingRunConfigurationOperations: RunConfigurationOperations, @unchecked Sendable {
    private(set) var generatedInventories: [[URL]] = []

    var generateCallCount: Int { generatedInventories.count }

    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(
            status: generatedInventories.isEmpty ? .missing : .ready,
            diagnostics: []
        )
    }
    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        generatedInventories.append(files)
        return RunConfigurationGenerationResult(entryCount: 1)
    }
    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [EffectiveRunConfiguration(
                configuration: .currentFile,
                options: RunOptions()
            )],
            diagnostics: [],
            defaultConfigurationID: RunConfiguration.currentFileID
        )
    }
    func launchPlan(at projectURL: URL, configurationID: String, currentFile: String?, classPath: String?, debugPort: Int?) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "Unavailable in identification test")
    }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {}
}

/// Reports an unreadable configuration so a test can observe the failed state.
private struct FailingInspectionRunConfigurationOperations: RunConfigurationOperations {
    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(
            status: .invalid("generated.json is invalid"),
            diagnostics: [],
            recoveryAction: .editConfiguration
        )
    }
    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 0)
    }
    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(configurations: [], diagnostics: [], defaultConfigurationID: nil)
    }
    func launchPlan(at projectURL: URL, configurationID: String, currentFile: String?, classPath: String?, debugPort: Int?) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "Unavailable in inspection test")
    }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {}
}

private struct TestReadyRunConfigurationOperations: RunConfigurationOperations {
    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 1)
    }
    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [EffectiveRunConfiguration(
                configuration: .currentFile,
                options: RunOptions()
            )],
            diagnostics: [],
            defaultConfigurationID: RunConfiguration.currentFileID
        )
    }
    func launchPlan(at projectURL: URL, configurationID: String, currentFile: String?, classPath: String?, debugPort: Int?) throws -> SharedLaunchPlan {
        throw RunConfigurationOperationFailure(message: "The extension must supply this launch plan")
    }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {}
}

private struct TestGoProjectRunConfigurationOperations: RunConfigurationOperations {
    private let configuration = RunConfiguration(
        id: "go:api",
        name: "Go API",
        kind: .process(provider: "go.main"),
        execution: .application,
        modulePath: "cmd/api",
        mainClass: nil
    )

    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }
    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 1)
    }
    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [EffectiveRunConfiguration(
                configuration: configuration,
                options: RunOptions()
            )],
            diagnostics: [],
            defaultConfigurationID: configuration.id
        )
    }
    func launchPlan(at projectURL: URL, configurationID: String, currentFile: String?, classPath: String?, debugPort: Int?) throws -> SharedLaunchPlan {
        SharedLaunchPlan(
            executable: .toolchain("project-go"),
            arguments: ["run", "./cmd/api"],
            workingDirectory: "."
        )
    }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {}
}

@MainActor
private final class TestGoRunExtension: LanguageRunExtensionProviding, LanguageTestExtensionProviding {
    let languageID = "go"
    private let executionSession: any LanguageExecutionSession

    init(session: any LanguageExecutionSession) {
        executionSession = session
    }

    func makeExecutionSession() -> any LanguageExecutionSession { executionSession }
    func makeTestExecutionSession() -> any LanguageExecutionSession { executionSession }

    func launchPlan(for request: LanguageRunExtensionRequest) throws -> LanguageRunExtensionPlan {
        LanguageRunExtensionPlan(
            executable: .toolchain("project-go"),
            arguments: ["run", request.relativeFilePath] + request.arguments,
            environment: request.environment
        )
    }

    func discoverTests(
        for request: LanguageTestExtensionDiscoveryRequest
    ) throws -> [LanguageTestExtensionItem] {
        [LanguageTestExtensionItem(id: "go:workspace", label: "All Go Tests", kind: .workspace)]
            + request.relativeProjectFilePaths
                .filter { $0.hasSuffix("_test.go") }
                .map {
                    LanguageTestExtensionItem(
                        id: "go:file:" + $0,
                        label: $0,
                        kind: .file,
                        relativeFilePath: $0
                    )
                }
    }

    func testPlan(for request: LanguageTestExtensionRequest) throws -> LanguageTestExtensionPlan {
        let package: String
        switch request.scope {
        case .workspace:
            package = "./..."
        case .file(let path), .testCase(_, let path?):
            package = "./" + path.split(separator: "/").dropLast().joined(separator: "/")
        case .testCase(_, nil):
            package = "./..."
        }
        return LanguageTestExtensionPlan(
            label: "Go Tests",
            frameworkID: "go",
            launchPlan: LanguageRunExtensionPlan(
                executable: .toolchain("project-go"),
                arguments: ["test", package]
            )
        )
    }
}

@MainActor
private final class TestLanguageExecutionSession: LanguageExecutionSession {
    var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?
    private(set) var startRequests: [LanguageExecutionProcessRequest] = []

    func start(_ request: LanguageExecutionProcessRequest) throws {
        startRequests.append(request)
        isRunning = true
        onStateChange?(LanguageExecutionLifecycleEvent(
            operationID: request.operationID,
            state: .running
        ))
    }

    func stop() { isRunning = false }
}
@MainActor private final class EmptyWorkspaceModule: LitheModule {
    let manifest = ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}
