import SwiftUI

private struct CommandInputEnvironmentKey: EnvironmentKey {
    static let defaultValue: CommandEnvironmentFeatureModel? = nil
}

extension EnvironmentValues {
    var commandInputEnvironment: CommandEnvironmentFeatureModel? {
        get { self[CommandInputEnvironmentKey.self] }
        set { self[CommandInputEnvironmentKey.self] = newValue }
    }
}
