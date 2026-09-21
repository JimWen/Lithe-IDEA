import AppKit
import LitheSearchModule
import SwiftUI

enum SearchEverywhereScope: String, CaseIterable, Identifiable {
    case all = "All"
    case classes = "Classes"
    case files = "Files"
    case symbols = "Symbols"
    case actions = "Actions"
    case text = "Text"

    var id: String { rawValue }
}

enum SearchEverywhereQueryMode: Equatable {
    case workspace(String)
    case commands(String)

    init(query: String) {
        if query.hasPrefix("/") {
            self = .commands(String(query.dropFirst()))
        } else {
            self = .workspace(query)
        }
    }

    var workspaceQuery: String {
        switch self {
        case .workspace(let query): return query
        case .commands: return ""
        }
    }

    var workspaceSearchTaskID: String {
        switch self {
        case .workspace(let query): return "workspace:\(query)"
        case .commands: return "commands"
        }
    }

    var commandQuery: String? {
        switch self {
        case .workspace: return nil
        case .commands(let query): return query
        }
    }
}

enum SearchEverywhereResultSource: Equatable {
    case combinedWorkspaceNames
    case classes
    case files
    case symbols
    case actions(String)
    case commands(String)
    case text

    init(queryMode: SearchEverywhereQueryMode, scope: SearchEverywhereScope) {
        if let commandQuery = queryMode.commandQuery {
            self = .commands(commandQuery)
            return
        }

        switch scope {
        case .all: self = .combinedWorkspaceNames
        case .classes: self = .classes
        case .files: self = .files
        case .symbols: self = .symbols
        case .actions: self = .actions(queryMode.workspaceQuery)
        case .text: self = .text
        }
    }

    var emptyResultsMessage: String {
        switch self {
        case .commands:
            return "No matching commands"
        case .combinedWorkspaceNames:
            return "No matches in All"
        case .classes:
            return "No matches in Classes"
        case .files:
            return "No matches in Files"
        case .symbols:
            return "No matches in Symbols"
        case .actions:
            return "No matches in Actions"
        case .text:
            return "No matches in Text"
        }
    }
}

/// IDEA 风格的全局搜索弹窗：分类标签、双栏结果和可执行 Actions 共用同一套键盘导航。
struct SearchEverywhereView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var scope: SearchEverywhereScope = .all
    @State private var searchOptions = ProjectSearchOptions.default

    private enum SearchItem {
        case result(FileSearchResult)
        case action(LitheAction)
    }

    private var visibleItems: [SearchItem] {
        switch resultSource {
        case .combinedWorkspaceNames:
            // 对齐 IDEA：默认视图按“名字”找（文件、类、符号），
            // 正文命中只在 Text 标签页出现，避免与 Find in Files 的结果重叠。
            // Action 由 `/` 命令模式或 Actions 标签页展示。
            let nameMatches = model.searchEverywhereResults.fileMatches
                + model.searchEverywhereResults.classMatches
                + model.searchEverywhereResults.symbolMatches
            return rankedResults(nameMatches)
        case .classes:
            return results(in: model.searchEverywhereResults.classMatches)
        case .files:
            return results(in: model.searchEverywhereResults.fileMatches)
        case .symbols:
            return results(in: model.searchEverywhereResults.symbolMatches)
        case .text:
            return results(in: model.searchEverywhereResults.contentMatches)
        case .actions(let actionQuery), .commands(let actionQuery):
            return model.searchEverywhereActionMatches(query: actionQuery).map(SearchItem.action)
        }
    }

    private var queryMode: SearchEverywhereQueryMode {
        SearchEverywhereQueryMode(query: query)
    }

    private var resultSource: SearchEverywhereResultSource {
        SearchEverywhereResultSource(queryMode: queryMode, scope: scope)
    }

    private struct RankedResult {
        let index: Int
        let score: Int
        let value: FileSearchResult
    }

    /// 按相关度降序。同分保持原顺序，避免逐字输入时行位置来回跳动。
    private func rankedResults(_ results: [FileSearchResult]) -> [SearchItem] {
        var ranked: [RankedResult] = []
        ranked.reserveCapacity(results.count)
        for (index, value) in results.enumerated() {
            ranked.append(
                RankedResult(index: index, score: SearchRelevance.score(value, query: query), value: value)
            )
        }
        ranked.sort { left, right in
            left.score == right.score ? left.index < right.index : left.score > right.score
        }
        return ranked.map { SearchItem.result($0.value) }
    }

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            // IDEA 不压暗编辑器，所以这层只用来接收“点击外部关闭”，不着色。
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { model.dismissSearchEverywhere() }

            VStack(spacing: 0) {
                scopeTabs
                searchField
                if hasQuery {
                    Rectangle().fill(LitheTheme.divider).frame(height: 1)
                    resultsList
                }
            }
            .frame(width: 860)
            .frame(maxHeight: 560, alignment: .top)
            .lithePopupChrome()
            .padding(.top, 84)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            query = model.searchEverywhereQuery
            searchFocused = true
            selectedIndex = 0
        }
        .background(MacSearchKeyboardHandler(isEnabled: { model.isSearchEverywhereVisible }, handle: handleKey))
        .onChange(of: query) { _ in
            selectedIndex = 0
            model.clearSearchEverywhereResults()
        }
        .onChange(of: searchOptions) { _ in model.clearSearchEverywhereResults() }
        .onChange(of: scope) { _ in selectedIndex = 0 }
        .task(id: "\(queryMode.workspaceSearchTaskID)|\(searchOptions.cacheKey)") {
            if queryMode.commandQuery != nil {
                await model.searchEverywhere(query: "", options: searchOptions)
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await model.searchEverywhere(query: queryMode.workspaceQuery, options: searchOptions)
        }
    }

    private var scopeTabs: some View {
        HStack(spacing: 2) {
            ForEach(SearchEverywhereScope.allCases) { item in
                Button {
                    scope = item
                } label: {
                    Text(LocalizedStringKey(item.rawValue))
                        .font(.system(size: 12, weight: scope == item ? .semibold : .regular))
                        .foregroundStyle(scope == item ? LitheTheme.primaryText : LitheTheme.secondaryText)
                        .padding(.horizontal, 11)
                        .frame(height: 38)
                        .overlay(alignment: .bottom) {
                            if scope == item {
                                Rectangle().fill(LitheTheme.accent).frame(height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .lithePointer()
                .contentShape(Rectangle())
            }

            Spacer(minLength: 12)
            if model.isSearchingEverywhere {
                ProgressView().controlSize(.mini)
            }
            searchOptionsMenu
            Button {
                model.dismissSearchEverywhere()
            } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .help("Close (Esc)")
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .background(LitheTheme.toolHeader)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            LitheSystemIcon(systemImage: "magnifyingglass")
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
            if query.isEmpty {
                Text("Type / to see commands")
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .allowsHitTesting(false)
            } else {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .litheIconButton()
                .foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(LitheTheme.popupBackground)
    }

    private var searchOptionsMenu: some View {
        Menu {
            Toggle("Match Case", isOn: $searchOptions.caseSensitive)
            Toggle("Whole Words", isOn: $searchOptions.wholeWords)
            Toggle("Regular Expression", isOn: $searchOptions.regularExpression)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(searchOptions == .default ? LitheTheme.secondaryText : LitheTheme.accent)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .lithePointer()
        .help("Search options")
    }

    @ViewBuilder
    private var resultsList: some View {
        if visibleItems.isEmpty {
            if !model.isSearchingEverywhere {
                placeholder(resultSource.emptyResultsMessage)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleItems.enumerated()), id: \.offset) { index, item in
                            itemRow(item, index: index)
                                .id(index)
                        }
                        if isTruncated {
                            moreRow
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: selectedIndex) { index in
                    guard visibleItems.indices.contains(index) else { return }
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    /// 后端按 matchLimit 截断，命中数刚好顶到上限时提示还有更多。
    private var isTruncated: Bool {
        guard queryMode.commandQuery == nil else { return false }
        return model.searchEverywhereResults.allMatches.count >= SearchEverywhereResults.matchLimit
    }

    private var moreRow: some View {
        Text("… more")
            .font(.system(size: 11))
            .foregroundStyle(LitheTheme.tertiaryText)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 22)
    }

    @ViewBuilder
    private func itemRow(_ item: SearchItem, index: Int) -> some View {
        switch item {
        case .result(let result):
            resultRow(result, index: index, showsLine: result.kind != .file)
        case .action(let action):
            actionRow(action, index: index)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(LitheTheme.uiFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 34)
    }

    private func resultRow(_ result: FileSearchResult, index: Int, showsLine: Bool) -> some View {
        // 文件夹按钮与整行点击是两个独立目标，所以并排放而不是嵌套，
        // 否则嵌套的 Button 收不到点击。
        HStack(spacing: 8) {
            Button {
                model.openSearchEverywhereResult(result)
            } label: {
                HStack(spacing: 8) {
                    LitheIcon(kind: iconKind(for: result), size: 14)
                        .frame(width: 16)

                    // 对齐 IDEA：名字和路径左侧连排，而不是把路径推到右端。
                    Text(result.symbolName ?? result.url.lastPathComponent)
                        .font(.system(size: 12.5))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if showsLine, let line = result.line {
                        Text(":\(line)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(containerPath(for: result.url))
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if result.kind == .content {
                        Text(result.preview)
                            .font(.system(size: 10.5))
                            .foregroundStyle(LitheTheme.tertiaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    Text(moduleLabel(for: result.url))
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()

            Button {
                model.revealProjectItemInFinder(result.url)
            } label: {
                LitheIcon(kind: .folder, size: 13)
            }
            .buttonStyle(.plain)
            .lithePointer()
            .help("Show in Finder")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(index == selectedIndex ? LitheTheme.selection : .clear)
        .litheContextMenu {
            [
                .action("Open", systemImage: "doc.text", action: {
                    model.openSearchEverywhereResult(result)
                }),
                .action("Show in Finder", systemImage: "folder", action: {
                    model.revealProjectItemInFinder(result.url)
                }),
                .submenu("Copy Path / Reference", items: [
                    .action("Copy Path", action: {
                        model.copyProjectItemPath(result.url, relative: false)
                    }),
                    .action("Copy Relative Path", action: {
                        model.copyProjectItemPath(result.url, relative: true)
                    })
                ])
            ]
        }
    }

    /// 结果所在目录（不含文件名本身），文件直接位于工作区根下时为空。
    private func containerPath(for url: URL) -> String {
        let relative = model.relativePath(for: url)
        let parent = (relative as NSString).deletingLastPathComponent
        return parent
    }

    /// Show the containing top-level workspace directory.
    private func moduleLabel(for url: URL) -> String {
        return model.relativePath(for: url).components(separatedBy: "/").first ?? ""
    }

    private func actionRow(_ action: LitheAction, index: Int) -> some View {
        Button {
            model.performSearchEverywhereAction(action)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LitheTheme.warning)
                    .frame(width: 16)
                Text(LocalizedStringKey(action.title))
                    .font(.system(size: 12.5))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(LocalizedStringKey(action.subtitle))
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(action.group.rawValue))
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                    if let keyEquivalent = action.keyEquivalent {
                        Text(keyEquivalent)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(index == selectedIndex ? LitheTheme.selection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    private func iconKind(for result: FileSearchResult) -> LitheIconKind {
        switch result.kind {
        case .file, .content:
            return LitheIcons.kind(for: result.url, isDirectory: false)
        case .type:
            return .javaClass
        case .symbol:
            return .javaGeneric
        }
    }

    private func results(in results: [FileSearchResult]) -> [SearchItem] {
        results.map(SearchItem.result)
    }

    private func handleKey(_ action: MacSearchKeyboardAction) -> Bool {
        switch action {
        case .move(let delta):
            if !visibleItems.isEmpty {
                selectedIndex = min(max(selectedIndex + delta, 0), visibleItems.count - 1)
            }
        case .category(let delta): moveScope(by: delta)
        case .submit: performSelectedItem()
        case .dismiss: model.dismissSearchEverywhere()
        }
        return true
    }

    private func moveScope(by offset: Int) {
        let scopes = SearchEverywhereScope.allCases
        guard let currentIndex = scopes.firstIndex(of: scope) else { return }
        let nextIndex = (currentIndex + offset + scopes.count) % scopes.count
        scope = scopes[nextIndex]
    }

    private func performSelectedItem() {
        guard visibleItems.indices.contains(selectedIndex) else { return }
        switch visibleItems[selectedIndex] {
        case .result(let result): model.openSearchEverywhereResult(result)
        case .action(let action): model.performSearchEverywhereAction(action)
        }
    }

}
