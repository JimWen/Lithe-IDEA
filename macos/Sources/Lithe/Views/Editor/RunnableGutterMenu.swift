import SwiftUI
import LitheCoreContracts

/// Shared menu projection for editor runnable markers. Both mouse buttons use
/// this view so the actions remain identical and revision checks stay at the
/// execution boundary.
struct RunnableGutterMenu: View {
    let runnable: DocumentRunnable
    let onRun: () -> Void
    let onDebug: () -> Void
    let onModify: () -> Void

    var body: some View {
        Group {
            Button("Run ‘\(runnable.displayName)’", action: onRun)
            Button("Debug ‘\(runnable.displayName)’", action: onDebug)
            Divider()
            Button("Modify Run Configuration…", action: onModify)
        }
        .accessibilityElement(children: .contain)
    }
}
