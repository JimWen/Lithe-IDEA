import Combine
import Foundation

enum KeyboardShortcutUpdateError: Error, Equatable {
    case unknownCommand(String)
    case invalidBinding
    case duplicateBinding
    case conflict(commandID: String)
}

struct KeyboardShortcutCommandSection: Identifiable, Equatable, Sendable {
    let group: LitheActionGroup
    let commands: [LitheCommandDefinition]

    var id: LitheActionGroup { group }
}

@MainActor
final class KeyboardShortcutFeatureModel: ObservableObject {
    @Published private(set) var recordingCommandID: String?
    @Published private(set) var resolution: KeyboardShortcutResolution

    private let settings: AppSettings
    private var settingsObservation: AnyCancellable?

    init(settings: AppSettings) {
        self.settings = settings
        resolution = KeyboardShortcutResolution(
            commands: LitheCommandCatalog.commands, overrides: settings.keyboardShortcutOverrides
        )
        settingsObservation = settings.$keyboardShortcutOverrides
            .dropFirst()
            .sink { [weak self] overrides in
                // Published sends before AppSettings stores the value. Resolve
                // the incoming payload, never reread its old stored property.
                self?.resolution = KeyboardShortcutResolution(
                    commands: LitheCommandCatalog.commands, overrides: overrides
                )
            }
    }

    var commands: [LitheCommandDefinition] {
        LitheCommandCatalog.commands
    }

    var registrations: [KeyboardShortcutRegistration] {
        commands.map { command in
            KeyboardShortcutRegistration(
                commandID: command.id,
                bindings: effectiveBindings(for: command.id)
            )
        }
    }

    func filteredCommands(
        query: String,
        additionalSearchText: (LitheCommandDefinition) -> String = { _ in "" }
    ) -> [LitheCommandDefinition] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return commands }
        return commands.filter { command in
            let searchText = [
                command.title,
                command.subtitle,
                command.id,
                command.group.rawValue,
                displayText(for: command.id) ?? "",
                additionalSearchText(command)
            ].joined(separator: " ").lowercased()
            return searchText.contains(normalizedQuery)
        }
    }

    func groupedCommands(
        query: String,
        additionalSearchText: (LitheCommandDefinition) -> String = { _ in "" }
    ) -> [KeyboardShortcutCommandSection] {
        let filtered = filteredCommands(query: query, additionalSearchText: additionalSearchText)
        return LitheActionGroup.allCases.compactMap { group in
            let groupCommands = filtered.filter { $0.group == group }
            guard !groupCommands.isEmpty else { return nil }
            return KeyboardShortcutCommandSection(group: group, commands: groupCommands)
        }
    }

    func effectiveBindings(for commandID: String) -> [KeyboardShortcutBinding] {
        resolution.effective[commandID] ?? []
    }

    func configuredBindings(for commandID: String) -> [KeyboardShortcutBinding] {
        resolution.configured[commandID] ?? []
    }

    func conflicts(for commandID: String) -> [KeyboardShortcutResolution.Conflict] {
        resolution.conflicts[commandID] ?? []
    }

    func displayText(for commandID: String) -> String? {
        let values = effectiveBindings(for: commandID).map(\.displayText)
        return values.isEmpty ? nil : values.joined(separator: "  ")
    }

    func primaryKeyPress(for commandID: String) -> KeyboardShortcutBinding? {
        effectiveBindings(for: commandID).first { binding in
            if case .keyPress = binding { return true }
            return false
        }
    }

    func replaceBindings(
        for commandID: String,
        with bindings: [KeyboardShortcutBinding]
    ) throws {
        guard LitheCommandCatalog.command(id: commandID) != nil else {
            throw KeyboardShortcutUpdateError.unknownCommand(commandID)
        }
        guard bindings.allSatisfy(\.isAssignable) else {
            throw KeyboardShortcutUpdateError.invalidBinding
        }
        guard Set(bindings).count == bindings.count else {
            throw KeyboardShortcutUpdateError.duplicateBinding
        }
        // Removing or keeping an already-conflicting legacy binding must not
        // make the configuration impossible to repair one binding at a time.
        let explicit = settings.keyboardShortcutOverrides[commandID] ?? []
        let introduced = bindings.filter { !explicit.contains($0) }
        if let owner = conflictingCommand(for: introduced, excluding: commandID) {
            throw KeyboardShortcutUpdateError.conflict(commandID: owner.id)
        }

        var overrides = settings.keyboardShortcutOverrides
        overrides[commandID] = bindings
        settings.setKeyboardShortcutOverrides(overrides)
    }

    func resetCommand(_ commandID: String) {
        guard settings.keyboardShortcutOverrides[commandID] != nil else { return }
        var overrides = settings.keyboardShortcutOverrides
        overrides[commandID] = nil
        settings.setKeyboardShortcutOverrides(overrides)
    }

    func resetAll() {
        guard !settings.keyboardShortcutOverrides.isEmpty else { return }
        settings.setKeyboardShortcutOverrides([:])
    }

    func isCustomized(_ commandID: String) -> Bool {
        settings.keyboardShortcutOverrides[commandID] != nil
    }

    func beginRecording(commandID: String) {
        recordingCommandID = commandID
    }

    func endRecording(commandID: String? = nil) {
        guard commandID == nil || recordingCommandID == commandID else { return }
        recordingCommandID = nil
    }

    func conflictingCommand(
        for bindings: [KeyboardShortcutBinding],
        excluding excludedCommandID: String
    ) -> LitheCommandDefinition? {
        let candidates = Set(bindings)
        guard !candidates.isEmpty else { return nil }
        return commands.first { command in
            command.id != excludedCommandID
                && !candidates.isDisjoint(with: configuredBindings(for: command.id))
        }
    }
}
