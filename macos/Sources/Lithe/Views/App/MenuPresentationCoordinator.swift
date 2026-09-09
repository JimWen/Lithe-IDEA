import Combine
import SwiftUI

struct ProjectMenuRenderState: Equatable {
    var context: ProjectCommandContext?
    var project = ProjectCommandState()
    var access: [URL: RecentProjectAccess] = [:]
    var colorTheme: AppColorTheme = .lithe
    var themePreference: AppThemePreference = .system
    var editorTabLayoutMode: EditorTabLayoutMode = .singleLine

    func isEnabled(_ command: ProjectMenuCommand) -> Bool { project.enabled.contains(command) }
}

enum AppearanceMenuCommand {
    case colorTheme(AppColorTheme)
    case themePreference(AppThemePreference)
    case editorTabLayout(EditorTabLayoutMode)
}

/// Commands subscribe only to renderState. Native tracking may defer its next
/// publication, but every action is checked against live execution eligibility.
@MainActor
final class MenuPresentationCoordinator: ObservableObject {
    @Published private(set) var renderState = ProjectMenuRenderState()
    private let windows: ProjectWindowManager
    private let presentation: ProjectWindowPresentation
    private let environment: CommandEnvironmentFeatureModel
    private let settings: AppSettings
    private let keyboardShortcuts: KeyboardShortcutFeatureModel
    private let updates: UpdateChecker
    private let platformUI: any PlatformUI
    private let scheduler: any CommandProjectionScheduling
    private let accessChecker: any RecentProjectAccessChecking
    private let refreshNativeFocus: () -> Void
    private var observations: [AnyCancellable] = []
    private var modelObservations: [UUID: AnyCancellable] = [:]
    private var globalShortcuts: (any ShortcutDetector)?
    private var cancelPending: (() -> Void)?
    private var accessTask: Task<Void, Never>?
    private var openRecentTask: Task<Void, Never>?
    private var accessPaths: [URL] = []
    private var access: [URL: RecentProjectAccess] = [:]
    private var accessGeneration = 0
    private var stopped = false
    private var isPresentingRequest = false
    private var pendingHostAction: (id: UUID, command: ProjectMenuCommand)?
    private var cancelHostDeadline: (() -> Void)?
    private var wasTrackingMenu = false
    private static let hostAttachmentTimeout: TimeInterval = 5

    var canUndoWorkspaceEdit: Bool {
        host?.model.services.workspaceTextEditUndoController.canUndo == true
    }

    var canRedoWorkspaceEdit: Bool {
        host?.model.services.workspaceTextEditUndoController.canRedo == true
    }

    func undoWorkspaceEdit() {
        guard canUndoWorkspaceEdit else { return }
        host?.model.services.workspaceTextEditUndoController.sharedUndoManager.undo()
    }

    func redoWorkspaceEdit() {
        guard canRedoWorkspaceEdit else { return }
        host?.model.services.workspaceTextEditUndoController.sharedUndoManager.redo()
    }

    init(
        windows: ProjectWindowManager,
        presentation: ProjectWindowPresentation,
        environment: CommandEnvironmentFeatureModel,
        settings: AppSettings,
        updates: UpdateChecker,
        platformUI: any PlatformUI,
        scheduler: any CommandProjectionScheduling,
        accessChecker: any RecentProjectAccessChecking,
        shortcutFactory: any ShortcutDetectorFactory,
        refreshNativeFocus: @escaping () -> Void
    ) {
        self.windows = windows
        self.presentation = presentation
        self.environment = environment
        self.settings = settings
        keyboardShortcuts = KeyboardShortcutFeatureModel(settings: settings)
        self.updates = updates
        self.platformUI = platformUI
        self.scheduler = scheduler
        self.accessChecker = accessChecker
        self.refreshNativeFocus = refreshNativeFocus
        observations = [windows.objectWillChange, presentation.objectWillChange,
                        environment.objectWillChange, settings.objectWillChange,
                        updates.objectWillChange].map { source in
            source.sink { [weak self] in self?.invalidate() }
        }
        globalShortcuts = shortcutFactory.make { [weak self] id in
            self?.perform(id == "settings" ? .settings : .openProject, from: nil)
        }
        globalShortcuts?.setCommandEligibility({ [weak self] _ in
            guard let self, !self.stopped else { return false }
            self.refreshNativeFocus()
            return self.environment.permitsApplicationCommand && !self.environment.isTrackingMenu
                && !self.isPresentingRequest && !self.isRecordingShortcut
        }, generation: { [weak environment] in environment?.generation ?? 0 })
        refresh()
        globalShortcuts?.start()
    }

    private var host: (windowID: UUID, model: AppModel)? {
        windows.existingCommandHost(in: presentation.presentedWindowIDs)
    }

    private var isRecordingShortcut: Bool {
        windows.windowIDs.contains { id in
            windows.existingSessions(for: id)?.sessions.contains {
                $0.keyboardShortcutFeature.recordingCommandID != nil
            } == true
        }
    }

    func invalidate() {
        guard !stopped, cancelPending == nil else { return }
        cancelPending = scheduler.schedule { [weak self] in
            guard let self, !self.stopped else { return }
            self.cancelPending = nil
            self.refresh()
        }
    }

    func windowAttached(_ id: UUID) {
        guard !stopped else { return }
        if let pending = pendingHostAction, pending.id == id {
            cancelHostDeadline?()
            cancelHostDeadline = nil
            pendingHostAction = nil
            isPresentingRequest = false
            perform(pending.command, from: nil)
        }
        invalidate()
    }

    func windowClosed(_ id: UUID) {
        if pendingHostAction?.id == id {
            cancelHostDeadline?()
            cancelHostDeadline = nil
            pendingHostAction = nil
            isPresentingRequest = false
        }
        invalidate()
    }

    private func refresh() {
        guard !stopped else { return }
        refreshNativeFocus()
        let models = windows.windowIDs.flatMap { windows.existingSessions(for: $0)?.sessions ?? [] }
        let liveIDs = Set(models.map(\.id))
        modelObservations = modelObservations.filter { liveIDs.contains($0.key) }
        for id in windows.windowIDs {
            guard let sessions = windows.existingSessions(for: id) else { continue }
            for model in sessions.sessions where modelObservations[model.id] == nil {
                modelObservations[model.id] = model.commandStateFeature.objectWillChange.sink { [weak self] in
                    self?.invalidate()
                }
                model.configureCommandInput(permits: { [weak self, weak model] commandID in
                    guard let self, !self.stopped, let model else { return false }
                    self.refreshNativeFocus()
                    let context = model.commandContext(windowID: id)
                    return !self.environment.isTrackingMenu && !self.isRecordingShortcut
                        && self.environment.permitsProjectCommand(from: context)
                        && self.windows.commandModel(for: context) === model
                        && model.canPerformShortcutCommand(id: commandID)
                }, generation: { [weak environment] in environment?.generation ?? 0 })
            }
        }

        let context = environment.context
        let model = context.flatMap { windows.commandModel(for: $0) }
        var state = model?.projectCommandState() ?? ProjectCommandState()
        let globalModel = model ?? host?.model
        let globalBindings = keyboardShortcuts.registrations.filter {
            ["open-project", "settings"].contains($0.commandID)
        }
        globalShortcuts?.update(registrations: globalBindings)
        for command in ProjectMenuCommand.allCases where command.isApplicationCommand {
            if environment.permitsApplicationCommand && !isPresentingRequest
                && (command != .checkUpdates || !updates.isChecking) {
                state.enabled.insert(command)
            } else { state.enabled.remove(command) }
            if let id = command.shortcutID,
               let binding = keyboardShortcuts.primaryKeyPress(for: id) {
                state.bindings[command] = binding
            }
        }
        state.recentProjects = globalModel?.recentProjects ?? []
        if presentation.presentedWindowIDs.count < 2 { state.enabled.remove(.mergeWindows) }
        if !presentation.canDetachSelectedProject {
            state.enabled.subtract([.detachWindow, .previousProject, .nextProject])
        }
        let beganTracking = !wasTrackingMenu && environment.isTrackingMenu
        wasTrackingMenu = environment.isTrackingMenu
        refreshAccess(for: state.recentProjects.map { $0.url.standardizedFileURL }, force: beganTracking)
        let next = ProjectMenuRenderState(
            context: context, project: state, access: access,
            colorTheme: settings.colorTheme, themePreference: settings.themePreference,
            editorTabLayoutMode: settings.editorTabLayoutMode
        )
        guard !environment.isTrackingMenu, next != renderState else { return }
        renderState = next
    }

    private func refreshAccess(for urls: [URL], force: Bool = false) {
        guard urls != accessPaths || (force && accessTask == nil) else { return }
        accessPaths = urls
        accessGeneration += 1
        let generation = accessGeneration
        accessTask?.cancel()
        access = [:]
        accessTask = Task { @MainActor [weak self, accessChecker] in
            let values = await accessChecker.check(urls)
            guard let self, !Task.isCancelled, self.accessGeneration == generation, !self.stopped else { return }
            self.accessTask = nil
            self.access = values
            self.invalidate()
        }
    }

    func perform(_ command: ProjectMenuCommand, from snapshot: ProjectMenuRenderState?) {
        refreshNativeFocus()
        guard !stopped else { return }
        if command.isApplicationCommand {
            guard !stopped, environment.permitsApplicationCommand, !isPresentingRequest else { return }
            performApplication(command)
            return
        }
        guard let context = snapshot?.context,
              environment.permitsProjectCommand(from: context),
              let model = windows.commandModel(for: context),
              model.projectCommandState().enabled.contains(command) else { return }
        let request = ProjectCommandRequest(
            command: command, context: context,
            documentID: snapshot?.project.activeDocumentID,
            editorItem: snapshot?.project.activeEditorItem,
            referenceID: snapshot?.project.currentReferenceID
        )
        guard request.matches(model.projectCommandState()) else { return }
        switch command {
        case .closeProject: presentation.closeSelectedProject()
        case .mergeWindows: presentation.mergeAllProjectWindows()
        case .detachWindow: presentation.detachSelectedProject()
        case .previousProject: presentation.selectProjectTab(next: false)
        case .nextProject: presentation.selectProjectTab(next: true)
        default:
            model.performProjectMenuCommand(request, canBegin: { [weak self, weak model] in
                guard let self, !self.stopped, let model else { return false }
                self.refreshNativeFocus()
                return self.environment.permitsProjectCommand(from: context)
                    && self.windows.commandModel(for: context) === model
            })
        }
    }

    func performAppearance(_ command: AppearanceMenuCommand) {
        refreshNativeFocus()
        guard !stopped, environment.permitsApplicationCommand, !isPresentingRequest else { return }
        switch command {
        case .colorTheme(let value): settings.colorTheme = value
        case .themePreference(let value): settings.themePreference = value
        case .editorTabLayout(let value): settings.editorTabLayoutMode = value
        }
    }

    func openRecent(_ url: URL) {
        refreshNativeFocus()
        guard !stopped, environment.permitsApplicationCommand, !isPresentingRequest else { return }
        let origin = host.map { $0.model.commandContext(windowID: $0.windowID) }
        isPresentingRequest = true
        invalidate()
        openRecentTask = Task { @MainActor [weak self, accessChecker] in
            let result = await accessChecker.check([url])
            guard let self, !self.stopped, !Task.isCancelled else { return }
            self.openRecentTask = nil
            self.isPresentingRequest = false
            self.invalidate()
            guard result[url.standardizedFileURL] == .present else {
                self.reportFailure("The project is currently unavailable. Check its location and try again.")
                return
            }
            self.openProject(url, origin: origin)
        }
    }

    private func openProject(_ url: URL, origin: ProjectCommandContext?) {
        if let origin, let model = windows.commandModel(for: origin) { model.openProject(url) }
        else if windows.openProjectFromApplication(url) == nil { reportPresentationFailure() }
    }

    private func performApplication(_ command: ProjectMenuCommand) {
        let origin = host.map { $0.model.commandContext(windowID: $0.windowID) }
        switch command {
        case .openProject, .newProject, .openFile:
            isPresentingRequest = true
            invalidate()
            let url = command == .openFile
                ? platformUI.chooseFile(title: "Open File", prompt: "Open")
                : platformUI.chooseDirectory(title: command == .newProject ? "New Project" : "Open a project", prompt: "Open")
            isPresentingRequest = false
            invalidate()
            guard let url else { return }
            if command == .openFile {
                if let origin, let model = windows.commandModel(for: origin) {
                    if model.workspaceURL == nil { model.openStandaloneFile(url) } else { model.openFile(url) }
                } else if windows.openFileFromApplication(url) == nil { reportPresentationFailure() }
            } else { openProject(url, origin: origin) }
        case .settings, .languageSettings, .appearanceSettings, .cloneRepository:
            if let host {
                if command == .cloneRepository {
                    windows.focusWindow?(host.windowID)
                    host.model.showCloneRepository()
                } else if command == .languageSettings { host.model.showSettings(category: .lsp) }
                else if command == .appearanceSettings { host.model.showSettings(category: .general) }
                else { host.model.showSettings() }
            } else {
                let id = UUID()
                pendingHostAction = (id, command)
                isPresentingRequest = true
                cancelHostDeadline = scheduler.schedule(after: Self.hostAttachmentTimeout) { [weak self] in
                    guard let self, self.pendingHostAction?.id == id else { return }
                    self.windowClosed(id)
                    self.windows.windowClosed(id)
                    self.reportPresentationFailure()
                }
                guard windows.presentWelcomeWindow(id: id) != nil else {
                    windowClosed(id)
                    reportPresentationFailure()
                    return
                }
                invalidate()
            }
        case .checkUpdates:
            guard !updates.isChecking else { return }
            Task { [updates] in await updates.checkForUpdates(manual: true) }
        default: break
        }
    }

    private func reportPresentationFailure() {
        reportFailure("The project window could not be opened. Please try again.")
    }

    private func reportFailure(_ message: String) {
        if let host { host.model.showNotification(message) }
        else { platformUI.presentCommandFailure(message) }
    }

    func stop() {
        stopped = true
        cancelPending?()
        cancelPending = nil
        accessTask?.cancel()
        openRecentTask?.cancel()
        accessTask = nil
        openRecentTask = nil
        pendingHostAction = nil
        cancelHostDeadline?()
        cancelHostDeadline = nil
        globalShortcuts?.stop()
        globalShortcuts = nil
        accessChecker.stop()
        observations.removeAll()
        modelObservations.removeAll()
    }
}
