import Foundation

/// Resolves persisted intent once, before menus and input monitors read it.
/// Explicit bindings outrank defaults; ambiguous explicit bindings run neither
/// command. The original configuration remains available for conflict repair.
struct KeyboardShortcutResolution: Equatable {
    struct Conflict: Equatable, Identifiable {
        let binding: KeyboardShortcutBinding
        let commandIDs: [String]
        var id: KeyboardShortcutBinding { binding }
    }

    let configured: [String: [KeyboardShortcutBinding]]
    let effective: [String: [KeyboardShortcutBinding]]
    let conflicts: [String: [Conflict]]

    init(commands: [LitheCommandDefinition], overrides: [String: [KeyboardShortcutBinding]]) {
        let configured = Dictionary(uniqueKeysWithValues: commands.map {
            ($0.id, overrides[$0.id] ?? $0.defaultBindings)
        })
        var owners: [KeyboardShortcutBinding: [String]] = [:]
        for command in commands {
            for binding in configured[command.id] ?? [] {
                owners[binding, default: []].append(command.id)
            }
        }
        var effective: [String: [KeyboardShortcutBinding]] = [:]
        var conflicts: [String: [Conflict]] = [:]
        for command in commands {
            for binding in configured[command.id] ?? [] {
                let candidates = owners[binding] ?? []
                let explicit = candidates.filter { overrides[$0] != nil }
                let eligible = explicit.isEmpty ? candidates : explicit
                if eligible.count == 1, eligible.first == command.id {
                    effective[command.id, default: []].append(binding)
                } else {
                    conflicts[command.id, default: []].append(Conflict(
                        binding: binding,
                        commandIDs: eligible.filter { $0 != command.id }
                    ))
                }
            }
        }
        self.configured = configured
        self.effective = effective
        self.conflicts = conflicts
    }
}
