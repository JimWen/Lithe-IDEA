import AppKit
import SwiftUI
import LitheTerminalModule

struct TerminalSurfaceView: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var model: AppModel
    @State private var focusRequestID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            virtualEnvironmentStatus
            if let error = session.lastError {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        if let code = session.lastExitCode {
                            Text("The terminal exited with code \(Int(code)). Check the shell program and arguments.")
                                .textSelection(.enabled)
                        } else {
                            Text(LocalizedStringKey(error)).textSelection(.enabled)
                        }
                    } icon: { Image(systemName: "exclamationmark.triangle") }
                        .foregroundStyle(LitheTheme.warning)
                    HStack {
                        Button("Retry original launch", action: session.restart)
                            .disabled(session.isManagedProcess)
                        Button("Terminal Settings") { model.showSettings(category: .terminal) }
                    }.buttonStyle(LitheSecondaryButtonStyle())
                    Text("Retry uses this session's original configuration. Open a new terminal to use changed settings.")
                        .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                }.padding(12)
            }
            if let nativeView = session.nativeView as? NSView {
                TerminalNativeSurface(
                    nativeView: nativeView,
                    focusRequestID: focusRequestID,
                    showsWorkbenchBackground: model.workbenchBackgroundFeature.hasImage
                )
            } else {
                model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.editor
            }
        }
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.editor)
        .overlay {
            if let error = session.launchError {
                VStack(spacing: 8) {
                    Text("Unable to start terminal").font(.headline)
                    Text(error).font(LitheTheme.smallFont).textSelection(.enabled)
                    Text("Detect installed shells and choose a shell from the New Terminal menu.")
                        .font(LitheTheme.smallFont)
                }
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(20)
            }
        }
        .litheContextMenu {
            [
                .action("Copy", systemImage: "doc.on.doc", action: {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }),
                .action("Paste", systemImage: "doc.on.clipboard", action: {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }),
                .action("Select All", systemImage: "selection.pin.in.out", action: {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }),
                .separator,
                .action("Clear", systemImage: "eraser", action: session.clear),
                .action("Restart", systemImage: "arrow.clockwise", action: {
                    session.restart()
                    session.focus()
                }),
                .action("Close Terminal", systemImage: "xmark", action: {
                    model.requestCloseTerminalSession(session)
                })
            ]
        }
        .task(id: session.id) {
            requestInputFocus()
        }
    }

    @ViewBuilder private var virtualEnvironmentStatus: some View {
        switch session.virtualEnvironmentState {
        case .inactive, .deactivated: EmptyView()
        case .detecting: status("Detecting virtual environment…")
        case .activating(let path): status("Activating virtual environment…", path: path)
        case .activated(let path): status("Startup virtual environment", path: path)
        case .unconfirmed(let path): status("Virtual environment activation was not confirmed. Check your shell configuration.", path: path, warning: true)
        case .skipped(let reason): status(reason.message, warning: reason != .existingEnvironment)
        }
    }

    private func status(_ message: String, path: String? = nil, warning: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: warning ? "exclamationmark.triangle" : "terminal")
            Text(LocalizedStringKey(message)).lineLimit(2)
            if let path {
                Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).truncationMode(.middle).help(path)
            }
            Spacer(minLength: 0)
            if warning {
                Button("Terminal Settings") { model.showSettings(category: .terminal) }
                    .buttonStyle(.plain).foregroundStyle(LitheTheme.accent)
            }
        }.font(LitheTheme.smallFont)
            .foregroundStyle(warning ? LitheTheme.warning : LitheTheme.secondaryText)
            .padding(.horizontal, 10).padding(.vertical, 4)
    }

    private func requestInputFocus() {
        guard session.isRunning else { return }
        focusRequestID &+= 1
        session.focus()
    }
}

private struct TerminalNativeSurface: NSViewRepresentable {
    let nativeView: NSView
    let focusRequestID: Int
    let showsWorkbenchBackground: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalSurfaceHostView {
        let hostView = TerminalSurfaceHostView(frame: .zero)
        hostView.attach(nativeView)
        (nativeView as? WorkbenchBackgroundRendering)?
            .setWorkbenchBackgroundVisible(showsWorkbenchBackground)
        return hostView
    }

    func updateNSView(_ hostView: TerminalSurfaceHostView, context: Context) {
        hostView.attach(nativeView)
        (nativeView as? WorkbenchBackgroundRendering)?
            .setWorkbenchBackgroundVisible(showsWorkbenchBackground)
        guard context.coordinator.lastFocusRequestID != focusRequestID else { return }
        context.coordinator.lastFocusRequestID = focusRequestID
        DispatchQueue.main.async {
            guard nativeView.superview === hostView,
                  let window = nativeView.window,
                  window.firstResponder !== nativeView else { return }
            window.makeFirstResponder(nativeView)
        }
    }

    static func dismantleNSView(_ hostView: TerminalSurfaceHostView, coordinator: Coordinator) {
        hostView.detachCurrentView()
    }

    final class Coordinator: NSObject {
        var lastFocusRequestID = -1
    }
}

private final class TerminalSurfaceHostView: NSView {
    private weak var terminalView: NSView?

    func attach(_ view: NSView) {
        // A source host can receive one last update after the persistent
        // terminal view has already moved to its destination. Do not let that
        // stale host reclaim the view or detach it while switching sessions.
        if terminalView === view {
            guard view.superview === self else { return }
            view.frame = bounds
            return
        }
        if let terminalView, terminalView.superview === self {
            terminalView.removeFromSuperview()
        }
        view.removeFromSuperview()
        terminalView = view
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    override func layout() {
        super.layout()
        guard let terminalView, terminalView.superview === self else { return }
        terminalView.frame = bounds
    }

    func detachCurrentView() {
        guard let terminalView, terminalView.superview === self else { return }
        terminalView.removeFromSuperview()
        self.terminalView = nil
    }
}
