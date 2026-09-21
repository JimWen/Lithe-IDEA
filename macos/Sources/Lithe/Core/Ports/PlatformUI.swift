import Foundation

/// Small platform-facing UI capabilities used by application orchestration.
/// Implementations may use AppKit, Qt, or another native UI toolkit.
@MainActor
protocol PlatformUI: AnyObject {
    func activateApplication()
    func chooseDirectory(title: String, prompt: String) -> URL?
    func chooseFile(title: String, prompt: String) -> URL?
    func revealInFileBrowser(_ url: URL)
    func open(_ url: URL)
    /// Opens a URL in the system default web browser, regardless of its file association.
    func openInBrowser(_ url: URL)
    func copyToClipboard(_ value: String)
    func markdownImageFromClipboard() -> MarkdownImageSource?
    func presentCommandFailure(_ message: String)
}

extension PlatformUI {
    func activateApplication() {}
    func startAccessingProject(_ url: URL) -> Bool { false }
    func stopAccessingProject(_ url: URL) {}
}

protocol ShortcutDetector: AnyObject {
    func start()
    func stop()
    func update(registrations: [KeyboardShortcutRegistration])
    func setSuspended(_ suspended: Bool)
    func setCommandEligibility(
        _ permits: @escaping @MainActor (String) -> Bool,
        generation: @escaping @MainActor () -> Int
    )
}

extension ShortcutDetector {
    func setCommandEligibility(
        _ permits: @escaping @MainActor (String) -> Bool,
        generation: @escaping @MainActor () -> Int
    ) {}
}

@MainActor
protocol ShortcutDetectorFactory {
    func make(onCommand: @escaping @MainActor (String) -> Void) -> any ShortcutDetector
}
