import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lithe

@Suite("Project windows", .serialized)
@MainActor
struct ProjectWindowManagerTests {
    @Test
    func defaultOpeningCreatesANativeTabWithoutReplacingTheSourceSession() async throws {
        try await withFixture { fixture in
            let manager = fixture.manager
            let sourceID = manager.initialWindowID
            let source = manager.activeSessions
            source.activeModel.openProjectDirectly(fixture.alpha)
            var presented: [UUID] = []
            manager.presentWindow = { presented.append($0) }

            source.requestOpenProject(fixture.beta, from: source.activeSessionID)

            let destination = try #require(presented.first)
            #expect(manager.windowIDs.count == 2)
            #expect(manager.sessions(for: sourceID) === source)
            #expect(source.activeModel.workspaceURL == fixture.alpha)
            #expect(manager.sessions(for: destination).activeModel.workspaceURL == fixture.beta)
            #expect(manager.takeTabParent(for: destination) == sourceID)
            #expect(manager.takeTabParent(for: destination) == nil)
        }
    }

    @Test
    func separateWindowsAndAskPreferencesControlProjectPlacement() async throws {
        try await withFixture { fixture in
            let manager = fixture.manager
            let source = manager.activeSessions
            source.activeModel.openProjectDirectly(fixture.alpha)
            fixture.settings.projectOpenBehavior = .newWindow
            source.requestOpenProject(fixture.beta, from: source.activeSessionID)
            let separateID = try #require(manager.windowIDs.last)
            #expect(manager.windowIDs.count == 2)
            #expect(manager.takeTabParent(for: separateID) == nil)

            fixture.settings.projectOpenBehavior = .ask
            source.requestOpenProject(fixture.gamma, from: source.activeSessionID)
            #expect(manager.windowIDs.count == 2)
            let request = try #require(source.pendingProjectOpen)
            source.resolvePendingOpen(request, placement: .thisWindow, doNotAskAgain: true)
            let tabID = try #require(manager.windowIDs.last)
            #expect(manager.windowIDs.count == 3)
            #expect(manager.takeTabParent(for: tabID) == manager.initialWindowID)
            #expect(fixture.settings.projectOpenBehavior == .thisWindow)
        }
    }

    @Test
    func reopeningAProjectFocusesItsExistingWindowAndKeepsDirtyContent() async throws {
        try await withFixture { fixture in
            let manager = fixture.manager
            let initialID = manager.initialWindowID
            let source = manager.activeSessions
            source.activeModel.openProjectDirectly(fixture.alpha)
            await source.activeModel.documentFeature.openFileAsync(
                fixture.alpha.appendingPathComponent("file.txt"),
                isReadOnly: false, displayPath: nil, activateWhenReady: true
            )
            let document = try #require(source.activeModel.activeDocument)
            document.applyLiveEditorText("unsaved source content")
            let secondID = UUID()
            let second = manager.sessions(for: secondID)
            second.activeModel.openProjectDirectly(fixture.beta)
            manager.activate(secondID)
            var focused: [UUID] = []
            manager.focusWindow = { focused.append($0) }

            second.requestOpenProject(fixture.alpha, from: second.activeSessionID)

            #expect(manager.windowIDs.count == 2)
            #expect(source.switcherProjects.map(\.workspaceURL) == [fixture.alpha, fixture.beta])
            #expect(second.switcherProjects.map(\.workspaceURL) == [fixture.alpha, fixture.beta])
            #expect(manager.activeWindowID == initialID)
            #expect(focused == [initialID])
            #expect(manager.activeSessions.activeModel.activeDocument === document)
            #expect(document.text == "unsaved source content")
            #expect(document.isDirty)
            #expect(manager.hasUnsavedDocuments)
            #expect(manager.unsavedDocumentNames.contains("alpha/file.txt"))
        }
    }

    @Test
    func nativeMergeAndDetachRetainEachProjectsModel() async throws {
        try await withFixture { fixture in
            let manager = fixture.manager
            let firstID = manager.initialWindowID
            let secondID = UUID()
            let firstModel = manager.activeSessions.activeModel
            let secondModel = manager.sessions(for: secondID).activeModel
            firstModel.openProjectDirectly(fixture.alpha)
            secondModel.openProjectDirectly(fixture.beta)
            let presentation = ProjectWindowPresentation(manager: manager)
            let first = makeWindow()
            let second = makeWindow()
            let firstTitlebar = WorkbenchTitlebar<AnyView>.Coordinator(
                content: AnyView(Text("Alpha project controls").frame(height: 32))
            )
            let secondTitlebar = WorkbenchTitlebar<AnyView>.Coordinator(
                content: AnyView(Text("Beta project controls").frame(height: 32))
            )
            defer {
                firstTitlebar.attach(to: nil)
                secondTitlebar.attach(to: nil)
                first.orderOut(nil)
                second.orderOut(nil)
                first.close()
                second.close()
            }
            presentation.attach(first, id: firstID, layout: .workspace)
            presentation.attach(second, id: secondID, layout: .workspace)
            firstTitlebar.attach(to: first)
            secondTitlebar.attach(to: second)
            manager.activate(firstID)

            presentation.mergeAllProjectWindows()
            #expect(first.tabbedWindows?.count == 2)
            #expect(first.tabbedWindows?.contains(second) == true)
            #expect(presentation.canDetachSelectedProject)
            // A native tab strip must reserve space below the project controls;
            // otherwise the former full-size content header is painted over it.
            for width: CGFloat in [980, 1440] {
                first.setFrame(NSRect(x: 40, y: 40, width: width, height: 640), display: true)
                first.layoutIfNeeded()
                let controls = firstTitlebar.host.convert(firstTitlebar.host.bounds, to: nil)
                #expect(controls.height >= 32)
                #expect(controls.minY > first.contentLayoutRect.maxY)
                #expect(controls.minX >= 70)
                #expect(controls.maxX <= first.frame.width)
            }

            manager.activate(secondID)
            presentation.detachSelectedProject()
            #expect((first.tabbedWindows?.count ?? 1) == 1)
            #expect((second.tabbedWindows?.count ?? 1) == 1)
            #expect(manager.sessions(for: firstID).activeModel === firstModel)
            #expect(manager.sessions(for: secondID).activeModel === secondModel)
            #expect(firstModel.workspaceURL == fixture.alpha)
            #expect(secondModel.workspaceURL == fixture.beta)
            #expect(!presentation.canDetachSelectedProject)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 480, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        return window
    }

    @Test
    func closeProjectShortcutRequestsNativeWindowClosureBeforeDiscardingContent() async throws {
        try await withFixture { fixture in
            let manager = fixture.manager
            let model = manager.activeSessions.activeModel
            model.openProjectDirectly(fixture.alpha)
            await model.documentFeature.openFileAsync(
                fixture.alpha.appendingPathComponent("file.txt"),
                isReadOnly: false, displayPath: nil, activateWhenReady: true
            )
            let document = try #require(model.activeDocument)
            document.applyLiveEditorText("unsaved content")
            var requested: [UUID] = []
            manager.closeWindow = { requested.append($0) }

            model.performShortcutCommand(id: "close-project")

            #expect(requested == [manager.initialWindowID])
            // The native window must confirm before the model changes to Welcome.
            #expect(model.workspaceURL == fixture.alpha)
            #expect(model.activeDocument === document)
            #expect(document.text == "unsaved content")
            #expect(document.isDirty)
        }
    }

    @Test
    func closingTheSelectedProjectTabRevealsTheRemainingProject() async throws {
        try await withFixture { fixture in
            let manager = fixture.manager
            let firstID = manager.initialWindowID
            let secondID = UUID()
            let firstSessions = manager.activeSessions
            let secondSessions = manager.sessions(for: secondID)
            firstSessions.openStartupProject(fixture.alpha)
            secondSessions.openStartupProject(fixture.beta)
            let secondModel = secondSessions.activeModel
            let presentation = ProjectWindowPresentation(manager: manager)
            let first = makeWindow()
            let second = makeWindow()
            let firstCoordinator = LitheWindowCoordinator(
                projectSessions: firstSessions, windowID: firstID, windowPresentation: presentation
            )
            let secondCoordinator = LitheWindowCoordinator(
                projectSessions: secondSessions, windowID: secondID, windowPresentation: presentation
            )
            firstCoordinator.attach(to: first, layout: .workspace)
            secondCoordinator.attach(to: second, layout: .workspace)
            manager.activate(secondID)
            presentation.mergeAllProjectWindows()
            let closed = TestGate()
            let closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: second, queue: nil
            ) { _ in closed.open() }
            defer {
                NotificationCenter.default.removeObserver(closeObserver)
                firstCoordinator.detach()
                secondCoordinator.detach()
                first.close()
                second.close()
            }

            second.performClose(nil)

            #expect(await closed.waitUntilOpen())
            #expect(first.isVisible)
            #expect((first.tabbedWindows?.count ?? 1) == 1)
            #expect(manager.activeWindowID == firstID)
            // Replacing the closing scene with Welcome changes its tabbing
            // identifier before AppKit can select the remaining project tab.
            #expect(secondSessions.activeModel === secondModel)
            #expect(firstSessions.activeModel.workspaceURL == fixture.alpha)
        }
    }

    @Test
    func switchingProjectWindowsDeactivatesThePreviousProjectsShortcutSession() async throws {
        try await withFixture { fixture in
            let manager = fixture.manager
            let first = manager.activeSessions.activeModel
            first.openProjectDirectly(fixture.alpha)
            let secondID = UUID()
            let second = manager.sessions(for: secondID).activeModel
            second.openProjectDirectly(fixture.beta)
            first.isSearchEverywhereVisible = true

            manager.activate(secondID)

            #expect(!first.isSearchEverywhereVisible)
            second.isSearchEverywhereVisible = true
            manager.activate(manager.initialWindowID)
            #expect(!second.isSearchEverywhereVisible)
            #expect(manager.activeSessions.activeModel === first)
        }
    }

    @Test
    func sidebarToggleKeepsSelectionAndSearchState() async throws {
        try await withFixture { fixture in
            let model = fixture.manager.activeSessions.activeModel
            model.searchQuery = "retained query"
            model.toggleSidebar(.project)
            #expect(!model.isSidebarVisible)
            #expect(model.selectedSidebar == .project)
            model.toggleSidebar(.project)
            #expect(model.isSidebarVisible)
            model.toggleSidebar(.project)
            model.selectedSidebar = .search
            #expect(model.isSidebarVisible)
            #expect(model.searchQuery == "retained query")
        }
    }

    @Test
    func projectTabTitleSurvivesSwiftUIResettingTheWindowTitle() async throws {
        try await withFixture { fixture in
            let window = makeWindow()
            let coordinator = LitheWindowCoordinator(projectSessions: fixture.manager.activeSessions)
            defer { coordinator.detach(); window.close() }
            coordinator.attach(to: window, layout: .workspace, title: "alpha – file.go")
            window.title = "Lithe"
            #expect(window.tab.title == "alpha – file.go")
            #expect(window.tab.attributedTitle?.string == "alpha – file.go")
            #expect(window.titlebarAppearsTransparent)
        }
    }

    @Test
    func backgroundRefreshDoesNotMutateNativeWindowChrome() async throws {
        try await withFixture { fixture in
            let manager = fixture.manager
            let presentation = ProjectWindowPresentation(manager: manager)
            let window = ChromeTrackingWindow(
                contentRect: NSRect(x: 40, y: 40, width: 980, height: 640),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let coordinator = LitheWindowCoordinator(
                projectSessions: manager.activeSessions,
                windowID: manager.initialWindowID, windowPresentation: presentation
            )
            defer { coordinator.detach(); window.close() }
            coordinator.attach(to: window, layout: .workspace, title: "alpha – file.go")
            window.chromeMutationCount = 0

            // Reassigning native chrome during unrelated model updates can end
            // menu tracking or refocus a project behind an open Settings window.
            for _ in 0..<10 {
                coordinator.attach(to: window, layout: .workspace, title: "alpha – file.go")
            }

            #expect(window.chromeMutationCount == 0)
            #expect(window.tab.title == "alpha – file.go")
        }
    }

    @Test
    func settingsFollowTheLanguageOfEachProject() async throws {
        try await withFixture { fixture in
            for (url, filename, category) in [
                (fixture.alpha, "go.mod", SettingsCategory.go),
                (fixture.beta, "Cargo.toml", SettingsCategory.rust),
                (fixture.gamma, "pyproject.toml", SettingsCategory.python)
            ] {
                try "".write(to: url.appendingPathComponent(filename), atomically: true, encoding: .utf8)
                let model = fixture.manager.sessions(for: UUID()).activeModel
                model.openProjectDirectly(url)
                await model.refreshWorkspace()
                #expect(model.availableSettingsCategories.contains(category))
                let languageCategories = model.availableSettingsCategories.filter { $0.languageProviderID != nil }
                #expect(languageCategories == [category])
            }
        }
    }

    @Test
    func searchPreviewClampsContextAtBothEndsOfTheFile() {
        let text = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let first = ProjectSearchPreview.context(in: text, line: 1)
        #expect(first.lines.first?.number == 1)
        #expect(first.lines.last?.number == 9)
        let last = ProjectSearchPreview.context(in: text, line: 40)
        #expect(last.lines.last?.number == 40)
        #expect(last.lines.last?.text == "line 40")
    }

    private func withFixture(_ body: (WindowFixture) async throws -> Void) async throws {
        let fixture = try WindowFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.manager.stopAllSessions()
            try? FileManager.default.removeItem(at: fixture.root)
            throw error
        }
        await fixture.manager.stopAllSessions()
        try FileManager.default.removeItem(at: fixture.root)
    }
}

@MainActor
private struct WindowFixture {
    let root: URL
    let settings: AppSettings
    let manager: ProjectWindowManager
    var alpha: URL { root.appendingPathComponent("alpha") }
    var beta: URL { root.appendingPathComponent("beta") }
    var gamma: URL { root.appendingPathComponent("gamma") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-windows-\(UUID())")
        do {
            for name in ["alpha", "beta", "gamma"] {
                let directory = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try "original\n".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        let store = WindowTestStore()
        let settings = AppSettings(store: store)
        self.settings = settings
        manager = ProjectWindowManager(settings: settings) {
            AppModel(settings: settings, services: MacServiceContainer(
                store: store, settings: settings, moduleLaunchMode: .safeMode
            ).services)
        }
    }
}

private final class WindowTestStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

@MainActor
private final class ChromeTrackingWindow: NSWindow {
    var chromeMutationCount = 0
    override var contentMinSize: NSSize { didSet { chromeMutationCount += 1 } }
    override var titleVisibility: NSWindow.TitleVisibility { didSet { chromeMutationCount += 1 } }
    override var titlebarAppearsTransparent: Bool { didSet { chromeMutationCount += 1 } }
    override var tabbingIdentifier: String { didSet { chromeMutationCount += 1 } }
    override var tabbingMode: NSWindow.TabbingMode { didSet { chromeMutationCount += 1 } }
}
