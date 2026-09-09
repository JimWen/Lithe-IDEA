import SwiftUI
import LitheSearchModule

struct ProjectReplaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedPaths: Set<String> = []
    @State private var query = ""
    @State private var replacement = ""
    @State private var options = ProjectSearchOptions.default

    private var selectedFiles: [ProjectReplacementFile] {
        model.projectReplacementFiles.filter {
            model.selectedProjectReplacementPaths.contains($0.relativePath)
        }
    }

    private var selectedMatchCount: Int {
        let excluded = model.searchFeatureIfActive?.excludedReplacementOccurrences ?? []
        return selectedFiles.reduce(0) { $0 + $1.edits.filter { !excluded.contains($0.id) }.count }
    }

    private var areAllMatchesSelected: Bool {
        model.selectedProjectReplacementPaths == Set(model.projectReplacementFiles.map(\.relativePath))
            && model.searchFeatureIfActive?.excludedReplacementOccurrences.isEmpty != false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            controls
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            if let failure = model.searchFeatureIfActive?.replacementFailure {
                Text(failure.localizedDescription)
                    .font(.system(size: 12)).foregroundStyle(LitheTheme.error)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            ForEach(model.searchFeatureIfActive?.replacementIssues ?? [], id: \.self) { issue in
                Text([issue.path, issue.message].compactMap { $0 }.joined(separator: ": "))
                    .font(.system(size: 12)).foregroundStyle(LitheTheme.error)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
            results
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(LitheTheme.window)
        .onAppear {
            query = model.projectReplaceQuery
            replacement = model.projectReplaceText
            options = model.projectReplaceOptions
        }
        .onChange(of: query) { _ in
            clearPreview()
        }
        .onChange(of: replacement) { _ in
            clearPreview()
        }
        .onChange(of: options) { _ in clearPreview() }
        .onChange(of: model.projectSearchScope) { _ in clearPreview() }
        .onChange(of: model.projectSearchDirectory) { _ in clearPreview() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(LitheTheme.accent)
            Text("Replace in Project")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer()
            Button {
                model.isProjectReplaceVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(LitheTheme.toolHeader)
    }

    private var controls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                TextField("Find", text: $query)
                    .textFieldStyle(.plain)
                    .litheSearchField()
                Image(systemName: "arrow.right")
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("Replace with", text: $replacement)
                    .textFieldStyle(.plain)
                    .litheSearchField()
            }

            HStack(spacing: 14) {
                Toggle("Match Case", isOn: $options.caseSensitive)
                    .lithePointer()
                Toggle("Whole Words", isOn: $options.wholeWords)
                    .lithePointer()
                Toggle("Regex", isOn: $options.regularExpression)
                    .lithePointer()
                Toggle("Preserve Case", isOn: $options.preserveCase)
                    .lithePointer()
                    .disabled(options.caseSensitive)
                    .help("Match the original casing of each hit: fooBar → bazQux, FooBar → BazQux, FOOBAR → BAZQUX.")

                TextField("File mask", text: $options.fileMask)
                    .textFieldStyle(.plain)
                    .litheSearchField()
                    .frame(maxWidth: 190)
                    .help("Comma-separated glob patterns, e.g. *.java, *.kt")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(LitheTheme.secondaryText)

            HStack(spacing: 8) {
                Picker("Scope", selection: $model.projectSearchScope) {
                    ForEach(ProjectSearchScope.allCases) { scope in
                        Text(LocalizedStringKey(scope.rawValue)).tag(scope)
                    }
                }
                .frame(maxWidth: 240)
                if model.projectSearchScope == .directory {
                    TextField("Project-relative directory", text: $model.projectSearchDirectory)
                        .textFieldStyle(.roundedBorder)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        await model.previewProjectReplacement(
                            query: query,
                            replacement: replacement,
                            options: options
                        )
                    }
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
                .lithePointer()
                .tint(LitheTheme.accent)
                .disabled(model.projectReplaceQuery.isEmpty || model.isLoadingProjectReplacement)

                Button {
                    let allSelected = areAllMatchesSelected
                    if !allSelected { model.searchFeatureIfActive?.includeAllReplacementOccurrences() }
                    model.selectedProjectReplacementPaths = allSelected
                        ? []
                        : Set(model.projectReplacementFiles.map(\.relativePath))
                } label: {
                    Text(areAllMatchesSelected
                        ? "Clear Selection"
                        : "Select All")
                }
                .buttonStyle(.bordered)
                .lithePointer()
                .disabled(model.projectReplacementFiles.isEmpty)

                Spacer()

                if model.isLoadingProjectReplacement {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("\(selectedFiles.count) files, \(selectedMatchCount) matches")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                Button("Apply") {
                    Task { await model.applyProjectReplacement() }
                }
                .buttonStyle(.borderedProminent)
                .lithePointer()
                .tint(LitheTheme.accent)
                .disabled(selectedMatchCount == 0 || model.isLoadingProjectReplacement
                    || model.searchFeatureIfActive?.canApplyReplacementPreview != true)
            }
        }
        .padding(12)
        .background(LitheTheme.sidebar)
    }

    @ViewBuilder
    private var results: some View {
        if model.projectReplacementFiles.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                if model.searchFeatureIfActive?.replacementFailure == nil,
                   model.searchFeatureIfActive?.replacementStatus != .incomplete {
                    Text(model.projectReplaceQuery.isEmpty
                        ? "Enter text to preview project changes"
                        : "No replacement matches")
                }
            }
            .font(LitheTheme.uiFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.projectReplacementFiles) { file in
                        fileRow(file)
                        Rectangle().fill(LitheTheme.divider).frame(height: 1)
                    }
                }
            }
            .background(LitheTheme.editor)
        }
    }

    private func fileRow(_ file: ProjectReplacementFile) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedPaths.contains(file.relativePath) },
                set: { expanded in
                    if expanded { expandedPaths.insert(file.relativePath) }
                    else { expandedPaths.remove(file.relativePath) }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(file.matches) { match in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Line \(match.line)  \(match.before)")
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(2)
                        ForEach(Array(file.edits.filter { $0.line == match.line }.enumerated()), id: \.element.id) { index, edit in
                            Toggle(isOn: Binding(
                                get: { model.searchFeatureIfActive?.excludedReplacementOccurrences.contains(edit.id) != true },
                                set: { model.searchFeatureIfActive?.setReplacementOccurrence(edit.id, included: $0) }
                            )) {
                                Text("Match \(index + 1) → \(edit.newText)")
                                    .lineLimit(2)
                            }
                            .disabled(!model.selectedProjectReplacementPaths.contains(file.relativePath)
                                || model.isLoadingProjectReplacement)
                        }
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                }
            }
            .padding(.leading, 28)
            .padding(.vertical, 5)
        } label: {
            HStack(spacing: 8) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.selectedProjectReplacementPaths.contains(file.relativePath) },
                        set: { selected in
                            if selected { model.selectedProjectReplacementPaths.insert(file.relativePath) }
                            else { model.selectedProjectReplacementPaths.remove(file.relativePath) }
                        }
                    )
                )
                .labelsHidden()
                .lithePointer()
                LitheSystemIcon(systemImage: "doc.text")
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(file.relativePath)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(file.matchCount) matches")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .lithePointer()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .litheContextMenu {
            [
                .action("Open", systemImage: "doc.text", action: {
                    model.openFile(file.url, displayPath: file.relativePath)
                }),
                .action("Show in Finder", systemImage: "folder", action: {
                    model.revealProjectItemInFinder(file.url)
                }),
                .submenu("Copy Path / Reference", items: [
                    .action("Copy Path", action: {
                        model.copyProjectItemPath(file.url, relative: false)
                    }),
                    .action("Copy Relative Path", action: {
                        model.copyProjectItemPath(file.url, relative: true)
                    })
                ])
            ]
        }
    }

    private func clearPreview() {
        model.clearProjectReplacementPreview()
    }
}
