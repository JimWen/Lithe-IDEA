import AppKit

/// Owns AppKit observation and weak window references. Merely keeping a last
/// active project ID does not grant that project keyboard or menu eligibility.
@MainActor
final class MacCommandEnvironmentObserver {
    private struct Registration {
        weak var window: NSWindow?
        let context: () -> ProjectCommandContext?
    }
    struct NativeState {
        var keyWindow: NSWindow?
        var isActive: Bool
        var isModal: Bool
    }
    private let readNativeState: () -> NativeState
    let feature: CommandEnvironmentFeatureModel
    private var registrations: [UUID: Registration] = [:]
    private var observers: [NSObjectProtocol] = []
    private var isStarted = false

    init(feature: CommandEnvironmentFeatureModel, readNativeState: (() -> NativeState)? = nil) {
        self.feature = feature
        self.readNativeState = readNativeState ?? {
            guard let application = NSApp else {
                return NativeState(keyWindow: nil, isActive: false, isModal: false)
            }
            let key = application.keyWindow
            return NativeState(keyWindow: key, isActive: application.isActive,
                               isModal: application.modalWindow != nil || key?.attachedSheet != nil || key?.sheetParent != nil)
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willCloseNotification, NSWindow.willBeginSheetNotification,
                     NSWindow.didEndSheetNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.isStarted, let menu = notification.object as? NSMenu else { return }
                self.feature.beginTracking(menu)
            }
        })
        observers.append(center.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.isStarted, let menu = notification.object as? NSMenu else { return }
                self.feature.endTracking(menu)
                self.refresh()
            }
        })
        refresh()
    }

    func register(_ window: NSWindow, id: UUID, context: @escaping () -> ProjectCommandContext?) {
        guard isStarted else { return }
        registrations[id] = Registration(window: window, context: context)
        refresh()
    }

    func unregister(_ id: UUID) {
        registrations[id] = nil
        refresh()
    }

    func refresh() {
        guard isStarted else { return }
        let state = readNativeState()
        let context = !state.isModal && state.isActive
            ? registrations.values.first(where: { $0.window === state.keyWindow && state.keyWindow != nil })?.context()
            : nil
        feature.update(context: context, isApplicationActive: state.isActive, isModal: state.isModal)
    }

    func stop() {
        isStarted = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        registrations.removeAll()
        feature.stop()
    }
}
