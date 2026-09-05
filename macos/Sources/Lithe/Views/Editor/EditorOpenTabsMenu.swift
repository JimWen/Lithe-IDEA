import SwiftUI

/// Gives overflowing document, media and terminal tabs one reachable switcher.
struct EditorOpenTabsMenu: View {
    @EnvironmentObject private var model: AppModel
    let selectedTab: EditorTabItem?

    private struct Entry: Identifiable {
        let id: EditorTabItem
        let title: String
        let detail: String
    }

    private var entries: [Entry] {
        var byID: [EditorTabItem: Entry] = [:]
        for document in model.openDocuments {
            let id = EditorTabItem.document(document.id)
            byID[id] = Entry(id: id, title: document.displayName, detail: document.url.path)
        }
        for media in model.openMediaDocuments {
            let id = EditorTabItem.media(media.id)
            byID[id] = Entry(id: id, title: media.displayName, detail: media.displayName)
        }
        for session in model.editorTerminalSessions {
            let id = EditorTabItem.terminal(session.id)
            let title = model.terminalTitle(for: session)
            byID[id] = Entry(id: id, title: title, detail: title)
        }
        return model.editorTabItems.compactMap { byID[$0] }
    }

    var body: some View {
        Menu {
            ForEach(entries) { entry in
                Button {
                    select(entry.id)
                } label: {
                    HStack {
                        Text(verbatim: entry.title)
                        if selectedTab == entry.id { Image(systemName: "checkmark") }
                    }
                }
                .help(entry.detail)
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 32, height: LitheTheme.Metrics.tabHeight)
        .help("Open Tabs")
        .accessibilityLabel("Open Tabs")
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
