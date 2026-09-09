import Combine
import Foundation

@MainActor
public final class TerminalSession: ObservableObject, Identifiable {
    public let id = UUID()
    @Published public private(set) var isRunning = false
    @Published public private(set) var isReady = false
    @Published public private(set) var isManagedProcess = false
    @Published public private(set) var launchError: String?
    @Published public private(set) var shellName = "Shell"
    @Published public private(set) var processTitle: String?
    @Published public private(set) var currentDirectory: URL?
    @Published public private(set) var lastExitCode: Int32?
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var endedAt: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var displayDiagnostics: [String] = []
    @Published public private(set) var virtualEnvironmentState: TerminalVirtualEnvironmentState = .inactive
    public var onLink: ((String, [String: String]) -> Void)?
    /// Receives decoded child-process output without taking ownership of the
    /// terminal surface.
    public var onOutput: ((String) -> Void)?

    private let transport: any TerminalTransport
    private var selectedShellPath: String?
    private var shellRequest: (configuration: TerminalShellConfiguration, context: TerminalLaunchContext)?
    private var shellLaunch: TerminalShellLaunch?
    private var launchGeneration = UUID()

    public init(transport: any TerminalTransport) {
        self.transport = transport
        transport.onTermination = { [weak self] exitCode in
            guard let self else { return }
            isRunning = false; isReady = false; lastExitCode = exitCode; endedAt = Date()
            if !isManagedProcess, exitCode != 0 {
                // exec failure and a shell that exits itself can both return
                // 127. Report the observed result without inventing exec errno.
                lastError = exitCode.map { "The terminal exited with code \($0). Check the shell program and arguments." }
                    ?? "The terminal process ended unexpectedly."
            }
        }
        transport.onOutput = { [weak self] data in
            guard let self, !data.isEmpty else { return }
            self.onOutput?(String(decoding: data, as: UTF8.self))
        }
        transport.onTitle = { [weak self] title in
            let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.processTitle = value.isEmpty ? nil : value
        }
        transport.onDirectoryUpdate = { [weak self] in self?.updateCurrentDirectory($0) }
        transport.onLink = { [weak self] link, params in self?.onLink?(link, params) }
        transport.onVirtualEnvironmentState = { [weak self] in self?.virtualEnvironmentState = $0 }
    }

    public var nativeView: AnyObject { transport.nativeView }

    public func applyDisplayConfiguration(_ configuration: TerminalDisplayConfiguration) {
        let diagnostics = transport.applyDisplayConfiguration(configuration)
        if displayDiagnostics != diagnostics { displayDiagnostics = diagnostics }
    }
    public var displayTitle: String { processTitle?.isEmpty == false ? processTitle! : shellName }
    public var displayDirectory: String? { currentDirectory?.lastPathComponent.nonEmpty }

    public func elapsedDescription(at date: Date = Date()) -> String? {
        guard let startedAt else { return nil }
        let seconds = Int(max(0, (endedAt ?? date).timeIntervalSince(startedAt)).rounded(.down))
        let hours = seconds / 3_600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, (seconds % 3_600) / 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    public func start(in workspaceURL: URL, shellPath: String? = nil) {
        var configuration = TerminalShellConfiguration()
        if let shell = shellPath ?? selectedShellPath {
            configuration.shell = .custom
            configuration.customProgram = shell
        }
        start(configuration: configuration, context: TerminalLaunchContext(projectURL: workspaceURL))
    }

    public func start(configuration: TerminalShellConfiguration, context: TerminalLaunchContext) {
        stop()
        isManagedProcess = false
        shellRequest = (configuration, context)
        shellLaunch = nil
        lastError = nil
        do {
            let launch = try transport.prepareShellLaunch(configuration, context: context)
            shellLaunch = launch
            startShell(launch)
        } catch {
            recordLaunchFailure(error)
        }
    }

    private func startShell(_ launch: TerminalShellLaunch) {
        stop()
        isManagedProcess = false
        currentDirectory = URL(fileURLWithPath: launch.process.workingDirectory, isDirectory: true)
        selectedShellPath = launch.process.executablePath
        shellName = URL(fileURLWithPath: launch.process.executablePath).lastPathComponent
        processTitle = nil; lastExitCode = nil; lastError = nil; startedAt = Date(); endedAt = nil
        let generation = launchGeneration
        transport.startShell(launch) { [weak self] resolved, result in
            guard let self, self.launchGeneration == generation else { return }
            self.shellLaunch = resolved
            switch result {
            case .success:
                self.isRunning = self.transport.isRunning; self.isReady = self.isRunning
            case .failure(let error): self.recordLaunchFailure(error)
            }
        }
    }

    private func recordLaunchFailure(_ error: any Error) {
        isRunning = false; isReady = false; lastExitCode = nil; startedAt = nil; endedAt = Date()
        virtualEnvironmentState = .inactive
        lastError = error.localizedDescription
    }

    @discardableResult
    public func startProcess(_ launch: TerminalProcessLaunch) throws -> Int32 {
        stop()
        let workingDirectory = URL(
            fileURLWithPath: launch.workingDirectory,
            isDirectory: true
        ).standardizedFileURL
        selectedShellPath = nil
        shellRequest = nil
        shellLaunch = nil
        lastError = nil
        isManagedProcess = true
        launchError = nil
        currentDirectory = workingDirectory
        processTitle = launch.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if processTitle?.isEmpty == true { processTitle = nil }
        lastExitCode = nil
        startedAt = Date()
        endedAt = nil
        shellName = URL(fileURLWithPath: launch.executablePath).lastPathComponent

        do {
            let processID = try transport.startProcess(
                launch,
                environment: terminalEnvironment(applying: launch.environmentChanges)
            )
            isRunning = transport.isRunning
            isReady = isRunning
            return processID
        } catch {
            recordLaunchFailure(error)
            throw error
        }
    }

    public func restart() {
        guard !isManagedProcess else { return }
        if let shellLaunch { startShell(shellLaunch) }
        else if let request = shellRequest { start(configuration: request.configuration, context: request.context) }
    }
    public func restart(using shellPath: String) {
        guard !isManagedProcess else { return }
        if let previous = shellLaunch {
            stop()
            do {
                let executable = try transport.resolveExecutablePath(shellPath, workingDirectory: previous.process.workingDirectory, environment: previous.environment)
                let launch = TerminalShellLaunch(
                    process: TerminalProcessLaunch(
                        title: nil, executablePath: executable, arguments: previous.process.arguments,
                        workingDirectory: previous.process.workingDirectory
                    ), environment: previous.environment, virtualEnvironment: previous.virtualEnvironment
                )
                shellLaunch = launch
                startShell(launch)
            } catch { recordLaunchFailure(error) }
        } else if let request = shellRequest {
            var configuration = request.configuration
            configuration.shell = .custom
            configuration.customProgram = shellPath
            start(configuration: configuration, context: request.context)
        }
    }
    public func send(_ command: String) { sendInput(command + "\n") }
    public func sendInput(_ input: String) {
        guard isRunning, isReady, let data = input.data(using: .utf8) else { return }
        try? transport.send(data)
    }
    public func interrupt() { if isRunning { try? transport.interrupt() } }
    public func clear() { transport.clear() }
    public func focus() { transport.focus() }
    public func stop() {
        launchGeneration = UUID()
        transport.stop(); isRunning = false; isReady = false
        virtualEnvironmentState = .inactive
        if startedAt != nil { endedAt = Date() }
    }

    private func updateCurrentDirectory(_ rawValue: String?) {
        guard let rawValue, !rawValue.isEmpty else { return }
        if let url = URL(string: rawValue), url.isFileURL { currentDirectory = url.standardizedFileURL }
        else if rawValue.hasPrefix("/") { currentDirectory = URL(fileURLWithPath: rawValue).standardizedFileURL }
    }

    private func terminalEnvironment(
        applying changes: [TerminalEnvironmentChange] = []
    ) -> [String: String] {
        var environment = transport.defaultEnvironment()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Lithe"
        for change in changes {
            if let value = change.value {
                environment[change.name] = value
            } else {
                environment[change.name] = nil
            }
        }
        return environment
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
