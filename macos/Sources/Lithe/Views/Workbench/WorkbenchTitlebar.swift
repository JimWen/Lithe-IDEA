import AppKit
import SwiftUI

/// Hosts project controls above AppKit's tab strip. Keeping them in the native
/// titlebar lets tab dragging, fullscreen and content safe areas share one layout.
struct WorkbenchTitlebar<Content: View>: NSViewRepresentable {
    var content: Content

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.windowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: AttachmentView, context: Context) {
        context.coordinator.update(content: content)
        context.coordinator.attach(to: nsView.window)
    }

    func makeCoordinator() -> Coordinator { Coordinator(content: content) }

    static func dismantleNSView(_ nsView: AttachmentView, coordinator: Coordinator) {
        nsView.windowChanged = nil
        coordinator.attach(to: nil)
    }

    final class AttachmentView: NSView {
        var windowChanged: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowChanged?(window)
        }
    }

    @MainActor
    final class ContentModel: ObservableObject {
        @Published var content: Content
        init(content: Content) { self.content = content }
    }

    struct HostedContent: View {
        @ObservedObject var model: ContentModel
        var body: some View { model.content }
    }

    @MainActor
    final class Coordinator {
        let host: NSHostingView<HostedContent>
        private let contentModel: ContentModel
        private let accessory = NSTitlebarAccessoryViewController()
        private let toolbar = NSToolbar(identifier: "lithe-workbench")
        private weak var window: NSWindow?
        private var previousToolbar: NSToolbar?
        private var resizeObserver: NSObjectProtocol?
        private static var trafficLightInset: CGFloat { 76 }

        init(content: Content) {
            let contentModel = ContentModel(content: content)
            self.contentModel = contentModel
            host = NSHostingView(rootView: HostedContent(model: contentModel))
            // AppKit controls the accessory height; the hosting view must not
            // impose its SwiftUI ideal size on the titlebar's constraints.
            host.sizingOptions = []
            accessory.layoutAttribute = .right
            accessory.view = host
            toolbar.allowsUserCustomization = false
        }

        func update(content: Content) {
            // Replacing NSHostingView.rootView tears down presented menus and
            // popovers during unrelated workbench updates. Keep one hosting root.
            contentModel.content = content
        }

        func attach(to newWindow: NSWindow?) {
            guard window !== newWindow else { return }
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver = nil
            if let window {
                if let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                    window.removeTitlebarAccessoryViewController(at: index)
                }
                if window.toolbar === toolbar { window.toolbar = previousToolbar }
            }
            window = newWindow
            guard let newWindow else { return }
            previousToolbar = newWindow.toolbar
            newWindow.toolbarStyle = .unifiedCompact
            newWindow.toolbar = toolbar
            updateWidth()
            newWindow.addTitlebarAccessoryViewController(accessory)
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: newWindow, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateWidth() }
            }
        }

        private func updateWidth() {
            guard let window else { return }
            let width = max(0, window.frame.width - Self.trafficLightInset)
            guard host.frame.width != width else { return }
            host.setFrameSize(NSSize(width: width, height: LitheTheme.Metrics.toolbarHeight))
        }

        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        }
    }
}
