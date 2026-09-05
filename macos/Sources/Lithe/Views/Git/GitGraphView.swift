import AppKit
import SwiftUI
import LitheGitModule

/// Commit-row callbacks are grouped so that a row receives one stable value
/// instead of four freshly allocated closures per redraw. Rows are compared by
/// their rendered data alone, which keeps SwiftUI from re-evaluating hundreds of
/// canvases and context menus whenever an unrelated observable changes.
struct GitGraphRowActions {
    let onSelect: (GitCommit) -> Void
    let onCherryPick: (GitCommit) -> Void
    let onRevert: (GitCommit) -> Void
    let onReset: (GitCommit) -> Void
    let onCreateTag: (GitCommit) -> Void
}

struct GitGraphView: View {
    let layout: GitGraphLayout
    let visibleHashes: Set<String>?
    let selectedHash: String?
    let showCommitDecorations: Bool
    let viewportWidth: CGFloat
    let actions: GitGraphRowActions

    private let rowHeight: CGFloat = 24

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(visibleRows) { row in
                let graphWidth = max(30, CGFloat(row.laneCount) * 13 + 16)
                GitGraphRowView(
                    row: row,
                    graphWidth: graphWidth,
                    width: max(viewportWidth, graphWidth + 420),
                    rowHeight: rowHeight,
                    isSelected: selectedHash == row.commit.hash,
                    showCommitDecorations: showCommitDecorations,
                    actions: actions
                )
                .equatable()
                .id(row.commit.hash)
            }

            if layout.hasMissingParents {
                HStack(spacing: 7) {
                    Image(systemName: "ellipsis")
                    Text("Older commits are outside the loaded history")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .frame(height: 30)
            }
        }
    }

    private var visibleRows: [GitGraphRow] {
        guard let visibleHashes else { return layout.rows }
        return layout.rows.filter { visibleHashes.contains($0.commit.hash) }
    }
}

private struct GitGraphRowView: View, Equatable {
    let row: GitGraphRow
    let graphWidth: CGFloat
    let width: CGFloat
    let rowHeight: CGFloat
    let isSelected: Bool
    let showCommitDecorations: Bool
    let actions: GitGraphRowActions

    @State private var isHovered = false

    static func == (lhs: GitGraphRowView, rhs: GitGraphRowView) -> Bool {
        lhs.row == rhs.row
            && lhs.graphWidth == rhs.graphWidth
            && lhs.width == rhs.width
            && lhs.rowHeight == rhs.rowHeight
            && lhs.isSelected == rhs.isSelected
            && lhs.showCommitDecorations == rhs.showCommitDecorations
    }

    var body: some View {
        Button { actions.onSelect(row.commit) } label: {
            HStack(spacing: 0) {
                GitGraphCanvas(
                    row: row,
                    width: graphWidth,
                    height: rowHeight
                )

                HStack(spacing: 0) {
                    Text(row.commit.subject)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(row.isMerge && !isSelected ? LitheTheme.secondaryText : LitheTheme.primaryText)
                        .lineLimit(1)

                    if showCommitDecorations, let label = primaryLabel {
                        Spacer(minLength: 8)

                        HStack(spacing: 4) {
                            GitGraphLabelView(label: label)
                            if row.labels.count > 1 {
                                Text("+\(row.labels.count - 1)")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .fixedSize()
                            }
                        }
                        .frame(maxWidth: 180, alignment: .trailing)
                        .clipped()
                        .help(row.commit.decorations)
                        .padding(.trailing, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(row.commit.authorName)
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .frame(width: 104, alignment: .leading)

                Text(row.commit.date)
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 118, alignment: .trailing)
            }
            .padding(.trailing, 8)
            .frame(width: width, alignment: .leading)
            .frame(height: rowHeight)
            .background(backgroundColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy Commit Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.commit.hash, forType: .string)
            }
            Button("Copy Short Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.commit.shortHash, forType: .string)
            }
            Divider()
            Button("New Tag…") { actions.onCreateTag(row.commit) }
            Button("Cherry-pick Commit…") { actions.onCherryPick(row.commit) }
            Button("Revert Commit…") { actions.onRevert(row.commit) }
            Button("Reset Current Branch to Here…") { actions.onReset(row.commit) }
        }
    }

    private var backgroundColor: Color {
        if isSelected { return LitheTheme.gitSelection }
        if isHovered { return LitheTheme.hoverBackground }
        return .clear
    }

    /// Prefer a named branch over HEAD. Rendering every reference in the same
    /// narrow cell truncates all names; the tooltip and details retain them all.
    private var primaryLabel: GitGraphLabel? {
        row.labels.first(where: { $0.kind == .branch })
            ?? row.labels.first(where: { $0.kind == .remote })
            ?? row.labels.first(where: { $0.kind == .tag })
            ?? row.labels.first
    }
}

struct GitGraphLabelView: View {
    let label: GitGraphLabel

    var body: some View {
        HStack(spacing: 2) {
            GitReferenceTagIcon(color: accentColor)
                .frame(width: 12, height: 12)
            Text(label.title)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(LitheTheme.primaryText.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.leading, 3)
        .padding(.trailing, 4)
        .frame(height: 17)
    }

    private var accentColor: Color {
        switch label.kind {
        case .head: return LitheTheme.accent
        case .branch: return LitheTheme.success
        case .remote: return Color(red: 0.55, green: 0.70, blue: 0.96)
        case .tag: return LitheTheme.warning
        }
    }
}

private struct GitReferenceTagIcon: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 6.25
            let origin = CGPoint(
                x: (size.width - 5.25 * scale) / 2,
                y: (size.height - 5 * scale) / 2
            )
            var path = Path()
            path.move(to: CGPoint(x: origin.x, y: origin.y))
            path.addLine(to: CGPoint(x: origin.x + 2 * scale, y: origin.y))
            path.addLine(to: CGPoint(x: origin.x + 5 * scale, y: origin.y + 3 * scale))
            path.addLine(to: CGPoint(x: origin.x + 3 * scale, y: origin.y + 5 * scale))
            path.addLine(to: CGPoint(x: origin.x, y: origin.y + 2 * scale))
            path.closeSubpath()
            context.stroke(path, with: .color(color), lineWidth: 1.1)
            let hole = Path(ellipseIn: CGRect(
                x: origin.x + scale,
                y: origin.y + scale,
                width: scale,
                height: scale
            ))
            context.fill(hole, with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

private struct GitGraphCanvas: View {
    let row: GitGraphRow
    let width: CGFloat
    let height: CGFloat

    private let laneSpacing: CGFloat = 13
    private let laneLineWidth: CGFloat = 1.2
    private let leftPadding: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let centerY = size.height / 2
            let currentX = x(for: row.lane)

            for (lane, incomingColorIndex) in row.incomingLaneColors.enumerated() {
                guard let colorIndex = incomingColorIndex else { continue }
                let path = linePath(
                    from: CGPoint(x: x(for: lane), y: 0),
                    to: CGPoint(x: x(for: lane), y: lane == row.lane ? centerY : size.height)
                )
                context.stroke(
                    path,
                    with: .color(GitGraphPalette.color(for: colorIndex)),
                    style: StrokeStyle(lineWidth: laneLineWidth, lineCap: .round)
                )
            }

            for edge in row.parentEdges {
                let color = GitGraphPalette.color(for: edge.colorIndex)
                if let targetLane = edge.targetLane {
                    let target = CGPoint(x: x(for: targetLane), y: size.height)
                    let start = CGPoint(x: currentX, y: centerY)
                    var path = Path()
                    path.move(to: start)
                    if targetLane == row.lane {
                        path.addLine(to: target)
                    } else {
                        // Keep each lane's boundary x unchanged. A short
                        // diagonal communicates the merge without the broad
                        // curves that made dense histories look tangled.
                        path.addLine(to: CGPoint(x: target.x, y: size.height - 3))
                        path.addLine(to: target)
                    }
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: laneLineWidth, lineCap: .round)
                    )
                } else {
                    let path = linePath(
                        from: CGPoint(x: currentX, y: centerY),
                        to: CGPoint(x: currentX, y: size.height - 2)
                    )
                    context.stroke(
                        path,
                        with: .color(color.opacity(0.65)),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 2])
                    )
                }
            }

            let nodeSize: CGFloat = 7
            let nodeRect = CGRect(
                x: currentX - nodeSize / 2,
                y: centerY - nodeSize / 2,
                width: nodeSize,
                height: nodeSize
            )
            context.fill(
                Path(ellipseIn: nodeRect),
                with: .color(GitGraphPalette.color(for: nodeColorIndex))
            )
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    private var nodeColorIndex: Int {
        row.incomingLaneColors[safe: row.lane].flatMap { $0 }
            ?? row.parentEdges.first?.colorIndex
            ?? 0
    }

    private func x(for lane: Int) -> CGFloat {
        leftPadding + CGFloat(lane) * laneSpacing
    }

    private func linePath(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }
}

private enum GitGraphPalette {
    private static let colors: [Color] = [
        Color(red: 0.61, green: 0.36, blue: 0.70),
        Color(red: 0.37, green: 0.62, blue: 0.42),
        Color(red: 0.37, green: 0.51, blue: 0.76),
        Color(red: 0.76, green: 0.56, blue: 0.32),
        Color(red: 0.34, green: 0.65, blue: 0.66),
        Color(red: 0.76, green: 0.41, blue: 0.47),
        Color(red: 0.54, green: 0.48, blue: 0.74)
    ]

    static func color(for index: Int) -> Color {
        colors[index % colors.count]
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
