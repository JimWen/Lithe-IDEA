import Darwin
import Foundation
import LitheApplicationKernel
import LitheCoreContracts
@testable import LitheDebugModule
import LitheExecutionModule
import LitheGoSupportModule
import LitheModuleAPI
import LithePythonSupportModule
import LitheRustSupportModule
import Testing
@testable import Lithe

@Suite("Batch D multi-language debugging")
@MainActor
struct BatchDMultiLanguageDebugTests {
    @Test
    func breakpointLocationValidatorSupportsGoRustPythonNodeAndJava() {
        let goSource = """
        package main

        // comment line
        import "fmt"

        /* block
           comment */
        func main() {
            x := 42
            fmt.Println(x)
        }
        """
        #expect(!DebugBreakpointLocationValidator.isCandidateLine(source: goSource, line: 1, languageID: "go"))
        #expect(!DebugBreakpointLocationValidator.isCandidateLine(source: goSource, line: 2, languageID: "go"))
        #expect(!DebugBreakpointLocationValidator.isCandidateLine(source: goSource, line: 3, languageID: "go"))
        #expect(!DebugBreakpointLocationValidator.isCandidateLine(source: goSource, line: 4, languageID: "go"))
        #expect(!DebugBreakpointLocationValidator.isCandidateLine(source: goSource, line: 6, languageID: "go"))
        #expect(!DebugBreakpointLocationValidator.isCandidateLine(source: goSource, line: 7, languageID: "go"))
        #expect(DebugBreakpointLocationValidator.isCandidateLine(source: goSource, line: 9, languageID: "go"))
        #expect(DebugBreakpointLocationValidator.isCandidateLine(source: goSource, line: 10, languageID: "go"))
        #expect(!DebugBreakpointLocationValidator.isCandidateLine(source: goSource, line: 11, languageID: "go"))

        let rustSource = """
        use std::fmt;

        // comment
        fn main() {
            let value = 7;
            println!("{value}");
        }
        """
        #expect(!DebugBreakpointLocationValidator.isCandidateLine(source: rustSource, line: 1, languageID: "rust"))
        #expect(!DebugBreakpointLocationValidator.isCandidateLine(source: rustSource, line: 3, languageID: "rust"))
        #expect(DebugBreakpointLocationValidator.isCandidateLine(source: rustSource, line: 5, languageID: "rust"))
        #expect(DebugBreakpointLocationValidator.isCandidateLine(source: rustSource, line: 6, languageID: "rust"))
        #expect(!DebugBreakpointLocationValidator.isCandidateLine(source: rustSource, line: 7, languageID: "rust"))

        let pythonSource = """
        # leading comment
        import os

        def compute(x):
            total = x + 1
            return total
        """
        #expect(!DebugBreakpointLocationValidator.isCandidateLine(source: pythonSource, line: 1, languageID: "python"))
        #expect(!DebugBreakpointLocationValidator.isCandidateLine(source: pythonSource, line: 3, languageID: "python"))
        #expect(DebugBreakpointLocationValidator.isCandidateLine(source: pythonSource, line: 2, languageID: "python"))
        #expect(DebugBreakpointLocationValidator.isCandidateLine(source: pythonSource, line: 5, languageID: "python"))
        #expect(DebugBreakpointLocationValidator.isCandidateLine(source: pythonSource, line: 6, languageID: "python"))
    }

    @Test
    func sourceResolverPreservesCurrentFileForNonJavaAndResolvesMultiLanguageAnchors() {
        let workspaceURL = URL(fileURLWithPath: "/fixture/polyglot", isDirectory: true)
        let currentFile = RunConfiguration(
            id: "current-file",
            name: "Current File",
            kind: .currentFile,
            execution: .application,
            modulePath: nil,
            mainClass: nil
        )
        let javaConfig = RunConfiguration(
            id: "java-main",
            name: "Main",
            kind: .javaMain,
            execution: .application,
            modulePath: nil,
            mainClass: "com.example.Main"
        )
        let goConfig = RunConfiguration(
            id: "go-api",
            name: "api",
            kind: .process(provider: "go.application"),
            execution: .application,
            modulePath: "cmd/api",
            mainClass: nil
        )
        let rustConfig = RunConfiguration(
            id: "cargo-cli",
            name: "lithe-cli",
            kind: .process(provider: "cargo.bin"),
            execution: .application,
            modulePath: "crates/cli",
            mainClass: nil
        )
        let pythonConfig = RunConfiguration(
            id: "py-app",
            name: "app",
            kind: .process(provider: "python.script"),
            execution: .application,
            modulePath: "scripts",
            mainClass: nil
        )

        let resolver = DebugLaunchSourceResolver()
        let goFile = workspaceURL.appendingPathComponent("cmd/api/main.go")
        let rustFile = workspaceURL.appendingPathComponent("crates/cli/src/main.rs")
        let pythonFile = workspaceURL.appendingPathComponent("scripts/app.py")
        let helperJava = workspaceURL.appendingPathComponent("src/Helper.java")
        let projectFiles = [goFile, rustFile, pythonFile, helperJava]

        // Non-Java active files must keep `.currentFile` instead of redirecting to `.javaMain`.
        #expect(resolver.configurationForDebug(
            selected: currentFile,
            activeDocumentText: "package main\nfunc main() {}",
            configurations: [currentFile, javaConfig],
            activeDocumentURL: goFile
        ) == currentFile)
        #expect(resolver.configurationForDebug(
            selected: currentFile,
            activeDocumentText: "fn main() {}",
            configurations: [currentFile, javaConfig],
            activeDocumentURL: rustFile
        ) == currentFile)
        #expect(resolver.configurationForDebug(
            selected: currentFile,
            activeDocumentText: "print('hi')",
            configurations: [currentFile, javaConfig],
            activeDocumentURL: pythonFile
        ) == currentFile)
        // Non-main Java file still redirects to the project `.javaMain` target.
        #expect(resolver.configurationForDebug(
            selected: currentFile,
            activeDocumentText: "class Helper {}",
            configurations: [currentFile, javaConfig],
            activeDocumentURL: helperJava
        ) == javaConfig)

        #expect(resolver.resolve(
            configuration: goConfig,
            activeDocumentURL: nil,
            projectFiles: projectFiles,
            workspaceURL: workspaceURL
        ) == goFile.standardizedFileURL)
        #expect(resolver.resolve(
            configuration: rustConfig,
            activeDocumentURL: nil,
            projectFiles: projectFiles,
            workspaceURL: workspaceURL
        ) == rustFile.standardizedFileURL)
        #expect(resolver.resolve(
            configuration: pythonConfig,
            activeDocumentURL: nil,
            projectFiles: projectFiles,
            workspaceURL: workspaceURL
        ) == pythonFile.standardizedFileURL)
    }

    @Test
    func configurationResolverForwardsArgsEnvCwdAndResolvesRustWorkspaceTargets() throws {
        let workspaceURL = URL(fileURLWithPath: "/fixture/workspace", isDirectory: true)
        let workspaceBinary = workspaceURL.appendingPathComponent("target/debug/worker")
        let customPrebuilt = workspaceURL.appendingPathComponent("custom/out/worker")
        let resolver = DebugLaunchConfigurationResolver(fileExists: { url in
            url.standardizedFileURL == workspaceBinary.standardizedFileURL
                || url.standardizedFileURL == customPrebuilt.standardizedFileURL
        })

        let sharedOptions = RunOptions(
            workingDirectoryPath: "runtime-cwd",
            programArguments: "--port 9000 \"hello world\"",
            environment: ["APP_ENV": "debug"]
        )
        let expectedCwd = workspaceURL.appendingPathComponent("runtime-cwd").standardizedFileURL.path

        // Go
        let goConfig = RunConfiguration(
            id: "go-svc",
            name: "svc",
            kind: .process(provider: "go.application"),
            execution: .application,
            modulePath: "cmd/svc",
            mainClass: nil
        )
        let goLaunch = try resolver.resolve(
            provider: LanguageProviderDescriptor(
                id: "go",
                displayName: "Go",
                fileExtensions: ["go"],
                capabilities: [.debugAdapter],
                activationPolicy: .onDemand
            ),
            documentURL: workspaceURL.appendingPathComponent("cmd/svc/main.go"),
            workspaceURL: workspaceURL,
            configurations: [goConfig],
            selectedConfiguration: goConfig,
            options: { _ in sharedOptions }
        )
        #expect(goLaunch.arguments["mode"] == ToolingJSONValue.string("debug"))
        #expect(goLaunch.arguments["program"] == ToolingJSONValue.string(workspaceURL.appendingPathComponent("cmd/svc").standardizedFileURL.path))
        #expect(goLaunch.arguments["cwd"] == ToolingJSONValue.string(expectedCwd))
        #expect(goLaunch.arguments["args"] == ToolingJSONValue.array([
            ToolingJSONValue.string("--port"),
            ToolingJSONValue.string("9000"),
            ToolingJSONValue.string("hello world")
        ]))
        #expect(goLaunch.arguments["env"] == ToolingJSONValue.object(["APP_ENV": ToolingJSONValue.string("debug")]))

        // Python
        let pyConfig = RunConfiguration(
            id: "py-main",
            name: "main",
            kind: .process(provider: "python.script"),
            execution: .application,
            modulePath: "scripts",
            mainClass: nil
        )
        let pyFile = workspaceURL.appendingPathComponent("scripts/main.py")
        let pyLaunch = try resolver.resolve(
            provider: LanguageProviderDescriptor(
                id: "python",
                displayName: "Python",
                fileExtensions: ["py"],
                capabilities: [.debugAdapter],
                activationPolicy: .onDemand
            ),
            documentURL: pyFile,
            workspaceURL: workspaceURL,
            configurations: [pyConfig],
            selectedConfiguration: pyConfig,
            options: { _ in sharedOptions }
        )
        #expect(pyLaunch.arguments["program"] == ToolingJSONValue.string(pyFile.standardizedFileURL.path))
        #expect(pyLaunch.arguments["cwd"] == ToolingJSONValue.string(expectedCwd))
        #expect(pyLaunch.arguments["args"] == ToolingJSONValue.array([
            ToolingJSONValue.string("--port"),
            ToolingJSONValue.string("9000"),
            ToolingJSONValue.string("hello world")
        ]))
        #expect(pyLaunch.arguments["env"] == ToolingJSONValue.object(["APP_ENV": ToolingJSONValue.string("debug")]))

        // Rust fallback to workspace-root target/debug/<bin>
        let cargoConfig = RunConfiguration(
            id: "cargo-worker",
            name: "worker",
            kind: .process(provider: "cargo.bin"),
            execution: .application,
            modulePath: "crates/worker",
            mainClass: nil
        )
        let rustDescriptor = LanguageProviderDescriptor(
            id: "rust",
            displayName: "Rust",
            fileExtensions: ["rs"],
            capabilities: [.debugAdapter],
            activationPolicy: .onDemand
        )
        let rustFallbackLaunch = try resolver.resolve(
            provider: rustDescriptor,
            documentURL: workspaceURL.appendingPathComponent("crates/worker/src/main.rs"),
            workspaceURL: workspaceURL,
            configurations: [cargoConfig],
            selectedConfiguration: cargoConfig,
            options: { _ in sharedOptions }
        )
        #expect(rustFallbackLaunch.arguments["program"] == ToolingJSONValue.string(workspaceBinary.standardizedFileURL.path))
        #expect(rustFallbackLaunch.arguments["cwd"] == ToolingJSONValue.string(expectedCwd))
        #expect(rustFallbackLaunch.arguments["args"] == ToolingJSONValue.array([
            ToolingJSONValue.string("--port"),
            ToolingJSONValue.string("9000"),
            ToolingJSONValue.string("hello world")
        ]))
        #expect(rustFallbackLaunch.arguments["env"] == ToolingJSONValue.object(["APP_ENV": ToolingJSONValue.string("debug")]))

        // Rust with explicit preBuiltRustExecutableURL
        let rustPrebuiltLaunch = try resolver.resolve(
            provider: rustDescriptor,
            documentURL: workspaceURL.appendingPathComponent("crates/worker/src/main.rs"),
            workspaceURL: workspaceURL,
            configurations: [cargoConfig],
            selectedConfiguration: cargoConfig,
            preBuiltRustExecutableURL: customPrebuilt,
            options: { _ in sharedOptions }
        )
        #expect(rustPrebuiltLaunch.arguments["program"] == ToolingJSONValue.string(customPrebuilt.standardizedFileURL.path))
    }

    @Test
    func rustDebugBuildServiceParsesCargoJsonCompilerArtifacts() {
        let output = """
        warning: unused variable `x`
        {"reason":"compiler-artifact","target":{"kind":["lib"],"name":"core"},"executable":null}
        {"reason":"compiler-artifact","target":{"kind":["bin"],"name":"helper"},"executable":"/tmp/ws/target/debug/helper"}
        {"reason":"compiler-artifact","target":{"kind":["bin"],"name":"app"},"executable":"/tmp/ws/target/debug/app"}
        {"reason":"build-finished","success":true}
        """

        #expect(RustDebugBuildService.parseBuiltExecutablePath(from: output, binaryName: "app") == "/tmp/ws/target/debug/app")
        #expect(RustDebugBuildService.parseBuiltExecutablePath(from: output, binaryName: "helper") == "/tmp/ws/target/debug/helper")
        #expect(RustDebugBuildService.parseBuiltExecutablePath(from: output, binaryName: nil) == "/tmp/ws/target/debug/app")
    }

    @Test
    func debugExtensionRegistrationGatesSessionsAndExportsCapabilities() async throws {
        let runtime = ModuleRuntime()
        let workspace = BuiltInModuleCatalog.manifest(for: .workspace)!
        try runtime.register(ModuleFactory(manifest: workspace) {
            BatchDWorkspaceModule(manifest: workspace)
        })
        let registry = ManagedProcessRegistry()
        let execHost = MacLanguageExecutionHost(processRegistry: registry)
        try runtime.register(ModuleFactory(
            manifest: GoExecutionModule.moduleManifest,
            contributions: GoExecutionModule.moduleContributions
        ) {
            GoExecutionModule(
                executionHost: execHost,
                projectToolHost: MacLanguageProjectToolHost(registry: registry)
            )
        })
        let toolHost = MacLanguageProjectToolHost(registry: registry)
        try runtime.register(ModuleFactory(
            manifest: RustExecutionModule.moduleManifest,
            contributions: RustExecutionModule.moduleContributions
        ) {
            RustExecutionModule(executionHost: execHost, projectToolHost: toolHost)
        })
        try runtime.register(ModuleFactory(
            manifest: PythonExecutionModule.moduleManifest
        ) {
            PythonExecutionModule(executionHost: execHost)
        })
        let nodeModule = BundledLanguageExecutionModule(
            languageID: "node",
            executionHost: execHost
        )
        try runtime.register(ModuleFactory(
            manifest: nodeModule.manifest,
            contributions: BundledLanguagePluginCatalog.executionContributions(languageID: "node")
        ) {
            BundledLanguageExecutionModule(
                languageID: "node",
                executionHost: execHost
            )
        })

        // Go execution module exports `.languageDebugExtension("go")` when enabled.
        try await runtime.setEnabled(true, for: .languageExecutionExtension("go"))
        let goDebugProvider = try #require(
            try await runtime.activateCapability(.languageDebugExtension("go"))
                as? any LanguageDebugExtensionProviding
        )
        #expect(goDebugProvider.languageID == "go")
        #expect(goDebugProvider.debugAdapterLaunch.transport == .dlvServer)

        // Bundled Rust/Python/Node execution modules stay disabled by default and export debug extensions once enabled.
        for (languageID, expectedTransport) in [
            ("rust", LanguageDebugAdapterTransportKind.stdio),
            ("python", LanguageDebugAdapterTransportKind.stdio),
            ("node", LanguageDebugAdapterTransportKind.nodeServer)
        ] {
            let moduleID = ModuleID.languageExecutionExtension(languageID)
            try await runtime.setEnabled(true, for: moduleID)
            let provider = try #require(
                try await runtime.activateCapability(.languageDebugExtension(languageID))
                    as? any LanguageDebugExtensionProviding
            )
            #expect(provider.languageID == languageID)
            #expect(provider.debugAdapterLaunch.transport == expectedTransport)
        }

        // DebugAdapterRuntimeFactory refuses extension-owned languages until registered.
        let fakeDlv = URL(fileURLWithPath: "/opt/fake/dlv")
        let fakeGo = URL(fileURLWithPath: "/opt/fake/go")
        let runtimeService = ProjectRuntimeService(
            runtimeLocator: StubRuntimeLocator(),
            store: BatchDEmptyKeyValueStore(),
            toolDiscovery: StaticToolDiscovery(executables: [
                "dlv": fakeDlv,
                "go": fakeGo
            ]),
            fileStorage: MacFileStorage()
        )
        var capturedDlvEnv: [String: String]?
        let factory = DebugAdapterRuntimeFactory(
            runtimeService: runtimeService,
            transportFactory: { _, _, _ in RecordingDebugAdapterTransport() },
            launches: [:],
            dlvTransportFactory: { _, env in
                capturedDlvEnv = env
                return RecordingDebugAdapterTransport()
            }
        )
        let goDescriptor = DebugProviderDescriptor(id: "go", displayName: "Go", fileExtensions: ["go"])
        let workspaceRoot = URL(fileURLWithPath: "/fixture/go", isDirectory: true)
        #expect(factory.makeSession(for: goDescriptor, rootURL: workspaceRoot) == nil)

        let goSupport = try #require(OfficialPluginCatalog.manifests.first?.languageSupports?.first)
        #expect(factory.registerExtension(goDebugProvider, support: goSupport))
        #expect(factory.makeSession(for: goDescriptor, rootURL: workspaceRoot) != nil)
        let dlvPath = capturedDlvEnv?["PATH"] ?? ""
        #expect(dlvPath.contains("/opt/fake"))

        factory.unregisterExtension(languageID: "go")
        #expect(factory.makeSession(for: goDescriptor, rootURL: workspaceRoot) == nil)

        for moduleID in [
            ModuleID.languageExecutionExtension("go"),
            .languageExecutionExtension("rust"),
            .languageExecutionExtension("python"),
            .languageExecutionExtension("node"),
            .workspace
        ] {
            try? await runtime.shutdown(moduleID)
        }
    }

    @Test
    func dapSessionRecoversFromMalformedHeadersAndStopsTransportOnTerminatedEvent() throws {
        let transport = RecordingDebugAdapterTransport()
        let session = DebugAdapterProtocolSession(adapterID: "lldb", transport: transport)
        var receivedEvents: [DebugAdapterEvent] = []
        session.onEvent = { receivedEvents.append($0) }

        let root = URL(fileURLWithPath: "/fixture/dap", isDirectory: true)
        try session.start(rootURL: root)
        #expect(transport.isRunning)

        // Malformed header (missing Content-Length) followed by negative length, then a valid output event.
        let malformed = Data("X-Bogus: 1\r\n\r\nContent-Length: -5\r\n\r\n".utf8)
        let outputPayload = Data(#"{"seq":1,"type":"event","event":"output","body":{"category":"stdout","output":"ok\n"}}"#.utf8)
        let validFrame = Data("Content-Length: \(outputPayload.count)\r\n\r\n".utf8) + outputPayload
        transport.emitData(malformed + validFrame)

        let sawOutput = receivedEvents.contains { event in
            if case .output(let category, let text) = event {
                return category == "stdout" && text == "ok\n"
            }
            return false
        }
        #expect(sawOutput)

        // Sending DAP `terminated` event must request disconnect and stop the transport.
        let terminatedPayload = Data(#"{"seq":2,"type":"event","event":"terminated"}"#.utf8)
        let terminatedFrame = Data("Content-Length: \(terminatedPayload.count)\r\n\r\n".utf8) + terminatedPayload
        transport.emitData(terminatedFrame)

        #expect(session.state == .terminated)
        #expect(transport.stopCount >= 1)
        let sentText = transport.sentMessages.compactMap { String(data: $0, encoding: .utf8) }.joined()
        #expect(sentText.contains(#""command":"disconnect""#))
    }

    @Test
    func runtimeToolDiscoveryFindsProjectPythonVenvAndSwiftlyLldbDap() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let project = URL(fileURLWithPath: "/Users/tester/app", isDirectory: true)
        let projectVenvPython = project.appendingPathComponent(".venv/bin/python3").standardizedFileURL
        let envVenvPython = URL(fileURLWithPath: "/opt/env/bin/python3").standardizedFileURL
        let swiftlyLldbDap = home.appendingPathComponent(".swiftly/bin/lldb-dap").standardizedFileURL

        let existing = Set([projectVenvPython.path, envVenvPython.path, swiftlyLldbDap.path])
        let discovery = MacRuntimeToolDiscovery(
            homeDirectoryURL: home,
            resourceDirectoryURL: nil,
            isExecutable: { existing.contains($0.standardizedFileURL.path) }
        )

        let pythonCandidates = discovery.candidates(
            for: "python3",
            projectURL: project,
            environment: ["VIRTUAL_ENV": "/opt/env", "PATH": "/usr/bin"]
        )
        #expect(pythonCandidates.first?.executableURL == projectVenvPython)
        #expect(pythonCandidates.contains(where: { $0.executableURL == envVenvPython }))

        let lldbCandidates = discovery.candidates(
            for: "lldb-dap",
            projectURL: project,
            environment: ["PATH": "/usr/bin"]
        )
        #expect(lldbCandidates.contains(where: { $0.executableURL == swiftlyLldbDap }))
    }

    @Test
    func rawProcessSessionRegistersPidAndStopAndWaitTerminatesCleanly() async throws {
        let sleepURL = URL(fileURLWithPath: "/bin/sleep")
        guard FileManager.default.isExecutableFile(atPath: sleepURL.path) else { return }

        let registry = ManagedProcessRegistry()
        let session = MacRawProcessSession(processRegistry: registry, ownerModuleID: .debug)
        defer { session.stop() }

        try session.start(ProcessRequest(
            operationID: "batch-d-raw-process-test",
            executablePath: sleepURL.path,
            arguments: ["30"],
            workingDirectory: "/tmp",
            environment: [:],
            keepsStandardInputOpen: true
        ))
        let pids = registry.processIDs(for: .debug)
        #expect(pids.count == 1)
        let pid = try #require(pids.first)
        #expect(Darwin.kill(pid, 0) == 0)

        let stopped = await session.stopAndWait()
        #expect(stopped)
        #expect(!session.isRunning)
        #expect(registry.processIDs(for: .debug).isEmpty)
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }
}

@MainActor
private final class BatchDWorkspaceModule: LitheModule {
    let manifest: ModuleManifest
    private var capability: BatchDWorkspaceCapability?

    init(manifest: ModuleManifest) {
        self.manifest = manifest
    }

    func activate(context _: ModuleContext) async throws {
        capability = BatchDWorkspaceCapability()
    }
    func prepareForSleep() async throws {}
    func sleep() async { capability = nil }
    func shutdown() async { capability = nil }
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        capability.map { [.workspaceFoundation: $0] } ?? [:]
    }
}

private final class BatchDWorkspaceCapability {}

private struct BatchDEmptyKeyValueStore: KeyValueStore {
    func data(forKey _: String) -> Data? { nil }
    func object(forKey _: String) -> Any? { nil }
    func string(forKey _: String) -> String? { nil }
    func stringArray(forKey _: String) -> [String]? { nil }
    func set(_: Any?, forKey _: String) {}
    func removeObject(forKey _: String) {}
}

private struct StubRuntimeLocator: RuntimeLocator {
    func environment() -> [String: String] { [:] }
    func discover() -> RuntimeDiscoveryResult { RuntimeDiscoveryResult(javaRuntimes: []) }
    func validJavaHome(path _: String) -> URL? { nil }
    func javaRuntime(at _: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at _: URL) -> Bool { false }
}

private struct StaticToolDiscovery: RuntimeToolDiscovery {
    let executables: [String: URL]
    func candidates(for command: String, projectURL _: URL?, environment _: [String: String]) -> [RuntimeToolCandidate] {
        guard let url = executables[command] else { return [] }
        return [RuntimeToolCandidate(command: command, executableURL: url, source: .path)]
    }
    func guidance(for command: String, projectURL _: URL?, environment _: [String: String]) -> RuntimeToolGuidance {
        RuntimeToolGuidance(command: command, summary: "\(command) unavailable", recovery: "Install \(command)")
    }
}

@MainActor
private final class RecordingDebugAdapterTransport: DebugAdapterTransport {
    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?
    private(set) var isRunning = false
    private(set) var sentMessages: [Data] = []
    private(set) var stopCount = 0

    func start(rootURL _: URL) throws {
        isRunning = true
    }

    func send(_ data: Data) throws {
        sentMessages.append(data)
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func emitData(_ data: Data) {
        onData?(data)
    }
}
