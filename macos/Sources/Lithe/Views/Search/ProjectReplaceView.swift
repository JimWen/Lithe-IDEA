import AppKit
import SwiftUI
import LitheSearchModule

struct ProjectReplaceView: View {
    @EnvironmentObject private var model: AppModel
    let loadPreviewDocument: (URL) async -> EditorDocument?
    @State private var selectedResult: String?
    @State private var previewNeedsRefresh = false
    @State private var retainedPreview: (file: ProjectReplacementFile, match: ProjectReplacementMatch)?
    @State private var query = ""
    @State private var replacement = ""
    @State private var options = ProjectSearchOptions.default
    @State private var isFileMaskEnabled = false
    @FocusState private var focusedField: Field?
    @Environment(\.colorScheme) private var colorScheme

    private enum Field {
        case query
        case replacement
        case fileMask
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            replacementProblems
            results
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(LitheTheme.popupBackground)
                .shadow(color: LitheTheme.popupShadow, radius: 18, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(LitheTheme.panelBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .projectReplaceArrowCursor()
        .onAppear {
            query = model.projectReplaceQuery
            replacement = model.projectReplaceText
            options = model.projectReplaceOptions
            isFileMaskEnabled = !options.fileMask.isEmpty
            focusedField = .query
        }
        .onChange(of: query) { _ in
            clearPreview()
        }
        .onChange(of: replacement) { _ in
            clearPreview()
        }
        .onChange(of: options) { _ in
            clearPreview()
        }
        .onChange(of: isFileMaskEnabled) { _ in
            clearPreview()
        }
        .onChange(of: model.projectSearchScope) { _ in clearPreview() }
        .onChange(of: model.projectSearchDirectory) { _ in clearPreview() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Replace in Files")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer()
            Button { model.isProjectReplaceVisible = false } label: { Image(systemName: "xmark") }
                .litheIconButton().help("Close")

            Toggle("File mask:", isOn: $isFileMaskEnabled)
                .toggleStyle(ProjectReplaceCheckboxStyle())
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)

            TextField("*.go, *.rs", text: $options.fileMask)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .fileMask)
                .projectReplaceTextCursor()
                .padding(.horizontal, 8)
                .projectReplaceInputChrome(isFocused: focusedField == .fileMask, height: 28)
                .frame(width: 96)
                .disabled(!isFileMaskEnabled)
                .opacity(isFileMaskEnabled ? 1 : 0.58)
                .help("Comma-separated glob patterns, e.g. *.go, *.rs, *.py")

        }
        .padding(.horizontal, 20)
        .frame(height: 40)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            projectReplaceInput(
                systemImage: "magnifyingglass",
                placeholder: "Find",
                text: $query,
                field: .query
            ) {
                ProjectReplaceOptionButton(title: "Cc", isOn: $options.caseSensitive)
                ProjectReplaceOptionButton(title: "W", isOn: $options.wholeWords)
                ProjectReplaceOptionButton(title: ".*", isOn: $options.regularExpression)
            }

            projectReplaceInput(
                systemImage: "arrow.left.arrow.right",
                placeholder: "Replace",
                text: $replacement,
                field: .replacement
            ) {
                ProjectReplaceOptionButton(
                    title: "Aa",
                    isOn: $options.preserveCase,
                    isEnabled: !options.caseSensitive
                )
            }

            HStack(spacing: 8) {
                Picker("Scope", selection: $model.projectSearchScope) {
                    ForEach(ProjectSearchScope.allCases) { scope in
                        Text(LocalizedStringKey(scope.rawValue)).tag(scope)
                    }
                }
                .frame(maxWidth: 230)
                if model.projectSearchScope == .directory {
                    TextField("Project-relative directory", text: $model.projectSearchDirectory)
                        .textFieldStyle(.roundedBorder)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func projectReplaceInput<Accessory: View>(
        systemImage: String,
        placeholder: String,
        text: Binding<String>,
        field: Field,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 16)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focusedField, equals: field)
                .projectReplaceTextCursor()
            HStack(spacing: 3) { accessory() }
        }
        .padding(.horizontal, 8)
        .projectReplaceInputChrome(
            isFocused: focusedField == field, height: 32,
            background: LitheTheme.popupBackground, border: LitheTheme.panelBorder
        )
    }

    private var selectedFiles: [ProjectReplacementFile] {
        model.projectReplacementFiles.filter { model.selectedProjectReplacementPaths.contains($0.relativePath) }
    }

    private var selectedMatchCount: Int {
        let excluded = model.searchFeatureIfActive?.excludedReplacementOccurrences ?? []
        return selectedFiles.reduce(0) { $0 + $1.edits.filter { !excluded.contains($0.id) }.count }
    }

    private var areAllMatchesSelected: Bool {
        model.selectedProjectReplacementPaths == Set(model.projectReplacementFiles.map(\.relativePath))
            && model.searchFeatureIfActive?.excludedReplacementOccurrences.isEmpty != false
    }

    @ViewBuilder
    private var replacementProblems: some View {
        if let feature = model.searchFeatureIfActive,
           feature.replacementFailure != nil || !feature.replacementIssues.isEmpty
            || (feature.replacementStatus != nil && feature.replacementStatus != .complete) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let failure = feature.replacementFailure { Text(failure.localizedDescription) }
                    ForEach(feature.replacementIssues, id: \.self) { issue in
                        Text([issue.path, issue.message].compactMap { $0 }.joined(separator: ": "))
                    }
                    if feature.replacementStatus != nil && feature.replacementStatus != .complete {
                        Text("Preview is incomplete. Refine the query before applying replacements.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12)).foregroundStyle(LitheTheme.error)
            .frame(maxHeight: 90).padding(.horizontal, 12)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Preview") {
                previewNeedsRefresh = false
                Task { await model.previewProjectReplacement(query: query, replacement: replacement, options: optionsForPreview) }
            }
            .buttonStyle(ProjectReplaceButtonStyle(isPrimary: true))
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isLoadingProjectReplacement)

            Button(areAllMatchesSelected ? "Clear Selection" : "Select All") {
                let clear = areAllMatchesSelected
                if !clear { model.searchFeatureIfActive?.includeAllReplacementOccurrences() }
                model.selectedProjectReplacementPaths = clear ? [] : Set(model.projectReplacementFiles.map(\.relativePath))
            }
            .buttonStyle(ProjectReplaceButtonStyle())
            .disabled(model.projectReplacementFiles.isEmpty || model.isLoadingProjectReplacement)
            Spacer()

            if model.isLoadingProjectReplacement {
                ProgressView().controlSize(.small)
            }
            Text("\(selectedFiles.count) files, \(selectedMatchCount) matches")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
            Button("Apply") { Task { await model.applyProjectReplacement() } }
                .buttonStyle(ProjectReplaceButtonStyle(isPrimary: true))
                .disabled(selectedMatchCount == 0 || model.isLoadingProjectReplacement || previewNeedsRefresh
                    || model.searchFeatureIfActive?.canApplyReplacementPreview != true)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }

    private var optionsForPreview: ProjectSearchOptions {
        var value = options
        if !isFileMaskEnabled { value.fileMask = "" }
        return value
    }

    private var selectedMatch: (file: ProjectReplacementFile, match: ProjectReplacementMatch)? {
        for file in model.projectReplacementFiles {
            if let match = file.matches.first(where: { resultID(file, $0) == selectedResult }) {
                return (file, match)
            }
        }
        guard let file = model.projectReplacementFiles.first, let match = file.matches.first else { return retainedPreview }
        return (file, match)
    }

    private func resultID(_ file: ProjectReplacementFile, _ match: ProjectReplacementMatch) -> String {
        "\(file.id):\(match.line)"
    }

    @ViewBuilder
    private var results: some View {
        if let selected = selectedMatch {
            GeometryReader { geometry in
                LitheSplitPaneView(
                    axis: .vertical, placement: .leading,
                    defaultSize: geometry.size.height * 0.4,
                    minimum: 90, maximum: max(90, geometry.size.height - 150),
                    flexibleMinimum: 150
                ) {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(model.projectReplacementFiles) { file in
                                fileResults(file, selected: selected)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .overlay {
                        if previewNeedsRefresh && model.projectReplacementFiles.isEmpty {
                            Text("File changed. Run Preview again to refresh results.")
                                .font(LitheTheme.uiFont)
                                .foregroundStyle(LitheTheme.secondaryText)
                                .padding()
                        }
                    }
                } flexible: {
                    ProjectReplacementSourcePreview(
                        file: selected.file, line: selected.match.line,
                        query: query, options: optionsForPreview, loadDocument: loadPreviewDocument, onEdit: {
                            // Keep the mounted editor (including its caret and undo stack)
                            // while invalidating only the obsolete search snapshot.
                            retainedPreview = selected
                            previewNeedsRefresh = true
                            clearPreview(preservingEditor: true)
                        }
                    )
                    .id(selected.file.id)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                if model.searchFeatureIfActive?.replacementFailure == nil,
                   model.searchFeatureIfActive?.replacementStatus != .incomplete {
                    Text(previewNeedsRefresh ? "File changed. Run Preview again to refresh results." : (query.isEmpty ? "Enter text to preview project changes" : "No replacement matches"))
                }
            }
            .font(LitheTheme.uiFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fileResults(_ file: ProjectReplacementFile, selected: (file: ProjectReplacementFile, match: ProjectReplacementMatch)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(file.relativePath, isOn: Binding(
                get: { model.selectedProjectReplacementPaths.contains(file.relativePath) },
                set: { included in
                    if included { model.selectedProjectReplacementPaths.insert(file.relativePath) }
                    else { model.selectedProjectReplacementPaths.remove(file.relativePath) }
                }
            ))
            .font(.system(size: 12, weight: .medium))
            .disabled(model.isLoadingProjectReplacement)
            ForEach(file.matches) { match in
                matchRow(file, match: match, selected: resultID(file, match) == resultID(selected.file, selected.match))
                ForEach(Array(file.edits.filter { $0.line == match.line }.enumerated()), id: \.element.id) { index, edit in
                    Toggle("Match \(index + 1) → \(edit.newText)", isOn: Binding(
                        get: { model.searchFeatureIfActive?.excludedReplacementOccurrences.contains(edit.id) != true },
                        set: { model.searchFeatureIfActive?.setReplacementOccurrence(edit.id, included: $0) }
                    ))
                    .font(.system(size: 11.5, design: .monospaced)).lineLimit(2)
                    .padding(.leading, 18)
                    .disabled(!model.selectedProjectReplacementPaths.contains(file.relativePath) || model.isLoadingProjectReplacement)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func matchRow(_ file: ProjectReplacementFile, match: ProjectReplacementMatch, selected: Bool) -> some View {
        Button {
            selectedResult = resultID(file, match)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Before").foregroundStyle(LitheTheme.secondaryText)
                        Text(ProjectReplacementPreviewText.highlighted(match.before, query: query, options: optionsForPreview, fileName: file.url.lastPathComponent, isDark: colorScheme == .dark))
                    }
                    HStack(spacing: 6) {
                        Text("After").foregroundStyle(LitheTheme.secondaryText)
                        Text(match.after).foregroundStyle(LitheTheme.primaryText)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                (Text(ProjectReplacementPreviewText.highlighted(file.relativePath, query: query, options: optionsForPreview)) + Text("  \(match.line)"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 230, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .background(selected ? LitheTheme.selection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(ProjectReplacementResultButtonStyle())
        .projectReplaceArrowCursor()
        .accessibilityLabel("\(file.relativePath), Line \(match.line), \(match.before)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .litheContextMenu {
            [
                .action("Open", systemImage: "doc.text", action: { model.openFile(file.url, displayPath: file.relativePath) }),
                .action("Show in Finder", systemImage: "folder", action: { model.revealProjectItemInFinder(file.url) }),
                .submenu("Copy Path / Reference", items: [
                    .action("Copy Path", action: { model.copyProjectItemPath(file.url, relative: false) }),
                    .action("Copy Relative Path", action: { model.copyProjectItemPath(file.url, relative: true) })
                ])
            ]
        }
    }

    private func clearPreview(preservingEditor: Bool = false) {
        if !preservingEditor { retainedPreview = nil }
        selectedResult = nil
        model.clearProjectReplacementPreview()
    }
}

private struct ProjectReplaceInputChrome: ViewModifier {
    let isFocused: Bool
    let height: CGFloat
    let background: Color
    let border: Color

    func body(content: Content) -> some View {
        content
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(background)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isFocused ? LitheTheme.accent : border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private extension View {
    func projectReplaceInputChrome(
        isFocused: Bool, height: CGFloat,
        background: Color = LitheTheme.inputBackground, border: Color = LitheTheme.inputBorder
    ) -> some View {
        modifier(ProjectReplaceInputChrome(isFocused: isFocused, height: height, background: background, border: border))
    }

    func projectReplaceArrowCursor() -> some View {
        onHover { isInside in
            if isInside {
                NSCursor.arrow.set()
            }
        }
    }

    func projectReplaceTextCursor() -> some View {
        onHover { isInside in
            (isInside ? NSCursor.iBeam : NSCursor.arrow).set()
        }
    }
}

private struct ProjectReplaceOptionButton: View {
    let title: String
    @Binding var isOn: Bool
    var isEnabled = true
    @State private var isHovering = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? LitheTheme.primaryText : LitheTheme.secondaryText)
                .padding(.horizontal, 5)
                .frame(height: 22)
                .background(isOn || isHovering ? LitheTheme.subtleSelection : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 }
        .lithePointer()
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }

    private var help: String {
        switch title {
        case "Cc": "Match Case"
        case "W": "Whole Words"
        case ".*": "Regular Expression"
        default: "Preserve Case"
        }
    }
}

private struct ProjectReplaceCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(configuration.isOn ? LitheTheme.accent : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(configuration.isOn ? LitheTheme.accent : LitheTheme.inputBorder, lineWidth: 1)
                    }
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 14, height: 14)
                configuration.label
            }
        }
        .buttonStyle(.plain)
        .lithePointer()
    }
}

private struct ProjectReplaceButtonStyle: ButtonStyle {
    var isPrimary = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(background(configuration: configuration))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isPrimary && isEnabled ? .clear : LitheTheme.panelBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .lithePointer()
    }

    private var foreground: Color {
        isPrimary && isEnabled ? .white : LitheTheme.secondaryText
    }

    private func background(configuration: Configuration) -> Color {
        guard isEnabled else { return LitheTheme.raised.opacity(0.55) }
        guard isPrimary else { return isHovering ? LitheTheme.raised : LitheTheme.popupBackground }
        return LitheTheme.accent.opacity(configuration.isPressed ? 0.78 : (isHovering ? 1 : 0.9))
    }
}

/// Result selection has no transient pressed appearance.
private struct ProjectReplacementResultButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
