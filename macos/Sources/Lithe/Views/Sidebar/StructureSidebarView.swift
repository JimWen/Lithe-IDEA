import LitheCoreContracts
import SwiftUI

struct StructureSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filterText = ""

    var body: some View {
        StructureSidebarContent(
            chrome: model.editorChrome,
            activeDocument: model.activeDocument,
            filterText: $filterText,
            onRefresh: {
                if let document = model.activeDocument {
                    model.refreshDocumentSymbols(for: document)
                }
            },
            onSelect: { symbol in
                guard let url = model.activeDocument?.url else { return }
                model.navigateToEditorLocation(
                    url: url,
                    line: symbol.selectionRange.start.line,
                    utf16Column: symbol.selectionRange.start.utf16Column
                )
            }
        )
    }
}

private struct StructureSidebarContent: View {
    @ObservedObject var chrome: EditorChromeModel
    let activeDocument: EditorDocument?
    @Binding var filterText: String
    let onRefresh: () -> Void
    let onSelect: (LanguageServerDocumentSymbol) -> Void

    private var activeDocumentURL: URL? {
        activeDocument?.url.standardizedFileURL
    }

    private var symbols: [LanguageServerDocumentSymbol] {
        guard let activeDocumentURL, chrome.documentSymbolsURL == activeDocumentURL else {
            return []
        }
        return chrome.documentSymbols
    }

    private var activeSymbolID: String? {
        guard let caret = chrome.caret,
              caret.url.standardizedFileURL == activeDocumentURL else { return nil }
        return LanguageServerDocumentSymbol.enclosingPath(
            in: symbols,
            line: caret.line,
            utf16Column: caret.utf16Column
        ).last?.id
    }

    private var flattenedRows: [StructureSymbolRow] {
        let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var rows: [StructureSymbolRow] = []
        collectRows(from: symbols, depth: 0, filter: trimmed, into: &rows)
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LitheTheme.divider)
            if activeDocument == nil {
                emptyState(message: "Open a file to inspect its structure")
            } else if flattenedRows.isEmpty {
                emptyState(message: "No symbols found")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(flattenedRows) { row in
                            symbolRowView(row)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if let activeDocument, chrome.documentSymbolsURL != activeDocument.url.standardizedFileURL {
                onRefresh()
            }
        }
        .onChange(of: activeDocument?.id) { _ in
            if activeDocument != nil {
                onRefresh()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("Structure")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                if let fileName = activeDocument?.displayName {
                    Text(fileName)
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(LitheIconButtonStyle())
                .lithePointer()
                .disabled(activeDocument == nil)
                .help("Refresh")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.tertiaryText)
                TextField(LocalizedStringKey("Filter symbols…"), text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(LitheTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(LitheTheme.divider, lineWidth: 1)
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func symbolRowView(_ row: StructureSymbolRow) -> some View {
        let isSelected = row.symbol.id == activeSymbolID
        let badge = SymbolKindBadge.badge(for: row.symbol.kind)
        return Button {
            onSelect(row.symbol)
        } label: {
            HStack(spacing: 6) {
                Text(badge.letter)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(badge.color)
                    .frame(width: 16, height: 16)
                    .background(badge.color.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Text(row.symbol.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    .lineLimit(1)

                if let detail = row.symbol.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                Text(":\(row.symbol.selectionRange.start.line + 1)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
            .padding(.leading, CGFloat(row.depth) * 14 + 6)
            .padding(.trailing, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
            .litheRowHover(
                isActive: isSelected,
                cornerRadius: 5,
                activeBackground: LitheTheme.subtleSelection
            )
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    private func emptyState(message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 22))
                .foregroundStyle(LitheTheme.tertiaryText)
            Text(LocalizedStringKey(message))
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func collectRows(
        from nodes: [LanguageServerDocumentSymbol],
        depth: Int,
        filter: String,
        into rows: inout [StructureSymbolRow]
    ) {
        for node in nodes {
            var childRows: [StructureSymbolRow] = []
            collectRows(from: node.children, depth: depth + 1, filter: filter, into: &childRows)
            let matchesSelf = filter.isEmpty
                || node.name.lowercased().contains(filter)
                || (node.detail?.lowercased().contains(filter) ?? false)
            if matchesSelf || !childRows.isEmpty {
                rows.append(StructureSymbolRow(symbol: node, depth: depth))
                rows.append(contentsOf: childRows)
            }
        }
    }
}

private struct StructureSymbolRow: Identifiable {
    let symbol: LanguageServerDocumentSymbol
    let depth: Int
    var id: String { "\(depth):\(symbol.id)" }
}

enum SymbolKindBadge {
    struct Style {
        let letter: String
        let color: Color
    }

    static func badge(for lspKind: Int) -> Style {
        switch lspKind {
        case 2, 3, 4: // Module, Namespace, Package
            Style(letter: "M", color: .secondary)
        case 5: // Class
            Style(letter: "C", color: Color(red: 0.88, green: 0.56, blue: 0.28))
        case 6: // Method
            Style(letter: "m", color: Color(red: 0.40, green: 0.66, blue: 0.96))
        case 7, 8: // Property, Field
            Style(letter: "f", color: Color(red: 0.68, green: 0.52, blue: 0.92))
        case 9: // Constructor
            Style(letter: "c", color: Color(red: 0.40, green: 0.66, blue: 0.96))
        case 10, 22: // Enum, EnumMember
            Style(letter: "E", color: Color(red: 0.85, green: 0.68, blue: 0.30))
        case 11: // Interface
            Style(letter: "I", color: Color(red: 0.36, green: 0.78, blue: 0.62))
        case 12: // Function
            Style(letter: "ƒ", color: Color(red: 0.40, green: 0.66, blue: 0.96))
        case 13: // Variable
            Style(letter: "v", color: Color(red: 0.56, green: 0.74, blue: 0.88))
        case 14: // Constant
            Style(letter: "K", color: Color(red: 0.80, green: 0.52, blue: 0.72))
        case 23: // Struct
            Style(letter: "S", color: Color(red: 0.88, green: 0.56, blue: 0.28))
        default:
            Style(letter: "•", color: .secondary)
        }
    }
}

/// Isolated breadcrumb tail observing `EditorChromeModel` directly so caret
/// movement updates the enclosing symbol path without redrawing `WorkbenchView`.
struct EditorSymbolBreadcrumbsView: View {
    @ObservedObject var chrome: EditorChromeModel
    let documentURL: URL
    let onSelect: (LanguageServerDocumentSymbol) -> Void

    private var enclosingSymbols: [LanguageServerDocumentSymbol] {
        let normalizedURL = documentURL.standardizedFileURL
        guard chrome.documentSymbolsURL == normalizedURL,
              !chrome.documentSymbols.isEmpty else { return [] }
        let line = chrome.caret?.url.standardizedFileURL == normalizedURL ? (chrome.caret?.line ?? 0) : 0
        let col = chrome.caret?.url.standardizedFileURL == normalizedURL ? (chrome.caret?.utf16Column ?? 0) : 0
        return LanguageServerDocumentSymbol.enclosingPath(
            in: chrome.documentSymbols,
            line: line,
            utf16Column: col
        )
    }

    var body: some View {
        ForEach(enclosingSymbols) { symbol in
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(LitheTheme.tertiaryText)
            Button {
                onSelect(symbol)
            } label: {
                let badge = SymbolKindBadge.badge(for: symbol.kind)
                HStack(spacing: 4) {
                    Text(badge.letter)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(badge.color)
                    Text(symbol.name)
                        .lineLimit(1)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
            .buttonStyle(.plain)
            .lithePointer()
        }
    }
}
