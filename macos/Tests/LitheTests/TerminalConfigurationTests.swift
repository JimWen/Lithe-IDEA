import Foundation
import LitheTerminalModule
import Testing
@testable import Lithe

@Suite("Terminal configuration")
@MainActor
struct TerminalConfigurationTests {
    private let project = URL(fileURLWithPath: "/fixture/project")
    private let home = URL(fileURLWithPath: "/fixture/home")

    @Test
    func literalArgumentsLoginAndEnvironmentKeepTheirExactMeaning() throws {
        var configuration = TerminalShellConfiguration()
        configuration.shell = .custom
        configuration.customProgram = "~/bin/custom shell"
        configuration.arguments = ["-c", "printf '%s' \"$1\"", "script name", "", "$(literal)", "a b"]
        configuration.environment = [
            .init(name: "VALUE", value: "a b=$x`literal`\nnext"),
            .init(name: "EMPTY", value: ""), .init(name: "REMOVE", value: nil)
        ]
        let plan = try configuration.launchPlan(context: .init(projectURL: project), systemShell: "/bin/zsh",
                                                homeDirectory: home, inheritedEnvironment: ["REMOVE": "old", "KEEP": "inherited"])
        #expect(plan.process.executablePath == "/fixture/home/bin/custom shell")
        #expect(plan.process.arguments == ["-l"] + configuration.arguments)
        #expect(plan.environment["VALUE"] == "a b=$x`literal`\nnext")
        #expect(plan.environment["EMPTY"] == "")
        #expect(plan.environment["REMOVE"] == nil)
        #expect(plan.environment["KEEP"] == "inherited")
        #expect(plan.environment["TERM_PROGRAM"] == "Lithe")
        configuration.arguments = ["--login", "", "--"]
        #expect(try makePlan(configuration).process.arguments == configuration.arguments)
        for literal in ["-l", "--login"] {
            configuration.arguments = ["-c", "printf '%s' \"$0\"", literal]
            #expect(try makePlan(configuration).process.arguments == ["-l"] + configuration.arguments)
        }
        configuration.loginShell = false
        configuration.arguments = ["-l", "-c", "literal"]
        #expect(try makePlan(configuration).process.arguments == configuration.arguments)
        configuration.arguments = []
        #expect(try makePlan(configuration).process.arguments.isEmpty)
    }

    @Test
    func workingDirectoryPoliciesUseCapturedFilesAndExplicitFallbacks() throws {
        var configuration = TerminalShellConfiguration()
        let first = URL(fileURLWithPath: "/fixture/first")
        let context = TerminalLaunchContext(projectURL: project, firstProjectURL: first,
                                            currentFileURL: project.appendingPathComponent("src/main.go"))
        let expected: [(TerminalWorkingDirectory, String)] = [
            (.currentProject, project.path), (.firstProject, first.path),
            (.currentFile, project.appendingPathComponent("src").path), (.home, home.path)
        ]
        for (policy, path) in expected {
            configuration.workingDirectory = policy
            #expect(try makePlan(configuration, context: context).process.workingDirectory == path)
        }
        configuration.workingDirectory = .currentFile
        #expect(try makePlan(configuration).process.workingDirectory == project.path)
        #expect(try makePlan(configuration, context: .init(projectURL: nil, firstProjectURL: first)).process.workingDirectory == first.path)
        #expect(try makePlan(configuration, context: .init(projectURL: nil)).process.workingDirectory == home.path)
        configuration.workingDirectory = .custom
        for (input, expected) in [("build/debug", "/fixture/project/build/debug"), ("~/work", "/fixture/home/work"), ("/absolute/path", "/absolute/path")] {
            configuration.customDirectory = input
            #expect(try makePlan(configuration).process.workingDirectory == expected)
        }
    }

    @Test
    func invalidAndOversizedPreferencesAreRejectedWithoutLeakingValues() {
        var configuration = TerminalShellConfiguration()
        configuration.environment = [.init(name: "INVALID=NAME", value: "PRIVATE_VALUE")]
        #expect(configuration.validationMessage != nil)
        #expect(configuration.validationMessage?.contains("PRIVATE_VALUE") == false)
        configuration.environment = [.init(name: "SAME", value: "a"), .init(name: "SAME", value: nil)]
        #expect(configuration.validationMessage != nil)
        configuration.environment = []
        configuration.arguments = ["bad\0argument"]
        #expect(configuration.validationMessage != nil)
        configuration.arguments = Array(repeating: "", count: 129)
        #expect(configuration.validationMessage != nil)
        configuration.arguments = [String(repeating: "x", count: TerminalShellConfiguration.maximumTextBytes + 1)]
        #expect(configuration.validationMessage != nil)
    }

    @Test
    func settingsMigratePreserveUnknownPayloadAndRestoreTheCompleteConfiguration() throws {
        let store = TerminalConfigurationTestStore()
        store.set("bash", forKey: "settings.terminalShell")
        let settings = AppSettings(store: store)
        #expect(settings.terminalConfiguration.shell == .bash)
        settings.terminalConfiguration.arguments = ["--norc", ""]
        settings.terminalConfiguration.loginShell = false
        settings.terminalConfiguration.environment = [.init(name: "EMPTY", value: ""), .init(name: "REMOVE", value: nil)]
        let restored = AppSettings(store: store)
        #expect(restored.terminalConfiguration == settings.terminalConfiguration)
        #expect(restored.terminalShellPath == "/bin/bash")

        for bytes in [Data("not JSON".utf8), Data("{\"version\":99,\"configuration\":{}}".utf8)] {
            store.set(bytes, forKey: "settings.terminalConfiguration")
            let future = AppSettings(store: store)
            #expect(future.terminalConfigurationLoadError != nil)
            #expect(store.data(forKey: "settings.terminalConfiguration") == bytes)
            future.restoreDefaults()
            #expect(future.terminalConfiguration == TerminalShellConfiguration())
            #expect(future.terminalConfigurationLoadError == nil)
            #expect(AppSettings(store: store).terminalConfiguration == TerminalShellConfiguration())
        }
        let defaults = try JSONDecoder().decode(TerminalShellConfiguration.self, from: Data("{}".utf8))
        #expect(defaults == TerminalShellConfiguration())
    }

    @Test
    func sessionRestartKeepsFrozenLaunchWhileManagedProcessesBypassShellPreferences() throws {
        let transport = ConfigurationTestTransport()
        let feature = TerminalFeatureModel(terminalFactory: { transport })
        var configuration = TerminalShellConfiguration()
        configuration.loginShell = false
        configuration.arguments = ["--norc", "a b"]
        configuration.environment = [.init(name: "CUSTOM", value: "original")]
        let session = feature.createSession(configuration: configuration, context: .init(projectURL: project))
        let first = try #require(transport.launches.first)
        let surface = ObjectIdentifier(session.nativeView)
        transport.inheritedEnvironment = ["INHERITED": "changed"]
        configuration.environment = [.init(name: "CUSTOM", value: "edited")]
        session.restart()
        #expect(transport.launches == [first, first])
        #expect(transport.prepareCount == 1)
        #expect(ObjectIdentifier(session.nativeView) == surface)
        session.restart(using: "/bin/bash")
        #expect(transport.launches.last?.process.arguments == first.process.arguments)
        #expect(transport.launches.last?.environment == first.environment)

        let managed = TerminalProcessLaunch(title: "Debug", executablePath: "/fixture/debuggee", arguments: ["run"], workingDirectory: "/fixture/run",
                                             environmentChanges: [.init(name: "DEBUG_ONLY", value: "1")])
        _ = try session.startProcess(managed)
        #expect(transport.launches.last?.process == managed)
        #expect(transport.launches.last?.environment["CUSTOM"] == nil)
        #expect(transport.launches.last?.environment["DEBUG_ONLY"] == "1")
        let count = transport.launches.count
        session.restart()
        #expect(transport.launches.count == count)
        feature.stopAllSessions()
    }

    @Test
    func failedPreparationIsVisibleAndRetryReusesTheOriginalRequest() {
        let transport = ConfigurationTestTransport()
        transport.failPreparation = true
        let session = TerminalSession(transport: transport)
        var configuration = TerminalShellConfiguration()
        configuration.arguments = ["original"]
        session.start(configuration: configuration, context: .init(projectURL: project))
        #expect(session.lastError != nil)
        #expect(!session.isRunning)
        #expect(transport.launches.isEmpty)
        configuration.arguments = ["edited elsewhere"]
        transport.failPreparation = false
        session.restart()
        #expect(session.lastError == nil)
        #expect(session.isRunning)
        #expect(transport.launches.last?.process.arguments == ["-l", "original"])
        session.stop()
    }

    private func makePlan(_ configuration: TerminalShellConfiguration, context: TerminalLaunchContext? = nil) throws -> TerminalShellLaunch {
        try configuration.launchPlan(context: context ?? .init(projectURL: project), systemShell: "/bin/zsh", homeDirectory: home, inheritedEnvironment: [:])
    }
}

@MainActor
final class ConfigurationTestTransport: TerminalTransport {
    let nativeView: AnyObject = NSObject()
    var isRunning = false
    var processID: Int32? { isRunning ? 42 : nil }
    var shellName = "Shell"
    var onTermination: ((Int32?) -> Void)?
    var onOutput: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectoryUpdate: ((String?) -> Void)?
    var onLink: ((String, [String: String]) -> Void)?
    var inheritedEnvironment = ["INHERITED": "original"]
    var launches: [TerminalShellLaunch] = []
    var prepareCount = 0
    var failPreparation = false

    func defaultShellPath() -> String { "/bin/zsh" }
    func defaultEnvironment() -> [String: String] { inheritedEnvironment }
    func resolveExecutablePath(_ executablePath: String, workingDirectory: String, environment: [String: String]) throws -> String {
        executablePath.hasPrefix("/") ? executablePath : URL(fileURLWithPath: workingDirectory).appendingPathComponent(executablePath).path
    }
    func prepareShellLaunch(_ configuration: TerminalShellConfiguration, context: TerminalLaunchContext) throws -> TerminalShellLaunch {
        prepareCount += 1
        if failPreparation { throw TerminalConfigurationError.missingDirectory }
        return try configuration.launchPlan(context: context, systemShell: defaultShellPath(), homeDirectory: URL(fileURLWithPath: "/fixture/home"), inheritedEnvironment: inheritedEnvironment)
    }
    func start(workingDirectory: String, shellPath: String, environment: [String: String]) throws {
        _ = try startProcess(.init(title: nil, executablePath: shellPath, arguments: ["-l"], workingDirectory: workingDirectory), environment: environment)
    }
    func startProcess(_ launch: TerminalProcessLaunch, environment: [String: String]) throws -> Int32 {
        launches.append(.init(process: launch, environment: environment))
        isRunning = true
        return 42
    }
    func send(_ input: Data) throws {}
    func interrupt() throws {}
    func focus() {}
    func clear() {}
    func stop() { isRunning = false }
}

final class TerminalConfigurationTestStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
}
