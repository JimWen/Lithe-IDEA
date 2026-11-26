import AppKit
import LitheCoreContracts

/// Pure, deterministic filtering and ranking model backing the non-blocking completion popup.
struct CompletionPopupModel: Equatable {
    private(set) var allItems: [LanguageServerCompletionItem] = []
    private(set) var filteredItems: [LanguageServerCompletionItem] = []
    private(set) var query: String = ""
    private(set) var selectedIndex: Int = 0
    private(set) var batchGeneration: UInt64 = 0
    private var resolvedItemsByID: [String: LanguageServerCompletionItem] = [:]

    var isEmpty: Bool { filteredItems.isEmpty }

    var selectedBaseItemID: String? {
        guard selectedIndex >= 0, selectedIndex < filteredItems.count else { return nil }
        return filteredItems[selectedIndex].id
    }

    var selectedItem: LanguageServerCompletionItem? {
        guard selectedIndex >= 0, selectedIndex < filteredItems.count else { return nil }
        let base = filteredItems[selectedIndex]
        return resolvedItemsByID[base.id] ?? base
    }

    mutating func update(items: [LanguageServerCompletionItem], query: String) {
        let previousSelectedID = selectedBaseItemID
        batchGeneration &+= 1
        resolvedItemsByID.removeAll()
        allItems = items
        self.query = query
        filteredItems = Self.filterAndRank(items: items, query: query)
        if let previousSelectedID,
           let preservedIndex = filteredItems.firstIndex(where: { $0.id == previousSelectedID }) {
            selectedIndex = preservedIndex
        } else if let preselected = filteredItems.firstIndex(where: \.preselect) {
            selectedIndex = preselected
        } else {
            selectedIndex = 0
        }
    }

    mutating func updateQuery(_ query: String) {
        let previousSelectedID = selectedBaseItemID
        self.query = query
        filteredItems = Self.filterAndRank(items: allItems, query: query)
        if let previousSelectedID,
           let preservedIndex = filteredItems.firstIndex(where: { $0.id == previousSelectedID }) {
            selectedIndex = preservedIndex
        } else {
            selectedIndex = 0
        }
    }

    mutating func moveSelection(delta: Int) {
        guard !filteredItems.isEmpty else {
            selectedIndex = 0
            return
        }
        let count = filteredItems.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    mutating func select(index: Int) {
        guard index >= 0, index < filteredItems.count else { return }
        selectedIndex = index
    }

    @discardableResult
    mutating func storeResolved(
        _ resolved: LanguageServerCompletionItem,
        for originalID: String,
        generation: UInt64? = nil
    ) -> Bool {
        if let generation, generation != batchGeneration {
            return false
        }
        resolvedItemsByID[originalID] = resolved
        return true
    }

    func resolvedItem(for item: LanguageServerCompletionItem) -> LanguageServerCompletionItem {
        resolvedItemsByID[item.id] ?? item
    }

    mutating func reset() {
        batchGeneration &+= 1
        allItems = []
        filteredItems = []
        query = ""
        selectedIndex = 0
        resolvedItemsByID = [:]
    }

    /// Filters and ranks completion items by prefix/subsequence match while preserving
    /// LSP `preselect` and `sortText` order within equal match tiers.
    static func filterAndRank(
        items: [LanguageServerCompletionItem],
        query: String
    ) -> [LanguageServerCompletionItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return Array(items.prefix(200))
        }
        let lowerQuery = trimmed.lowercased()
        struct Scored {
            let item: LanguageServerCompletionItem
            let tier: Int
            let originalIndex: Int
        }
        var scored: [Scored] = []
        scored.reserveCapacity(min(items.count, 200))
        for (index, item) in items.enumerated() {
            let candidate = item.filterText ?? item.label
            let lowerCandidate = candidate.lowercased()
            let tier: Int?
            if candidate == trimmed {
                tier = 0
            } else if candidate.hasPrefix(trimmed) {
                tier = 1
            } else if lowerCandidate.hasPrefix(lowerQuery) {
                tier = 2
            } else if lowerCandidate.contains(lowerQuery) {
                tier = 3
            } else if isSubsequence(lowerQuery, of: lowerCandidate) {
                tier = 4
            } else {
                tier = nil
            }
            if let tier {
                scored.append(Scored(item: item, tier: tier, originalIndex: index))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.item.preselect != rhs.item.preselect { return lhs.item.preselect }
            let lhsSort = lhs.item.sortText ?? lhs.item.label
            let rhsSort = rhs.item.sortText ?? rhs.item.label
            if lhsSort != rhsSort { return lhsSort < rhsSort }
            return lhs.originalIndex < rhs.originalIndex
        }
        return scored.prefix(200).map(\.item)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var needleIndex = needle.startIndex
        for ch in haystack {
            guard needleIndex < needle.endIndex else { return true }
            if ch == needle[needleIndex] {
                needleIndex = needle.index(after: needleIndex)
            }
        }
        return needleIndex == needle.endIndex
    }
}

/// Non-focus-stealing floating AppKit completion popup with incremental filtering,
/// keyboard navigation (`↑`/`↓`/`↩`/`⇥`/`Esc`), and lazy quick-documentation preview.
@MainActor
final class CompletionPopupController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var listScrollView: NSScrollView?
    private var docDivider: NSView?
    private var docScrollView: NSScrollView?
    private var docTextView: NSTextView?

    private(set) var model = CompletionPopupModel()
    private(set) var isVisible = false
    private(set) var anchorFallbackRange: NSRange?
    private var pendingResolveIDs: Set<String> = []
    private var isDarkAppearance = true

    var onAccept: ((LanguageServerCompletionItem, NSRange) -> Void)?
    var onRequestResolve: ((LanguageServerCompletionItem, @escaping (LanguageServerCompletionItem?) -> Void) -> Void)?

    func show(
        items: [LanguageServerCompletionItem],
        query: String,
        fallbackRange: NSRange,
        anchoredTo caretRectInView: NSRect,
        in view: NSView
    ) {
        guard let parentWindow = view.window else {
            dismiss()
            return
        }
        pendingResolveIDs.removeAll()
        model.update(items: items, query: query)
        anchorFallbackRange = fallbackRange
        guard !model.isEmpty else {
            dismiss()
            return
        }
        isDarkAppearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let panel = ensurePanel(isDark: isDarkAppearance)
        tableView?.reloadData()
        selectRowInTable(model.selectedIndex)
        refreshDocumentationPane()
        layoutAndPosition(panel: panel, caretRectInView: caretRectInView, in: view, parentWindow: parentWindow)
        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        isVisible = true
    }

    func updateQuery(
        _ query: String,
        fallbackRange: NSRange,
        anchoredTo caretRectInView: NSRect,
        in view: NSView
    ) {
        guard isVisible, let parentWindow = view.window, let panel else { return }
        anchorFallbackRange = fallbackRange
        model.updateQuery(query)
        guard !model.isEmpty else {
            dismiss()
            return
        }
        tableView?.reloadData()
        selectRowInTable(model.selectedIndex)
        refreshDocumentationPane()
        layoutAndPosition(panel: panel, caretRectInView: caretRectInView, in: view, parentWindow: parentWindow)
    }

    func moveSelection(delta: Int) {
        guard isVisible, !model.isEmpty else { return }
        model.moveSelection(delta: delta)
        selectRowInTable(model.selectedIndex)
        refreshDocumentationPane()
    }

    @discardableResult
    func acceptSelected() -> Bool {
        guard isVisible,
              let selected = model.selectedItem,
              let range = anchorFallbackRange else { return false }
        let handler = onAccept
        dismiss()
        handler?(selected, range)
        return true
    }

    func dismiss() {
        isVisible = false
        anchorFallbackRange = nil
        pendingResolveIDs.removeAll()
        model.reset()
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
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

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in _: NSTableView) -> Int {
        model.filteredItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < model.filteredItems.count else { return nil }
        let item = model.resolvedItem(for: model.filteredItems[row])
        let identifier = NSUserInterfaceItemIdentifier("CompletionRowCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? CompletionRowCellView)
            ?? CompletionRowCellView(identifier: identifier)
        cell.configure(
            item: item,
            query: model.query,
            isSelected: row == model.selectedIndex,
            isDark: isDarkAppearance
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView, tableView.selectedRow >= 0,
              tableView.selectedRow != model.selectedIndex else { return }
        model.select(index: tableView.selectedRow)
        refreshDocumentationPane()
    }

    @objc private func handleTableDoubleClick() {
        guard let tableView, tableView.clickedRow >= 0 else { return }
        model.select(index: tableView.clickedRow)
        _ = acceptSelected()
    }

    // MARK: - Layout & Documentation

    private func selectRowInTable(_ index: Int) {
        guard let tableView, index >= 0, index < model.filteredItems.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    private func refreshDocumentationPane() {
        guard let baseItemID = model.selectedBaseItemID,
              let selected = model.selectedItem else {
            setDocumentationVisible(false, text: "")
            return
        }
        let docText = Self.formattedDocumentation(for: selected)
        if !docText.isEmpty {
            setDocumentationVisible(true, text: docText)
        } else {
            setDocumentationVisible(false, text: "")
        }

        if selected.documentation == nil,
           selected.data != nil,
           !pendingResolveIDs.contains(baseItemID) {
            let itemID = baseItemID
            let requestGeneration = model.batchGeneration
            pendingResolveIDs.insert(itemID)
            onRequestResolve?(selected) { [weak self] resolved in
                guard let self,
                      self.isVisible,
                      self.model.batchGeneration == requestGeneration,
                      let resolved else { return }
                guard self.model.storeResolved(resolved, for: itemID, generation: requestGeneration) else { return }
                if self.model.selectedBaseItemID == itemID {
                    let updatedDoc = Self.formattedDocumentation(for: resolved)
                    self.setDocumentationVisible(!updatedDoc.isEmpty, text: updatedDoc)
                    self.tableView?.reloadData(
                        forRowIndexes: IndexSet(integer: self.model.selectedIndex),
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
            }
        }
    }

    private func setDocumentationVisible(_ visible: Bool, text: String) {
        docDivider?.isHidden = !visible
        docScrollView?.isHidden = !visible
        docTextView?.string = text
        guard let panel, let container = panel.contentView else { return }
        let listWidth: CGFloat = 310
        let docWidth: CGFloat = visible ? 250 : 0
        let totalWidth = listWidth + (visible ? 1 + docWidth : 0)
        var frame = panel.frame
        if abs(frame.width - totalWidth) > 0.5 {
            frame.size.width = totalWidth
            panel.setFrame(frame, display: true)
        }
        layoutSubviews(in: container, listWidth: listWidth, showDoc: visible, docWidth: docWidth)
    }

    private func layoutAndPosition(
        panel: NSPanel,
        caretRectInView: NSRect,
        in view: NSView,
        parentWindow: NSWindow
    ) {
        let rowHeight: CGFloat = 24
        let visibleRows = min(max(1, model.filteredItems.count), 10)
        let listHeight = CGFloat(visibleRows) * rowHeight + 8
        let showDoc = docScrollView?.isHidden == false
        let listWidth: CGFloat = 310
        let docWidth: CGFloat = showDoc ? 250 : 0
        let totalWidth = listWidth + (showDoc ? 1 + docWidth : 0)
        let totalHeight = max(listHeight, showDoc ? 156 : listHeight)

        let rectInWindow = view.convert(caretRectInView, to: nil)
        let rectOnScreen = parentWindow.convertToScreen(rectInWindow)
        let screenFrame = parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var originX = rectOnScreen.minX
        if originX + totalWidth > screenFrame.maxX - 8 {
            originX = max(screenFrame.minX + 8, screenFrame.maxX - totalWidth - 8)
        }
        var originY = rectOnScreen.minY - totalHeight - 4
        if originY < screenFrame.minY + 8 {
            originY = min(screenFrame.maxY - totalHeight - 8, rectOnScreen.maxY + 4)
        }

        panel.setFrame(NSRect(x: originX, y: originY, width: totalWidth, height: totalHeight), display: true)
        if let container = panel.contentView {
            layoutSubviews(in: container, listWidth: listWidth, showDoc: showDoc, docWidth: docWidth)
        }
    }

    private func layoutSubviews(in container: NSView, listWidth: CGFloat, showDoc: Bool, docWidth: CGFloat) {
        let height = container.bounds.height
        listScrollView?.frame = NSRect(x: 0, y: 0, width: listWidth, height: height)
        if showDoc {
            docDivider?.frame = NSRect(x: listWidth, y: 0, width: 1, height: height)
            docScrollView?.frame = NSRect(x: listWidth + 1, y: 0, width: docWidth, height: height)
            docTextView?.frame.size.width = max(1, docWidth - 4)
        }
    }

    private func ensurePanel(isDark: Bool) -> NSPanel {
        if let panel {
            updateAppearance(panel: panel, isDark: isDark)
            return panel
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 310, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.level = .floating

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 220))
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 1
        container.layer?.masksToBounds = true

        let table = NSTableView(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CompletionColumn"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(handleTableDoubleClick)

        let listScroll = NSScrollView(frame: .zero)
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        container.addSubview(listScroll)

        let divider = NSView(frame: .zero)
        divider.wantsLayer = true
        divider.isHidden = true
        container.addSubview(divider)

        let docText = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 150))
        docText.isEditable = false
        docText.isSelectable = true
        docText.drawsBackground = false
        docText.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        docText.textContainerInset = NSSize(width: 10, height: 8)
        docText.isVerticallyResizable = true
        docText.isHorizontallyResizable = false
        docText.textContainer?.widthTracksTextView = true

        let docScroll = NSScrollView(frame: .zero)
        docScroll.documentView = docText
        docScroll.hasVerticalScroller = true
        docScroll.autohidesScrollers = true
        docScroll.drawsBackground = false
        docScroll.isHidden = true
        container.addSubview(docScroll)

        panel.contentView = container
        self.panel = panel
        self.tableView = table
        self.listScrollView = listScroll
        self.docDivider = divider
        self.docScrollView = docScroll
        self.docTextView = docText
        updateAppearance(panel: panel, isDark: isDark)
        return panel
    }

    private func updateAppearance(panel: NSPanel, isDark: Bool) {
        panel.contentView?.layer?.backgroundColor = LitheTheme.nsColor(.editor, isDark: isDark).cgColor
        panel.contentView?.layer?.borderColor = LitheTheme.nsColor(.divider, isDark: isDark).cgColor
        docDivider?.layer?.backgroundColor = LitheTheme.nsColor(.divider, isDark: isDark).cgColor
        docTextView?.textColor = LitheTheme.nsColor(.primaryText, isDark: isDark)
    }

    static func formattedDocumentation(for item: LanguageServerCompletionItem) -> String {
        var parts: [String] = []
        if let detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            parts.append(detail)
        }
        if let doc = item.documentation?.trimmingCharacters(in: .whitespacesAndNewlines), !doc.isEmpty {
            parts.append(doc)
        }
        return parts.joined(separator: "\n\n")
    }
}

private final class CompletionRowCellView: NSTableCellView {
    private let badgeField = NSTextField(labelWithString: "")
    private let labelField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        badgeField.alignment = .center
        badgeField.font = .monospacedSystemFont(ofSize: 9.5, weight: .bold)
        badgeField.wantsLayer = true
        badgeField.layer?.cornerRadius = 4

        labelField.lineBreakMode = .byTruncatingTail
        labelField.maximumNumberOfLines = 1

        detailField.alignment = .right
        detailField.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        detailField.lineBreakMode = .byTruncatingTail
        detailField.maximumNumberOfLines = 1

        addSubview(badgeField)
        addSubview(labelField)
        addSubview(detailField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        item: LanguageServerCompletionItem,
        query: String,
        isSelected _: Bool,
        isDark: Bool
    ) {
        let style = Self.kindBadge(for: item.kind)
        badgeField.stringValue = style.letter
        badgeField.textColor = style.color
        badgeField.layer?.backgroundColor = style.color.withAlphaComponent(0.16).cgColor

        let baseColor = LitheTheme.nsColor(.primaryText, isDark: isDark)
        let attributed = NSMutableAttributedString(
            string: item.label,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: baseColor,
            ]
        )
        if !query.isEmpty {
            let nsLabel = item.label as NSString
            let range = nsLabel.range(of: query, options: [.caseInsensitive])
            if range.location != NSNotFound {
                attributed.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                        .foregroundColor: LitheTheme.nsColor(.accent, isDark: isDark),
                    ],
                    range: range
                )
            }
        }
        labelField.attributedStringValue = attributed
        detailField.stringValue = item.detail ?? ""
        detailField.textColor = LitheTheme.nsColor(.secondaryText, isDark: isDark)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        badgeField.frame = NSRect(x: 8, y: (h - 16) / 2, width: 16, height: 16)
        let hasDetail = !detailField.stringValue.isEmpty
        let detailWidth: CGFloat = hasDetail ? min(115, bounds.width * 0.38) : 0
        let labelX: CGFloat = 30
        let labelWidth = max(40, bounds.width - labelX - detailWidth - (hasDetail ? 14 : 8))
        labelField.frame = NSRect(x: labelX, y: (h - 16) / 2, width: labelWidth, height: 16)
        detailField.frame = NSRect(
            x: bounds.width - detailWidth - 8,
            y: (h - 14) / 2,
            width: detailWidth,
            height: 14
        )
    }

    private static func kindBadge(for lspKind: Int?) -> (letter: String, color: NSColor) {
        switch lspKind {
        case 2, 3: // Method, Function
            ("ƒ", NSColor.systemBlue)
        case 4: // Constructor
            ("c", NSColor.systemBlue)
        case 5, 10: // Field, Property
            ("p", NSColor.systemPurple)
        case 6: // Variable
            ("v", NSColor.systemTeal)
        case 7, 22: // Class, Struct
            ("S", NSColor.systemOrange)
        case 8: // Interface
            ("I", NSColor.systemGreen)
        case 9: // Module
            ("M", NSColor.secondaryLabelColor)
        case 13, 20: // Enum, EnumMember
            ("E", NSColor.systemYellow)
        case 14: // Keyword
            ("k", NSColor.systemPink)
        case 15: // Snippet
            ("⌘", NSColor.systemIndigo)
        case 21: // Constant
            ("K", NSColor.systemPink)
        default:
            ("•", NSColor.secondaryLabelColor)
        }
    }
}
