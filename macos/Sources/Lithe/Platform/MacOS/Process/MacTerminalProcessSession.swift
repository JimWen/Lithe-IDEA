import Darwin
import Foundation

@_silgen_name("proc_listallpids")
private func terminalListAllPIDs(_ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

@_silgen_name("proc_pidinfo")
private func terminalPIDInfo(
    _ pid: pid_t, _ flavor: Int32, _ argument: UInt64,
    _ buffer: UnsafeMutableRawPointer?, _ size: Int32
) -> Int32

/// Identifies an incarnation of a process, independently of its reusable PID.
struct MacTerminalProcessIdentity: Equatable, Sendable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func read(_ pid: pid_t) -> (identity: Self, info: proc_bsdinfo)? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard terminalPIDInfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (Self(pid: pid, startSeconds: info.pbi_start_tvsec,
                     startMicroseconds: info.pbi_start_tvusec), info)
    }

    func isAlive(in sessionID: pid_t) -> Bool {
        guard let current = Self.read(pid), current.identity == self,
              current.info.pbi_status != SZOMB else { return false }
        return Darwin.getsid(pid) == sessionID
    }

    var isOwnedChild: Bool {
        guard let current = Self.read(pid), current.identity == self else { return false }
        return current.info.pbi_status != SZOMB && current.info.pbi_ppid == UInt32(Darwin.getpid())
    }

    func signal(_ value: Int32, in sessionID: pid_t) {
        // Recheck immediately before each positive-PID signal. In particular,
        // delayed escalation must never adopt a replacement process or group.
        guard isAlive(in: sessionID) else { return }
        if Darwin.kill(pid, value) != 0, errno != ESRCH {
            NSLog("Lithe could not signal stopped terminal process %d: %d", pid, errno)
        }
    }
}

/// Stops the owned PTY session, including jobs in separate process groups.
/// SwiftTerm closes the transport, but interactive shells can ignore its TERM.
final class MacTerminalProcessSession: Sendable {
    private static let queue = DispatchQueue(label: "app.lithe.terminal-session-stop", qos: .utility)
    private static let pendingStops = DispatchGroup()
    private let root: MacTerminalProcessIdentity

    init?(processID: pid_t) {
        guard let process = MacTerminalProcessIdentity.read(processID),
              process.info.pbi_ppid == UInt32(Darwin.getpid()) else { return nil }
        root = process.identity
    }

    func terminate(stopTransport: () -> Void) {
        // Snapshot before SwiftTerm can terminate/reap the root and orphan its
        // jobs. This is one finite OS query, with no wait on the UI thread.
        let current = MacTerminalProcessIdentity.read(root.pid)
        let ownsRoot = current?.identity == root
            && current?.info.pbi_ppid == UInt32(Darwin.getpid())
        // forkpty may return before the child establishes its session. Keep
        // that owned root for the bounded retry, never scan the host session.
        let discovered = ownsRoot && Darwin.getsid(root.pid) == root.pid ? Self.members(in: root.pid) : []
        let members = ownsRoot ? [root] + discovered.filter { $0 != root } : []
        stopTransport()
        guard !members.isEmpty else { return }

        Self.pendingStops.enter()
        // The native monitor is cancelled before signals can produce an old
        // exit callback on the persistent surface after its next launch.
        Self.signal(members, root: root, value: SIGHUP)
        Self.signal(members, root: root, value: SIGCONT)
        Self.queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [root] in
            let remaining = Self.refresh(members, root: root)
            guard !remaining.isEmpty else { Self.pendingStops.leave(); return }
            Self.signal(remaining, root: root, value: SIGKILL)
            Self.queue.asyncAfter(deadline: .now() + .seconds(1)) {
                let survivors = Self.refresh(remaining, root: root)
                // Include any job forked during escalation, without reopening
                // ownership once the last captured identity has disappeared.
                Self.signal(survivors, root: root, value: SIGKILL)
                if !survivors.isEmpty {
                    NSLog("Lithe terminal stop reached its deadline with %d live processes", survivors.count)
                }
                Self.pendingStops.leave()
            }
        }
    }

    /// Application termination joins the same bounded cleanup as tab close and
    /// Restart, including stops whose transport has already been released.
    @discardableResult
    static func waitForPendingStops() async -> Bool {
        await withCheckedContinuation { continuation in
            // Only this native worker blocks. Keep a separate deadline even if
            // a future cleanup regression fails to balance the group.
            DispatchQueue.global(qos: .utility).async {
                let completed = pendingStops.wait(timeout: .now() + .seconds(2)) == .success
                if !completed { NSLog("Lithe terminal cleanup exceeded its shutdown deadline") }
                continuation.resume(returning: completed)
            }
        }
    }

    private static func refresh(
        _ known: [MacTerminalProcessIdentity], root: MacTerminalProcessIdentity
    ) -> [MacTerminalProcessIdentity] {
        let surviving = known.filter { $0.isAlive(in: root.pid) || ($0 == root && $0.isOwnedChild) }
        guard !surviving.isEmpty else { return [] }
        let discovered = members(in: root.pid)
        // Never discard known ownership on an incomplete OS enumeration, and
        // do not extend it if every original anchor disappeared during the scan.
        guard surviving.contains(where: { $0.isAlive(in: root.pid) }) else { return surviving }
        return surviving + discovered.filter { !surviving.contains($0) }
    }

    private static func members(in sessionID: pid_t) -> [MacTerminalProcessIdentity] {
        let capacity = max(1024, Int(terminalListAllPIDs(nil, 0)) + 64)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = terminalListAllPIDs(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else {
            NSLog("Lithe could not enumerate terminal session processes: %d", errno)
            return []
        }
        return pids.prefix(min(Int(count), capacity)).compactMap { pid in
            guard pid > 0, Darwin.getsid(pid) == sessionID,
                  let process = MacTerminalProcessIdentity.read(pid),
                  process.info.pbi_status != SZOMB else { return nil }
            return process.identity
        }
    }

    private static func signal(
        _ members: [MacTerminalProcessIdentity], root: MacTerminalProcessIdentity, value: Int32
    ) {
        for member in members where member != root { member.signal(value, in: root.pid) }
        if members.contains(root) { root.signal(value, in: root.pid) }
    }
}
