import Darwin
import Foundation

protocol MacProcessGroupControlling: Sendable {
    func prepareForRootReap()
    func terminateAndWait(gracePeriod: TimeInterval, forcedTerminationTimeout: TimeInterval) -> Bool
}

/// Retains group ownership across root exit and failed cleanup attempts.
/// An unreaped child reserves the original PID; after reap, only continuous
/// member incarnations can authorize discovering or signalling descendants.
final class MacProcessGroup: MacProcessGroupControlling, @unchecked Sendable {
    let processGroupID: pid_t
    private let backend: any MacProcessGroupBackend
    private let lock = NSLock()
    private var rootReserved = true
    private var known: Set<MacProcessGroupMember> = []
    private var confirmedAbsent = false

    init(processGroupID: pid_t, backend: any MacProcessGroupBackend = MacNativeProcessGroupBackend()) {
        self.processGroupID = processGroupID
        self.backend = backend
    }

    func prepareForRootReap() {
        lock.withLock {
            _ = refresh()
            // This transition happens before waitpid, including when libproc
            // cannot inspect a very short-lived root that is already a zombie.
            rootReserved = false
        }
    }

    /// Runs only on the managed process's native cleanup worker.
    func terminateAndWait(gracePeriod: TimeInterval = 0.2, forcedTerminationTimeout: TimeInterval = 1) -> Bool {
        if step(signal: SIGTERM) == .absent { return true }
        if waitUntilExited(timeout: gracePeriod) { return true }
        if step(signal: SIGKILL) == .absent { return true }
        return waitUntilExited(timeout: forcedTerminationTimeout)
    }

    private func step(signal: Int32? = nil) -> MacProcessGroupPresence {
        lock.withLock {
            let state = refresh()
            if state == .present, let signal {
                // Descendants first lets a live parent reap them during grace.
                for identity in known where identity.pid != processGroupID {
                    backend.signal(signal, to: identity)
                }
                for identity in known where identity.pid == processGroupID {
                    backend.signal(signal, to: identity)
                }
            }
            return state
        }
    }

    /// Called under lock. No wait/sleep or user callback runs under this lock.
    private func refresh() -> MacProcessGroupPresence {
        if confirmedAbsent { return .absent }
        if backend.presence(of: processGroupID) == .absent {
            confirmedAbsent = true
            known.removeAll()
            return .absent
        }
        let anchors = known.filter { backend.member($0.pid) == $0 }
        guard rootReserved || !anchors.isEmpty else { return .unknown }
        let discovered = backend.members(of: processGroupID)
        // The same old incarnation must span enumeration; a reused group ID
        // alone never extends ownership. Incomplete queries retain known IDs.
        guard rootReserved || anchors.contains(where: { backend.member($0.pid) == $0 }) else {
            return .unknown
        }
        // A failed query is not evidence of death. Keep that identity so a
        // later retry can recover it even if the other anchors have exited.
        known = known.filter { identity in
            guard let current = backend.member(identity.pid) else { return true }
            return current == identity
        }
        if let discovered {
            guard known.count + discovered.count <= 65_536 else { return .unknown }
            known.formUnion(discovered)
        }
        return .present
    }

    private func waitUntilExited(timeout: TimeInterval) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))
        while step() != .absent {
            guard ContinuousClock.now < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}
