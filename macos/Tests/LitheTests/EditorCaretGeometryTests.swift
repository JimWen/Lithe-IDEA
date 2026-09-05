import AppKit
import Testing
@testable import Lithe

/// Regression coverage for #385: custom caret drawing must reach the true end
/// of the last line and the extra line after a trailing newline.
@Suite("Editor caret geometry")
struct EditorCaretGeometryTests {
    @MainActor
    @Test
    func nativeInsertionPointDrawingFollowsReturn() throws {
        let textView = makeLaidOutEditor(text: "first")
        textView.isRichText = false
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let fallback = layoutManager.defaultLineHeight(for: textView.font!)
        func paintedCaretRows() throws -> Set<Int> {
            let caret = EditorCaretGeometry.rect(
                at: textView.selectedRange().location, sourceLength: textView.string.utf16.count,
                layoutManager: layoutManager, textContainer: textContainer, fallbackLineHeight: fallback
            ).offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 240,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: 640, height: 240))
            // Exercise the callback AppKit uses after updating its insertion
            // point; a no-op override leaves no caret at the new position.
            textView.drawInsertionPoint(in: caret, color: .magenta, turnedOn: true)
            context.flushGraphics()
            return Set((0..<240).filter { row in
                let color = bitmap.colorAt(x: Int(caret.minX), y: row)
                return (color?.alphaComponent ?? 0) > 0.5
                    && (color?.redComponent ?? 0) > 0.5
                    && (color?.blueComponent ?? 0) > 0.5
            })
        }
        let previousRows = try paintedCaretRows()
        textView.insertNewline(nil)
        let newRows = try paintedCaretRows()
        #expect(!previousRows.isEmpty)
        #expect(!newRows.isEmpty)
        #expect(previousRows.isDisjoint(with: newRows))
    }

    @MainActor
    @Test
    func returnKeepsTheNewLineVisibleAtTheBottomOfTheEditor() throws {
        let textView = makeLaidOutEditor(text: String(repeating: "line\n", count: 60))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 120))
        LitheTextViewportLayout.applyUnwrappedScrolling(to: textView, in: scrollView)
        scrollView.documentView = textView
        let window = NSWindow(contentRect: scrollView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer {
            window.contentView = nil
            window.close()
        }
        textView.isRichText = false
        window.makeFirstResponder(textView)
        textView.sizeToFit()
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        for _ in 0..<3 {
            textView.insertNewline(nil)
            let caret = EditorCaretGeometry.rect(
                at: textView.selectedRange().location, sourceLength: textView.string.utf16.count,
                layoutManager: layoutManager, textContainer: textContainer,
                fallbackLineHeight: layoutManager.defaultLineHeight(for: textView.font!)
            ).offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            // AppKit may shift the document frame while resizing it. Compare
            // both rectangles in text-view coordinates, not clip-view space.
            let viewport = textView.convert(scrollView.contentView.bounds, from: scrollView.contentView)
            #expect(caret.minY >= viewport.minY)
            #expect(caret.maxY <= viewport.maxY + 1)
        }
    }

    @MainActor
    @Test(arguments: ["", "first", "first\n"])
    func liveEditorReturnKeepsSelectionAndCaretAfterHighlighting(initialText: String) throws {
        let store = CaretTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        let document = EditorDocument(
            url: URL(fileURLWithPath: "/workspace/return.txt"),
            text: initialText,
            modificationDate: nil
        )
        let textView = makeLaidOutEditor(text: initialText)
        textView.isRichText = false
        let coordinator = CodeEditorView.Coordinator(
            document: document, model: model, markdownScrollPosition: nil,
            viewportStore: EditorViewportStore()
        )
        coordinator.textView = textView
        textView.delegate = coordinator
        defer { textView.delegate = nil }
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let fallback = layoutManager.defaultLineHeight(for: textView.font!)
        textView.setSelectedRange(NSRange(location: initialText.utf16.count, length: 0))
        var previousY = EditorCaretGeometry.rect(
            at: textView.selectedRange().location, sourceLength: textView.string.utf16.count,
            layoutManager: layoutManager, textContainer: textContainer, fallbackLineHeight: fallback
        ).minY
        for _ in 0..<3 {
            textView.insertNewline(nil)
            let caret = EditorCaretGeometry.rect(
                at: textView.selectedRange().location, sourceLength: textView.string.utf16.count,
                layoutManager: layoutManager, textContainer: textContainer, fallbackLineHeight: fallback
            )
            #expect(document.text == textView.string)
            #expect(textView.selectedRange().location == textView.string.utf16.count)
            #expect(caret.minY > previousY)
            previousY = caret.minY
        }
    }

    @MainActor
    @Test(arguments: ["", "first", "first\n", "first\nsecond"])
    func typingReturnMovesTheCaretToEachNewLine(initialText: String) throws {
        let textView = makeLaidOutEditor(text: initialText)
        textView.isRichText = false
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let fallback = layoutManager.defaultLineHeight(for: textView.font!)
        textView.setSelectedRange(NSRange(location: initialText.utf16.count, length: 0))
        func caretRect() -> NSRect {
            EditorCaretGeometry.rect(
                at: textView.selectedRange().location,
                sourceLength: textView.string.utf16.count,
                layoutManager: layoutManager,
                textContainer: textContainer,
                fallbackLineHeight: fallback
            )
        }
        var previous = caretRect()
        for _ in 0..<3 {
            textView.insertNewline(nil)
            let next = caretRect()
            #expect(textView.selectedRange().location == textView.string.utf16.count)
            #expect(next.minY > previous.minY)
            previous = next
        }
    }

    @MainActor
    @Test
    func caretAfterLastCharacterSitsPastTheFinalGlyphWhenFileHasNoTrailingNewline() throws {
        let textView = makeLaidOutEditor(text: "DP_LOAD_BALANCE_PORT=18081")
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let length = textView.string.utf16.count
        let fallback = layoutManager.defaultLineHeight(for: textView.font!)

        let onLastCharacter = EditorCaretGeometry.rect(
            at: length - 1,
            sourceLength: length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )
        let atDocumentEnd = EditorCaretGeometry.rect(
            at: length,
            sourceLength: length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )

        #expect(atDocumentEnd.minX > onLastCharacter.minX)
        #expect(abs(atDocumentEnd.minY - onLastCharacter.minY) < 0.5)
        #expect(atDocumentEnd.width == EditorLayoutMetrics.caretWidth)
    }

    @MainActor
    @Test
    func caretOnLineEndingSitsAfterVisibleLineContent() throws {
        let textView = makeLaidOutEditor(text: "first\nsecond\n")
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let source = textView.string as NSString
        let fallback = layoutManager.defaultLineHeight(for: textView.font!)

        // Index of the newline after "first"
        let firstNewline = source.range(of: "\n").location
        let caretOnNewline = EditorCaretGeometry.rect(
            at: firstNewline,
            sourceLength: source.length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )
        let caretOnLastLetter = EditorCaretGeometry.rect(
            at: firstNewline - 1,
            sourceLength: source.length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )

        #expect(caretOnNewline.minX > caretOnLastLetter.minX)
        #expect(abs(caretOnNewline.minY - caretOnLastLetter.minY) < 0.5)
    }

    @MainActor
    @Test
    func caretAtDocumentEndAfterTrailingNewlineUsesExtraLineFragment() throws {
        let textView = makeLaidOutEditor(text: "only\n")
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let length = textView.string.utf16.count
        let fallback = layoutManager.defaultLineHeight(for: textView.font!)

        let endCaret = EditorCaretGeometry.rect(
            at: length,
            sourceLength: length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )
        let contentCaret = EditorCaretGeometry.rect(
            at: 0,
            sourceLength: length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )

        #expect(endCaret.minY > contentCaret.minY)
        #expect(layoutManager.extraLineFragmentUsedRect.height > 0)
    }

    @MainActor
    @Test
    func caretOnCRLFLineEndingStillSitsAfterVisibleContent() throws {
        let textView = makeLaidOutEditor(text: "alpha\r\nbeta")
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let source = textView.string as NSString
        let fallback = layoutManager.defaultLineHeight(for: textView.font!)
        let crIndex = source.range(of: "\r").location

        let caretOnCR = EditorCaretGeometry.rect(
            at: crIndex,
            sourceLength: source.length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )
        let caretOnLastLetter = EditorCaretGeometry.rect(
            at: crIndex - 1,
            sourceLength: source.length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )
        let caretOnLF = EditorCaretGeometry.rect(
            at: crIndex + 1,
            sourceLength: source.length,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )

        #expect(caretOnCR.minX > caretOnLastLetter.minX)
        #expect(abs(caretOnLF.minX - caretOnCR.minX) < 0.5)
        #expect(abs(caretOnLF.minY - caretOnCR.minY) < 0.5)
    }

    @MainActor
    @Test
    func emptyDocumentCaretUsesFallbackLineHeight() throws {
        let textView = makeLaidOutEditor(text: "")
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let fallback = layoutManager.defaultLineHeight(for: textView.font!)

        let caret = EditorCaretGeometry.rect(
            at: 0,
            sourceLength: 0,
            layoutManager: layoutManager,
            textContainer: textContainer,
            fallbackLineHeight: fallback
        )

        #expect(caret.height >= fallback)
        #expect(caret.width == EditorLayoutMetrics.caretWidth)
    }

    @MainActor
    private func makeLaidOutEditor(text: String) -> CodeTextView {
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        textView.font = LitheTheme.editorFont(size: 13)
        textView.defaultParagraphStyle = LitheTheme.editorParagraphStyle
        textView.string = text
        textView.textContainerInset = NSSize(width: EditorLayoutMetrics.leadingInset, height: 0)
        textView.textContainer?.lineFragmentPadding = EditorLayoutMetrics.lineFragmentPadding
        if let textStorage = textView.textStorage, textStorage.length > 0 {
            textStorage.addAttributes(
                [
                    .font: textView.font as Any,
                    .paragraphStyle: textView.defaultParagraphStyle as Any
                ],
                range: NSRange(location: 0, length: textStorage.length)
            )
        }
        textView.layoutManager?.delegate = textView
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }
        return textView
    }
}

private final class CaretTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
