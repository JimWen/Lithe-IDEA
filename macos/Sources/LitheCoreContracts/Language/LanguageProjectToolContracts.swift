import Foundation
import LitheModuleAPI

public extension PluginHostServiceID {
    static let languageProjectTools = PluginHostServiceID("dev.lithe.host.language-project-tools.v1")
}

/// A resolved native command. Environment is complete, never implicitly inherited.
public struct LanguageProjectToolRequest: Sendable {
    public let operationID: String
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String
    public let environment: [String: String]
    public let timeoutMilliseconds: Int
    public let stdoutByteLimit: Int
    public let stderrByteLimit: Int

    public init(
        operationID: String, executablePath: String, arguments: [String] = [],
        workingDirectory: String, environment: [String: String],
        timeoutMilliseconds: Int = 30_000,
        stdoutByteLimit: Int = 16 * 1_024 * 1_024, stderrByteLimit: Int = 1_024 * 1_024
    ) {
        self.operationID = operationID
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeoutMilliseconds = timeoutMilliseconds
        self.stdoutByteLimit = stdoutByteLimit
        self.stderrByteLimit = stderrByteLimit
    }
}

public enum LanguageProjectToolState: String, Sendable {
    case idle, starting, running, draining, stopping, cleanupFailed, finished

    public var isActive: Bool {
        switch self {
        case .idle, .finished: false
        default: true
        }
    }
}

public enum LanguageProjectToolStatus: String, Sendable {
    case succeeded, processFailed, startFailed, cancelled, timedOut
    case outputLimit, readFailed, cleanupFailed, invalidRequest, capacityUnavailable, unavailable
}

public struct LanguageProjectToolResult: Sendable {
    public let operationID: String
    public let status: LanguageProjectToolStatus
    /// The original failure is preserved if cleanup itself subsequently fails.
    public let cause: LanguageProjectToolStatus?
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32?
    public let stdoutReachedEOF: Bool
    public let stderrReachedEOF: Bool
    /// Includes native launch completion, root/group cleanup, and reader closure.
    public let cleanupConfirmed: Bool
    public let message: String?

    public init(
        operationID: String, status: LanguageProjectToolStatus,
        cause: LanguageProjectToolStatus? = nil, stdout: Data = Data(), stderr: Data = Data(),
        exitCode: Int32? = nil, stdoutReachedEOF: Bool = false, stderrReachedEOF: Bool = false,
        cleanupConfirmed: Bool, message: String? = nil
    ) {
        self.operationID = operationID
        self.status = status
        self.cause = cause
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.stdoutReachedEOF = stdoutReachedEOF
        self.stderrReachedEOF = stderrReachedEOF
        self.cleanupConfirmed = cleanupConfirmed
        self.message = message
    }
}

@MainActor
public protocol LanguageProjectToolSession: AnyObject {
    var state: LanguageProjectToolState { get }
    var onStateChange: (@MainActor @Sendable (LanguageProjectToolState) -> Void)? { get set }
    /// Single use. A failed cleanup may return, but the session remains active.
    func capture(_ request: LanguageProjectToolRequest) async -> LanguageProjectToolResult
    func stopAndWait() async -> Bool
}

@MainActor
public protocol LanguageProjectToolHostProviding: AnyObject {
    func makeProjectToolSession(ownerModuleID: ModuleID) -> any LanguageProjectToolSession
}

@MainActor
public protocol LanguageProjectToolsProviding: AnyObject {
    var languageID: String { get }
    func makeProjectToolSession() -> any LanguageProjectToolSession
}

public enum LanguageProjectToolHostError: Error {
    case missingHost(languageID: String)
}
