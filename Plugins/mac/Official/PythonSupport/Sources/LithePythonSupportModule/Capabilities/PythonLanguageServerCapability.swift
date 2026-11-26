import Foundation
import LitheCoreContracts

@MainActor
public final class PythonLanguageServerCapability: NSObject,
    LanguageServerExtensionProviding,
    LanguageSyntaxExtensionProviding {
    public let configuration = LanguageServerExtensionConfiguration(
        languageID: pythonLanguageID,
        displayName: "Python",
        executableNames: ["basedpyright-langserver", "pyright-langserver"],
        arguments: ["--stdio"],
        languageIdentifier: "python"
    )
    public let syntaxProfile = LanguageSyntaxProfile.python
    public let lifecycle: any LanguageServerExtensionLifecycle

    init(lifecycle: any LanguageServerExtensionLifecycle) {
        self.lifecycle = lifecycle
    }
}

@MainActor
final class PythonLanguageServerLifecycle: LanguageServerExtensionLifecycle {
    private var running: @MainActor () -> Bool = { false }
    private var stopAction: @MainActor () -> Void = {}

    var isRunning: Bool { running() }

    func attach(
        isRunning: @escaping @MainActor () -> Bool,
        stop: @escaping @MainActor () -> Void
    ) {
        running = isRunning
        stopAction = stop
    }

    func stop() {
        stopAction()
    }
}
