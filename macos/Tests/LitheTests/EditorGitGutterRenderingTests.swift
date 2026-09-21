import AppKit
@testable import LitheGitModule
import Testing
@testable import Lithe

@Suite("Editor Git gutter rendering")
@MainActor
struct EditorGitGutterRenderingTests {
    @Test(arguments: [false, true])
    func adjacentAddedLinesPaintOneContinuousBlockIncludingSoftWraps(wrapped: Bool) throws {
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 480))
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = .zero
        textView.string = "unchanged\n"
            + (wrapped ? String(repeating: "added text ", count: 8) : "first added line")
            + "\nsecond added line\nunchanged\nseparate addition\nunchanged\n"
        textView.rebuildLineIndex()
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        textContainer.containerSize = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        let gutter = LineNumberGutterView(frame: NSRect(x: 0, y: 0, width: 80, height: 480))
        gutter.attach(textView: textView, scrollView: scrollView)
        gutter.updateGitLineChanges([
            GitLineChangeMarker(line: 1, kind: .added, hunkID: "h1"),
            GitLineChangeMarker(line: 2, kind: .added, hunkID: "h1"),
            GitLineChangeMarker(line: 4, kind: .added, hunkID: "h1")
        ], onShow: { _ in })

        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 480,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: 480)
        context.cgContext.scaleBy(x: 1, y: -1)
        gutter.draw(gutter.bounds)
        context.flushGraphics()
        // Inspect the actual AppKit drawing: adjacent additions must have no
        // blank pixel row between them, while unchanged lines separate blocks.
        let paintedRows = (0..<480).filter { y in
            (0..<80).contains { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.greenComponent > color.redComponent + 0.2
                    && color.greenComponent > color.blueComponent + 0.2
            }
        }
        var blocks: [[Int]] = []
        for row in paintedRows {
            if blocks.last?.last == row - 1 { blocks[blocks.count - 1].append(row) }
            else { blocks.append([row]) }
        }
        #expect(blocks.count == 2, "Consecutive additions must form one bar, not a dashed line")
        let source = textView.string as NSString
        let start = source.range(of: wrapped ? "added text" : "first added line").location
        let end = source.range(of: "second added line").location
        let firstRect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
        let lastRect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: end), effectiveRange: nil)
        #expect(CGFloat(blocks.map(\.count).max() ?? 0) >= lastRect.maxY - firstRect.minY - 3,
                "The bar must cover all visual fragments of both logical lines")

        gutter.updateGitLineChanges([], onShow: { _ in })
        gutter.draw(gutter.bounds)
        context.flushGraphics()
        let cleared = paintedRows.allSatisfy { y in
            (0..<80).allSatisfy { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return true }
                return color.greenComponent <= color.redComponent + 0.2
                    || color.greenComponent <= color.blueComponent + 0.2
            }
        }
        #expect(cleared, "Refreshing a clean file must remove the previous markers")

        gutter.updateGitLineChanges([
            GitLineChangeMarker(line: 1, kind: .deleted, hunkID: "deletion")
        ], onShow: { _ in })
        gutter.draw(gutter.bounds)
        context.flushGraphics()
        let deletedRows = (0..<480).filter { y in
            (0..<80).contains { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.redComponent > color.greenComponent + 0.3
                    && color.redComponent > color.blueComponent + 0.3
            }
        }
        let deletionStart = try #require(deletedRows.first)
        let deletionEnd = try #require(deletedRows.last)
        #expect(deletionEnd - deletionStart <= 3)
        #expect(abs(CGFloat(deletionStart + deletionEnd) / 2 - firstRect.midY) <= 2,
                "A deletion stays anchored to the first visual fragment, including on wrapped lines")
    }
}
