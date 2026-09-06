import Darwin
import Foundation

/// Launches a subprocess in a dedicated process group and reaps its root PID.
///
/// `Foundation.Process` cannot assign a process group before `exec`, leaving a
/// race where a short-lived shell can orphan descendants before cleanup gains
/// ownership. This adapter uses `posix_spawn` so group membership is atomic with
/// launch and remains available after the group leader exits.
final class MacManagedProcess: @unchecked Sendable {
    typealias TerminationHandler = @Sendable (MacManagedProcess) -> Void
    typealias GroupFactory = @Sendable (pid_t) -> any MacProcessGroupControlling

    enum CleanupState: Equatable { case idle, cleaning, failed, complete }

    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL?
    let environment: [String: String]?
    let standardInput: FileHandle
    let standardOutput: FileHandle
    let standardError: FileHandle

    private let lock = NSLock()
    private let rootReapCompletion = DispatchGroup()
    private let terminationQueue = DispatchQueue(
        label: "dev.lithe.managed-process.termination",
        qos: .utility
    )
    private var source: DispatchSourceProcess?
    private var running = false
    private var status: Int32 = 0
    private var pid: pid_t = 0
    private var group: (any MacProcessGroupControlling)?
    private let groupFactory: GroupFactory
    private var rootReaped = false
    private var rootExitPublished = false
    private var cleanupAttempt: MacProcessCleanupAttempt?
    private var firstCleanupAttempt: MacProcessCleanupAttempt?
    private var cleanupOutcome: Bool?
    private var exitCleanupOutcome: Bool?
    private var handler: TerminationHandler?
    private var rootReapHandler: TerminationHandler?

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        standardInput: FileHandle,
        standardOutput: FileHandle,
        standardError: FileHandle,
        groupFactory: @escaping GroupFactory = { MacProcessGroup(processGroupID: $0) }
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.groupFactory = groupFactory
    }

    var processIdentifier: pid_t {
        lock.withLock { pid }
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    var isRootReaped: Bool { lock.withLock { rootReaped } }

    /// Unlike legacy isRunning, failure retains ownership after the root exits.
    var hasOwnedProcesses: Bool {
        lock.withLock { (pid > 0 && !rootReaped) || group != nil }
    }

    var cleanupState: CleanupState {
        lock.withLock {
            guard cleanupAttempt != nil else { return .idle }
            guard let cleanupOutcome else { return .cleaning }
            return cleanupOutcome ? .complete : .failed
        }
    }

    /// The immutable outcome attached to the single legacy root-exit callback,
    /// independent of a later explicit retry's current cleanupState.
    var rootExitCleanupSucceeded: Bool? { lock.withLock { exitCleanupOutcome } }

    var terminationStatus: Int32 {
        lock.withLock { status }
    }

    var terminationHandler: TerminationHandler? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    /// Native capture can begin draining immediately after waitpid, while
    /// legacy consumers keep their post-cleanup termination notification.
    var onRootReaped: TerminationHandler? {
        get { lock.withLock { rootReapHandler } }
        set { lock.withLock { rootReapHandler = newValue } }
    }

    func run(onLaunch: (pid_t) -> Void = { _ in }) throws {
        // This owner is single-use; a retained failed group must never be
        // overwritten by another launch on the same object.
        try lock.withLock {
            guard pid == 0 else { throw POSIXError(.EALREADY) }
            pid = -1
        }
        defer { lock.withLock { if pid == -1 { pid = 0 } } }
        let launchedPID = try Self.spawn(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: environment,
            standardInput: standardInput.fileDescriptor,
            standardOutput: standardOutput.fileDescriptor,
            standardError: standardError.fileDescriptor
        )
        rootReapCompletion.enter()
        let processGroup = groupFactory(launchedPID)
        let processSource = DispatchSource.makeProcessSource(
            identifier: launchedPID,
            eventMask: .exit,
            queue: terminationQueue
        )
        lock.withLock {
            pid = launchedPID
            group = processGroup
            source = processSource
            running = true
        }
        // The source deliberately retains this object until waitpid reaps the
        // child, even when a session releases its reference during stop().
        processSource.setEventHandler { [self] in
            reapRootProcess(processSource)
        }
        // Callers can publish the PID to their registry before an immediately
        // exiting child makes the termination callback observable.
        onLaunch(launchedPID)
        processSource.activate()
    }

    @discardableResult
    func terminate(
        gracePeriod: Duration = .milliseconds(200),
        forcedTerminationTimeout: Duration = .seconds(1)
    ) -> Task<Bool, Never>? {
        guard let attempt = requestCleanup(
            explicit: true, gracePeriod: Self.seconds(gracePeriod),
            forcedTerminationTimeout: Self.seconds(forcedTerminationTimeout)
        ) else { return nil }
        return Task { await attempt.value() }
    }

    @discardableResult
    func terminateAndWait(
        gracePeriod: TimeInterval = 0.2,
        forcedTerminationTimeout: TimeInterval = 1,
        waitTimeout: TimeInterval? = nil
    ) -> Bool {
        guard let attempt = requestCleanup(
            explicit: true, gracePeriod: gracePeriod,
            forcedTerminationTimeout: forcedTerminationTimeout
        ) else { return !hasOwnedProcesses }
        // A local timeout does not finish the physical attempt or permit an
        // overlapping retry. The independent worker keeps its fixed deadline.
        return attempt.wait(timeout: waitTimeout ?? (max(0, gracePeriod) + max(0, forcedTerminationTimeout) + 0.5))
    }

    private func reapRootProcess(_ processSource: DispatchSourceProcess) {
        let processID = processIdentifier
        lock.withLock { group }?.prepareForRootReap()
        var waitStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = Darwin.waitpid(processID, &waitStatus, 0)
        } while waitResult == -1 && errno == EINTR
        let waitError = errno

        let reapPublication = lock.withLock { () -> (TerminationHandler?, Bool) in
            status = waitResult == processID ? Self.exitCode(from: waitStatus) : 1
            let previouslyReaped = rootReaped
            rootReaped = waitResult == processID || (waitResult == -1 && waitError == ECHILD)
            source = nil
            return (rootReaped ? rootReapHandler : nil, rootReaped && !previouslyReaped)
        }
        if reapPublication.1 { rootReapCompletion.leave() }
        processSource.cancel()
        reapPublication.0?(self)
        // Reap before joining cleanup: otherwise a worker waiting for group
        // disappearance could wait on the unreaped root itself. Legacy running
        // and callback publication still wait for this attempt to finish.
        if let attempt = requestCleanup(explicit: false, gracePeriod: 0.2, forcedTerminationTimeout: 1) {
            attempt.observe { [self] result in publishRootExit(cleanupSucceeded: result) }
        } else {
            publishRootExit(cleanupSucceeded: !hasOwnedProcesses)
        }
    }

    private func publishRootExit(cleanupSucceeded: Bool) {
        let callback = lock.withLock { () -> TerminationHandler? in
            guard !rootExitPublished else { return nil }
            rootExitPublished = true
            exitCleanupOutcome = cleanupSucceeded
            running = false
            return handler
        }
        callback?(self)
    }

    private func requestCleanup(
        explicit: Bool, gracePeriod: TimeInterval, forcedTerminationTimeout: TimeInterval
    ) -> MacProcessCleanupAttempt? {
        lock.withLock {
            if !explicit, let firstCleanupAttempt { return firstCleanupAttempt }
            if let cleanupAttempt, cleanupOutcome == nil { return cleanupAttempt }
            guard let group else { return nil }
            let attempt = MacProcessCleanupAttempt()
            cleanupAttempt = attempt
            if firstCleanupAttempt == nil { firstCleanupAttempt = attempt }
            cleanupOutcome = nil
            // A native worker owns all blocking cleanup. Reaper and callers can
            // join it without occupying that worker or holding a state lock.
            DispatchQueue.global(qos: .utility).async { [self] in
                let groupStopped = group.terminateAndWait(
                    gracePeriod: gracePeriod, forcedTerminationTimeout: forcedTerminationTimeout
                )
                // Group disappearance can race the reaper's state publication.
                // Only this native worker joins the root latch, with a bounded
                // deadline; the reaper never waits on this worker to reap.
                let result = groupStopped
                    && rootReapCompletion.wait(timeout: .now() + .milliseconds(500)) == .success
                lock.withLock {
                    guard cleanupAttempt === attempt else { return }
                    cleanupOutcome = result
                    if result { self.group = nil }
                }
                attempt.complete(result)
            }
            return attempt
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }

    private static func spawn(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String]?,
        standardInput: Int32,
        standardOutput: Int32,
        standardError: Int32
    ) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        var fileActions: posix_spawn_file_actions_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        try check(posix_spawnattr_setflags(&attributes, flags))
        // A pgroup value of zero creates a new group whose ID is the child PID.
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        let resolvedStandardInput: Int32
        if standardInput >= 0 {
            resolvedStandardInput = standardInput
        } else {
            resolvedStandardInput = Darwin.open("/dev/null", O_RDONLY)
            guard resolvedStandardInput >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        defer {
            if resolvedStandardInput != standardInput {
                Darwin.close(resolvedStandardInput)
            }
        }
        try check(posix_spawn_file_actions_adddup2(
            &fileActions,
            resolvedStandardInput,
            STDIN_FILENO
        ))
        try check(posix_spawn_file_actions_adddup2(&fileActions, standardOutput, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&fileActions, standardError, STDERR_FILENO))
        if let currentDirectoryURL {
            try check(posix_spawn_file_actions_addchdir_np(&fileActions, currentDirectoryURL.path))
        }

        let argumentValues = [executableURL.path] + arguments
        let environmentValues = (environment ?? ProcessInfo.processInfo.environment)
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var launchedPID: pid_t = 0
        let spawnResult = try withCStringArray(argumentValues) { argumentPointers in
            try withCStringArray(environmentValues) { environmentPointers in
                posix_spawn(
                    &launchedPID,
                    executableURL.path,
                    &fileActions,
                    &attributes,
                    argumentPointers,
                    environmentPointers
                )
            }
        }
        try check(spawnResult)
        return launchedPID
    }

    private static func withCStringArray<ResultValue>(
        _ values: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> ResultValue
    ) throws -> ResultValue {
        var pointers = values.map { strdup($0) }
        guard pointers.allSatisfy({ $0 != nil }) else {
            pointers.forEach { free($0) }
            throw POSIXError(.ENOMEM)
        }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private static func check(_ result: Int32) throws {
        guard result != 0 else { return }
        throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let terminationSignal = waitStatus & 0x7f
        if terminationSignal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return terminationSignal
    }
}
