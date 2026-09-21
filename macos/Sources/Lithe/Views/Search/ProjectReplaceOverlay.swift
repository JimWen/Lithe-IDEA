import AppKit
import SwiftUI

/// Owns replacement observation without moving drag state into the workbench.
struct ProjectReplaceOverlay: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.isProjectReplaceVisible {
            ZStack {
                Color.black.opacity(0.14).ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { model.isProjectReplaceVisible = false }
                ProjectReplaceFloatingPanel {
                    ProjectReplaceView(loadPreviewDocument: { await model.documentFeature.previewDocument(at: $0) })
                        .environmentObject(model)
                }
            }
            .background(ProjectReplaceKeyMonitor(
                isPresented: { model.isProjectReplaceVisible },
                dismiss: { model.isProjectReplaceVisible = false }
            ))
            .onDisappear { model.documentFeature.discardPreviewDocuments() }
        }
    }
}

private struct ProjectReplaceKeyMonitor: NSViewRepresentable {
    let isPresented: () -> Bool
    let dismiss: () -> Void

    func makeNSView(context: Context) -> ProjectReplaceKeyMonitorView {
        ProjectReplaceKeyMonitorView(isPresented: isPresented, dismiss: dismiss)
    }

    func updateNSView(_ view: ProjectReplaceKeyMonitorView, context: Context) {
        view.isPresented = isPresented
        view.dismiss = dismiss
    }

    static func dismantleNSView(_ view: ProjectReplaceKeyMonitorView, coordinator: ()) {
        view.removeKeyMonitor()
    }
}

/// Scopes replacement shortcuts to the native window hosting this overlay.
final class ProjectReplaceKeyMonitorView: NSView {
    var isPresented: () -> Bool
    var dismiss: () -> Void
    private var keyMonitor: Any?

    init(isPresented: @escaping () -> Bool, dismiss: @escaping () -> Void) {
        self.isPresented = isPresented
        self.dismiss = dismiss
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeKeyMonitor()
        guard window != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }
    }

    func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window,
              isPresented() else { return event }
        let textInput = window.firstResponder as? NSTextInputClient
        if event.keyCode == 53 {
            // Let the input method cancel marked text before treating Escape as dismissal.
            if textInput?.hasMarkedText() == true { return event }
            dismiss()
            return nil
        }

        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.contains(.command) else { return event }
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == .command && ["a", "c", "v", "x", "z"].contains(character) { return event }
        if modifiers == [.command, .shift] && ["z", "v"].contains(character) { return event }
        guard textInput != nil else { return nil }
        if modifiers == [.command, .option, .shift] && character == "v" { return event }
        // Native movement/selection and deletion use key codes, independent of keyboard layout.
        if modifiers == .command || modifiers == [.command, .shift] {
            switch event.keyCode {
            case 123...126, 51, 117: return event
            default: break
            }
        }
        return nil
    }

    func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
