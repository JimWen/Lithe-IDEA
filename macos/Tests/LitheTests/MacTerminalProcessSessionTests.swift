import Darwin
import Foundation
import LitheTerminalModule
import Testing
@testable import Lithe

@_silgen_name("proc_listallpids")
private func testTerminalListPIDs(_ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

@MainActor
struct MacTerminalProcessSessionTests {
    @Test
    func restartStopsBashAndResistantJobWithoutStoppingNewOrOtherSessions() async throws {
        let terminal = MacTerminalTransport()
        let other = MacTerminalTransport()
        let ready = TestGate()
        let restarted = TestGate()
        let surface = terminal.nativeView
        var output = ""
        var jobPID: pid_t?
        var owned: [MacTerminalProcessIdentity] = []
        terminal.onOutput = { data in
            output += String(decoding: data, as: UTF8.self)
            for line in output.components(separatedBy: .newlines) {
                let value = line.trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("LITHE_JOB:"), let pid = pid_t(value.dropFirst("LITHE_JOB:".count)) {
                    jobPID = pid
                    ready.open()
                }
                if value == "LITHE_RESTART_OK" { restarted.open() }
            }
        }
        do {
            let oldPID = try launchBash(terminal)
            if let identity = MacTerminalProcessIdentity.read(oldPID)?.identity { owned.append(identity) }
            let otherPID = try launchBash(other)
            if let identity = MacTerminalProcessIdentity.read(otherPID)?.identity { owned.append(identity) }
            // A foreground job has its own process group. Both it and the
            // interactive parent ignore HUP/TERM, forcing bounded escalation.
            try terminal.send(Data("trap '' HUP TERM; /bin/bash --noprofile --norc -c 'trap \"\" HUP TERM; printf \"\\nLITHE_%s:%s\\n\" JOB \"$$\"; exec /bin/sleep 30'\n".utf8))
            #expect(await ready.waitUntilOpen())
            let job = try #require(jobPID)
            #expect(Darwin.getsid(job) == oldPID)
            #expect(Darwin.getpgid(job) != Darwin.getpgid(oldPID))
            let oldIdentity = try #require(MacTerminalProcessIdentity.read(oldPID)?.identity)
            let jobIdentity = try #require(MacTerminalProcessIdentity.read(job)?.identity)
            owned.append(jobIdentity)

            terminal.stop()
            terminal.stop()
            let newPID = try launchBash(terminal)
            if let identity = MacTerminalProcessIdentity.read(newPID)?.identity { owned.append(identity) }
            #expect(await MacTerminalProcessSession.waitForPendingStops())
            #expect(!oldIdentity.isAlive(in: oldPID))
            #expect(!jobIdentity.isAlive(in: oldPID))
            #expect(newPID != oldPID)
            #expect(Darwin.kill(newPID, 0) == 0)
            #expect(Darwin.kill(otherPID, 0) == 0)
            #expect(terminal.isRunning)
            // Keep AnyObject identity outside the macro: Swift 6.2.4 crashes
            // lowering its generic reabstraction thunk for this expression.
            let preservesSurface = terminal.nativeView === surface
            #expect(preservesSurface)
            try terminal.send(Data("printf '\\nLITHE_%s\\n' RESTART_OK\n".utf8))
            #expect(await restarted.waitUntilOpen())

            // A changed start identity or another session cannot authorize a
            // delayed signal, even when a positive PID still exists.
            let otherIdentity = try #require(MacTerminalProcessIdentity.read(otherPID)?.identity)
            otherIdentity.signal(SIGKILL, in: oldPID)
            MacTerminalProcessIdentity(
                pid: otherPID, startSeconds: otherIdentity.startSeconds &+ 1,
                startMicroseconds: otherIdentity.startMicroseconds
            ).signal(SIGKILL, in: otherPID)
            #expect(Darwin.kill(otherPID, 0) == 0)
        } catch {
            let cleanupMembers = captureCleanupMembers(owned)
            terminal.stop()
            other.stop()
            #expect(await MacTerminalProcessSession.waitForPendingStops())
            #expect(await cleanup(cleanupMembers))
            throw error
        }
        let cleanupMembers = captureCleanupMembers(owned)
        terminal.stop()
        other.stop()
        #expect(await MacTerminalProcessSession.waitForPendingStops())
        #expect(await cleanup(cleanupMembers))
    }

    private func captureCleanupMembers(_ owned: [MacTerminalProcessIdentity]) -> [MacTerminalProcessIdentity] {
        // Independent fallback if the stop implementation under test regresses.
        // Freeze owned roots before enumeration so a readiness/parse failure
        // cannot leave an unrecorded foreground job behind when roots are killed.
        let roots = owned.filter { $0.isOwnedChild && Darwin.getsid($0.pid) == $0.pid }
        for root in roots where MacTerminalProcessIdentity.read(root.pid)?.identity == root {
            Darwin.kill(root.pid, SIGSTOP)
        }
        var cleanupMembers = owned
        let capacity = max(1024, Int(testTerminalListPIDs(nil, 0)) + 64)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = testTerminalListPIDs(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
        for pid in pids.prefix(max(0, min(Int(count), capacity))) where pid > 0 {
            guard roots.contains(where: { $0.pid == Darwin.getsid(pid) }),
                  let identity = MacTerminalProcessIdentity.read(pid)?.identity,
                  !cleanupMembers.contains(identity) else { continue }
            cleanupMembers.insert(identity, at: 0)
        }
        return cleanupMembers
    }

    private func cleanup(_ cleanupMembers: [MacTerminalProcessIdentity]) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            var remaining = false
            for identity in cleanupMembers {
                guard MacTerminalProcessIdentity.read(identity.pid)?.identity == identity else { continue }
                Darwin.kill(identity.pid, SIGKILL)
                var status: Int32 = 0
                Darwin.waitpid(identity.pid, &status, WNOHANG)
                remaining = remaining || MacTerminalProcessIdentity.read(identity.pid)?.identity == identity
            }
            if !remaining { return true }
            guard ContinuousClock.now < deadline else { return false }
            // test-stability: allow(swift-real-sleep) reason: bounded OS exit polling independently cleans up real PTY children if the terminal stop implementation fails.
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func launchBash(_ terminal: MacTerminalTransport) throws -> pid_t {
        try terminal.startProcess(
            TerminalProcessLaunch(
                title: nil, executablePath: "/bin/bash", arguments: ["--noprofile", "--norc", "-i"],
                workingDirectory: FileManager.default.temporaryDirectory.path
            ),
            environment: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin", "PS1": ""]
        )
    }
}
