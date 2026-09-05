import Foundation

@MainActor
struct MacCommandProjectionScheduler: CommandProjectionScheduling {
    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        schedule(after: 0, action)
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }
}
