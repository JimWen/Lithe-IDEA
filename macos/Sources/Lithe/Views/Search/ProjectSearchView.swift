import AppKit
import SwiftUI
import LitheSearchModule

/// Find in Files keeps search state in the existing search module; selecting a
/// row previews bounded context without opening or modifying an editor tab.
struct ProjectSearchView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var queryFocused: Bool
    @State private var selectedID: String?
    @State private var preview: ProjectSearchPreview?

    private var matches: [FileSearchResult] { model.projectSearchMatches }
    private var selected: FileSearchResult? { matches.first { $0.id == selectedID } }
    private var searchIdentity: String {
        "\(model.searchQuery)|\(model.projectSearchOptions.cacheKey)|\(model.projectSearchScope.rawValue)|\(model.projectSearchDirectory)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            queryBar
            scopes
            if let error = model.projectSearchError {
                Text(error).font(.system(size: 12)).foregroundStyle(LitheTheme.error)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            }
            GeometryReader { geometry in
                LitheSplitPaneView(
                    axis: .vertical, placement: .leading,
                    defaultSize: geometry.size.height * 0.43,
                    minimum: 90, maximum: max(90, geometry.size.height - 150),
                    flexibleMinimum: 140,
                    sized: { results }, flexible: { previewPane }
                )
            }
            Divider()
            footer
        }
        .frame(width: 880, height: 650)
        .background(LitheTheme.popupBackground)
        .foregroundStyle(LitheTheme.primaryText)
        .onAppear { queryFocused = true; selectedID = matches.first?.id }
        .onExitCommand { model.isProjectSearchPresented = false }
        .task(id: searchIdentity) {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            await model.searchProject()
        }
        .onChange(of: matches) { values in
            if !values.contains(where: { $0.id == selectedID }) { selectedID = values.first?.id }
        }
        .task(id: selectedID) {
            preview = nil
            guard let selected else { return }
            let value = await model.searchPreview(for: selected)
            guard !Task.isCancelled, selectedID == selected.id else { return }
            preview = value
        }
        .background(MacSearchKeyboardHandler(isEnabled: { model.isProjectSearchPresented }) { action in
            guard case .move(let delta) = action else { return false }
            moveSelection(delta)
            return true
        })
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Find in Files").font(.system(size: 14, weight: .semibold))
            Text("\(matches.count) matches in \(Set(matches.map(\.url)).count) files")
                .font(.system(size: 13)).foregroundStyle(LitheTheme.secondaryText)
            if model.isSearching { ProgressView().controlSize(.small) }
            Spacer()
            Text("File mask:").font(.system(size: 13))
            TextField("*.go, *.rs, *.py", text: $model.projectSearchOptions.fileMask)
                .textFieldStyle(.roundedBorder).frame(width: 155)
                .help("Comma-separated glob patterns. Empty searches every file.")
            Button { model.isProjectSearchPresented = false } label: { Image(systemName: "xmark") }
                .litheIconButton().help("Close")
        }
        .padding(.horizontal, 16).frame(height: 46)
        .background(LitheTheme.toolHeader)
    }

    private var queryBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(LitheTheme.secondaryText)
            TextField("Find", text: $model.searchQuery)
                .textFieldStyle(.plain).font(.system(size: 14)).focused($queryFocused)
                .onSubmit(openSelected)
            if !model.searchQuery.isEmpty {
                Button { model.searchQuery = "" } label: { Image(systemName: "xmark") }
                    .litheIconButton().help("Clear search")
            }
            option("Cc", title: "Match Case", value: $model.projectSearchOptions.caseSensitive)
            option("W", title: "Whole Words", value: $model.projectSearchOptions.wholeWords)
            option(".*", title: "Regular Expression", value: $model.projectSearchOptions.regularExpression)
        }
        .padding(.horizontal, 16).frame(height: 46)
    }

    private func option(_ text: String, title: String, value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            Text(text).font(.system(size: 14))
                .frame(width: 28, height: 28)
                .litheRowHover(isActive: value.wrappedValue, cornerRadius: 4,
                    activeBackground: LitheTheme.subtleSelection)
        }
        .buttonStyle(.plain).help(LocalizedStringKey(title))
        .accessibilityLabel(LocalizedStringKey(title))
        .accessibilityAddTraits(value.wrappedValue ? .isSelected : [])
    }

    private var scopes: some View {
        HStack(spacing: 8) {
            ForEach(ProjectSearchScope.allCases) { scope in
                Button { model.projectSearchScope = scope } label: {
                    Text(LocalizedStringKey(scope.rawValue)).font(.system(size: 13))
                        .padding(.horizontal, 10).frame(height: 28)
                        .litheRowHover(isActive: scope == model.projectSearchScope, cornerRadius: 4,
                            activeBackground: LitheTheme.hoverBackground)
                }
                .buttonStyle(.plain)
            }
            if model.projectSearchScope == .directory {
                TextField("Project-relative directory", text: $model.projectSearchDirectory)
                    .textFieldStyle(.roundedBorder)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(matches) { result in
                        Button { selectedID = result.id } label: {
                            HStack(spacing: 12) {
                                highlighted(result.preview).lineLimit(1)
                                Spacer(minLength: 12)
                                Text("\(model.relativePath(for: result.url)):\(result.line ?? 1)")
                                    .foregroundStyle(LitheTheme.secondaryText).lineLimit(1)
                            }
                            .font(.system(size: 13)).padding(.horizontal, 12).frame(height: 28)
                            .background(result.id == selectedID ? LitheTheme.selection : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(result.id)
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            selectedID = result.id
                            openSelected()
                        })
                    }
                    if matches.isEmpty, !model.isSearching {
                        Text(model.searchQuery.isEmpty ? "Search across the project" : "No matches")
                            .foregroundStyle(LitheTheme.secondaryText).padding(20)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onChange(of: selectedID) { id in if let id { proxy.scrollTo(id) } }
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selected {
                HStack {
                    Text(selected.url.lastPathComponent).fontWeight(.semibold)
                    Text((model.relativePath(for: selected.url) as NSString).deletingLastPathComponent)
                        .foregroundStyle(LitheTheme.secondaryText)
                    Spacer()
                }
                .font(.system(size: 13)).padding(.horizontal, 16).frame(height: 36)
                if let preview {
                    if let message = preview.message {
                        Text(message).font(.system(size: 12)).padding(16)
                    }
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(preview.lines) { line in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(String(line.number)).foregroundStyle(LitheTheme.tertiaryText)
                                        .frame(width: 46, alignment: .trailing)
                                    highlighted(line.text).textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 13, design: .monospaced))
                                .frame(minHeight: 22)
                                .background(line.number == selected.line ? LitheTheme.activeTabBackground : .clear)
                            }
                        }
                        .frame(minWidth: 840, alignment: .leading)
                    }
                } else { ProgressView().padding(16) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LitheTheme.editor)
    }

    private var footer: some View {
        HStack {
            Button("Replace in Files…") {
                model.isProjectSearchPresented = false
                model.openProjectReplace(inheriting: model.projectSearchOptions)
            }
            Spacer()
            Button("Open in Find Window") {
                model.isProjectSearchPresented = false
                model.selectedSidebar = .search
                model.searchSidebarFocusRequest += 1
            }
            Button("Open", action: openSelected).disabled(selected == nil)
        }
        .padding(.horizontal, 16).frame(height: 46).background(LitheTheme.toolHeader)
    }

    private func highlighted(_ text: String) -> Text {
        var value = AttributedString(text)
        let options = model.projectSearchOptions
        let query = model.searchQuery
        guard !query.isEmpty else { return Text(value) }
        let pattern = options.regularExpression ? query : NSRegularExpression.escapedPattern(for: query)
        let bounded = options.wholeWords && !options.regularExpression
            ? "(?<![A-Za-z0-9_$])\(pattern)(?![A-Za-z0-9_$])" : pattern
        if let expression = try? NSRegularExpression(pattern: bounded, options: options.caseSensitive ? [] : [.caseInsensitive]) {
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range, in: text), let attributedRange = Range(range, in: value) {
                    value[attributedRange].backgroundColor = LitheTheme.warning.opacity(0.4)
                }
            }
        }
        return Text(value)
    }

    private func moveSelection(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let current = matches.firstIndex { $0.id == selectedID } ?? 0
        selectedID = matches[min(max(0, current + delta), matches.count - 1)].id
    }

    private func openSelected() {
        guard let selected else { return }
        model.isProjectSearchPresented = false
        model.openSearchResult(selected)
    }
}
