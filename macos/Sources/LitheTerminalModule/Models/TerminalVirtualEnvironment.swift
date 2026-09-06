import Foundation

/// Memory-only discovery decision. Restart retains both positive and negative
/// results; only a newly created terminal searches the configured candidates.
public enum TerminalVirtualEnvironmentPlan: Equatable, Sendable {
    case disabled
    case preserveExisting
    case discover([String])
    case selected(String)
    case notFound
    case unknown
}

public enum TerminalVirtualEnvironmentState: Equatable, Sendable {
    case inactive
    case detecting
    case activating(String)
    case activated(String)
    case deactivated
    case skipped(TerminalVirtualEnvironmentSkip)
    case unconfirmed(String)
}

public enum TerminalVirtualEnvironmentSkip: Equatable, Sendable {
    case existingEnvironment, unsupportedShell, unavailable, discoveryUnavailable
    case integrationUnavailable, shellConfiguration, unsupportedPath

    public var message: String {
        switch self {
        case .existingEnvironment: "Automatic activation skipped: using your shell environment."
        case .unsupportedShell: "Automatic activation is unavailable for this shell or its arguments."
        case .unavailable: "The selected virtual environment is unavailable. Restart to retry it."
        case .discoveryUnavailable: "Virtual environment detection was unavailable. Open a new terminal to retry."
        case .integrationUnavailable: "Terminal integration resources are unavailable."
        case .shellConfiguration: "Automatic activation skipped to preserve your shell configuration."
        case .unsupportedPath: "Automatic activation requires an environment path without a colon."
        }
    }
}
