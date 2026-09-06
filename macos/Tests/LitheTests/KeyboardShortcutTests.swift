import Foundation
import Testing
@testable import Lithe

@Suite("Keyboard shortcuts")
@MainActor
struct KeyboardShortcutTests {
    @Test
    func catalogHasStableUniqueCommandsAndConflictFreeDefaults() {
        let commands = LitheCommandCatalog.commands
        #expect(Set(["toggle-project", "toggle-commit", "toggle-find", "toggle-run",
                     "toggle-debug", "toggle-problems", "toggle-git-log", "toggle-terminal",
                     "toggle-tests"]).isSubset(of: Set(commands.map(\.id))))
        #expect(Set(commands.map(\.id)).count == commands.count)

        let owners = commands.flatMap { command in
            command.defaultBindings.map { (binding: $0, commandID: command.id) }
        }
        for (index, owner) in owners.enumerated() {
            #expect(!owners.dropFirst(index + 1).contains {
                $0.binding == owner.binding && $0.commandID != owner.commandID
            })
        }
    }

    @Test
    func toggleBreakpointUsesTheIDEADefaultShortcut() throws {
        let command = try #require(LitheCommandCatalog.command(id: "toggle-breakpoint"))

        #expect(command.defaultBindings == [
            .keyPress(key: "f8", modifiers: [.command])
        ])
    }

    @Test
    func viewBreakpointsUsesTheIDEADefaultShortcut() throws {
        let command = try #require(LitheCommandCatalog.command(id: "view-breakpoints"))

        #expect(command.defaultBindings == [
            .keyPress(key: "f8", modifiers: [.shift, .command])
        ])
    }

    @Test
    @MainActor
    func actionRegistryCoversEveryCatalogCommand() async {
        let store = KeyboardShortcutTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
        ).services
        let model = AppModel(settings: settings, services: services)
        let actions = LitheActionRegistry.actions(for: model)
        let actionIDs = Set(actions.map(\.id))
        let commandIDs = Set(LitheCommandCatalog.commands.map(\.id))

        #expect(actions.count == LitheCommandCatalog.commands.count)
        #expect(actionIDs.count == actions.count)
        #expect(actionIDs == commandIDs)
        #expect(actionIDs.contains("save"))
        #expect(actionIDs.contains("search-everywhere"))
        #expect(actionIDs.contains("find-next"))
        #expect(actionIDs.contains("find-previous"))
        #expect(actionIDs.contains("navigate-back"))
        #expect(actionIDs.contains("navigate-forward"))
        #expect(actionIDs.contains("go-to-definition"))
        #expect(actionIDs.contains("go-to-implementation"))
        #expect(actionIDs.contains("rebuild-java-index"))
        #expect(!actionIDs.contains("spring-endpoints"))
        #expect(!actionIDs.contains("toggle-maven"))
        #expect(actionIDs.contains("toggle-breakpoint"))
        #expect(actionIDs.contains("view-breakpoints"))
        await model.shutdownProjectSession()
    }

    @Test
    func bindingsUseCanonicalDisplayOrderAndRoundTripThroughJSON() throws {
        let binding = KeyboardShortcutBinding.keyPress(
            key: "u",
            modifiers: [.control, .option, .shift, .command]
        )
        #expect(binding.displayText == "⌃⌥⇧⌘U")
        let data = try JSONEncoder().encode(binding)
        #expect(try JSONDecoder().decode(KeyboardShortcutBinding.self, from: data) == binding)
        #expect(KeyboardShortcutBinding.doubleTap(.shift).displayText == "⇧ ⇧")
    }

    @Test
    func plainTextKeysRequireANonShiftModifier() {
        #expect(!KeyboardShortcutBinding.keyPress(key: "a", modifiers: []).isAssignable)
        #expect(!KeyboardShortcutBinding.keyPress(key: "a", modifiers: [.shift]).isAssignable)
        #expect(KeyboardShortcutBinding.keyPress(key: "a", modifiers: [.command]).isAssignable)
        #expect(KeyboardShortcutBinding.keyPress(key: "f5", modifiers: []).isAssignable)
    }

    @Test
    func overridesPersistDisableAndResetWithoutChangingOtherSettings() throws {
        let store = KeyboardShortcutTestStore()
        let settings = AppSettings(store: store)
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let replacement = KeyboardShortcutBinding.keyPress(
            key: "k",
            modifiers: [.command, .option]
        )

        try feature.replaceBindings(for: "run", with: [replacement])
        #expect(feature.effectiveBindings(for: "run") == [replacement])
        #expect(AppSettings(store: store).keyboardShortcutOverrides["run"] == [replacement])

        try feature.replaceBindings(for: "run", with: [])
        #expect(feature.effectiveBindings(for: "run").isEmpty)

        feature.resetCommand("run")
        #expect(
            feature.effectiveBindings(for: "run")
                == LitheCommandCatalog.command(id: "run")?.defaultBindings
        )

        settings.editorFontSize = 17
        try feature.replaceBindings(for: "debug", with: [replacement])
        feature.resetAll()
        #expect(settings.editorFontSize == 17)
        #expect(settings.keyboardShortcutOverrides.isEmpty)
    }

    @Test
    func conflictReportsTheOwningCommandAndDoesNotPersist() throws {
        let settings = AppSettings(store: KeyboardShortcutTestStore())
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let findShortcut = try #require(feature.effectiveBindings(for: "find-in-file").first)

        #expect(throws: KeyboardShortcutUpdateError.conflict(commandID: "find-in-file")) {
            try feature.replaceBindings(for: "run", with: [findShortcut])
        }
        #expect(settings.keyboardShortcutOverrides["run"] == nil)
    }

    @Test
    func corruptPersistenceFallsBackToDefaults() {
        let store = KeyboardShortcutTestStore()
        store.set(Data("not-json".utf8), forKey: "settings.keyboardShortcutOverrides")

        let settings = AppSettings(store: store)
        let feature = KeyboardShortcutFeatureModel(settings: settings)

        #expect(settings.keyboardShortcutOverrides.isEmpty)
        #expect(
            feature.effectiveBindings(for: "run")
                == LitheCommandCatalog.command(id: "run")?.defaultBindings
        )
    }

    @Test
    func featureProjectsCurrentDisplayPrimaryKeyPressAndRegistrations() throws {
        let settings = AppSettings(store: KeyboardShortcutTestStore())
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let replacement = KeyboardShortcutBinding.keyPress(
            key: "p",
            modifiers: [.command, .option]
        )
        try feature.replaceBindings(for: "find-in-file", with: [replacement])

        #expect(feature.displayText(for: "find-in-file") == "⌥⌘P")
        #expect(feature.primaryKeyPress(for: "find-in-file") == replacement)
        #expect(
            feature.registrations.first { $0.commandID == "find-in-file" }?.bindings
                == [replacement]
        )
        #expect(
            feature.primaryKeyPress(for: "search-everywhere")
                == .keyPress(key: "o", modifiers: [.shift, .command])
        )
    }

    @Test
    func filteringMatchesTitleIDGroupAndShortcutText() {
        let feature = KeyboardShortcutFeatureModel(
            settings: AppSettings(store: KeyboardShortcutTestStore())
        )

        #expect(feature.filteredCommands(query: "find usages").map(\.id) == ["find-usages"])
        #expect(feature.filteredCommands(query: "window").allSatisfy { $0.group == .window })
        #expect(feature.filteredCommands(query: "⌃R").map(\.id).contains("run"))
        #expect(
            feature.filteredCommands(query: "全局搜索") { command in
                command.id == "search-everywhere" ? "全局搜索 查找文件和操作" : ""
            }.map(\.id) == ["search-everywhere"]
        )
        #expect(feature.groupedCommands(query: "history").allSatisfy { !$0.commands.isEmpty })
    }

    @Test
    func applicationRestoreDefaultsAlsoClearsShortcutOverrides() throws {
        let settings = AppSettings(store: KeyboardShortcutTestStore())
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let replacement = KeyboardShortcutBinding.keyPress(
            key: "k",
            modifiers: [.command, .option]
        )
        settings.editorFontSize = 18
        try feature.replaceBindings(for: "run", with: [replacement])

        settings.restoreDefaults()

        #expect(settings.editorFontSize == 13)
        #expect(settings.keyboardShortcutOverrides.isEmpty)
        #expect(
            feature.effectiveBindings(for: "run")
                == LitheCommandCatalog.command(id: "run")?.defaultBindings
        )
    }

    @Test
    func legacyOverrideOutranksNewToolDefaultAcrossSharedSettingsAndReload() throws {
        let store = KeyboardShortcutTestStore()
        let settings = AppSettings(store: store)
        let first = KeyboardShortcutFeatureModel(settings: settings)
        let second = KeyboardShortcutFeatureModel(settings: settings)
        let binding = KeyboardShortcutBinding.keyPress(key: "1", modifiers: [.command])
        settings.setKeyboardShortcutOverrides(["save": [binding], "toggle-debug": []])

        for feature in [first, second, KeyboardShortcutFeatureModel(settings: AppSettings(store: store))] {
            #expect(feature.effectiveBindings(for: "save") == [binding])
            #expect(feature.effectiveBindings(for: "toggle-project").isEmpty)
            #expect(feature.displayText(for: "toggle-project") == nil)
            #expect(feature.primaryKeyPress(for: "toggle-project") == nil)
            #expect(feature.registrations.first { $0.commandID == "toggle-project" }?.bindings == [])
            #expect(feature.conflicts(for: "toggle-project").first?.commandIDs == ["save"])
            #expect(feature.effectiveBindings(for: "toggle-debug").isEmpty)
            #expect(feature.conflicts(for: "toggle-debug").isEmpty)
        }
        #expect(settings.keyboardShortcutOverrides == ["save": [binding], "toggle-debug": []])
    }

    @Test
    func ambiguousLegacyOverridesKeepIntentButNeitherOwnsTheConflictingKey() throws {
        let settings = AppSettings(store: KeyboardShortcutTestStore())
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let ambiguous = KeyboardShortcutBinding.keyPress(key: "1", modifiers: [.command])
        let other = KeyboardShortcutBinding.keyPress(key: "k", modifiers: [.command, .option])
        settings.setKeyboardShortcutOverrides(["save": [ambiguous, other], "run": [ambiguous]])

        #expect(feature.effectiveBindings(for: "save") == [other])
        #expect(feature.effectiveBindings(for: "run").isEmpty)
        #expect(feature.effectiveBindings(for: "toggle-project").isEmpty)
        #expect(feature.configuredBindings(for: "save") == [ambiguous, other])
        #expect(feature.conflicts(for: "save").first?.commandIDs == ["run"])
        #expect(feature.conflicts(for: "run").first?.commandIDs == ["save"])
        #expect(feature.conflictingCommand(for: [ambiguous], excluding: "debug")?.id == "save")

        // A non-conflicting binding can be removed without destroying legacy intent.
        try feature.replaceBindings(for: "save", with: [ambiguous])
        try feature.replaceBindings(for: "run", with: [])
        #expect(feature.effectiveBindings(for: "save") == [ambiguous])
        #expect(feature.conflicts(for: "save").isEmpty)
        #expect(settings.keyboardShortcutOverrides["run"] == [])
    }

    @Test
    func resettingToolDefaultKeepsItsExplicitOwnerAndReportsTheBlockedDefault() throws {
        let settings = AppSettings(store: KeyboardShortcutTestStore())
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let binding = KeyboardShortcutBinding.keyPress(key: "1", modifiers: [.command])
        settings.setKeyboardShortcutOverrides(["save": [binding], "toggle-project": []])
        feature.resetCommand("toggle-project")
        #expect(!feature.isCustomized("toggle-project"))
        #expect(feature.effectiveBindings(for: "toggle-project").isEmpty)
        #expect(feature.conflicts(for: "toggle-project").first?.commandIDs == ["save"])
        #expect(settings.keyboardShortcutOverrides == ["save": [binding]])
        feature.resetAll()
        #expect(feature.effectiveBindings(for: "toggle-project") == [binding])
        #expect(feature.resolution.conflicts.isEmpty)
    }

    @Test
    func addingShortcutCannotPromoteABlockedDefaultAndDisableItsExistingOwner() throws {
        let settings = AppSettings(store: KeyboardShortcutTestStore())
        let feature = KeyboardShortcutFeatureModel(settings: settings)
        let blocked = KeyboardShortcutBinding.keyPress(key: "1", modifiers: [.command])
        let added = KeyboardShortcutBinding.keyPress(key: "2", modifiers: [.command])
        settings.setKeyboardShortcutOverrides(["save": [blocked]])
        #expect(throws: KeyboardShortcutUpdateError.conflict(commandID: "save")) {
            try feature.replaceBindings(for: "toggle-project", with: [blocked, added])
        }
        #expect(feature.effectiveBindings(for: "save") == [blocked])
        #expect(settings.keyboardShortcutOverrides["toggle-project"] == nil)
        try feature.replaceBindings(for: "toggle-project", with: [added])
        #expect(feature.effectiveBindings(for: "save") == [blocked])
        #expect(feature.effectiveBindings(for: "toggle-project") == [added])
    }

    @Test
    func toolWindowDefaultsMatchTheirMenuAndInputRegistrations() {
        let feature = KeyboardShortcutFeatureModel(settings: AppSettings(store: KeyboardShortcutTestStore()))
        let expected: [(String, KeyboardShortcutBinding)] = [
            ("toggle-project", .keyPress(key: "1", modifiers: [.command])),
            ("toggle-commit", .keyPress(key: "0", modifiers: [.command])),
            ("toggle-find", .keyPress(key: "3", modifiers: [.command])),
            ("toggle-run", .keyPress(key: "4", modifiers: [.command])),
            ("toggle-debug", .keyPress(key: "5", modifiers: [.command])),
            ("toggle-problems", .keyPress(key: "6", modifiers: [.command])),
            ("toggle-git-log", .keyPress(key: "9", modifiers: [.command])),
            ("toggle-terminal", .keyPress(key: "f12", modifiers: [.option]))
        ]
        for (id, binding) in expected {
            #expect(feature.primaryKeyPress(for: id) == binding)
            #expect(feature.registrations.first { $0.commandID == id }?.bindings == [binding])
            #expect(feature.displayText(for: id) == binding.displayText)
            #expect(ProjectMenuCommand.allCases.filter { $0.shortcutID == id }.count == 1)
        }
        #expect(feature.effectiveBindings(for: "toggle-tests").isEmpty)
        #expect(feature.primaryKeyPress(for: "search-in-project") == .keyPress(key: "f", modifiers: [.shift, .command]))
    }
}

private final class KeyboardShortcutTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
