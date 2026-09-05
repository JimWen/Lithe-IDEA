import SwiftUI

/// Commands observe the focused project's state without rebuilding every
/// project window for editor selection and document changes.
struct LitheProjectCommands: Commands {
    @FocusedObject private var focusedModel: AppModel?
    @ObservedObject var projectWindows: ProjectWindowManager
    @ObservedObject var windowPresentation: ProjectWindowPresentation
    @ObservedObject var updateChecker: UpdateChecker

    private var model: AppModel { focusedModel ?? projectWindows.activeSessions.activeModel }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Project…") {
                model.chooseProject()
            }
            .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "open-project"))
        }

        CommandGroup(after: .saveItem) {
            Button("Save") {
                model.saveActiveDocument()
            }
            .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "save"))
            .disabled(model.activeDocument == nil)

            Button("Close Project") {
                windowPresentation.closeSelectedProject()
            }
            .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "close-project"))
            .disabled(model.workspaceURL == nil)

            Button("Close File") {
                model.closeStandaloneFile()
            }
            .disabled(model.standaloneFileURL == nil)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                model.showSettings()
            }
            .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "settings"))
        }

        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Merge All Project Windows") {
                windowPresentation.mergeAllProjectWindows()
            }
            .disabled(projectWindows.windowIDs.count < 2 || model.workspaceURL == nil)
            Button("Move Project to New Window") {
                windowPresentation.detachSelectedProject()
            }
            .disabled(!windowPresentation.canDetachSelectedProject)
            Divider()
            Button("Previous Project Tab") {
                windowPresentation.selectProjectTab(next: false)
            }
            .disabled(!windowPresentation.canDetachSelectedProject)
            Button("Next Project Tab") {
                windowPresentation.selectProjectTab(next: true)
            }
            .disabled(!windowPresentation.canDetachSelectedProject)
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task { await updateChecker.checkForUpdates(manual: true) }
            }
            .disabled(updateChecker.isChecking)
        }

        CommandMenu("Navigate") {
            Group {
                Button("Back") {
                    model.navigateBack()
                }
                .litheKeyboardShortcut(
                    model.keyboardShortcutFeature.primaryKeyPress(for: "navigate-back")
                )
                .disabled(!model.canNavigateBack)

                Button("Forward") {
                    model.navigateForward()
                }
                .litheKeyboardShortcut(
                    model.keyboardShortcutFeature.primaryKeyPress(for: "navigate-forward")
                )
                .disabled(!model.canNavigateForward)

                Divider()

                Button("Search Everywhere…") {
                    model.toggleSearchEverywhere()
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "search-everywhere"))
                .disabled(model.workspaceURL == nil)

                Divider()

                Button("Find in File…") {
                    model.showFindBar()
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "find-in-file"))
                .disabled(model.activeDocument == nil)

                Button("Replace in File…") {
                    model.showReplaceBar()
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "replace-in-file"))
                .disabled(model.activeDocument == nil)

                Button("Find Next") {
                    model.navigateFind(offset: 1)
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "find-next"))
                .disabled(!model.isFindBarVisible || model.findMatchCount == 0)

                Button("Find Previous") {
                    model.navigateFind(offset: -1)
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "find-previous"))
                .disabled(!model.isFindBarVisible || model.findMatchCount == 0)

                Button("Go to Line…") {
                    model.showGoToLine()
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "go-to-line"))
                .disabled(model.activeDocument == nil)
            }

            Divider()

            Button("Go to Definition") {
                model.goToDefinition()
            }
            .litheKeyboardShortcut(
                model.keyboardShortcutFeature.primaryKeyPress(for: "go-to-definition")
            )
            .disabled(!model.canPerformShortcutCommand(id: "go-to-definition"))

            Button("Go to Implementation") {
                model.goToImplementation()
            }
            .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "go-to-implementation"))
            .disabled(!model.supportsLanguageServerFeature(.implementation))

            Button("Find Usages") {
                model.findReferences()
            }
            .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "find-usages"))
            .disabled(!model.supportsLanguageServerFeature(.references))

            Divider()

            Button("Find in Files…") {
                model.openProjectSearch()
            }
            .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "search-in-project"))
            .disabled(model.workspaceURL == nil)

            Button("Replace in Files…") {
                model.openProjectReplace()
            }
            .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "replace-in-project"))
            .disabled(model.workspaceURL == nil)
        }

        CommandMenu("History") {
            Button("Show Local History…") {
                if let fileURL = model.activeDocument?.url {
                    model.showLocalHistory(for: fileURL)
                }
            }
            .disabled(model.activeDocument == nil)

            Button("Show Project Local History…") {
                model.showProjectLocalHistory()
            }
            .disabled(model.workspaceURL == nil)
        }
    }
}
