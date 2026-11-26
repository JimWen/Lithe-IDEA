import AppKit
import LitheCoreContracts

/// Renders non-intrusive LSP inlay hints at the end of visible source lines
/// without mutating `NSTextStorage` or shifting UTF-16 character coordinates.
@MainActor
final class InlayHintOverlayController {
    private weak var textView: NSTextView?
    private var hintViews: [NSView] = []
    private(set) var renderedLineCount = 0

    init(textView: NSTextView) {
        self.textView = textView
    }

    func clear() {
        for view in hintViews {
            view.removeFromSuperview()
        }
        hintViews.removeAll(keepingCapacity: true)
        renderedLineCount = 0
    }

    func update(
        hints: [LanguageServerInlayHint],
        collapsedLineSet: Set<Int> = [],
        isDark: Bool
    ) {
        clear()
        guard !hints.isEmpty,
              let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let source = textView.string as NSString
        guard source.length > 0 else { return }

        // Group hints by zero-based line and cap rendered lines for smooth scrolling.
        var byLine: [Int: [LanguageServerInlayHint]] = [:]
        for hint in hints {
            guard hint.position.line >= 0,
                  !collapsedLineSet.contains(hint.position.line),
                  !hint.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            byLine[hint.position.line, default: []].append(hint)
        }
        guard !byLine.isEmpty else { return }

        let fontSize = max(9.5, (textView.font?.pointSize ?? 13) - 2)
        let hintFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let textColor = isDark
            ? NSColor(calibratedWhite: 0.72, alpha: 0.85)
            : NSColor(calibratedWhite: 0.36, alpha: 0.85)
        let backgroundColor = isDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.06)
            : NSColor(calibratedWhite: 0.0, alpha: 0.05)

        let sortedLines = byLine.keys.sorted().prefix(80)
        for line in sortedLines {
            guard let lineHints = byLine[line] else { continue }
            let sortedHints = lineHints.sorted { $0.position.utf16Column < $1.position.utf16Column }
            let combinedText = sortedHints
                .map { hint in
                    let trimmed = hint.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed
                }
                .joined(separator: " · ")
            guard !combinedText.isEmpty else { continue }

            let lineStart = characterOffset(forLine: line, in: source)
            guard lineStart < source.length else { continue }
            let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location {
                let character = source.character(at: contentEnd - 1)
                guard character == 10 || character == 13 else { break }
                contentEnd -= 1
            }
            guard contentEnd > lineRange.location else { continue }
            let lastChar = max(lineRange.location, contentEnd - 1)
            let lastGlyph = layoutManager.glyphIndexForCharacter(at: lastChar)
            var visualGlyphRange = NSRange()
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: lastGlyph,
                effectiveRange: &visualGlyphRange
            )
            let contentGlyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(
                    location: lineRange.location,
                    length: contentEnd - lineRange.location
                ),
                actualCharacterRange: nil
            )
            let visibleRange = NSIntersectionRange(contentGlyphRange, visualGlyphRange)
            guard visibleRange.length > 0 else { continue }
            let contentRect = layoutManager.boundingRect(
                forGlyphRange: visibleRange,
                in: textContainer
            )

            let originX = textView.textContainerOrigin.x + contentRect.maxX + 10
            let availableWidth = textView.bounds.width - originX - 12
            guard availableWidth >= 28 else { continue }

            let badge = InlayHintBadgeView(
                text: combinedText,
                font: hintFont,
                textColor: textColor,
                backgroundColor: backgroundColor
            )
            let fitting = badge.fittingSize
            let width = min(fitting.width, availableWidth)
            let height = max(15, fitting.height)
            badge.frame = NSRect(
                x: originX,
                y: textView.textContainerOrigin.y + lineRect.midY - height / 2,
                width: width,
                height: height
            )
            textView.addSubview(badge)
            hintViews.append(badge)
            renderedLineCount += 1
        }
    }

    private func characterOffset(forLine line: Int, in source: NSString) -> Int {
        if let codeTextView = textView as? CodeTextView {
            return codeTextView.characterOffset(forLine: line, in: source)
        }
        var current = 0
        var location = 0
        while current < line, location < source.length {
            location = NSMaxRange(source.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        return location
    }
}

private final class InlayHintBadgeView: NSView {
    private let label: NSTextField
    private let fillColor: NSColor

    init(text: String, font: NSFont, textColor: NSColor, backgroundColor: NSColor) {
        self.fillColor = backgroundColor
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = textColor
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.isEditable = false
        field.isSelectable = false
        self.label = field
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = fillColor.cgColor
        addSubview(field)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize {
        let size = label.fittingSize
        return NSSize(width: ceil(size.width) + 10, height: ceil(size.height) + 2)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 5, dy: 1)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Non-focus-stealing floating panel displaying LSP Signature Help (Parameter Info)
/// anchored above or below the active editor caret.
@MainActor
final class SignatureHelpPanelController {
    private var panel: NSPanel?
    private var signatureLabel: NSTextField?
    private var documentationLabel: NSTextField?
    private(set) var isVisible = false
    private(set) var currentHelp: LanguageServerSignatureHelp?

    func show(
        _ help: LanguageServerSignatureHelp,
        anchoredTo caretRectInView: NSRect,
        in view: NSView
    ) {
        guard let signature = help.currentSignature,
              let parentWindow = view.window else {
            dismiss()
            return
        }
        currentHelp = help
        let isDark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let panel = ensurePanel(isDark: isDark)

        let attributed = Self.attributedSignature(
            signature,
            activeParameterIndex: help.effectiveActiveParameter,
            isDark: isDark
        )
        signatureLabel?.attributedStringValue = attributed

        let activeParamDoc: String? = {
            guard let index = help.effectiveActiveParameter,
                  index < signature.parameters.count else { return nil }
            return signature.parameters[index].documentation
        }()
        let docText = [activeParamDoc, signature.documentation]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })

        if let docText, let documentationLabel {
            documentationLabel.stringValue = docText
            documentationLabel.isHidden = false
        } else {
            documentationLabel?.stringValue = ""
            documentationLabel?.isHidden = true
        }

        let maxWidth: CGFloat = 520
        let horizontalPadding: CGFloat = 12
        let verticalPadding: CGFloat = 8
        let contentWidth = maxWidth - horizontalPadding * 2

        signatureLabel?.preferredMaxLayoutWidth = contentWidth
        documentationLabel?.preferredMaxLayoutWidth = contentWidth

        let sigSize = signatureLabel?.sizeThatFits(NSSize(width: contentWidth, height: 120)) ?? .zero
        let docSize: NSSize
        if let docLabel = documentationLabel, !docLabel.isHidden {
            docSize = docLabel.sizeThatFits(NSSize(width: contentWidth, height: 80))
        } else {
            docSize = .zero
        }
        let spacing: CGFloat = docSize.height > 0 ? 4 : 0
        let panelWidth = min(maxWidth, max(160, max(sigSize.width, docSize.width) + horizontalPadding * 2))
        let panelHeight = sigSize.height + spacing + docSize.height + verticalPadding * 2

        if let container = panel.contentView {
            container.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
            let sigY = verticalPadding + (docSize.height > 0 ? docSize.height + spacing : 0)
            signatureLabel?.frame = NSRect(
                x: horizontalPadding,
                y: sigY,
                width: panelWidth - horizontalPadding * 2,
                height: sigSize.height
            )
            if docSize.height > 0 {
                documentationLabel?.frame = NSRect(
                    x: horizontalPadding,
                    y: verticalPadding,
                    width: panelWidth - horizontalPadding * 2,
                    height: docSize.height
                )
            }
        }

        let rectInWindow = view.convert(caretRectInView, to: nil)
        let rectOnScreen = parentWindow.convertToScreen(rectInWindow)
        let screenFrame = parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var originX = rectOnScreen.minX
        if originX + panelWidth > screenFrame.maxX - 8 {
            originX = max(screenFrame.minX + 8, screenFrame.maxX - panelWidth - 8)
        }
        // Prefer placing Parameter Info right above the caret so it doesn't cover the line being typed.
        var originY = rectOnScreen.maxY + 4
        if originY + panelHeight > screenFrame.maxY - 8 {
            originY = max(screenFrame.minY + 8, rectOnScreen.minY - panelHeight - 4)
        }

        panel.setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight), display: true)
        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        isVisible = true
    }

    func dismiss() {
        currentHelp = nil
        isVisible = false
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    deinit {
        let panel = self.panel
        Task { @MainActor in
            panel?.parent?.removeChildWindow(panel!)
            panel?.orderOut(nil)
        }
    }

    private func ensurePanel(isDark: Bool) -> NSPanel {
        if let panel {
            updateAppearance(panel: panel, isDark: isDark)
            return panel
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.ignoresMouseEvents = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.layer?.borderWidth = 1

        let sigLabel = NSTextField(wrappingLabelWithString: "")
        sigLabel.isEditable = false
        sigLabel.isSelectable = false
        sigLabel.maximumNumberOfLines = 3
        sigLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(sigLabel)

        let docLabel = NSTextField(wrappingLabelWithString: "")
        docLabel.isEditable = false
        docLabel.isSelectable = false
        docLabel.font = .systemFont(ofSize: 11)
        docLabel.maximumNumberOfLines = 3
        docLabel.lineBreakMode = .byTruncatingTail
        docLabel.isHidden = true
        container.addSubview(docLabel)

        panel.contentView = container
        self.panel = panel
        self.signatureLabel = sigLabel
        self.documentationLabel = docLabel
        updateAppearance(panel: panel, isDark: isDark)
        return panel
    }

    private func updateAppearance(panel: NSPanel, isDark: Bool) {
        panel.contentView?.layer?.backgroundColor = LitheTheme.nsColor(.editor, isDark: isDark).cgColor
        panel.contentView?.layer?.borderColor = LitheTheme.nsColor(.divider, isDark: isDark).cgColor
        documentationLabel?.textColor = LitheTheme.nsColor(.secondaryText, isDark: isDark)
    }

    static func attributedSignature(
        _ signature: LanguageServerSignatureInformation,
        activeParameterIndex: Int?,
        isDark: Bool
    ) -> NSAttributedString {
        let baseFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
        let baseColor = LitheTheme.nsColor(.primaryText, isDark: isDark)
        let accentColor = LitheTheme.nsColor(.accent, isDark: isDark)

        let attributed = NSMutableAttributedString(
            string: signature.label,
            attributes: [
                .font: baseFont,
                .foregroundColor: baseColor,
            ]
        )
        guard let activeParameterIndex,
              activeParameterIndex >= 0,
              activeParameterIndex < signature.parameters.count else {
            return attributed
        }
        let param = signature.parameters[activeParameterIndex]
        let nsLabel = signature.label as NSString
        let highlightRange: NSRange?
        if let start = param.labelStart, let end = param.labelEnd,
           start >= 0, end >= start, end <= nsLabel.length {
            highlightRange = NSRange(location: start, length: end - start)
        } else if !param.label.isEmpty {
            let found = nsLabel.range(of: param.label)
            highlightRange = found.location == NSNotFound ? nil : found
        } else {
            highlightRange = nil
        }
        if let highlightRange, highlightRange.length > 0 {
            attributed.addAttributes(
                [
                    .font: boldFont,
                    .foregroundColor: accentColor,
                ],
                range: highlightRange
            )
        }
        return attributed
    }
}

/// Inline floating rename box anchored directly over the symbol range in the editor.
/// Commits on Return, cancels cleanly on Escape or focus loss without mutating text.
@MainActor
final class InlineRenamePanelController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private var panel: InlineRenamePanel?
    private var textField: NSTextField?
    private var initialValue = ""
    private var onCommit: ((String) -> Void)?
    private var onCancel: (() -> Void)?
    private weak var returnFocusView: NSView?
    private(set) var isVisible = false

    func show(
        initialName: String,
        anchoredTo symbolRectInView: NSRect,
        in view: NSView,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        dismiss(restoreFocus: false)
        guard let parentWindow = view.window else {
            onCancel()
            return
        }
        initialValue = initialName
        self.onCommit = onCommit
        self.onCancel = onCancel
        returnFocusView = view

        let isDark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let panel = ensurePanel(isDark: isDark)
        guard let textField else { return }

        if let editorFont = (view as? NSTextView)?.font {
            textField.font = editorFont
        } else {
            textField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        }
        textField.stringValue = initialName

        let panelWidth = max(190, min(380, ceil(textField.fittingSize.width) + 48))
        let panelHeight: CGFloat = 30

        let rectInWindow = view.convert(symbolRectInView, to: nil)
        let rectOnScreen = parentWindow.convertToScreen(rectInWindow)
        let screenFrame = parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var originX = rectOnScreen.minX - 6
        if originX + panelWidth > screenFrame.maxX - 8 {
            originX = max(screenFrame.minX + 8, screenFrame.maxX - panelWidth - 8)
        }
        let originY = min(
            max(screenFrame.minY + 8, rectOnScreen.midY - panelHeight / 2),
            screenFrame.maxY - panelHeight - 8
        )

        panel.setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight), display: true)
        if let container = panel.contentView {
            container.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
            textField.frame = NSRect(x: 8, y: 4, width: panelWidth - 16, height: panelHeight - 8)
        }

        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        isVisible = true
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)
        textField.selectText(nil)
    }

    func commitCurrentValue() {
        guard isVisible, let textField else { return }
        if let fieldEditor = textField.currentEditor() as? NSTextView, fieldEditor.hasMarkedText() {
            return
        }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitHandler = onCommit
        let cancelHandler = onCancel
        let original = initialValue
        dismiss(restoreFocus: true)
        if !trimmed.isEmpty, trimmed != original {
            commitHandler?(trimmed)
        } else {
            cancelHandler?()
        }
    }

    func cancel(restoreFocus: Bool = true) {
        guard isVisible else { return }
        let cancelHandler = onCancel
        dismiss(restoreFocus: restoreFocus)
        cancelHandler?()
    }

    func dismiss(restoreFocus: Bool = false) {
        let wasVisible = isVisible
        isVisible = false
        onCommit = nil
        onCancel = nil
        let targetView = returnFocusView
        returnFocusView = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if wasVisible, restoreFocus, let targetView, let window = targetView.window {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(targetView)
        }
    }

    // MARK: - NSTextFieldDelegate / NSWindowDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if textView.hasMarkedText() { return false }
            commitCurrentValue()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if textView.hasMarkedText() { return false }
            cancel()
            return true
        }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        if isVisible {
            cancel(restoreFocus: false)
        }
    }

    deinit {
        let panel = self.panel
        Task { @MainActor in
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        }
    }

    private func ensurePanel(isDark: Bool) -> InlineRenamePanel {
        if let panel {
            updateAppearance(panel: panel, isDark: isDark)
            return panel
        }
        let panel = InlineRenamePanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.delegate = self

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.borderWidth = 1.5

        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.delegate = self
        container.addSubview(field)

        panel.contentView = container
        self.panel = panel
        self.textField = field
        updateAppearance(panel: panel, isDark: isDark)
        return panel
    }

    private func updateAppearance(panel: InlineRenamePanel, isDark: Bool) {
        panel.contentView?.layer?.backgroundColor = LitheTheme.nsColor(.editor, isDark: isDark).cgColor
        panel.contentView?.layer?.borderColor = LitheTheme.nsColor(.accent, isDark: isDark).cgColor
        textField?.textColor = LitheTheme.nsColor(.primaryText, isDark: isDark)
    }
}

private final class InlineRenamePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
