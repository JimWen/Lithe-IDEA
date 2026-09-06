import Darwin
import Foundation
import Testing
@testable import Lithe

struct MacStoppedChildProcessReaperTests {
    @Test
    func duplicateStopsShareOneSourceAndCompleteEachCallbackOnce() async throws {
        // cat cannot exit until the parent releases stdin. This guarantees both
        // registrations use the live-child branch that previously trapped.
        let child = try ReaperChildFixture()
        let first = TestGate(), second = TestGate()
        let calls = ReaperCallbackCounts()
        let reaper = MacStoppedChildProcessReaper()
        reaper.reapWhenExited(child.pid) { calls.record(0); first.open() }
        reaper.reapWhenExited(child.pid) { calls.record(1); second.open() }
        #expect(!first.isOpen && !second.isOpen)
        child.releaseInput()
        #expect(await first.waitUntilOpen())
        #expect(await second.waitUntilOpen())
        #expect(calls.snapshot == [1, 1])
        var status: Int32 = 0
        errno = 0
        #expect(Darwin.waitpid(child.pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
        #expect(await child.cleanup())
    }
}

private final class ReaperCallbackCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = [0, 0]
    func record(_ index: Int) { lock.withLock { counts[index] += 1 } }
    var snapshot: [Int] { lock.withLock { counts } }
}

private final class ReaperChildFixture {
    let pid: pid_t
    private var input: Int32

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        var transferred = false
        defer {
            Darwin.close(descriptors[0])
            if !transferred { Darwin.close(descriptors[1]) }
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, descriptors[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0 else { throw POSIXError(.EIO) }
        var arguments = [strdup("/bin/cat"), nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { arguments.forEach { free($0) } }
        var childPID: pid_t = 0
        let result = posix_spawn(&childPID, "/bin/cat", &actions, nil, &arguments, &environment)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        pid = childPID
        input = descriptors[1]
        transferred = true
    }

    func releaseInput() {
        guard input >= 0 else { return }
        Darwin.close(input)
        input = -1
    }

    func cleanup() async -> Bool {
        releaseInput()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var sentKill = false
        while true {
            var status: Int32 = 0
            errno = 0
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) { return true }
            guard ContinuousClock.now < deadline else { return false }
            if result == 0 && !sentKill { Darwin.kill(pid, SIGKILL); sentKill = true }
            // test-stability: allow(swift-real-sleep) reason: bounded waitpid polling is the independent OS cleanup fallback if the reaper callback under test fails.
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    deinit { releaseInput() }
}
