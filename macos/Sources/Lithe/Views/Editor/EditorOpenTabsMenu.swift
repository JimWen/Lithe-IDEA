import SwiftUI

/// Gives overflowing document, media and terminal tabs one reachable switcher.
struct EditorOpenTabsMenu: View {
    @EnvironmentObject private var model: AppModel
    let selectedTab: EditorTabItem?
    @State private var isPresented = false

    fileprivate struct Entry: Identifiable {
        let id: EditorTabItem
        let title: String
        let detail: String
        let icon: LitheIconKind?
    }

    private var entries: [Entry] {
        var byID: [EditorTabItem: Entry] = [:]
        for document in model.openDocuments {
            let id = EditorTabItem.document(document.id)
            byID[id] = Entry(id: id, title: document.displayName, detail: displayPath(document.url),
                             icon: LitheIcons.kind(for: document.url, isDirectory: false))
        }
        for media in model.openMediaDocuments {
            let id = EditorTabItem.media(media.id)
            byID[id] = Entry(id: id, title: media.displayName, detail: displayPath(media.url),
                             icon: LitheIcons.kind(for: media.url, isDirectory: false))
        }
        for session in model.editorTerminalSessions {
            let id = EditorTabItem.terminal(session.id)
            let title = model.terminalTitle(for: session)
            byID[id] = Entry(id: id, title: title, detail: title, icon: nil)
        }
        return model.editorTabItems.compactMap { byID[$0] }
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .litheRowHover(isActive: isPresented, cornerRadius: LitheTheme.Metrics.cornerRadius,
                       activeBackground: LitheTheme.subtleSelection)
        .frame(width: 32, height: LitheTheme.Metrics.tabHeight)
        .help("Open Tabs")
        .accessibilityLabel("Open Tabs")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            EditorOpenTabsPopover(entries: entries, selectedTab: selectedTab) { item in
                isPresented = false
                select(item)
            }
        }
    }

    private func displayPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let root = model.workspaceURL?.standardizedFileURL.path, path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return url.deletingLastPathComponent().path + "/" + url.lastPathComponent
    }

    private func select(_ item: EditorTabItem) {
        switch item {
        case .document(let id):
            if let document = model.openDocuments.first(where: { $0.id == id }) {
                model.selectEditorDocument(document)
            }
        case .terminal(let id):
            if let session = model.editorTerminalSessions.first(where: { $0.id == id }) {
                model.selectEditorTerminalSession(session)
            }
        case .media(let id):
            if let media = model.openMediaDocuments.first(where: { $0.id == id }) {
                model.selectMediaDocument(media)
            }
        }
    }
}

private struct EditorOpenTabsPopover: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [EditorOpenTabsMenu.Entry]
    let selectedTab: EditorTabItem?
    let select: (EditorTabItem) -> Void
    @State private var query = ""
    @State private var highlightedTab: EditorTabItem?
    @FocusState private var searchFocused: Bool

    private var filteredEntries: [EditorOpenTabsMenu.Entry] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? entries : entries.filter {
            $0.title.localizedCaseInsensitiveContains(value) || $0.detail.localizedCaseInsensitiveContains(value)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("Open Tabs", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let highlightedTab { select(highlightedTab) } }
                    .onMoveCommand { direction in
                        if direction == .up { moveSelection(by: -1) }
                        if direction == .down { moveSelection(by: 1) }
                    }
                Text(verbatim: "\(entries.count)")
                    .font(LitheTheme.uiFont(size: LitheTheme.Metrics.popupDetailFontSize))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(336, CGFloat(max(1, filteredEntries.count)) * LitheTheme.Metrics.popupRowHeight + 12))
                .overlay {
                    if filteredEntries.isEmpty {
                        Text("No matching files").foregroundStyle(LitheTheme.secondaryText)
                    }
                }
                .onAppear { if let selectedTab { proxy.scrollTo(selectedTab, anchor: .center) } }
                .onChange(of: highlightedTab) { value in
                    if let value { proxy.scrollTo(value) }
                }
            }
            Divider()
            Text(verbatim: filteredEntries.first(where: { $0.id == highlightedTab })?.detail ?? " ")
                .font(LitheTheme.uiFont(size: LitheTheme.Metrics.popupDetailFontSize))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        }
        .font(LitheTheme.uiFont(size: LitheTheme.Metrics.popupFontSize))
        .foregroundStyle(LitheTheme.primaryText)
        .frame(width: 360)
        .background(LitheTheme.popupBackground)
        .onExitCommand { dismiss() }
        .onAppear {
            highlightedTab = selectedTab ?? entries.first?.id
            searchFocused = true
        }
        .onChange(of: query) { _ in highlightedTab = filteredEntries.first?.id }
    }

    private func row(_ entry: EditorOpenTabsMenu.Entry) -> some View {
        Button { select(entry.id) } label: {
            HStack(spacing: 8) {
                if let icon = entry.icon {
                    LitheIcon(kind: icon, size: LitheTheme.Metrics.tabIconSize)
                } else {
                    LitheIDEAIcon(resourcePath: "toolwindows/toolWindowTerminal.svg", size: 16,
                                  fallbackSystemImage: "terminal")
                }
                Text(verbatim: entry.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LitheTheme.accent)
                    .opacity(entry.id == selectedTab ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: LitheTheme.Metrics.popupRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .litheRowHover(isActive: entry.id == highlightedTab, cornerRadius: LitheTheme.Metrics.cornerRadius,
                       activeBackground: LitheTheme.subtleSelection)
        .onHover { if $0 { highlightedTab = entry.id } }
        .help(entry.detail)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(entry.id == selectedTab ? .isSelected : [])
    }

    private func moveSelection(by offset: Int) {
        guard !filteredEntries.isEmpty else { return }
        let index = filteredEntries.firstIndex(where: { $0.id == highlightedTab }) ?? 0
        highlightedTab = filteredEntries[min(max(0, index + offset), filteredEntries.count - 1)].id
    }
}
