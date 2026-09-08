import SwiftUI

/// Menus observe a deduplicated, tracking-aware projection. Closures capture the
/// displayed project context, then revalidate it before dispatching an action.
struct LitheProjectCommands: Commands {
    @ObservedObject var presentation: MenuPresentationCoordinator

    private var items: ProjectCommandMenuItems {
        return ProjectCommandMenuItems(snapshot: presentation.renderState, presentation: presentation)
    }

    var body: some Commands {
        LitheFileCommands(items: items)
        LitheFindCommands(items: items)
        LitheToolCommands(items: items)
        LitheViewCommands(items: items)
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { presentation.undoWorkspaceEdit() }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { presentation.redoWorkspaceEdit() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appSettings) {
            items.button("Settings…", .settings)
        }
        CommandGroup(after: .appInfo) {
            items.button("Check for Updates…", .checkUpdates)
        }
        CommandGroup(after: .windowArrangement) {
            items.button("Merge All Project Windows", .mergeWindows)
            items.button("Move Project to New Window", .detachWindow)
            Divider()
            items.button("Previous Project Tab", .previousProject)
            items.button("Next Project Tab", .nextProject)
        }
        CommandMenu("Navigate") {
            items.button("Back", .back)
            items.button("Forward", .forward)
            Divider()
            items.button("Search Everywhere…", .searchEverywhere)
            items.button("Go to Line…", .goToLine)
            Divider()
            items.button("Go to Definition", .definition)
            items.button("Go to Implementation", .implementation)
            items.button("Find Usages", .usages)
        }
    }
}

private struct LitheViewCommands: Commands {
    let items: ProjectCommandMenuItems

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Menu("Tool Windows") {
                items.toggle("Project", .project)
                items.toggle("Commit", .commit)
                items.toggle("Find", .find)
                Divider()
                items.toggle("Git", .git)
                items.toggle("Terminal", .terminal)
                items.toggle("Run", .run)
                items.toggle("Debug", .debug)
                items.toggle("Problems", .problems)
                items.toggle("Tests", .tests)
            }
            Menu("Appearance") {
                Menu("Color theme") {
                    ForEach(AppColorTheme.allCases) { value in
                        appearanceToggle(value.title, selected: items.snapshot.colorTheme == value,
                                         command: .colorTheme(value))
                    }
                }
                Menu("Appearance mode") {
                    ForEach(AppThemePreference.allCases) { value in
                        appearanceToggle(value.title, selected: items.snapshot.themePreference == value,
                                         command: .themePreference(value))
                    }
                }
                Divider()
                items.button("Appearance Settings…", .appearanceSettings)
            }
            Menu("Editor Tabs") {
                ForEach(EditorTabLayoutMode.allCases) { value in
                    appearanceToggle(value.title, selected: items.snapshot.editorTabLayoutMode == value,
                                     command: .editorTabLayout(value))
                }
            }
            Divider()
        }
    }

    private func appearanceToggle(_ title: String, selected: Bool, command: AppearanceMenuCommand) -> some View {
        Toggle(LocalizedStringKey(title), isOn: Binding(
            get: { selected }, set: { _ in items.presentation.performAppearance(command) }
        ))
        .disabled(!items.snapshot.isEnabled(.appearanceSettings))
    }
}

@MainActor
private struct ProjectCommandMenuItems {
    let snapshot: ProjectMenuRenderState
    let presentation: MenuPresentationCoordinator

    func button(_ title: LocalizedStringKey, _ command: ProjectMenuCommand) -> some View {
        Button(title) { presentation.perform(command, from: snapshot) }
            .disabled(!snapshot.isEnabled(command))
            .litheKeyboardShortcut(snapshot.project.bindings[command])
    }

    func toggle(_ title: LocalizedStringKey, _ command: ProjectMenuCommand) -> some View {
        Toggle(title, isOn: Binding(
            get: { snapshot.project.selected.contains(command) },
            set: { _ in presentation.perform(command, from: snapshot) }
        ))
        .disabled(!snapshot.isEnabled(command))
        .litheKeyboardShortcut(snapshot.project.bindings[command])
    }

    func recentTitle(_ project: RecentProject) -> String {
        let duplicates = snapshot.project.recentProjects.filter { $0.name == project.name }
        guard duplicates.count > 1 else { return project.name }
        return "\(project.name) — \(project.url.deletingLastPathComponent().path)"
    }
}

private struct LitheFileCommands: Commands {
    let items: ProjectCommandMenuItems

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Menu("New") {
                items.button("Project from Existing Folder…", .newProject)
                items.button("File…", .newFile)
                items.button("Directory…", .newDirectory)
            }
            items.button("Open…", .openProject)
            items.button("Open File…", .openFile)
            Menu("Recent Projects") {
                if items.snapshot.project.recentProjects.isEmpty {
                    Text("No recent projects")
                }
                ForEach(items.snapshot.project.recentProjects) { project in
                    Button(items.recentTitle(project)) {
                        items.presentation.openRecent(project.url)
                    }
                    .help(project.url.path)
                    .disabled(!items.snapshot.isEnabled(.openProject)
                        || items.snapshot.access[project.url.standardizedFileURL] == .missing)
                }
            }
            items.button("Clone Repository…", .cloneRepository)
            Divider()
            items.button("Close Project", .closeProject)
        }
        CommandGroup(replacing: .saveItem) {
            items.button("Save", .save)
            items.button("Save All", .saveAll)
            items.button("Close Editor Tab", .closeEditor)
            Divider()
            items.button("Synchronize", .synchronize)
        }
    }
}

private struct LitheFindCommands: Commands {
    let items: ProjectCommandMenuItems

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                items.button("Find…", .findInFile)
                items.button("Replace…", .replaceInFile)
                Divider()
                items.button("Find in Files…", .findInFiles)
                items.button("Replace in Files…", .replaceInFiles)
                Divider()
                items.button("Find Next", .findNext)
                items.button("Find Previous", .findPrevious)
                items.button("Find Usages", .usages)
            }
        }
    }
}

private struct LitheToolCommands: Commands {
    let items: ProjectCommandMenuItems

    var body: some Commands {
        CommandMenu("Tools") {
            items.button("Terminal", .terminal)
            items.button("Edit Configurations…", .editConfigurations)
            items.button("Identify / Rescan Project…", .rescan)
            Divider()
            items.button("Language Support…", .languageSettings)
            items.button("Restart Language Servers", .restartLanguageServers)
            Divider()
            Menu("Local History") {
                items.button("Show File History…", .fileHistory)
                items.button("Show Project History…", .projectHistory)
            }
        }
        CommandMenu("Git") {
            items.button("Commit…", .showCommit)
            items.button("Push…", .push)
            items.button("Update Project…", .update)
            items.button("Fetch", .fetch)
            Divider()
            items.button("Branches…", .branches)
            items.button("New Branch…", .newBranch)
            items.button("Show Log", .showLog)
        }
    }
}
