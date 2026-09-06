import Combine
import Darwin
import Foundation
import LitheTerminalModule
import Testing
@testable import Lithe

@Suite("Terminal virtual environments", .serialized)
@MainActor
struct TerminalVirtualEnvironmentTests {
    @Test
    func configurationPreservesExplicitEnvironmentPolicyAndValidatesCandidates() throws {
        var configuration = TerminalShellConfiguration()
        let context = TerminalLaunchContext(projectURL: URL(fileURLWithPath: "/fixture/project"))
        func plan(_ environment: [String: String] = [:]) throws -> TerminalShellLaunch {
            try configuration.launchPlan(context: context, systemShell: "/bin/zsh",
                                         homeDirectory: URL(fileURLWithPath: "/fixture/home"), inheritedEnvironment: environment)
        }
        #expect(try plan().virtualEnvironment == .discover([".env", "env", ".venv", "venv"]))
        #expect(try plan(["VIRTUAL_ENV": "/fixture/inherited"]).virtualEnvironment == .preserveExisting)
        for name in ["VIRTUAL_ENV", "PYTHONHOME"] {
            for value in [nil, "", "literal"] as [String?] {
                configuration.environment = [.init(name: name, value: value)]
                #expect(try plan().virtualEnvironment == .preserveExisting)
            }
        }
        configuration.environment = []
        configuration.detectVirtualEnvironment = false
        #expect(try plan().virtualEnvironment == .disabled)
        configuration.virtualEnvironmentDirectories = ["nested/a b'$(literal)", "正常"]
        try configuration.validate()
        for values in [[""], [" "], ["/absolute"], ["~/env"], ["../env"], ["a/./b"], ["a//b"], ["a\0b"],
                       ["same", "same"], [String(repeating: "x", count: 513)], (0..<17).map { "env\($0)" }] {
            configuration.virtualEnvironmentDirectories = values
            #expect(configuration.validationMessage != nil)
        }
        #expect(try JSONDecoder().decode(TerminalShellConfiguration.self, from: Data("{}".utf8)) == TerminalShellConfiguration())
    }

    @Test
    func supportedShellArgumentsRemainNativeAndPathsNeverBecomeShellCode() throws {
        let resources = try #require(MacTerminalShellIntegration.directory)
        for shell in ["zsh", "bash"] {
            for args in [[], ["-l"], ["--login", "-i"], ["-il"]] {
                let launch = TerminalShellLaunch(process: .init(title: nil, executablePath: "/bin/\(shell)", arguments: args,
                                                               workingDirectory: "/fixture"), environment: ["PATH": "/original", "PROMPT_COMMAND": "printf ready"])
                let integrated = try #require(MacTerminalShellIntegration.prepare(launch, path: "/fixture/a'$(literal)", nonce: "nonce", resources: resources))
                #expect(integrated.process.arguments.suffix(args.count) == args[...])
                #expect(integrated.environment["PATH"] == "/original")
                #expect(integrated.environment["LITHE_VENV_PATH"] == "/fixture/a'$(literal)")
                #expect(integrated.environment["VIRTUAL_ENV"] == nil)
                #expect(!integrated.process.arguments.contains("/fixture/a'$(literal)"))
                #expect(launch.environment["LITHE_VENV_NONCE"] == nil)
            }
            for args in [["-c", "echo"], ["-s"], ["--rcfile", "file"], ["--norc"], ["script"], ["-r"], [""], ["--"]] {
                #expect(MacTerminalShellIntegration.shell(for: .init(title: nil, executablePath: "/bin/\(shell)", arguments: args,
                                                                    workingDirectory: "/fixture")) == nil)
            }
        }
    }

    @Test
    func discoveryKeepsCandidateOrderAcceptsSymlinksAndNeverExecutesActivation() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ordinary dotenv".utf8).write(to: root.appendingPathComponent(".env"))
        let first = try makeEnvironment(root, name: "nested/space '$(literal)")
        let second = try makeEnvironment(root, name: "second")
        try Data("touch SHOULD_NOT_EXIST".utf8).write(to: first.appendingPathComponent("bin/activate"))
        let checker = MacTerminalVirtualEnvironmentProbe()
        func check(_ paths: [String]) async throws -> MacTerminalVirtualEnvironmentProbe.Result {
            let done = TestGate()
            var result: MacTerminalVirtualEnvironmentProbe.Result?
            let cancel = checker.check(paths) { result = $0; done.open() }
            defer { cancel(); done.open() }
            try #require(await done.waitUntilOpen())
            return try #require(result)
        }
        #expect(try await check([root.appendingPathComponent(".env").path, first.path, second.path]) == .found(first.path))
        try FileManager.default.removeItem(at: first.appendingPathComponent("bin/python"))
        #expect(try await check([first.path, second.path]) == .found(second.path))
        #expect(try await check([first.path]) == .missing)
        #expect(try await check([root.path + ":colon/venv"]) == .unsupportedPath)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }

    @Test
    func timeoutDoesNotReleaseBlockedWorkersForNewRequests() async throws {
        let first = ProbeWorker(), second = ProbeWorker()
        let scheduler = ManualCommandScheduler()
        let checker = MacTerminalVirtualEnvironmentProbe(probe: { path in
            path == "first" ? first.run() : second.run()
        }, scheduleTimeout: { scheduler.schedule(after: 1, $0) })
        var results: [MacTerminalVirtualEnvironmentProbe.Result] = []
        let cancelFirst = checker.check(["first", "must-not-probe"]) { results.append($0) }
        let cancelSecond = checker.check(["second"]) { results.append($0) }
        defer { cancelFirst(); cancelSecond(); first.release.open(); second.release.open() }
        do {
            try #require(await first.entered.waitUntilOpen())
            try #require(await second.entered.waitUntilOpen())
            scheduler.drain(includingDeadlines: true)
            #expect(results == [.unknown, .unknown])
            let cancelOverloaded = checker.check(["third"]) { results.append($0) }
            cancelOverloaded()
            #expect(results == [.unknown, .unknown, .unknown])
            #expect(!first.ranOnMainThread && !second.ranOnMainThread)
        } catch {
            first.release.open(); second.release.open()
            _ = await first.exited.waitUntilOpen(); _ = await second.exited.waitUntilOpen()
            throw error
        }
        first.release.open(); second.release.open()
        #expect(await first.exited.waitUntilOpen())
        #expect(await second.exited.waitUntilOpen())
        #expect(!first.timedOut && !second.timedOut)
    }

    @Test
    func sessionIgnoresCancelledPreparationAndFreezesNegativeAndFailedSelections() throws {
        let transport = ConfigurationTestTransport()
        var requests: [TerminalShellLaunch] = []
        var completions: [@MainActor (TerminalShellLaunch, Result<Int32, any Error>) -> Void] = []
        transport.shellStartHandler = { requests.append($0); completions.append($1) }
        let session = TerminalSession(transport: transport)
        defer { session.stop(); completions.removeAll() }
        let context = TerminalLaunchContext(projectURL: URL(fileURLWithPath: "/fixture/project"))
        session.start(configuration: .init(), context: context)
        session.stop()
        completions[0](requests[0].selectingVirtualEnvironment(.selected("/fixture/late")), .success(42))
        #expect(!session.isReady)
        session.start(configuration: .init(), context: context)
        let negative = requests[1].selectingVirtualEnvironment(.notFound)
        transport.isRunning = true
        completions[1](negative, .success(42))
        session.restart()
        #expect(requests[2].virtualEnvironment == .notFound)
        let selected = requests[2].selectingVirtualEnvironment(.selected("/fixture/selected"))
        transport.onVirtualEnvironmentState?(.detecting)
        completions[2](selected, .failure(TerminalConfigurationError.missingDirectory))
        #expect(session.lastError != nil)
        #expect(session.virtualEnvironmentState == .inactive)
        session.restart()
        #expect(requests[3].virtualEnvironment == .selected("/fixture/selected"))
        #expect(transport.prepareCount == 2)
    }

    @Test
    func failedNativeSpawnAfterDiscoveryClearsPendingActivation() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let removed = TestGate()
        let checker = MacTerminalVirtualEnvironmentProbe(probe: { _ in
            do { try FileManager.default.removeItem(at: root); removed.open() }
            catch { return .unknown }
            return .missing
        })
        let transport = MacTerminalTransport(linkActivation: MacTerminalLinkActivation(), virtualEnvironmentProbe: checker, inheritedEnvironment: { ["PATH": "/usr/bin:/bin"] })
        let session = TerminalSession(transport: transport)
        let failed = TestGate()
        let observation = session.$lastError.sink { if $0 != nil { failed.open() } }
        var identities: [MacTerminalProcessIdentity] = []
        let capture = session.$isRunning.sink { running in
            if running, let pid = transport.processID, let identity = MacTerminalProcessIdentity.read(pid)?.identity { identities.append(identity) }
        }
        defer { session.stop(); capture.cancel(); observation.cancel(); failed.open(); removed.open() }
        do {
            session.start(configuration: .init(), context: .init(projectURL: root))
            try #require(await failed.waitUntilOpen())
            #expect(removed.isOpen)
            #expect(!session.isRunning)
            #expect(session.virtualEnvironmentState == .inactive)
        } catch { await cleanup(session, identities: identities); throw error }
        await cleanup(session, identities: identities)
    }

    @Test
    func timeoutClearAndLateAcknowledgmentStayBoundToTheCurrentProcess() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try makeEnvironment(root, name: ".venv")
        let rc = #"""
        stty -echo
        printf '\033]%s;1;wrong-nonce;%s;activated\007' "$LITHE_VENV_OSC" "$$"
        printf 'WAITING_FOR_USER\n'
        read -r answer
        """#
        try Data(rc.utf8).write(to: root.appendingPathComponent(".zshrc"))
        var deadlines: [@MainActor @Sendable () -> Void] = []
        let terminal = MacTerminalTransport(linkActivation: MacTerminalLinkActivation(), inheritedEnvironment: { ["PATH": "/usr/bin:/bin"] }, scheduleActivationTimeout: {
            deadlines.append($0)
            // Intentionally retain cancelled callbacks to exercise late delivery.
            return {}
        })
        let session = TerminalSession(transport: terminal)
        let waiting = TestGate(), activated = TestGate()
        var output = "", identities: [MacTerminalProcessIdentity] = []
        session.onOutput = { output += $0; if output.contains("WAITING_FOR_USER") { waiting.open() } }
        let capture = session.$isRunning.sink { running in
            if running, let pid = terminal.processID, let identity = MacTerminalProcessIdentity.read(pid)?.identity { identities.append(identity) }
        }
        let state = session.$virtualEnvironmentState.sink { if $0 == .activated(environment.path) { activated.open() } }
        defer { session.stop(); capture.cancel(); state.cancel(); waiting.open(); activated.open(); deadlines.removeAll() }
        do {
            var config = TerminalShellConfiguration()
            config.shell = .zsh
            config.environment = [.init(name: "HOME", value: root.path), .init(name: "ZDOTDIR", value: root.path)]
            session.start(configuration: config, context: .init(projectURL: root))
            try #require(await waiting.waitUntilOpen())
            #expect(session.virtualEnvironmentState == .activating(environment.path))
            try #require(deadlines.count == 1)
            deadlines[0]()
            #expect(session.virtualEnvironmentState == .unconfirmed(environment.path))
            session.clear()
            session.send("continue")
            try #require(await activated.waitUntilOpen())
            session.stop()
            deadlines[0]()
            #expect(session.virtualEnvironmentState == .inactive)
            #expect(!session.isRunning)
        } catch {
            await cleanup(session, identities: identities); throw error
        }
        await cleanup(session, identities: identities)
    }

    @Test
    func realZshActivatesAfterRCDeactivatesAndRestartKeepsItsSelectedDirectory() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try makeEnvironment(root, name: "env '$(literal)")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Isolated startup files, with no dependency on developer shell plugins.
        try Data("export PATH=/usr/bin:/bin; export PYTHONHOME=original-home; PROMPT=\"VENV_READY> \"; RPROMPT=\"\"\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
        let terminal = MacTerminalTransport(linkActivation: MacTerminalLinkActivation(), inheritedEnvironment: { ["PATH": "/usr/bin:/bin"] })
        let session = TerminalSession(transport: terminal)
        let promptReady = TestGate()
        var transcript = ""
        session.onOutput = { transcript += $0; if transcript.contains("VENV_READY> ") { promptReady.open() } }
        var identities: [MacTerminalProcessIdentity] = []
        let capture = session.$isRunning.sink { running in
            if running, let pid = terminal.processID, let identity = MacTerminalProcessIdentity.read(pid)?.identity {
                identities.append(identity)
            }
        }
        defer { capture.cancel(); session.stop(); promptReady.open() }
        func waitForState(_ predicate: @escaping (TerminalVirtualEnvironmentState) -> Bool,
                          start: () -> Void) async throws {
            let gate = TestGate()
            let observation = session.$virtualEnvironmentState.sink { if predicate($0) { gate.open() } }
            defer { observation.cancel(); gate.open() }
            start()
            try #require(await gate.waitUntilOpen(), "Observed: \(session.virtualEnvironmentState); error: \(session.lastError ?? "none")")
        }
        do {
            var config = TerminalShellConfiguration()
            config.shell = .zsh
            config.virtualEnvironmentDirectories = [environment.lastPathComponent]
            config.environment = [.init(name: "HOME", value: home.path), .init(name: "ZDOTDIR", value: home.path)]
            try await waitForState({ $0 == .activated(environment.path) }) {
                session.start(configuration: config, context: .init(projectURL: root))
            }
            #expect(session.isReady)
            try #require(await promptReady.waitUntilOpen())
            let originalPID = terminal.processID
            let output = TestGate()
            var text = ""
            session.onOutput = {
                text += $0
                if text.contains("RESTORE_OK\r\n") { output.open() }
            }
            try await waitForState({ $0 == .deactivated }) {
                session.send("deactivate; [[ $PATH = /usr/bin:/bin && $PYTHONHOME = original-home && -z ${VIRTUAL_ENV+x} ]] && printf 'RESTORE_%s\\n' OK")
            }
            #expect(await output.waitUntilOpen())
            #expect(terminal.processID == originalPID)
            try FileManager.default.removeItem(at: environment)
            try await waitForState({ $0 == .skipped(.unavailable) }) { session.restart() }
            #expect(session.isRunning)
            _ = try makeEnvironment(root, name: environment.lastPathComponent)
            try await waitForState({ $0 == .activated(environment.path) }) { session.restart() }
            session.stop()
        } catch {
            await cleanup(session, identities: identities)
            throw error
        }
        await cleanup(session, identities: identities)
    }

    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-venv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeEnvironment(_ root: URL, name: String) throws -> URL {
        let environment = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: environment.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("home = fixture".utf8).write(to: environment.appendingPathComponent("pyvenv.cfg"))
        try FileManager.default.createSymbolicLink(at: environment.appendingPathComponent("bin/python"), withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        return environment
    }

    private func cleanup(_ session: TerminalSession, identities: [MacTerminalProcessIdentity]) async {
        session.stop()
        for identity in identities { identity.signal(SIGKILL, in: identity.pid) }
        for identity in identities {
            let gate = TestGate()
            MacStoppedChildProcessReaper().reapWhenExited(identity.pid) { gate.open() }
            #expect(await gate.waitUntilOpen())
        }
        #expect(await MacTerminalProcessSession.waitForPendingStops())
    }
}

private final class ProbeWorker: @unchecked Sendable {
    let entered = TestGate(), release = TestGate(), exited = TestGate()
    private let lock = NSLock()
    private var mainThread = false, timeout = false
    var ranOnMainThread: Bool { lock.withLock { mainThread } }
    var timedOut: Bool { lock.withLock { timeout } }
    func run() -> MacTerminalVirtualEnvironmentProbe.Presence {
        lock.withLock { mainThread = Thread.isMainThread }
        entered.open()
        let released = release.waitSynchronously()
        lock.withLock { timeout = !released }
        exited.open()
        return .missing
    }
}
