import Combine
import Darwin
import Foundation
import LitheTerminalModule
import Testing
@testable import Lithe

@Suite("Native terminal configuration", .serialized)
@MainActor
struct MacTerminalConfigurationTests {
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
        var child: MacTerminalProcessIdentity?
        // Freeze ownership immediately after start, before the first await can
        // deliver exit/reap callbacks. Never adopt an identity during cleanup.
        let captureChild: @MainActor () throws -> Void = {
            let pid = try #require(terminal.processID)
            let process = try #require(MacTerminalProcessIdentity.read(pid))
            try #require(process.info.pbi_ppid == UInt32(getpid()))
            child = process.identity
        }
        do { try await operation(root, terminal, session, captureChild) }
        catch { await cleanUp(child, session: session); throw error }
        await cleanUp(child, session: session)
    }

    private func cleanUp(_ identity: MacTerminalProcessIdentity?, session: TerminalSession) async {
        session.stop()
        // Independent fallback uses the captured child identity and an exit
        // event, so assertion failures cannot strand a PTY or block a thread.
        if let identity { identity.signal(SIGKILL, in: identity.pid) }
        if let pid = identity?.pid {
            let reaped = TestGate()
            let reaper = MacStoppedChildProcessReaper()
            reaper.reapWhenExited(pid) { reaped.open() }
            #expect(await reaped.waitUntilOpen())
        }
        #expect(await MacTerminalProcessSession.waitForPendingStops())
    }
}
