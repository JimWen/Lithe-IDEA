import AppKit
import Combine
import Darwin
import Foundation
import LitheTerminalModule
import Testing
@testable import Lithe

@_silgen_name("proc_pidinfo")
private func configurationTestPIDInfo(
    _ pid: pid_t, _ flavor: Int32, _ argument: UInt64,
    _ buffer: UnsafeMutableRawPointer?, _ size: Int32
) -> Int32

@Suite("Native terminal configuration", .serialized)
@MainActor
struct MacTerminalConfigurationTests {
    @Test
    func cursorDefaultsReturnOnRestartAndOptionMetaReachesRealPTY() async throws {
        try await withTerminalFixture { root, transport, session, captureChild in
            let ready = TestGate()
            let metaReceived = TestGate()
            defer { ready.open(); metaReceived.open() }
            var output = ""
            session.onOutput = { text in
                output += text
                if output.contains("LITHE_CURSOR_READY") { ready.open() }
                if output.contains("LITHE_META_OK") || output.contains("LITHE_META_BAD") { metaReceived.open() }
            }
            var display = TerminalDisplayConfiguration()
            display.cursorShape = .underline; display.cursorBlink = false
            session.applyDisplayConfiguration(display)
            var launch = TerminalShellConfiguration()
            launch.shell = .bash; launch.loginShell = false
            launch.arguments = ["--noprofile", "--norc", "-c", #"stty -echo -icanon min 1 time 0; printf '\033[6 qLITHE_CURSOR_READY'; IFS= read -r -n 2 key; if [[ "$key" == $'\ex' ]]; then printf 'LITHE_META_OK'; else printf 'LITHE_META_BAD'; fi; IFS= read -r -n 1 done"#]
            session.start(configuration: launch, context: .init(projectURL: root))
            try captureChild()
            #expect(transport.view.getTerminal().options.cursorStyle == .steadyUnderline)
            try #require(await ready.waitUntilOpen())
            let firstPID = try #require(transport.processID)
            #expect(transport.view.getTerminal().options.cursorStyle == .steadyBar)
            display.copyOnSelect = true; display.scrollSensitivity = 1.5
            session.applyDisplayConfiguration(display)
            #expect(transport.view.getTerminal().options.cursorStyle == .steadyBar)
            let optionX = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
                windowNumber: 0, context: nil, characters: "≈", charactersIgnoringModifiers: "x",
                isARepeat: false, keyCode: 7
            ))
            transport.view.keyDown(with: optionX)
            try #require(await metaReceived.waitUntilOpen())
            #expect(output.contains("LITHE_META_OK"))
            session.restart()
            try captureChild()
            #expect(transport.processID != firstPID)
            // Inspect synchronously before the new process can publish output
            // and override the user's default through another DECSCUSR.
            #expect(transport.view.getTerminal().options.cursorStyle == .steadyUnderline)
        }
    }

    @Test
    func typographyKeepsRealPTYAndApplicationArrowInput() async throws {
        try await withTerminalFixture { root, transport, session, captureChild in
            transport.view.setFrameSize(CGSize(width: 800, height: 480))
            let ready = TestGate()
            let modeChecked = TestGate()
            let done = TestGate()
            defer { ready.open(); modeChecked.open(); done.open() }
            var output = ""
            session.onOutput = { text in
                output += text
                if output.contains("LITHE_READY") { ready.open() }
                if output.contains("LITHE_MODE_OK") { modeChecked.open() }
                if output.contains("LITHE_DONE") { done.open() }
            }
            var configuration = TerminalShellConfiguration()
            configuration.shell = .bash
            configuration.loginShell = false
            // The child enables DECCKM, waits for the test's typography update,
            // then checks the emulator's real reply and native Up-arrow bytes.
            let script = #"""
            stty raw -echo
            printf '\033[?1hLITHE_READY\n'
            IFS= read -r -n 1 trigger
            printf '\033[?1$p'
            IFS= read -r -d y reply
            if [[ "$reply" == $'\e[?1;1$' ]]; then printf 'LITHE_MODE_OK\n'; else printf 'LITHE_MODE_BAD\n'; fi
            IFS= read -r -n 3 arrow
            if [[ "$arrow" == $'\eOA' ]]; then printf 'LITHE_KEY_OK\n'; else printf 'LITHE_KEY_BAD\n'; fi
            printf 'LITHE_SIZE:'; stty size
            printf 'LITHE_DONE\n'
            IFS= read -r -n 1 finish
            """#
            configuration.arguments = ["--noprofile", "--norc", "-c", script]
            session.start(configuration: configuration, context: .init(projectURL: root))
            try captureChild()
            try #require(await ready.waitUntilOpen())
            let pid = try #require(transport.processID)
            let surface = transport.nativeView
            let emulator = transport.view.getTerminal()
            var display = TerminalDisplayConfiguration()
            display.fontSize = 18; display.lineSpacing = 1.3
            #expect(transport.applyDisplayConfiguration(display).isEmpty)
            #expect(transport.processID == pid)
            let sameSurface = transport.nativeView === surface
            #expect(sameSurface)
            #expect(transport.view.getTerminal() === emulator)
            try transport.send(Data("x".utf8))
            try #require(await modeChecked.waitUntilOpen())
            let arrow = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{f700}",
                charactersIgnoringModifiers: "\u{f700}", isARepeat: false, keyCode: 126
            ))
            transport.view.keyDown(with: arrow)
            try #require(await done.waitUntilOpen())
            #expect(output.contains("LITHE_KEY_OK"))
            #expect(output.contains("LITHE_SIZE:\(emulator.rows) \(emulator.cols)"))
            #expect(transport.processID == pid)
            #expect(session.isRunning)
        }
    }

    @Test
    func realShellReceivesLiteralArgumentsEnvironmentAndWorkingDirectory() async throws {
        try await withTerminalFixture { root, terminal, session, captureChild in
            var configuration = TerminalShellConfiguration()
            configuration.shell = .bash
            configuration.loginShell = false
            configuration.arguments = ["--noprofile", "--norc", "-c",
                "printf 'LITHE_CWD:<%s>\\n' \"$PWD\"; printf 'LITHE_ARG:<%s>\\n' \"$@\"; printf 'LITHE_ENV:<%s>\\nLITHE_EMPTY:<%s>\\nLITHE_HOME:<%s>\\nLITHE_DONE\\n' \"$LITHE_TEST_VALUE\" \"${LITHE_TEST_EMPTY+x}\" \"${HOME+x}\"",
                "fixture", "a b", "", "$(literal)", "-l"]
            configuration.environment = [.init(name: "LITHE_TEST_VALUE", value: "literal=$x `value`"),
                                         .init(name: "LITHE_TEST_EMPTY", value: ""), .init(name: "HOME", value: nil)]
            let outputReady = TestGate()
            let exited = TestGate()
            var output = ""
            session.onOutput = { text in
                output += text
                if output.contains("LITHE_DONE") { outputReady.open() }
            }
            let observation = session.$lastExitCode.sink { if $0 != nil { exited.open() } }
            defer { observation.cancel(); outputReady.open(); exited.open() }
            session.start(configuration: configuration, context: .init(projectURL: root))
            try captureChild()
            #expect(await outputReady.waitUntilOpen())
            #expect(await exited.waitUntilOpen())
            let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
            let cwdLine = try #require(normalized.split(separator: "\n").first { $0.hasPrefix("LITHE_CWD:<") })
            let actualDirectory = String(cwdLine.dropFirst("LITHE_CWD:<".count).dropLast())
            // macOS may spell the same directory with /var or /private/var.
            // Compare filesystem identity instead of Foundation's path spelling.
            let actual = try FileManager.default.attributesOfItem(atPath: actualDirectory)
            let expected = try FileManager.default.attributesOfItem(atPath: root.path)
            #expect(actual[.systemNumber] as? NSNumber == expected[.systemNumber] as? NSNumber)
            #expect(actual[.systemFileNumber] as? NSNumber == expected[.systemFileNumber] as? NSNumber)
            #expect(normalized.contains("LITHE_ARG:<a b>\nLITHE_ARG:<>\nLITHE_ARG:<$(literal)>\nLITHE_ARG:<-l>\n"))
            #expect(normalized.contains("LITHE_ENV:<literal=$x `value`>\nLITHE_EMPTY:<x>\nLITHE_HOME:<>\n"))
            #expect(session.lastExitCode == 0)
            #expect(session.lastError == nil)
            #expect(!session.isRunning)
        }
    }

    @Test
    func badInterpreterProducesNormalizedExitAndVisibleRetryError() async throws {
        try await withTerminalFixture { root, terminal, session, captureChild in
            let executable = root.appendingPathComponent("bad-interpreter")
            try Data("#!/nonexistent-lithe-fixture/interpreter\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            var configuration = TerminalShellConfiguration()
            configuration.shell = .custom
            configuration.customProgram = executable.path
            configuration.loginShell = false
            let exited = TestGate()
            let observation = session.$lastExitCode.sink { if $0 != nil { exited.open() } }
            defer { observation.cancel(); exited.open() }
            session.start(configuration: configuration, context: .init(projectURL: root))
            try captureChild()
            #expect(await exited.waitUntilOpen())
            #expect(session.lastExitCode == 127)
            #expect(session.lastError?.contains("127") == true)
            #expect(!session.isReady)
        }
    }

    @Test
    func nativePreparationResolvesRelativePathEntriesAndRejectsDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("fixture-shell"), withDestinationURL: URL(fileURLWithPath: "/bin/bash"))
        let terminal = MacTerminalTransport()
        let path = try terminal.resolveExecutablePath("fixture-shell", workingDirectory: root.path, environment: ["PATH": ":bin"])
        #expect(path == bin.appendingPathComponent("fixture-shell").path)
        #expect(throws: (any Error).self) { try terminal.resolveExecutablePath(bin.path, workingDirectory: root.path, environment: [:]) }
        var configuration = TerminalShellConfiguration()
        configuration.workingDirectory = .custom
        configuration.customDirectory = "missing"
        #expect(throws: (any Error).self) { try terminal.prepareShellLaunch(configuration, context: .init(projectURL: root)) }
        if geteuid() != 0 {
            let inaccessible = root.appendingPathComponent("no-search")
            try FileManager.default.createDirectory(at: inaccessible, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inaccessible.path)
            defer { _ = chmod(inaccessible.path, 0o700) }
            #expect(access(inaccessible.path, X_OK) != 0)
            configuration.customDirectory = inaccessible.path
            #expect(throws: (any Error).self) { try terminal.prepareShellLaunch(configuration, context: .init(projectURL: root)) }
        }
        #expect(MacTerminalProcessConnection.exitCode(fromWaitStatus: 42 << 8) == 42)
        #expect(MacTerminalProcessConnection.exitCode(fromWaitStatus: SIGTERM) == 128 + SIGTERM)
    }

    private func withTerminalFixture(
        _ operation: @MainActor (URL, MacTerminalTransport, TerminalSession, @MainActor () throws -> Void) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal settings \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = MacTerminalTransport()
        let session = TerminalSession(transport: terminal)
        var children: [MacTerminalProcessIdentity] = []
        // Freeze ownership immediately after start, before the first await can
        // deliver exit/reap callbacks. Never adopt an identity during cleanup.
        let captureChild: @MainActor () throws -> Void = {
            let pid = try #require(terminal.processID)
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            // Argument 1 includes zombies. A bad interpreter can already be
            // dead, but SwiftTerm's main-queue waitpid cannot reap it before
            // this synchronous capture. Read ownership without consuming exit.
            let bytes = configurationTestPIDInfo(pid, PROC_PIDTBSDINFO, 1, &info, size)
            try #require(bytes == size)
            try #require(info.pbi_ppid == UInt32(getpid()))
            let identity = MacTerminalProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec,
                                                     startMicroseconds: info.pbi_start_tvusec)
            if !children.contains(where: { $0 == identity }) { children.append(identity) }
        }
        do { try await operation(root, terminal, session, captureChild) }
        catch { await cleanUp(children, session: session); throw error }
        await cleanUp(children, session: session)
    }

    private func cleanUp(_ identities: [MacTerminalProcessIdentity], session: TerminalSession) async {
        session.stop()
        // Independent fallback uses the captured child identity and an exit
        // event, including pre-restart children if production stop regresses.
        for identity in identities { identity.signal(SIGKILL, in: identity.pid) }
        for identity in identities {
            let reaped = TestGate()
            let reaper = MacStoppedChildProcessReaper()
            reaper.reapWhenExited(identity.pid) { reaped.open() }
            #expect(await reaped.waitUntilOpen())
        }
        #expect(await MacTerminalProcessSession.waitForPendingStops())
    }
}
