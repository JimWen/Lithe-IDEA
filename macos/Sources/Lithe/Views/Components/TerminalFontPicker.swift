import AppKit
import SwiftUI

/// Native completion keeps a long font catalog searchable without rebuilding
/// its popup while unrelated model publications refresh the settings page.
struct TerminalFontPicker: NSViewRepresentable {
    @Environment(\.locale) private var locale
    @Binding var selection: String?
    let fonts: [TerminalFontChoice]
    let includesDefault: Bool
    let label: String

    struct Entry: Equatable {
        let id: String?
        let title: String
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FontComboBox {
        let view = FontComboBox()
        view.font = .systemFont(ofSize: 13)
        view.controlSize = .regular
        view.numberOfVisibleItems = 12
        view.completes = true
        view.isEditable = true
        view.delegate = context.coordinator
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: FontComboBox, context: Context) {
        let coordinator = context.coordinator
        let bundle = Bundle.main.path(forResource: locale.identifier, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
        let defaultTitle = bundle.localizedString(forKey: "Default terminal font", value: nil, table: nil)
        let duplicates = Dictionary(grouping: fonts, by: \.displayName)
        var entries = fonts.map { font in
            Entry(id: font.id, title: (duplicates[font.displayName]?.count ?? 0) > 1
                  ? "\(font.displayName) (\(font.id))" : font.displayName)
        }
        if includesDefault { entries.insert(Entry(id: nil, title: defaultTitle), at: 0) }
        coordinator.onChange = { selection = $0 }
        view.onWindowClose = { [weak view, weak coordinator] in
            guard let view else { return }
            coordinator?.finishEditing(in: view)
        }
        coordinator.includesDefault = includesDefault
        coordinator.updating = true
        if coordinator.entries != entries {
            coordinator.entries = entries
            view.removeAllItems()
            view.addItems(withObjectValues: entries.map(\.title))
        }
        if view.currentEditor() == nil || coordinator.selectedID != selection {
            coordinator.draft = nil
            if let index = entries.firstIndex(where: { $0.id == selection }) {
                if view.indexOfSelectedItem != index { view.selectItem(at: index) }
            } else if view.indexOfSelectedItem >= 0 {
                view.deselectItem(at: view.indexOfSelectedItem)
            }
            let title = entries.first { $0.id == selection }?.title ?? selection ?? ""
            view.stringValue = title
            view.currentEditor()?.string = title
        }
        coordinator.selectedID = selection
        coordinator.updating = false
        let localizedLabel = bundle.localizedString(forKey: label, value: label, table: nil)
        view.placeholderString = localizedLabel
        view.setAccessibilityLabel(localizedLabel)
    }

    static func dismantleNSView(_ view: FontComboBox, coordinator: Coordinator) {
        view.delegate = nil
        view.onWindowClose = nil
        coordinator.onChange = nil
    }

    final class FontComboBox: NSComboBox {
        var onWindowClose: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                                       name: NSWindow.willCloseNotification, object: window)
            }
        }

        @objc private func windowWillClose(_ notification: Notification) { onWindowClose?() }
        deinit { NotificationCenter.default.removeObserver(self) }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var entries: [Entry] = []
        var selectedID: String?
        var draft: String?
        var includesDefault = false
        var updating = false
        var onChange: ((String?) -> Void)?

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSComboBox,
                  entries.indices.contains(view.indexOfSelectedItem) else { return }
            commit(entries[view.indexOfSelectedItem].id)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSComboBox else { return }
            finishEditing(in: view)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSComboBox else { return }
            draft = view.currentEditor()?.string ?? view.stringValue
        }

        func finishEditing(in view: NSComboBox) {
            let text = (draft ?? view.currentEditor()?.string ?? view.stringValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let entry = entries.first(where: { $0.title == text }) {
                commit(entry.id)
            } else {
                // A manually entered value is a PostScript ID, never a family
                // display name that CoreText might silently substitute.
                commit(text.isEmpty && includesDefault ? nil : text)
            }
        }

        private func commit(_ id: String?) {
            draft = nil
            guard id != selectedID else { return }
            selectedID = id
            onChange?(id)
        }
    }
}
