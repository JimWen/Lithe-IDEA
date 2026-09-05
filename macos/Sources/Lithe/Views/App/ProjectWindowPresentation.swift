import AppKit
import SwiftUI

/// Native window references and tab operations stay in the presentation layer.
/// Session ownership remains unchanged when AppKit merges or detaches tabs.
@MainActor
final class ProjectWindowPresentation: ObservableObject {
    @MainActor
    private final class WindowReference {
        weak var window: NSWindow?
        weak var observedGroup: NSWindowTabGroup?
        var groupObservation: NSKeyValueObservation?
        private weak var newTabButton: NSControl?
        private var windowUpdateObserver: NSObjectProtocol?

        init(_ window: NSWindow) {
            self.window = window
            windowUpdateObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideNewTabButton() }
            }
        }

        private func hideNewTabButton() {
            guard let window else { return }
            if let newTabButton, newTabButton.window === window {
                if !newTabButton.isHidden { newTabButton.isHidden = true }
                if newTabButton.isEnabled { newTabButton.isEnabled = false }
                return
            }
            guard window.tabGroup?.isTabBarVisible == true,
                  let frame = window.contentView?.superview else { return }

            // AppKit exposes no add-tab visibility property. Identify only the
            // native control's action, then use NSView.isHidden; never invoke
            // private APIs or remove AppKit-owned views/constraints. AppKit may
            // route through its internal forwarding action instead of the public
            // responder action. If that changes, leave unknown controls intact.
            func findButton(in view: NSView) -> NSControl? {
                guard view !== window.contentView else { return nil }
                if let control = view as? NSControl, let action = control.action,
                   action == #selector(NSResponder.newWindowForTab(_:)) ||
                   NSStringFromSelector(action) == "_newTabWithinWindow:" {
                    return control
                }
                for child in view.subviews {
                    if let button = findButton(in: child) { return button }
                }
                return nil
            }
            newTabButton = findButton(in: frame)
            if let newTabButton {
                newTabButton.isHidden = true
                newTabButton.isEnabled = false
                newTabButton.setAccessibilityElement(false)
            }
        }

        deinit {
            if let windowUpdateObserver { NotificationCenter.default.removeObserver(windowUpdateObserver) }
        }
    }

    private var windows: [UUID: WindowReference] = [:]
    private let manager: ProjectWindowManager
    var onCommandWindowAttached: ((NSWindow, UUID) -> Void)?
    var onCommandWindowClosed: ((UUID) -> Void)?

    var presentedWindowIDs: Set<UUID> {
        Set(windows.compactMap { $0.value.window == nil ? nil : $0.key })
    }

    init(manager: ProjectWindowManager) {
        self.manager = manager
        manager.focusWindow = { [weak self] id in
            self?.windows[id]?.window?.makeKeyAndOrderFront(nil)
        }
        manager.closeWindow = { [weak self] id in
            self?.windows[id]?.window?.performClose(nil)
        }
    }

    var canDetachSelectedProject: Bool {
        (windows[manager.activeWindowID]?.window?.tabbedWindows?.count ?? 0) > 1
    }

    func attach(_ window: NSWindow, id: UUID, layout: LitheWindowLayout) {
        guard manager.existingSessions(for: id) != nil else {
            // A delayed scene can arrive after its bounded presentation request
            // was cancelled. It must not resurrect an orphaned project window.
            window.close()
            return
        }
        let isNew = windows[id]?.window !== window
        if isNew { windows[id] = WindowReference(window) }
        let identifier = layout == .workspace ? "lithe-project" : "lithe-\(id)"
        let mode: NSWindow.TabbingMode = layout == .workspace ? .automatic : .disallowed
        // Setting native tab properties can rearrange windows and end menu
        // tracking, even when SwiftUI is only refreshing background state.
        if window.tabbingIdentifier != identifier { window.tabbingIdentifier = identifier }
        if window.tabbingMode != mode { window.tabbingMode = mode }
        if isNew, let parentID = manager.takeTabParent(for: id),
           let parent = windows[parentID]?.window {
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        if window.isKeyWindow { manager.activate(id) }
        onCommandWindowAttached?(window, id)
        observeTabGroups()
        if isNew { objectWillChange.send() }
    }

    func activate(_ id: UUID) {
        manager.activate(id)
        observeTabGroups()
    }

    func closed(_ id: UUID) {
        let closedWindow = windows[id]?.window
        let remaining = closedWindow?.tabbedWindows?.first { $0 !== closedWindow }
        let wasActive = manager.activeWindowID == id
        windows[id] = nil
        onCommandWindowClosed?(id)
        manager.windowClosed(id)
        if wasActive, let remaining {
            // Select after AppKit finishes removing the closed tab. A SwiftUI
            // scene disappearing must not leave the remaining project hidden.
            Task { @MainActor [weak self, weak remaining] in
                guard let self, let remaining,
                      let next = self.windows.first(where: { $0.value.window === remaining })?.key else { return }
                self.manager.activate(next)
                remaining.makeKeyAndOrderFront(nil)
            }
        }
    }

    func mergeAllProjectWindows() {
        guard let selected = windows[manager.activeWindowID]?.window,
              selected.tabbingIdentifier == "lithe-project" else { return }
        for id in manager.windowIDs {
            guard let window = windows[id]?.window, window !== selected,
                  window.tabbingIdentifier == selected.tabbingIdentifier,
                  !(selected.tabbedWindows?.contains(window) ?? false) else { continue }
            selected.addTabbedWindow(window, ordered: .above)
        }
        selected.makeKeyAndOrderFront(nil)
        observeTabGroups()
        objectWillChange.send()
    }

    func detachSelectedProject() {
        windows[manager.activeWindowID]?.window?.moveTabToNewWindow(nil)
        observeTabGroups()
        objectWillChange.send()
    }

    func closeSelectedProject() {
        windows[manager.activeWindowID]?.window?.performClose(nil)
    }

    func selectProjectTab(next: Bool) {
        guard let window = windows[manager.activeWindowID]?.window else { return }
        if next { window.selectNextTab(nil) } else { window.selectPreviousTab(nil) }
    }

    private func observeTabGroups() {
        for reference in windows.values {
            guard let group = reference.window?.tabGroup,
                  reference.observedGroup !== group else { continue }
            reference.observedGroup = group
            reference.groupObservation = group.observe(\.windows) { [weak self] _, _ in
                // Native drag-out/reorder also changes menu availability. Wait
                // until AppKit has finished assigning the new group to windows.
                Task { @MainActor [weak self] in
                    self?.observeTabGroups()
                    self?.objectWillChange.send()
                }
            }
        }
    }
}

struct ProjectWindowScene: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var windows: ProjectWindowManager
    let presentation: ProjectWindowPresentation
    let windowID: UUID

    init(windows: ProjectWindowManager, presentation: ProjectWindowPresentation, windowID: UUID) {
        self.windows = windows
        self.presentation = presentation
        self.windowID = windowID
        windows.acceptRestoredScene(windowID)
    }

    var body: some View {
        if let sessions = windows.existingSessions(for: windowID) {
            ProjectWindowContent(windows: windows, presentation: presentation,
                                 windowID: windowID, sessions: sessions)
        } else {
            // Scene delivery can outlive a cancelled presentation request. Only
            // opening/restoration paths may allocate a new session manager.
            Color.clear.onAppear {
                dismiss()
            }
        }
    }
}

private struct ProjectWindowContent: View {
    @Environment(\.openWindow) private var openWindow
    let windows: ProjectWindowManager
    let presentation: ProjectWindowPresentation
    let windowID: UUID
    @ObservedObject var sessions: ProjectSessionManager

    var body: some View {
        RootView(windowID: windowID, windowPresentation: presentation)
            .environmentObject(sessions)
            .environmentObject(sessions.activeModel)
            .onAppear {
                windows.presentWindow = { id in
                    openWindow(id: LitheWindowID.workspace, value: id)
                }
            }
    }
}
