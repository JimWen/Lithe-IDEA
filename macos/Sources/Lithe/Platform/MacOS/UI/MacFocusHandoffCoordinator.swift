import AppKit
import Foundation

/// Synchronously detaches focus from the previous responder (typically the
/// native code editor) and buffers early non-shortcut keystrokes across the
/// brief SwiftUI mount/layout boundary until the destination responder claims
/// first responder.
///
/// The buffer is strictly bounded in both duration and capacity and cancels
/// immediately on Escape, modifier shortcuts, window deactivation, or target
/// dismissal so input can never be trapped.
@MainActor
final class MacFocusHandoffCoordinator {
    static let shared = MacFocusHandoffCoordinator()
    nonisolated static let maxBufferedEvents = 32
    nonisolated static let defaultTimeout: TimeInterval = 0.25

    enum KeyDecision: Equatable {
        case buffer
        case cancelAndPassThrough
        case passThrough
    }

    private(set) var pendingTarget: FocusHandoffTarget?
    private(set) var targetWindowNumber: Int?
    private(set) var bufferedEvents: [NSEvent] = []
    private var deadline: Date?
    private var keyMonitor: Any?
    private var timeoutWorkItem: DispatchWorkItem?
    private let timeout: TimeInterval
    private let now: () -> Date
    private let installsEventMonitor: Bool

    init(
        timeout: TimeInterval = MacFocusHandoffCoordinator.defaultTimeout,
        now: @escaping () -> Date = Date.init,
        installsEventMonitor: Bool = true
    ) {
        self.timeout = timeout
        self.now = now
        self.installsEventMonitor = installsEventMonitor
    }

    func begin(
        to target: FocusHandoffTarget,
        in window: NSWindow? = nil
    ) {
        cancel()
        let resolvedWindow = window ?? NSApp?.keyWindow
        if let resolvedWindow {
            resolvedWindow.makeFirstResponder(nil)
        }
        pendingTarget = target
        targetWindowNumber = resolvedWindow?.windowNumber
        deadline = now().addingTimeInterval(timeout)

        guard installsEventMonitor else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                self.intercept(event)
            }
        }
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.cancel(for: target)
            }
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    func cancel(for target: FocusHandoffTarget? = nil) {
        if let target, pendingTarget != target { return }
        pendingTarget = nil
        targetWindowNumber = nil
        deadline = nil
        bufferedEvents.removeAll()
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    @discardableResult
    func complete(
        for target: FocusHandoffTarget,
        responder: NSResponder,
        in window: NSWindow?,
        replay: (([NSEvent]) -> Void)? = nil
    ) -> [NSEvent] {
        let matchedTarget = pendingTarget == target
        let events = matchedTarget ? bufferedEvents : []
        if matchedTarget {
            cancel()
        }
        if let window, window.firstResponder !== responder {
            window.makeFirstResponder(responder)
        }
        guard !events.isEmpty else { return [] }
        if let replay {
            replay(events)
        } else {
            let receiver = window?.firstResponder ?? responder
            for event in events {
                receiver.keyDown(with: event)
            }
        }
        return events
    }

    func intercept(_ event: NSEvent) -> NSEvent? {
        guard pendingTarget != nil else { return event }
        if let deadline, now() > deadline {
            cancel()
            return event
        }
        if let targetWindowNumber,
           let eventWindow = event.window,
           eventWindow.windowNumber != targetWindowNumber {
            cancel()
            return event
        }
        switch Self.classify(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
        case .buffer:
            if bufferedEvents.count < Self.maxBufferedEvents {
                bufferedEvents.append(event)
            }
            return nil
        case .cancelAndPassThrough:
            cancel()
            return event
        case .passThrough:
            return event
        }
    }

    static func classify(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> KeyDecision {
        // Escape always cancels focus handoff so popups dismiss immediately.
        if keyCode == 53 {
            return .cancelAndPassThrough
        }
        let modifiers = modifierFlags.intersection([.command, .control, .option])
        if !modifiers.isEmpty {
            return .cancelAndPassThrough
        }
        return .buffer
    }
}
