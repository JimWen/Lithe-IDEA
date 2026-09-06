import Darwin
import Foundation
import Testing
@testable import Lithe

@Suite("Managed process cleanup ownership")
struct MacManagedProcessCleanupTests {
    @Test
    func rootReapsBeforeHeldCleanupButLegacyRunningWaits() async throws {
        let step = ControlledCleanupStep(result: true)
        let group = ControlledProcessGroup(steps: [step])
        let process = makeProcess(group)
        let terminated = TestGate()
        process.terminationHandler = { _ in terminated.open() }
        defer { step.release.open() }
        try process.run()
        #expect(await step.entered.waitUntilOpen())
        #expect(process.isRootReaped)
        #expect(process.isRunning)
        #expect(process.hasOwnedProcesses)
        #expect(process.cleanupState == .cleaning)
        #expect(!terminated.isOpen)
        var status: Int32 = 0
        #expect(Darwin.waitpid(process.processIdentifier, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
        step.release.open()
        #expect(await terminated.waitUntilOpen())
        #expect(!process.isRunning)
        #expect(!process.hasOwnedProcesses)
        #expect(process.cleanupState == .complete)
        #expect(!step.timedOut)
    }

    @Test
    func naturalAsyncAndSyncStopsShareAttemptDespiteWaiterTimeoutAndCancellation() async throws {
        let step = ControlledCleanupStep(result: true)
        let group = ControlledProcessGroup(steps: [step])
        let process = makeProcess(group)
        let reaped = TestGate()
        let terminated = TestGate()
        process.onRootReaped = { _ in reaped.open() }
        process.terminationHandler = { _ in terminated.open() }
        defer { step.release.open() }
        var stop: Task<Bool, Never>?
        // Explicit stop is installed before the root-exit source is activated.
        try process.run { _ in stop = process.terminate() }
        #expect(await step.entered.waitUntilOpen())
        #expect(await reaped.waitUntilOpen())
        let second = process.terminate()
        stop?.cancel()
        let syncDone = TestGate()
        let syncResult = CleanupLockedValue<Bool?>(nil)
        DispatchQueue.global(qos: .utility).async {
            syncResult.value = process.terminateAndWait(waitTimeout: 0)
            syncDone.open()
        }
        #expect(await syncDone.waitUntilOpen())
        #expect(syncResult.value == false)
        #expect(group.callCount == 1)
        #expect(process.cleanupState == .cleaning)
        #expect(process.isRunning)
        step.release.open()
        #expect(await stop?.value == true)
        #expect(await second?.value == true)
        #expect(await terminated.waitUntilOpen())
        #expect(group.callCount == 1)
        #expect(!process.hasOwnedProcesses)
        #expect(!step.timedOut)
    }

    @Test
    func failedGroupIsRetainedAndCallbackCanRetryWithoutDeadlockOrDuplicateExit() async throws {
        let first = ControlledCleanupStep(result: false)
        let retry = ControlledCleanupStep(result: true)
        let group = ControlledProcessGroup(steps: [first, retry])
        let process = makeProcess(group)
        let callbacks = CleanupLockedValue(0)
        let failedState = CleanupLockedValue(false)
        let callbackDone = TestGate()
        let retryTask = CleanupLockedValue<Task<Bool, Never>?>(nil)
        process.terminationHandler = { owner in
            callbacks.value += 1
            failedState.value = owner.isRootReaped && !owner.isRunning
                && owner.hasOwnedProcesses && owner.cleanupState == .failed
            retryTask.value = owner.terminate()
            callbackDone.open()
        }
        defer { first.release.open(); retry.release.open() }
        try process.run()
        #expect(await first.entered.waitUntilOpen())
        first.release.open()
        #expect(await callbackDone.waitUntilOpen())
        #expect(await retry.entered.waitUntilOpen())
        #expect(failedState.value)
        #expect(process.hasOwnedProcesses)
        retry.release.open()
        #expect(await retryTask.value?.value == true)
        #expect(callbacks.value == 1)
        #expect(group.callCount == 2)
        #expect(!process.hasOwnedProcesses)
        #expect(process.cleanupState == .complete)
        #expect(!first.timedOut && !retry.timedOut)
    }

    @Test
    func failedExplicitAttemptIsConsumedByNaturalExitWithoutAutomaticRetry() async throws {
        let step = ControlledCleanupStep(result: false)
        let group = ControlledProcessGroup(steps: [step])
        let process = makeProcess(group)
        let terminated = TestGate()
        process.terminationHandler = { _ in terminated.open() }
        defer { step.release.open() }
        try process.run { _ in _ = process.terminate() }
        #expect(await step.entered.waitUntilOpen())
        step.release.open()
        #expect(await terminated.waitUntilOpen())
        #expect(group.callCount == 1)
        #expect(process.cleanupState == .failed)
        #expect(process.hasOwnedProcesses)
        // The injected failure owns no real descendants; retire its retained
        // owner explicitly and join the retry before leaving the test.
        #expect(await process.terminate()?.value == true)
        #expect(!process.hasOwnedProcesses)
        #expect(!step.timedOut)
    }

    @Test
    func rootCallbackPreservesFirstFailureWhileExplicitRetryIsStillRunning() async throws {
        let first = ControlledCleanupStep(result: false)
        let retry = ControlledCleanupStep(result: true)
        let reapRelease = TestGate()
        let group = ControlledProcessGroup(steps: [first, retry], reapRelease: reapRelease)
        let process = makeProcess(group)
        let callbackDone = TestGate()
        let callbacks = CleanupLockedValue(0)
        let callbackFirstResult = CleanupLockedValue<Bool?>(nil)
        let callbackCurrentState = CleanupLockedValue<MacManagedProcess.CleanupState?>(nil)
        process.terminationHandler = { owner in
            callbacks.value += 1
            callbackFirstResult.value = owner.rootExitCleanupSucceeded
            callbackCurrentState.value = owner.cleanupState
            callbackDone.open()
        }
        defer { first.release.open(); retry.release.open(); reapRelease.open() }
        var firstStop: Task<Bool, Never>?
        try process.run { _ in firstStop = process.terminate() }
        #expect(await first.entered.waitUntilOpen())
        #expect(await group.reapEntered.waitUntilOpen())
        first.release.open()
        #expect(await firstStop?.value == false)
        let retryStop = process.terminate()
        #expect(await retry.entered.waitUntilOpen())
        #expect(!process.isRootReaped)
        reapRelease.open()
        #expect(await callbackDone.waitUntilOpen())
        #expect(callbackFirstResult.value == false)
        #expect(callbackCurrentState.value == .cleaning)
        retry.release.open()
        #expect(await retryStop?.value == true)
        #expect(process.rootExitCleanupSucceeded == false)
        #expect(callbacks.value == 1)
        #expect(!process.hasOwnedProcesses)
        #expect(!first.timedOut && !retry.timedOut && !group.reapTimedOut)
    }

    @Test
    func nativeGroupSamplesAnExitedRootBeforeWaitpidReleasesItsIdentity() async throws {
        let snapshot = CleanupLockedValue<MacProcessGroupMember?>(nil)
        let process = MacManagedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
            standardInput: .nullDevice, standardOutput: .standardOutput, standardError: .standardError,
            groupFactory: { pid in RootSnapshotGroup(pid: pid) { snapshot.value = $0 } }
        )
        let terminated = TestGate()
        process.terminationHandler = { _ in terminated.open() }
        try process.run()
        #expect(await terminated.waitUntilOpen())
        #expect(snapshot.value?.pid == process.processIdentifier)
        #expect(snapshot.value?.groupID == process.processIdentifier)
        #expect(process.isRootReaped)
        #expect(!process.hasOwnedProcesses)
        #expect(process.rootExitCleanupSucceeded == true)
        // Also join cleanup on the assertion-failure path.
        if process.hasOwnedProcesses { #expect(await process.terminate()?.value == true) }
    }

    @Test
    func groupSuccessWithoutRootReapFailsBoundedlyAndCanBeRetried() async throws {
        let step = ControlledCleanupStep(result: true)
        let reapRelease = TestGate()
        let group = ControlledProcessGroup(steps: [step], reapRelease: reapRelease)
        let process = makeProcess(group)
        let terminated = TestGate()
        process.terminationHandler = { _ in terminated.open() }
        defer { step.release.open(); reapRelease.open() }
        var stop: Task<Bool, Never>?
        try process.run { _ in stop = process.terminate() }
        #expect(await group.reapEntered.waitUntilOpen())
        #expect(await step.entered.waitUntilOpen())
        step.release.open()
        // The group says true, but waitpid is deliberately held. This awaits
        // the production native root-join deadline, not a synchronization sleep.
        #expect(await stop?.value == false)
        #expect(!process.isRootReaped)
        #expect(process.hasOwnedProcesses)
        #expect(process.cleanupState == .failed)
        reapRelease.open()
        #expect(await terminated.waitUntilOpen())
        #expect(process.isRootReaped)
        #expect(process.rootExitCleanupSucceeded == false)
        #expect(await process.terminate()?.value == true)
        #expect(!process.hasOwnedProcesses)
        #expect(!step.timedOut && !group.reapTimedOut)
    }

    @Test
    func failedLaunchesDoNotAcquireCleanupOwnership() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-missing-process-\(UUID().uuidString)")
        for invalidExecutable in [true, false] {
            let process = MacManagedProcess(
                executableURL: invalidExecutable ? missing : URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [], currentDirectoryURL: invalidExecutable ? nil : missing,
                standardInput: .nullDevice, standardOutput: .standardOutput, standardError: .standardError
            )
            for _ in 0..<2 {
                #expect(throws: POSIXError.self) { try process.run() }
                #expect(process.processIdentifier == 0)
                #expect(!process.hasOwnedProcesses)
                #expect(!process.isRunning)
                #expect(!process.isRootReaped)
                #expect(process.cleanupState == .idle)
                #expect(process.rootExitCleanupSucceeded == nil)
            }
        }
    }

    private func makeProcess(_ group: ControlledProcessGroup) -> MacManagedProcess {
        MacManagedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
            standardInput: .nullDevice, standardOutput: .standardOutput, standardError: .standardError,
            groupFactory: { _ in group }
        )
    }
}

private final class CleanupLockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class ControlledCleanupStep: @unchecked Sendable {
    let entered = TestGate()
    let release = TestGate()
    let result: Bool
    private let timeout = CleanupLockedValue(false)
    var timedOut: Bool { timeout.value }
    init(result: Bool) { self.result = result }
    func run() -> Bool {
        entered.open()
        // Only the production native cleanup worker blocks on this bounded gate.
        let released = release.waitSynchronously(timeout: 2)
        timeout.value = !released
        return released && result
    }
}

private final class ControlledProcessGroup: MacProcessGroupControlling, @unchecked Sendable {
    private let lock = NSLock()
    private let steps: [ControlledCleanupStep]
    private var calls = 0
    private let reapRelease: TestGate?
    let reapEntered = TestGate()
    private let reapTimeout = CleanupLockedValue(false)
    var reapTimedOut: Bool { reapTimeout.value }
    var callCount: Int { lock.withLock { calls } }
    init(steps: [ControlledCleanupStep], reapRelease: TestGate? = nil) {
        self.steps = steps
        self.reapRelease = reapRelease
    }
    func prepareForRootReap() {
        reapEntered.open()
        if let reapRelease { reapTimeout.value = !reapRelease.waitSynchronously(timeout: 2) }
    }
    func terminateAndWait(gracePeriod: TimeInterval, forcedTerminationTimeout: TimeInterval) -> Bool {
        let step = lock.withLock { () -> ControlledCleanupStep? in
            defer { calls += 1 }
            return calls < steps.count ? steps[calls] : nil
        }
        return step?.run() ?? true
    }
}

private final class RootSnapshotGroup: MacProcessGroupControlling, Sendable {
    let pid: pid_t
    let native: MacProcessGroup
    let observer: @Sendable (MacProcessGroupMember?) -> Void
    init(pid: pid_t, observer: @escaping @Sendable (MacProcessGroupMember?) -> Void) {
        self.pid = pid
        self.native = MacProcessGroup(processGroupID: pid)
        self.observer = observer
    }
    func prepareForRootReap() {
        observer(MacNativeProcessGroupBackend().member(pid))
        native.prepareForRootReap()
    }
    func terminateAndWait(gracePeriod: TimeInterval, forcedTerminationTimeout: TimeInterval) -> Bool {
        native.terminateAndWait(gracePeriod: gracePeriod, forcedTerminationTimeout: forcedTerminationTimeout)
    }
}
