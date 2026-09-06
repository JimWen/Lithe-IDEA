import Combine
import Foundation

/// Owns terminal sessions while the platform adapter owns the PTY and surface.
@MainActor
public final class TerminalFeatureModel: ObservableObject {
    @Published public private(set) var terminalSessions: [TerminalSession] = []
    @Published public private(set) var activeTerminalSessionID: UUID?
    @Published public private(set) var displayDiagnostics: [String] = []
    public private(set) var displayConfiguration = TerminalDisplayConfiguration()

    private let terminalFactory: () -> any TerminalTransport
    private let shellDiscovery: () -> [String]

    public init(
        terminalFactory: @escaping () -> any TerminalTransport,
        shellDiscovery: @escaping () -> [String] = { [] }
    ) {
        self.terminalFactory = terminalFactory
        self.shellDiscovery = shellDiscovery
    }

    public var availableShells: [String] { shellDiscovery() }

    public func applyDisplayConfiguration(_ configuration: TerminalDisplayConfiguration) {
        displayConfiguration = configuration
        terminalSessions.forEach { $0.applyDisplayConfiguration(configuration) }
        updateDisplayDiagnostics()
    }

    private func makeSession() -> TerminalSession {
        let session = TerminalSession(transport: terminalFactory())
        session.applyDisplayConfiguration(displayConfiguration)
        return session
    }

    private func updateDisplayDiagnostics() {
        let diagnostics = Array(Set(terminalSessions.flatMap(\.displayDiagnostics))).sorted()
        if diagnostics != displayDiagnostics { displayDiagnostics = diagnostics }
    }

    public var activeTerminalSession: TerminalSession? {
        guard let activeTerminalSessionID else { return terminalSessions.first }
        return terminalSessions.first { $0.id == activeTerminalSessionID }
    }

    public func terminalTitle(for session: TerminalSession) -> String {
        if session.isManagedProcess, let processTitle = session.processTitle, !processTitle.isEmpty {
            return processTitle
        }
        guard let index = terminalSessions.firstIndex(where: { $0.id == session.id }) else { return "Local" }
        return index == 0 ? "Local" : "Local (\(index + 1))"
    }

    @discardableResult
    public func createSession(in workspaceURL: URL, shellPath: String? = nil) -> TerminalSession {
        let session = makeSession()
        session.start(in: workspaceURL, shellPath: shellPath)
        terminalSessions.append(session)
        updateDisplayDiagnostics()
        activeTerminalSessionID = session.id
        return session
    }

    @discardableResult
    public func createSession(configuration: TerminalShellConfiguration, context: TerminalLaunchContext) -> TerminalSession {
        let session = makeSession()
        session.start(configuration: configuration, context: context)
        terminalSessions.append(session)
        updateDisplayDiagnostics()
        activeTerminalSessionID = session.id
        return session
    }

    @discardableResult
    public func createProcessSession(
        _ launch: TerminalProcessLaunch,
        onOutput: ((String) -> Void)? = nil
    ) throws -> (session: TerminalSession, processID: Int32) {
        let session = makeSession()
        session.onOutput = onOutput
        let processID = try session.startProcess(launch)
        terminalSessions.append(session)
        updateDisplayDiagnostics()
        activeTerminalSessionID = session.id
        return (session, processID)
    }

    @discardableResult
    public func selectSession(_ session: TerminalSession) -> Bool {
        guard terminalSessions.contains(where: { $0.id == session.id }) else { return false }
        activeTerminalSessionID = session.id
        return true
    }

    public func closeSession(_ session: TerminalSession) {
        guard let index = terminalSessions.firstIndex(where: { $0.id == session.id }) else { return }
        let wasActive = activeTerminalSessionID == session.id
        let replacement = terminalSessions.dropFirst(index + 1).first
            ?? (index > 0 ? terminalSessions[index - 1] : nil)
        session.stop()
        terminalSessions.remove(at: index)
        updateDisplayDiagnostics()
        if wasActive { activeTerminalSessionID = replacement?.id }
        if terminalSessions.isEmpty { activeTerminalSessionID = nil }
    }

    public func restartActiveSession() { activeTerminalSession?.restart() }
    public func restartActiveSession(using shellPath: String) { activeTerminalSession?.restart(using: shellPath) }

    /// Sends UTF-8 input to a specific terminal session when its PTY is live.
    /// The session ID keeps callers from accidentally writing to whichever
    /// terminal happens to be selected in the UI.
    @discardableResult
    public func sendInput(_ input: String, to sessionID: UUID) -> Bool {
        guard let session = terminalSessions.first(where: { $0.id == sessionID }),
              session.isRunning,
              session.isReady else { return false }
        session.sendInput(input)
        return true
    }

    public func stopAllSessions() {
        terminalSessions.forEach { $0.stop() }
        terminalSessions.removeAll()
        updateDisplayDiagnostics()
        activeTerminalSessionID = nil
    }
}
