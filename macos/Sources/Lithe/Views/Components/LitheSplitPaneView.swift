import SwiftUI

/// A two-pane split whose divider drag is confined to this container.
///
/// One pane has a tracked size and the other takes the remainder. The dragged
/// size lives here rather than in the hosting feature view, so moving a divider
/// invalidates only this container: `sized` and `flexible` were built by the
/// host's last body pass and are the same values on every re-evaluation, which
/// lets SwiftUI skip their bodies. That is the protection `WorkbenchWorkspaceSplitView`
/// already had and this generalizes to the Git, Run, and test tool windows.
struct LitheSplitPaneView<Sized: View, Flexible: View>: View {
    let axis: LitheSplitAxis
    let placement: LitheSplitPaneGeometry.Placement
    /// The size used until the user drags, re-supplied by the host every body
    /// pass. Hosts that derive it from live geometry keep following the window
    /// until the first drag, matching the pre-extraction behavior.
    let defaultSize: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    /// Minimum size reserved for the flexible pane, when the hosted content
    /// has a product-level usability requirement of its own.
    let flexibleMinimum: CGFloat?
    let showsIdleDivider: Bool
    /// Keep the content mounted when a tool window is hidden, preserving its
    /// expansion, selection and native editor state across layout changes.
    let isSizedPaneVisible: Bool
    /// Called with the final size when a drag ends. Hosts that persist the size
    /// write it here; the container then defers to `defaultSize` again so the
    /// persisted value is the single source of truth.
    let onCommit: ((CGFloat) -> Void)?

    private let sized: Sized
    private let flexible: Flexible

    @State private var draggedSize: CGFloat?
    @State private var dragStart: CGFloat = 0

    init(
        axis: LitheSplitAxis,
        placement: LitheSplitPaneGeometry.Placement,
        defaultSize: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        flexibleMinimum: CGFloat? = nil,
        showsIdleDivider: Bool = true,
        isSizedPaneVisible: Bool = true,
        onCommit: ((CGFloat) -> Void)? = nil,
        @ViewBuilder sized: () -> Sized,
        @ViewBuilder flexible: () -> Flexible
    ) {
        self.axis = axis
        self.placement = placement
        self.defaultSize = defaultSize
        self.minimum = minimum
        self.maximum = maximum
        self.flexibleMinimum = flexibleMinimum
        self.showsIdleDivider = showsIdleDivider
        self.isSizedPaneVisible = isSizedPaneVisible
        self.onCommit = onCommit
        self.sized = sized()
        self.flexible = flexible()
    }

    private var resolvedSize: CGFloat {
        LitheSplitPaneGeometry.clamp(
            draggedSize ?? defaultSize,
            minimum: minimum,
            maximum: maximum
        )
    }

    var body: some View {
        let size = resolvedSize
        if axis == .horizontal {
            HStack(spacing: 0) { panes(size) }
        } else {
            VStack(spacing: 0) { panes(size) }
        }
    }

    @ViewBuilder
    private func panes(_ size: CGFloat) -> some View {
        switch placement {
        case .leading:
            sizedPane(isSizedPaneVisible ? size : 0)
            if isSizedPaneVisible { handle(size) }
            flexiblePane
        case .trailing:
            flexiblePane
            if isSizedPaneVisible { handle(size) }
            sizedPane(isSizedPaneVisible ? size : 0)
        }
    }

    @ViewBuilder
    private func sizedPane(_ size: CGFloat) -> some View {
        if axis == .horizontal {
            sized.frame(width: size).clipped()
                .opacity(isSizedPaneVisible ? 1 : 0)
                .allowsHitTesting(isSizedPaneVisible)
                .accessibilityHidden(!isSizedPaneVisible)
        } else {
            sized.frame(height: size).clipped()
                .opacity(isSizedPaneVisible ? 1 : 0)
                .allowsHitTesting(isSizedPaneVisible)
                .accessibilityHidden(!isSizedPaneVisible)
        }
    }

    @ViewBuilder
    private var flexiblePane: some View {
        if axis == .horizontal {
            flexible.frame(minWidth: flexibleMinimum, maxWidth: .infinity)
        } else {
            flexible.frame(minHeight: flexibleMinimum, maxHeight: .infinity)
        }
    }

    private func handle(_ size: CGFloat) -> some View {
        SplitHandleView(
            axis: axis,
            showsIdleDivider: showsIdleDivider,
            onDragStarted: { dragStart = size },
            onDragChanged: { translation in
                draggedSize = resolved(from: translation)
            },
            onDragEnded: { translation in
                let finalSize = resolved(from: translation)
                if let onCommit {
                    onCommit(finalSize)
                    // The host now owns the value and feeds it back as
                    // `defaultSize`; keeping a dragged size too would shadow it.
                    draggedSize = nil
                } else {
                    draggedSize = finalSize
                }
            }
        )
    }

    private func resolved(from translation: CGFloat) -> CGFloat {
        LitheSplitPaneGeometry.resolve(
            start: dragStart,
            translation: translation,
            placement: placement,
            minimum: minimum,
            maximum: maximum
        )
    }
}
