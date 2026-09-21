import SwiftUI

/// Keeps source/preview resizing local while both panes retain their minimum usable width.
struct SourcePreviewSplitView<Editor: View, Preview: View>: View {
    let editor: Editor
    let preview: Preview

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - SplitHandleView.thickness)
            let minimum = min(200, available / 2)
            LitheSplitPaneView(
                axis: .horizontal,
                placement: .leading,
                defaultSize: available / 2,
                minimum: minimum,
                maximum: max(minimum, available - minimum),
                flexibleMinimum: minimum,
                sized: { editor },
                flexible: { preview }
            )
        }
    }
}
