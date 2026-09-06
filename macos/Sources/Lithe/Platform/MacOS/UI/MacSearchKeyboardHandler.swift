import AppKit
import SwiftUI

/// Routes popup navigation without taking text editing or IME keys away from
/// the field editor. Each monitor lives exactly as long as its attached view.
struct MacSearchKeyboardHandler: NSViewRepresentable {
    var isEnabled: () -> Bool
    var handle: (MacSearchKeyboardAction) -> Bool

    func makeNSView(context: Context) -> MacSearchKeyView { MacSearchKeyView() }
    func updateNSView(_ view: MacSearchKeyView, context: Context) {
        view.isEnabled = isEnabled
        view.handle = handle
    }
    static func dismantleNSView(_ view: MacSearchKeyView, coordinator: ()) {
        view.removeMonitor()
    }
}

enum MacSearchKeyboardAction: Equatable {
    case move(Int), category(Int), submit, dismiss

    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Self? {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        if keyCode == 48, flags.isSubset(of: [.shift]) {
            return .category(flags.contains(.shift) ? -1 : 1)
        }
        guard flags.isEmpty else { return nil }
        switch keyCode {
        case 125: return .move(1)
        case 126: return .move(-1)
        case 36, 76: return .submit
        case 53: return .dismiss
        default: return nil
        }
    }
}

final class MacSearchKeyView: NSView {
    var isEnabled: () -> Bool = { false }
    var handle: ((MacSearchKeyboardAction) -> Bool)?
    private var monitor: Any?
    private var closeObserver: NSObjectProtocol?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard let window else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in self?.removeMonitor() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.consume(event) == true ? nil : event
        }
    }

    func consume(_ event: NSEvent) -> Bool {
        guard monitor != nil, isEnabled(), let window, window.isKeyWindow,
              event.window === window, window.attachedSheet == nil,
              (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
              let action = MacSearchKeyboardAction.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags)
        else { return false }
        return handle?(action) ?? false
    }

    func removeMonitor() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
