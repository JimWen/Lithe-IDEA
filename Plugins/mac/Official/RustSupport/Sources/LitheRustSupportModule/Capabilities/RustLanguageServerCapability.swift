import Foundation
import LitheCoreContracts

@MainActor
public final class RustLanguageServerCapability: NSObject,
    LanguageServerExtensionProviding,
    LanguageSyntaxExtensionProviding {
    public let configuration = LanguageServerExtensionConfiguration(
        languageID: rustLanguageID,
        displayName: "Rust",
        executableNames: ["rust-analyzer"],
        validationArguments: ["--version"],
        languageIdentifier: "rust"
    )
    public let syntaxProfile = LanguageSyntaxProfile.rust
    public let lifecycle: any LanguageServerExtensionLifecycle

    init(lifecycle: any LanguageServerExtensionLifecycle) {
        self.lifecycle = lifecycle
    }
}

@MainActor
final class RustLanguageServerLifecycle: LanguageServerExtensionLifecycle {
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
