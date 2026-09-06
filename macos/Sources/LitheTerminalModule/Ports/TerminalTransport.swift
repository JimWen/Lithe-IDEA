import Foundation

public struct TerminalEnvironmentChange: Codable, Equatable, Sendable {
    public var name: String
    public var value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

/// Direct process launch for a PTY-backed terminal. Arguments stay separated
/// so callers never need to build a shell command string.
public struct TerminalProcessLaunch: Equatable, Sendable {
    public let title: String?
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String
    public let environmentChanges: [TerminalEnvironmentChange]

    public init(
        title: String?,
        executablePath: String,
        arguments: [String],
        workingDirectory: String,
        environmentChanges: [TerminalEnvironmentChange] = []
    ) {
        self.title = title
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentChanges = environmentChanges
    }
}

/// Platform terminal runtime injected by the native composition root.
@MainActor
public protocol TerminalTransport: AnyObject {
    var isRunning: Bool { get }
    var processID: Int32? { get }
    var shellName: String { get }
    var nativeView: AnyObject { get }
    var onTermination: ((Int32?) -> Void)? { get set }
    /// Raw bytes received from the child process before terminal emulation.
    /// Hosts may mirror this output into another product surface.
    var onOutput: ((Data) -> Void)? { get set }
    var onTitle: ((String) -> Void)? { get set }
    var onDirectoryUpdate: ((String?) -> Void)? { get set }
    var onLink: ((String, [String: String]) -> Void)? { get set }
    var onVirtualEnvironmentState: ((TerminalVirtualEnvironmentState) -> Void)? { get set }

    /// Returns display diagnostics without interrupting the running process.
    func applyDisplayConfiguration(_ configuration: TerminalDisplayConfiguration) -> [String]
    func defaultShellPath() -> String
    func defaultEnvironment() -> [String: String]
    func prepareShellLaunch(_ configuration: TerminalShellConfiguration, context: TerminalLaunchContext) throws -> TerminalShellLaunch
    func resolveExecutablePath(_ executablePath: String, workingDirectory: String, environment: [String: String]) throws -> String
    func start(workingDirectory: String, shellPath: String, environment: [String: String]) throws
    func startProcess(_ launch: TerminalProcessLaunch, environment: [String: String]) throws -> Int32
    /// Native discovery may complete asynchronously. stop() cancels preparation;
    /// completion returns the frozen selection even if process creation fails.
    func startShell(_ launch: TerminalShellLaunch,
                    completion: @escaping @MainActor (TerminalShellLaunch, Result<Int32, any Error>) -> Void)
    func send(_ input: Data) throws
    func interrupt() throws
    func focus()
    func clear()
    func stop()
}

public extension TerminalTransport {
    func startShell(_ launch: TerminalShellLaunch,
                    completion: @escaping @MainActor (TerminalShellLaunch, Result<Int32, any Error>) -> Void) {
        let resolved: TerminalShellLaunch
        if case .discover = launch.virtualEnvironment { resolved = launch.selectingVirtualEnvironment(.unknown) }
        else { resolved = launch }
        completion(resolved, Result { try startProcess(launch.process, environment: launch.environment) })
    }
}
