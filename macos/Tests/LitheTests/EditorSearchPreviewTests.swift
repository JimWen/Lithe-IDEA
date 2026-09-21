import AppKit
import SwiftUI
import LitheSearchModule
import Testing
@testable import Lithe

@MainActor
@Suite("Editor search preview isolation")
struct EditorSearchPreviewTests {
    @Test
    func searchPreviewNavigationPreservesCaretAfterEditingManagedDocument() throws {
        withCoordinator(source: "<root>\n22\n</root>", fileExtension: "xml") { coordinator in
            let view = CodeTextView(frame: .zero)
            view.string = "<root>\n22\n</root>"
            coordinator.textView = view
            coordinator.applyPreviewLine(2)
            #expect(view.selectedRange().location == 7)
            coordinator.lastFindVisible = true
            coordinator.lastFindQuery = "22"
            view.syncFindState(isVisible: true, query: "22", options: .default)
            #expect(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 8, length: 1), replacementString: "3"))
            view.string = "<root>\n23\n</root>"
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
            #expect(coordinator.document?.text == view.string)
            #expect(coordinator.document?.isDirty == true)
            view.setSelectedRange(NSRange(location: 8, length: 0))
            // Re-rendering the same result must not jump the caret away from the user's edit.
            coordinator.applyPreviewLine(2)
            #expect(view.selectedRange().location == 8)
        }
    }

    @Test(arguments: [false, true])
    func mountedPreviewKeepsCommandsAndFindStateLocal(isPreview: Bool) async throws {
        let store = SearchPreviewTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/Preview.xml"),
                                      text: "<root>needle needle</root>", modificationDate: nil)
        // Even previewing the active file must not overwrite the workbench's other query.
        model.activeDocumentID = document.id
        model.editorChrome.setFindBarQuery("other")
        model.editorChrome.updateFindState(currentIndex: 4, count: 7)
        let chrome = isPreview ? EditorChromeModel() : model.editorChrome
        chrome.setFindBarVisible(true)
        chrome.setFindBarQuery("needle")
        let hosting = NSHostingView(rootView:
            CodeEditorView(document: document, shouldFocus: false,
                           previewLine: isPreview ? 1 : nil, viewportStore: EditorViewportStore())
                .environmentObject(model).environmentObject(chrome)
                .environmentObject(settings).environmentObject(model.editorDiagnosticsStore))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); model.documentFeature.reset() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func editor(in view: NSView) -> CodeTextView? {
            if let text = view as? CodeTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let textView = try #require(editor(in: hosting))
        #expect(textView.isEditable)
        #expect((textView.onCompletionSelected == nil) == isPreview)
        #expect((textView.onRenameRequested == nil) == isPreview)
        #expect((textView.onFormatRequested == nil) == isPreview)
        #expect((textView.onCodeActionsRequested == nil) == isPreview)
        #expect((textView.onGoToLineRequested == nil) == isPreview)
        #expect((textView.onFindRequested == nil) == isPreview)
        if isPreview { #expect(textView.languageServerFeatures.isEmpty) }
        let updated = await awaitChange(on: chrome, timeout: .seconds(2)) { chrome.findMatchCount == 2 }
        #expect(updated, "Native find results must reach the editor's own chrome")
        if isPreview {
            #expect(model.editorChrome.findBarQuery == "other")
            #expect(model.editorChrome.findMatchCount == 7)
            #expect(model.editorChrome.currentFindMatchIndex == 4)
            let selection = textView.selectedRange()
            NotificationCenter.default.post(name: .litheFindNavigate, object: nil,
                userInfo: [FindNotificationKeys.direction: 1])
            #expect(textView.selectedRange() == selection)
            NotificationCenter.default.post(name: .litheFindReplaceAll, object: nil,
                userInfo: [FindNotificationKeys.documentID: document.id, FindNotificationKeys.replacement: "wrong"])
            #expect(document.text == "<root>needle needle</root>")
            NotificationCenter.default.post(name: .litheFindQueryChanged, object: nil,
                userInfo: [FindNotificationKeys.query: "absent"])
            NotificationCenter.default.post(name: .litheFindDismiss, object: nil)
            #expect(textView.currentFindMatchCountForTesting == 2)
        }
    }

    @Test
    func nativePreviewEditInvalidatesResultSnapshot() async throws {
        let store = SearchPreviewTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/Preview.xml"),
                                      text: "foo\nfoo", modificationDate: nil)
        let file = ProjectReplacementFile(url: document.url, relativePath: "Preview.xml", matches: [
            .init(line: 1, before: "foo", after: "bar", occurrenceCount: 1),
            .init(line: 2, before: "foo", after: "bar", occurrenceCount: 1)
        ])
        var invalidated = false
        let hosting = NSHostingView(rootView:
            ProjectReplacementSourcePreview(file: file, line: 1, query: "foo", options: .default,
                loadDocument: { _ in document }, onEdit: { invalidated = true })
                .environmentObject(model).environmentObject(settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); model.documentFeature.reset() }
        window.contentView = hosting
        func editor(in view: NSView) -> CodeTextView? {
            if let text = view as? CodeTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        // Mounting follows the asynchronous load; poll only the native view boundary with a local deadline.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while editor(in: hosting) == nil && clock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        let textView = try #require(editor(in: hosting))
        #expect(!invalidated)
        textView.insertText("\n\n", replacementRange: NSRange(location: 0, length: 3))
        #expect(document.text == "\n\n\nfoo")
        #expect(invalidated, "Do not allow another click on obsolete match lines after an edit")
    }

    @Test
    func replacementDialogKeepsEditorMountedAfterInvalidatingResults() async throws {
        let store = SearchPreviewTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/Preview.xml"),
                                      text: "foo\nfoo", modificationDate: nil)
        let file = ProjectReplacementFile(url: document.url, relativePath: "Preview.xml", matches: [
            .init(line: 1, before: "foo", after: "bar", occurrenceCount: 1)
        ], replacementText: "bar\nfoo", sourceText: document.text, edits: [
            .init(id: "preview-first", line: 1, utf16Start: 0, utf16Length: 3, newText: "bar")
        ])
        let feature = SearchFeatureModel(operations: RetainedPreviewSearchOperations(file: file))
        model.cacheModuleCapability(SearchModuleCapability(feature: feature), id: .searchWorkspace, moduleID: .search)
        model.observeModuleFeature(.search, observation: feature.objectWillChange.sink { [weak model] _ in
            model?.scheduleObjectWillChangeRelay()
        })
        let previewFinished = TestGate()
        let previewTask = Task { @MainActor in
            defer { previewFinished.open() }
            await feature.previewProjectReplacement(
                at: document.url.deletingLastPathComponent(), query: "foo", replacement: "bar",
                scope: .files([file.relativePath]), textOverrides: [:],
                visibilityRules: .init(hiddenDirectoryNames: [], hiddenFilePatterns: []), isCurrent: { true })
        }
        defer { previewTask.cancel(); feature.reset(); model.documentFeature.reset(); model.clearModuleBindings(for: .search) }
        try #require(await previewFinished.waitUntilOpen(timeout: .seconds(2)), "Replacement preview did not finish")
        await previewTask.value
        #expect(feature.canApplyReplacementPreview)
        model.selectedProjectReplacementPaths = [file.relativePath]
        let hosting = NSHostingView(rootView:
            ProjectReplaceView(loadPreviewDocument: { _ in document })
                .environmentObject(model).environmentObject(settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 614),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); feature.reset(); model.documentFeature.reset() }
        window.contentView = hosting
        func editor(in view: NSView) -> CodeTextView? {
            if let text = view as? CodeTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        // Await the native mounting boundary with a deadline, never a fixed rendering delay.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while editor(in: hosting) == nil && clock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        let originalEditor = try #require(editor(in: hosting))
        originalEditor.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(feature.projectReplacementFiles.isEmpty)
        // Flush the parent view update: testing the child alone misses its removal by results.
        hosting.layoutSubtreeIfNeeded()
        let retainedEditor = try #require(editor(in: hosting))
        #expect(retainedEditor === originalEditor)
        retainedEditor.insertText("y", replacementRange: retainedEditor.selectedRange())
        hosting.layoutSubtreeIfNeeded()
        #expect(editor(in: hosting) === originalEditor)
        #expect(document.text == "xyfoo\nfoo")
        #expect(document.isDirty)
        #expect(feature.projectReplacementFiles.isEmpty)
    }

    private func withCoordinator(
        source: String,
        fileExtension: String = "txt",
        isDark: Bool = true,
        body: (CodeEditorView.Coordinator) throws -> Void
    ) rethrows {
        let store = SearchPreviewTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/Viewport.\(fileExtension)"),
                                      text: source, modificationDate: nil)
        let coordinator = CodeEditorView.Coordinator(
            document: document, model: model, isDarkAppearance: isDark, colorTheme: .lithe,
            markdownScrollPosition: nil, viewportStore: EditorViewportStore()
        )
        try withExtendedLifetime((model, document)) { try body(coordinator) }
    }
}

private final class SearchPreviewTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}


private struct RetainedPreviewSearchOperations: SearchOperations {
    let file: ProjectReplacementFile
    func cancelTextPreview(operationID: String) {}
    func textPreview(_ request: ProjectTextPreviewRequest) -> Result<ProjectTextPreview, ProjectSearchFailure> {
        .success(ProjectTextPreview(files: [file], status: .complete))
    }
    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { [] }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> SearchEverywhereResults? { nil }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? { [file] }
    func readFile(at rootURL: URL, relativePath: String) -> String? { file.sourceText }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool {
        Issue.record("A preview editor test must not write workspace files")
        return false
    }
}
