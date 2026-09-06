import AppKit

/// An unmodified link click waits for macOS's double-click interval so the
/// second click can claim the gesture for selection. Own and cancel the delay
/// with the persistent terminal surface, never with a SwiftUI render pass.
@MainActor
final class MacTerminalLinkActivation {
    typealias Schedule = (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> () -> Void
    private let schedule: Schedule
    private var cancelPending: (() -> Void)?
    private var pendingID: UUID?

    init(schedule: @escaping Schedule = { delay, action in
        let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }) {
        self.schedule = schedule
    }

    func submit(_ action: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        let id = UUID()
        pendingID = id
        cancelPending = schedule(NSEvent.doubleClickInterval) { [weak self] in
            guard let self, self.pendingID == id else { return }
            self.pendingID = nil
            self.cancelPending = nil
            action()
        }
    }

    func cancel() {
        pendingID = nil
        cancelPending?()
        cancelPending = nil
    }

    deinit { cancelPending?() }
}
