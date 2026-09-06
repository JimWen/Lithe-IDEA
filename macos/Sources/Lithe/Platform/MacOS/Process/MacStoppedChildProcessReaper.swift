import Darwin
import Foundation

/// Reaps direct child processes after a platform-owned stop operation.
///
/// Some native terminal libraries send the termination signal themselves but
/// can miss their eventual `waitpid` callback. Keeping a second process source
/// prevents an exited debuggee from remaining as a zombie under Lithe.
final class MacStoppedChildProcessReaper: @unchecked Sendable {
    typealias Completion = @Sendable () -> Void

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "app.lithe.stopped-child-process-reaper",
        qos: .utility
    )
    private var sources: [pid_t: DispatchSourceProcess] = [:]
    private var completions: [pid_t: [Completion]] = [:]

    func reapWhenExited(
        _ processID: pid_t,
        completion: @escaping Completion = {}
    ) {
        guard processID > 0 else {
            completion()
            return
        }

        let alreadyExited = lock.withLock { () -> Bool in
            // A duplicate stop shares the active source. Creating a second
            // inactive source and discarding it traps inside libdispatch.
            if sources[processID] != nil {
                completions[processID, default: []].append(completion)
                return false
            }

            var waitStatus: Int32 = 0
            errno = 0
            let result = Darwin.waitpid(processID, &waitStatus, WNOHANG)
            if result == processID || (result == -1 && errno == ECHILD) {
                return true
            }

            let source = DispatchSource.makeProcessSource(
                identifier: processID, eventMask: .exit, queue: queue
            )
            completions[processID] = [completion]
            sources[processID] = source
            // Retain the reaper until the child exits even if its terminal
            // session has already closed. The handler never runs under this lock.
            source.setEventHandler { [self] in reap(processID) }
            source.activate()
            return false
        }
        if alreadyExited { completion() }
    }

    private func reap(_ processID: pid_t) {
        var waitStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = Darwin.waitpid(processID, &waitStatus, 0)
        } while waitResult == -1 && errno == EINTR

        let state = lock.withLock { () -> (DispatchSourceProcess?, [Completion]) in
            let source = sources.removeValue(forKey: processID)
            let callbacks = completions.removeValue(forKey: processID) ?? []
            return (source, callbacks)
        }
        state.0?.cancel()
        state.1.forEach { $0() }
    }
}
