import Foundation

/// One physical cleanup, shared by native synchronous and asynchronous waiters.
/// A waiter's timeout or cancellation never restarts or cancels the worker.
final class MacProcessCleanupAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchGroup()
    private var result: Bool?
    private var observers: [@Sendable (Bool) -> Void] = []

    init() { completion.enter() }

    func complete(_ value: Bool) {
        let callbacks = lock.withLock { () -> [@Sendable (Bool) -> Void] in
            precondition(result == nil)
            result = value
            let callbacks = observers
            observers.removeAll()
            return callbacks
        }
        completion.leave()
        callbacks.forEach { $0(value) }
    }

    func observe(_ callback: @escaping @Sendable (Bool) -> Void) {
        let completed = lock.withLock { () -> Bool? in
            if let result { return result }
            observers.append(callback)
            return nil
        }
        if let completed { callback(completed) }
    }

    func value() async -> Bool {
        await withCheckedContinuation { continuation in
            observe { continuation.resume(returning: $0) }
        }
    }

    /// Call only on a native runner, never a cooperative executor or reaper.
    func wait(timeout: TimeInterval) -> Bool {
        guard completion.wait(timeout: .now() + max(0, timeout)) == .success else { return false }
        return lock.withLock { result == true }
    }
}
