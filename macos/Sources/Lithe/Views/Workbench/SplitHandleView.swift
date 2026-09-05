import AppKit
import SwiftUI

enum LitheSplitAxis {
    case horizontal
    case vertical
}

struct SplitHandleView: View {
    // Keep the hit target wider than the visible divider so resizing does not
    // depend on landing on a single pixel row or column.
    static let thickness: CGFloat = 10

    let axis: LitheSplitAxis
    let leadingBackground: Color
    let trailingBackground: Color
    let showsIdleDivider: Bool
    let onDragStarted: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragScheduler = LitheDragUpdateScheduler()

    init(
        axis: LitheSplitAxis,
        leadingBackground: Color = .clear,
        trailingBackground: Color = .clear,
        showsIdleDivider: Bool = true,
        onDragStarted: @escaping () -> Void,
        onDragChanged: @escaping (CGFloat) -> Void,
        onDragEnded: @escaping (CGFloat) -> Void
    ) {
        self.axis = axis
        self.leadingBackground = leadingBackground
        self.trailingBackground = trailingBackground
        self.showsIdleDivider = showsIdleDivider
        self.onDragStarted = onDragStarted
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    var body: some View {
        ZStack {
            trackBackground
            Color.clear
            dividerLine
        }
        .frame(
            width: axis == .horizontal ? Self.thickness : nil,
            height: axis == .vertical ? Self.thickness : nil
        )
        .contentShape(Rectangle())
        .gesture(
            // The handle moves with the resized pane, so local coordinates create a
            // feedback loop where translation jumps as the coordinate origin moves.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        resizeCursor.set()
                        onDragStarted()
                    }
                    let currentTranslation = axis == .horizontal ? value.translation.width : value.translation.height
                    // Pointer devices can deliver substantially more events than
                    // the display can present. The scheduler keeps only the
                    // newest translation for the next run-loop turn and applies
                    // the sub-point deadband, so no per-event @State is written.
                    dragScheduler.submit(currentTranslation) { translation in
                        onDragChanged(translation)
                    }
                }
                .onEnded { value in
                    let finalTranslation = axis == .horizontal
                        ? value.translation.width
                        : value.translation.height
                    dragScheduler.cancel()
                    isDragging = false
                    if isHovering { resizeCursor.set() }
                    onDragEnded(finalTranslation)
                }
        )
        .onHover { isInside in
            guard isInside != isHovering else { return }
            isHovering = isInside
        }
        .background(SplitHandleCursorRegion(cursor: resizeCursor))
        .onDisappear {
            dragScheduler.cancel()
        }
        .help(axis == .horizontal ? "Drag left or right to resize" : "Drag up or down to resize")
        .accessibilityLabel(axis == .horizontal ? "Horizontal pane resize handle" : "Vertical pane resize handle")
    }

    @ViewBuilder
    private var trackBackground: some View {
        if axis == .horizontal {
            HStack(spacing: 0) {
                leadingBackground
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                trailingBackground
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                leadingBackground
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                trailingBackground
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var dividerLine: some View {
        let isHighlighted = isHovering || isDragging
        if showsIdleDivider || isHighlighted {
            let color = isHighlighted ? LitheTheme.accent : LitheTheme.divider

            if axis == .horizontal {
                Rectangle()
                    .fill(color)
                    .frame(width: isDragging ? 3 : 1)
                    .frame(maxHeight: .infinity)
            } else {
                Rectangle()
                    .fill(color)
                    .frame(height: isDragging ? 3 : 1)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var resizeCursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }
}

/// Native text and terminal views reset the cursor while moving across a
/// divider. Register the entire hit region with AppKit instead of pushing a
/// cursor only once when SwiftUI reports a hover transition.
struct SplitHandleCursorRegion: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorView { CursorView(cursor: cursor) }

    func updateNSView(_ view: CursorView, context: Context) {
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var cursor: NSCursor
        private var tracking: NSTrackingArea?

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
                owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseEntered(with event: NSEvent) { cursor.set() }
        override func mouseMoved(with event: NSEvent) { cursor.set() }
    }
}
