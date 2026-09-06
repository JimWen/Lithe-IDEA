import Foundation

/// A menu request belongs to one opening of one project, even when the native
/// tab group or the currently selected project changes before dispatch.
struct ProjectCommandContext: Equatable, Hashable, Sendable {
    let windowID: UUID
    let sessionID: UUID
    let workspaceGeneration: Int
    let standaloneGeneration: Int
}

enum ProjectMenuCommand: String, CaseIterable, Sendable {
    case newProject, newFile, newDirectory, openProject, openFile, cloneRepository
    case closeProject, save, saveAll, closeEditor, synchronize, settings, checkUpdates
    case project, commit, find, git, terminal, run, debug, tests, problems
    case mergeWindows, detachWindow, previousProject, nextProject
    case back, forward, searchEverywhere, goToLine, definition, implementation, usages
    case findInFile, replaceInFile, findInFiles, replaceInFiles, findNext, findPrevious
    case editConfigurations, rescan, languageSettings, appearanceSettings, restartLanguageServers
    case fileHistory, projectHistory, showCommit, push, update, fetch, branches, newBranch, showLog

    var shortcutID: String? {
        switch self {
        case .openProject: "open-project"
        case .closeProject: "close-project"
        case .save: "save"
        case .settings: "settings"
        case .project: "toggle-project"
        case .commit: "toggle-commit"
        case .find: "toggle-find"
        case .git: "toggle-git-log"
        case .terminal: "toggle-terminal"
        case .run: "toggle-run"
        case .debug: "toggle-debug"
        case .tests: "toggle-tests"
        case .problems: "toggle-problems"
        case .back: "navigate-back"
        case .forward: "navigate-forward"
        case .searchEverywhere: "search-everywhere"
        case .goToLine: "go-to-line"
        case .definition: "go-to-definition"
        case .implementation: "go-to-implementation"
        case .usages: "find-usages"
        case .findInFile: "find-in-file"
        case .replaceInFile: "replace-in-file"
        case .findInFiles: "search-in-project"
        case .replaceInFiles: "replace-in-project"
        case .findNext: "find-next"
        case .findPrevious: "find-previous"
        case .fileHistory: "local-history"
        case .projectHistory: "project-local-history"
        default: nil
        }
    }

    var isApplicationCommand: Bool {
        switch self {
        case .newProject, .openProject, .openFile, .cloneRepository, .settings,
             .checkUpdates, .languageSettings, .appearanceSettings: true
        default: false
        }
    }
}

/// Only facts affecting menu presentation are projected. Editor text, caret
/// movement, terminal output and Git progress never become menu payloads.
struct ProjectCommandState: Equatable {
    var activeDocumentID: UUID?
    var activeEditorItem: EditorTabItem?
    var currentReferenceID: String?
    var enabled: Set<ProjectMenuCommand> = []
    var selected: Set<ProjectMenuCommand> = []
    var bindings: [ProjectMenuCommand: KeyboardShortcutBinding] = [:]
    var recentProjects: [RecentProject] = []
}

struct ProjectCommandRequest: Equatable {
    let command: ProjectMenuCommand
    let context: ProjectCommandContext
    let documentID: UUID?
    let editorItem: EditorTabItem?
    let referenceID: String?

    func matches(_ state: ProjectCommandState) -> Bool {
        switch command {
        case .closeEditor: return state.activeEditorItem == editorItem
        case .save, .findInFile, .replaceInFile, .goToLine, .definition,
             .implementation, .usages, .fileHistory, .findNext, .findPrevious:
            return state.activeDocumentID == documentID
        case .push, .update, .newBranch:
            return state.currentReferenceID == referenceID
        default: return true
        }
    }
}
