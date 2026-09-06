import Foundation
import LitheModuleAPI

@MainActor
extension AppModel {
    func refreshShortcutDetector() {
        shortcutDetector?.update(registrations: keyboardShortcutFeature.registrations.filter {
            !usesApplicationCommandRouter || !["open-project", "settings"].contains($0.commandID)
        })
    }

    func configureCommandInput(
        permits: @escaping @MainActor (String) -> Bool,
        generation: @escaping @MainActor () -> Int
    ) {
        usesApplicationCommandRouter = true
        shortcutDetector?.setCommandEligibility(permits, generation: generation)
        refreshShortcutDetector()
    }

    var commandStateFeature: ProjectCommandStateFeatureModel {
        if let cached = commandStateFeatureStorage { return cached }
        let feature = ProjectCommandStateFeatureModel(
            scheduler: services.commandProjectionScheduler,
            project: { [weak self] in self?.projectCommandState() ?? ProjectCommandState() },
            sources: [objectWillChange, documentFeature.objectWillChange,
                      editorChrome.objectWillChange, keyboardShortcutFeature.objectWillChange,
                      settings.objectWillChange]
        )
        commandStateFeatureStorage = feature
        return feature
    }

    func commandContext(windowID: UUID) -> ProjectCommandContext {
        ProjectCommandContext(
            windowID: windowID, sessionID: id,
            workspaceGeneration: workspaceFeature.workspaceGeneration,
            standaloneGeneration: standaloneCommandGeneration
        )
    }

    func projectCommandState() -> ProjectCommandState {
        var result = ProjectCommandState()
        result.activeDocumentID = activeDocument?.id
        if let terminal = activeEditorTerminalSession { result.activeEditorItem = .terminal(terminal.id) }
        else if let document = activeDocument { result.activeEditorItem = .document(document.id) }
        else if let media = activeMediaDocument { result.activeEditorItem = .media(media.id) }
        result.currentReferenceID = currentGitReference?.id
        let workspace = workspaceURL != nil
        let document = activeDocument
        let writable = document.map { !$0.isReadOnly } ?? false
        let modules = Dictionary(uniqueKeysWithValues: moduleSnapshots.map { ($0.manifest.id, $0) })
        func available(_ id: ModuleID) -> Bool {
            guard let snapshot = modules[id], !snapshot.isQuarantined,
                  !snapshot.isSuppressedBySafeMode else { return false }
            switch snapshot.state {
            case .disabled, .failed: return false
            default: return true
            }
        }
        let git = workspace && available(.git)
        let repository = git && gitRepositoryRoot != nil
        let branch = repository && currentGitReference != nil && !isPerformingBranchOperation
        let search = workspace && available(.search)
        let execution = workspace && available(.execution)
        let language = available(.languageIntelligence)
        let history = available(.localHistory)
        for command in ProjectMenuCommand.allCases {
            let enabled: Bool
            switch command {
            case .newProject, .openProject, .openFile, .cloneRepository, .settings,
                 .languageSettings, .appearanceSettings, .checkUpdates: enabled = true
            case .newFile, .newDirectory, .closeProject, .synchronize, .project:
                enabled = workspace
            case .save, .replaceInFile: enabled = writable
            case .saveAll: enabled = openDocuments.contains { $0.isDirty && !$0.isReadOnly }
            case .closeEditor:
                enabled = document != nil || activeMediaDocument != nil
                    || activeEditorTerminalSession != nil || standaloneFileURL != nil
            case .commit, .git, .showCommit, .showLog:
                // A sleeping module has no live repository projection. Its
                // tool-window command must remain able to wake the module.
                enabled = git
            case .find, .searchEverywhere, .findInFiles, .replaceInFiles: enabled = search
            case .terminal: enabled = workspace && available(.terminal)
            case .run, .tests, .editConfigurations, .rescan: enabled = execution
            case .debug: enabled = execution && available(.debug)
            case .problems: enabled = workspace && language
            case .back: enabled = canNavigateBack
            case .forward: enabled = canNavigateForward
            case .goToLine, .findInFile: enabled = document != nil
            case .definition: enabled = language && supportsLanguageServerFeature(.definition)
            case .implementation: enabled = language && supportsLanguageServerFeature(.implementation)
            case .usages: enabled = language && supportsLanguageServerFeature(.references)
            case .findNext, .findPrevious: enabled = isFindBarVisible && findMatchCount > 0
            case .restartLanguageServers: enabled = workspace && language
            case .fileHistory: enabled = document != nil && history
            case .projectHistory: enabled = workspace && history
            case .push, .update, .newBranch: enabled = branch
            case .fetch: enabled = repository && !isPerformingBranchOperation
            case .branches: enabled = repository
            case .mergeWindows, .detachWindow, .previousProject, .nextProject:
                enabled = workspace // The native window projection narrows this.
            }
            if enabled { result.enabled.insert(command) }
            if let id = command.shortcutID,
               let binding = keyboardShortcutFeature.primaryKeyPress(for: id) {
                result.bindings[command] = binding
            }
        }
        if isSidebarVisible {
            switch selectedSidebar {
            case .project: result.selected.insert(.project)
            case .changes: result.selected.insert(.commit)
            case .search: result.selected.insert(.find)
            default: break
            }
        }
        if isGitLogVisible { result.selected.insert(.git) }
        if isTerminalVisible { result.selected.insert(.terminal) }
        if isRunVisible { result.selected.insert(.run) }
        if isDebugVisible { result.selected.insert(.debug) }
        if isTestsVisible { result.selected.insert(.tests) }
        if isProblemsVisible { result.selected.insert(.problems) }
        result.recentProjects = recentProjects
        return result
    }

    /// Native focus and request identity are checked by the command router;
    /// this second check protects against facts changing while a menu is open.
    func performProjectMenuCommand(
        _ request: ProjectCommandRequest,
        canBegin: @escaping @MainActor () -> Bool
    ) {
        let command = request.command
        guard !command.isApplicationCommand,
              commandContext(windowID: request.context.windowID) == request.context,
              request.matches(projectCommandState()), canBegin(),
              projectCommandState().enabled.contains(command) else { return }
        switch command {
        case .newFile:
            if let root = workspaceURL { requestCreateFile(in: root) }
        case .newDirectory:
            if let root = workspaceURL { requestCreateDirectory(in: root) }
        case .save: saveActiveDocument()
        case .saveAll: _ = saveAllDocuments()
        case .closeEditor: _ = requestCloseActiveWorkbenchItem()
        case .synchronize: scheduleMenuCommand(request, canBegin: canBegin) { model in await model.refreshWorkspace() }
        case .project, .commit, .find, .terminal, .run, .debug, .tests, .problems:
            if let id = command.shortcutID { performShortcutCommand(id: id) }
        case .git: scheduleMenuCommand(request, canBegin: canBegin) { model in await model.toggleGitLog() }
        case .back: navigateBack()
        case .forward: navigateForward()
        case .searchEverywhere: toggleSearchEverywhere()
        case .goToLine: showGoToLine()
        case .definition: goToDefinition()
        case .implementation: goToImplementation()
        case .usages: findReferences()
        case .findInFile: showFindBar()
        case .replaceInFile: showReplaceBar()
        case .findInFiles: openProjectSearch()
        case .replaceInFiles: openProjectReplace()
        case .findNext: navigateFind(offset: 1)
        case .findPrevious: navigateFind(offset: -1)
        case .editConfigurations: showRunConfigurationEditor()
        case .rescan: requestRunConfigurationRescan()
        case .restartLanguageServers: restartLanguageServers()
        case .fileHistory:
            if let url = activeDocument?.url { showLocalHistory(for: url) }
        case .projectHistory: showProjectLocalHistory()
        case .showCommit: showCommitToolWindow(request, canBegin: canBegin)
        case .push: pendingGitPushReference = currentGitReference
        case .update:
            if let reference = currentGitReference {
                scheduleMenuCommand(request, canBegin: canBegin) { model in await model.updateCurrentBranch(reference) }
            }
        case .fetch: scheduleMenuCommand(request, canBegin: canBegin) { model in await model.fetchGit() }
        case .branches: branchSwitcherRequest += 1
        case .newBranch: pendingNewBranchReference = currentGitReference
        case .showLog:
            scheduleMenuCommand(request, canBegin: canBegin) { model in
                guard await model.activateGitModule() != nil, model.isMenuRequestCurrent(request) else { return }
                if !model.isGitLogVisible { await model.toggleGitLog() }
            }
        case .closeProject, .mergeWindows, .detachWindow, .previousProject, .nextProject:
            break // The native router owns window operations and close confirmation.
        case .newProject, .openProject, .openFile, .cloneRepository, .settings,
             .languageSettings, .appearanceSettings, .checkUpdates:
            break // Application requests never inherit project execution eligibility.
        }
    }

    private func showCommitToolWindow(_ request: ProjectCommandRequest, canBegin: @escaping @MainActor () -> Bool) {
        scheduleMenuCommand(request, canBegin: canBegin) { model in
            guard await model.activateGitModule() != nil, model.isMenuRequestCurrent(request) else { return }
            model.selectedSidebar = .changes
            model.isSidebarVisible = true
            await model.refreshGit()
        }
    }

    private func isMenuRequestCurrent(_ request: ProjectCommandRequest) -> Bool {
        !Task.isCancelled && commandContext(windowID: request.context.windowID) == request.context
            && request.matches(projectCommandState())
            && projectCommandState().enabled.contains(request.command)
    }

    private func scheduleMenuCommand(
        _ request: ProjectCommandRequest,
        canBegin: @escaping @MainActor () -> Bool,
        action: @escaping @MainActor (AppModel) async -> Void
    ) {
        let id = UUID()
        menuCommandTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.menuCommandTasks[id] = nil }
            guard self.isMenuRequestCurrent(request), canBegin() else { return }
            await action(self)
        }
    }
}
