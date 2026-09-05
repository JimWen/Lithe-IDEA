import SwiftUI

/// Menu actions observe the focused project, including when several projects
/// share a native tab group. They reuse the same model entry points as tools.
struct LitheProjectCommands: Commands {
    @FocusedObject private var focusedModel: AppModel?
    @ObservedObject var projectWindows: ProjectWindowManager
    @ObservedObject var windowPresentation: ProjectWindowPresentation
    @ObservedObject var updateChecker: UpdateChecker

    private var model: AppModel { focusedModel ?? projectWindows.activeSessions.activeModel }

    var body: some Commands {
        LitheFileCommands(model: model, presentation: windowPresentation)
        LitheFindCommands(model: model)
        LitheToolCommands(model: model)

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showSettings() }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "settings"))
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task { await updateChecker.checkForUpdates(manual: true) }
            }
            .disabled(updateChecker.isChecking)
        }
        CommandGroup(after: .windowArrangement) {
            Menu("Tool Windows") {
                Button("Project") { model.toggleSidebar(.project) }
                Button("Commit") { model.toggleSidebar(.changes) }
                Button("Find") { model.selectedSidebar = .search }
                Divider()
                Button("Git") { Task { await model.toggleGitLog() } }
                Button("Terminal") { model.toggleTerminal() }
                Button("Run") { model.toggleRun() }
                Button("Problems") { model.toggleProblems() }
            }
            .disabled(model.workspaceURL == nil)
            Divider()
            Button("Merge All Project Windows") { windowPresentation.mergeAllProjectWindows() }
                .disabled(projectWindows.windowIDs.count < 2 || model.workspaceURL == nil)
            Button("Move Project to New Window") { windowPresentation.detachSelectedProject() }
                .disabled(!windowPresentation.canDetachSelectedProject)
            Divider()
            Button("Previous Project Tab") { windowPresentation.selectProjectTab(next: false) }
                .disabled(!windowPresentation.canDetachSelectedProject)
            Button("Next Project Tab") { windowPresentation.selectProjectTab(next: true) }
                .disabled(!windowPresentation.canDetachSelectedProject)
        }
        CommandMenu("Navigate") {
            Button("Back") { model.navigateBack() }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "navigate-back"))
                .disabled(!model.canNavigateBack)
            Button("Forward") { model.navigateForward() }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "navigate-forward"))
                .disabled(!model.canNavigateForward)
            Divider()
            Button("Search Everywhere…") { model.toggleSearchEverywhere() }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "search-everywhere"))
                .disabled(model.workspaceURL == nil)
            Button("Go to Line…") { model.showGoToLine() }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "go-to-line"))
                .disabled(model.activeDocument == nil)
            Divider()
            Button("Go to Definition") { model.goToDefinition() }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "go-to-definition"))
                .disabled(!model.canPerformShortcutCommand(id: "go-to-definition"))
            Button("Go to Implementation") { model.goToImplementation() }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "go-to-implementation"))
                .disabled(!model.supportsLanguageServerFeature(.implementation))
            Button("Find Usages") { model.findReferences() }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "find-usages"))
                .disabled(!model.supportsLanguageServerFeature(.references))
        }
    }
}

private struct LitheFileCommands: Commands {
    @ObservedObject var model: AppModel
    let presentation: ProjectWindowPresentation

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Menu("New") {
                Button("Project from Existing Folder…") { model.chooseProject(title: "New Project", prompt: "Choose Folder") }
                Button("File…") {
                    if let root = model.workspaceURL { model.requestCreateFile(in: root) }
                }
                .disabled(model.workspaceURL == nil)
                Button("Directory…") {
                    if let root = model.workspaceURL { model.requestCreateDirectory(in: root) }
                }
                .disabled(model.workspaceURL == nil)
            }
            Button("Open…") { model.chooseProject() }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "open-project"))
            Button("Open File…") { model.chooseEditorFile() }
            Menu("Recent Projects") {
                if model.recentProjects.isEmpty {
                    Text("No recent projects")
                }
                ForEach(model.recentProjects) { project in
                    Button(project.url.lastPathComponent) { model.openProject(project.url) }
                        .help(project.url.path)
                        .disabled(!model.fileExists(at: project.url))
                }
            }
            Button("Clone Repository…") { model.showCloneRepository() }
            Divider()
            Button("Close Project") { presentation.closeSelectedProject() }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "close-project"))
                .disabled(model.workspaceURL == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.saveActiveDocument() }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "save"))
                .disabled(model.activeDocument == nil)
            Button("Save All") { _ = model.saveAllDocuments() }
                .disabled(!model.hasUnsavedDocuments)
            Button("Close Editor Tab") { _ = model.requestCloseActiveWorkbenchItem() }
                .disabled(model.activeDocument == nil && model.activeMediaDocument == nil
                    && model.activeEditorTerminalSession == nil && model.standaloneFileURL == nil)
            Divider()
            Button("Synchronize") { Task { await model.refreshWorkspace() } }
                .disabled(model.workspaceURL == nil)
        }
    }
}

private struct LitheFindCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") { model.showFindBar() }
                    .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "find-in-file"))
                    .disabled(model.activeDocument == nil)
                Button("Replace…") { model.showReplaceBar() }
                    .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "replace-in-file"))
                    .disabled(model.activeDocument == nil)
                Divider()
                Button("Find in Files…") { model.openProjectSearch() }
                    .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "search-in-project"))
                    .disabled(model.workspaceURL == nil)
                Button("Replace in Files…") { model.openProjectReplace() }
                    .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "replace-in-project"))
                    .disabled(model.workspaceURL == nil)
                Divider()
                Button("Find Next") { model.navigateFind(offset: 1) }
                    .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "find-next"))
                    .disabled(!model.isFindBarVisible || model.findMatchCount == 0)
                Button("Find Previous") { model.navigateFind(offset: -1) }
                    .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "find-previous"))
                    .disabled(!model.isFindBarVisible || model.findMatchCount == 0)
                Button("Find Usages") { model.findReferences() }
                    .disabled(!model.supportsLanguageServerFeature(.references))
            }
        }
    }
}

private struct LitheToolCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("Tools") {
            Button("Terminal") { model.toggleTerminal() }
                .disabled(model.workspaceURL == nil)
            Button("Edit Configurations…") { model.showRunConfigurationEditor() }
                .disabled(model.workspaceURL == nil)
            Button("Identify / Rescan Project…") { model.requestRunConfigurationRescan() }
                .disabled(model.workspaceURL == nil)
            Divider()
            Button("Language Support…") { model.showSettings(category: .lsp) }
            Button("Restart Language Servers") { model.restartLanguageServers() }
                .disabled(model.workspaceURL == nil)
            Divider()
            Menu("Local History") {
                Button("Show File History…") {
                    if let url = model.activeDocument?.url { model.showLocalHistory(for: url) }
                }
                .disabled(model.activeDocument == nil)
                Button("Show Project History…") { model.showProjectLocalHistory() }
                    .disabled(model.workspaceURL == nil)
            }
        }
        CommandMenu("Git") {
            Button("Commit…") { model.selectedSidebar = .changes }
                .disabled(model.gitRepositoryRoot == nil)
            Button("Push…") { model.pendingGitPushReference = model.currentGitReference }
                .disabled(model.currentGitReference == nil || model.isPerformingBranchOperation)
            Button("Update Project…") {
                if let reference = model.currentGitReference {
                    Task { await model.updateCurrentBranch(reference) }
                }
            }
            .disabled(model.currentGitReference == nil || model.isPerformingBranchOperation)
            Button("Fetch") { Task { await model.fetchGit() } }
                .disabled(model.gitRepositoryRoot == nil || model.isPerformingBranchOperation)
            Divider()
            Button("Branches…") { model.branchSwitcherRequest += 1 }
                .disabled(model.gitRepositoryRoot == nil)
            Button("New Branch…") { model.pendingNewBranchReference = model.currentGitReference }
                .disabled(model.currentGitReference == nil || model.isPerformingBranchOperation)
            Button("Show Log") {
                if !model.isGitLogVisible { Task { await model.toggleGitLog() } }
            }
            .disabled(model.gitRepositoryRoot == nil)
        }
    }
}
