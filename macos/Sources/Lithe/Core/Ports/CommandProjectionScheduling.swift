import Foundation

/// Schedules sampling after the synchronous mutation which emitted willChange.
/// The returned cancellation is idempotent and releases pending work on teardown.
@MainActor
protocol CommandProjectionScheduling {
    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) -> () -> Void
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> () -> Void
}
