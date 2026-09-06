import Darwin
import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("Project tool capture ordering")
struct MacProjectToolCaptureStateTests {
    @Test(arguments: [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]])
    func completeOutputWaitsForRootAndBothRealEOFs(_ order: [Int]) async {
        let fixture = CaptureStateFixture()
        let task = fixture.start()
        #expect(await fixture.started.waitUntilOpen())
        await fixture.send([.launched, .spawnFinished(nil, writersClosed: true),
                            .bytes(.stdout, Data([0xe4, 0xbd])), .bytes(.stderr, Data("noise".utf8)),
                            .bytes(.stdout, Data([0xa0]))])
        let endings: [[MacProjectToolEvent]] = [
            [.rootReaped(0), .cleanupFinished(generation: 0, stopped: true)],
            [.eof(.stdout), .readerClosed(.stdout)], [.eof(.stderr), .readerClosed(.stderr)]
        ]
        for index in order.dropLast() {
            await fixture.send(endings[index])
            #expect(fixture.coordinator.activeCaptureCount == 1)
        }
        await fixture.send(endings[order.last!])
        #expect(await task.completed.waitUntilOpen())
        let result = await task.boundedValue()
        #expect(result?.status == .succeeded)
        #expect(result?.stdout == Data("你".utf8))
        #expect(result?.stderr == Data("noise".utf8))
        #expect(result?.cleanupConfirmed == true && result?.stdoutReachedEOF == true && result?.stderrReachedEOF == true)
        #expect(fixture.coordinator.activeCaptureCount == 0)
        await fixture.cleanup(captures: [task])
    }

    @Test
    func timeoutDuringSpawnRetainsCapacityAndStopsLateLaunchWithoutReturningAgain() async {
        let fixture = CaptureStateFixture()
        let task = fixture.start()
        #expect(await fixture.started.waitUntilOpen())
        await fixture.scheduler.fire(milliseconds: 1_000)
        #expect(fixture.owner.state == .stopping)
        await fixture.scheduler.fire(milliseconds: 2_500)
        #expect(await task.completed.waitUntilOpen())
        let result = await task.boundedValue()
        #expect(result?.status == .cleanupFailed && result?.cause == .timedOut)
        #expect(result?.cleanupConfirmed == false)
        #expect(fixture.coordinator.activeCaptureCount == 1)
        let requestsBeforeLaunch = fixture.driver.value?.stopRequests ?? 0
        await fixture.send([.launched, .spawnFinished(nil, writersClosed: true)])
        #expect((fixture.driver.value?.stopRequests ?? 0) > requestsBeforeLaunch)
        await fixture.send([.rootReaped(15), .cleanupFinished(generation: 1, stopped: true)])
        #expect(fixture.owner.state == .finished)
        #expect(fixture.coordinator.activeCaptureCount == 0)
        #expect((await task.boundedValue())?.status == .cleanupFailed)
        await fixture.cleanup(captures: [task])
    }

    @Test
    func lateRootFailureCannotEndANewerCleanupAttempt() async {
        let fixture = CaptureStateFixture()
        let task = fixture.start()
        #expect(await fixture.started.waitUntilOpen())
        await fixture.send([.launched, .spawnFinished(nil, writersClosed: true), .rootReaped(1)])
        await fixture.scheduler.fire(milliseconds: 1_000)
        await fixture.send([.cleanupFinished(generation: 1, stopped: false)])
        #expect(await task.completed.waitUntilOpen())
        #expect((await task.boundedValue())?.status == .cleanupFailed)
        let stopped = CaptureTask { await fixture.owner.stopAndWait() }
        #expect(await fixture.driver.value?.retried.waitUntilOpen() == true)
        await fixture.send([.cleanupFinished(generation: 0, stopped: false)])
        #expect(fixture.owner.state == .stopping)
        #expect(!stopped.completed.isOpen)
        await fixture.send([.cleanupFinished(generation: 2, stopped: true)])
        #expect(await stopped.completed.waitUntilOpen())
        #expect(await stopped.boundedValue() == true)
        #expect(fixture.coordinator.activeCaptureCount == 0)
        await fixture.cleanup(captures: [task], stops: [stopped])
    }

    @Test
    func readFailureReleasesResourcesWithoutPretendingCancellationWasEOF() async {
        let fixture = CaptureStateFixture()
        let task = fixture.start()
        #expect(await fixture.started.waitUntilOpen())
        await fixture.send([.launched, .spawnFinished(nil, writersClosed: true),
                            .bytes(.stdout, Data("partial".utf8)), .readFailed(EIO)])
        await fixture.send([.rootReaped(15), .cleanupFinished(generation: 1, stopped: true)])
        #expect(await task.completed.waitUntilOpen())
        let result = await task.boundedValue()
        #expect(result?.status == .readFailed)
        #expect(result?.cleanupConfirmed == true)
        #expect(result?.stdoutReachedEOF == false && result?.stderrReachedEOF == false)
        #expect(fixture.coordinator.activeCaptureCount == 0)
        await fixture.cleanup(captures: [task])
    }

    @Test
    func cancelledDuplicateCaptureDoesNotCancelTheFirstOperation() async {
        let fixture = CaptureStateFixture()
        let first = fixture.start()
        #expect(await fixture.started.waitUntilOpen())
        let duplicate = fixture.start()
        duplicate.task.cancel()
        #expect(await duplicate.completed.waitUntilOpen())
        #expect((await duplicate.boundedValue())?.status == .invalidRequest)
        #expect(fixture.owner.state == .starting)
        #expect(fixture.driver.value?.stopRequests == 0)
        await fixture.finishSuccessfully()
        #expect(await first.completed.waitUntilOpen())
        #expect((await first.boundedValue())?.status == .succeeded)
        await fixture.cleanup(captures: [first, duplicate])
    }

    @Test
    func capacityIsSharedByIndependentWorkspaceCapturesAndBusyNeverStarts() async {
        let coordinator = MacProjectToolCoordinator()
        let first = CaptureStateFixture(coordinator: coordinator)
        let second = CaptureStateFixture(coordinator: coordinator)
        let third = CaptureStateFixture(coordinator: coordinator)
        let firstTask = first.start()
        let secondTask = second.start()
        #expect(await first.started.waitUntilOpen())
        #expect(await second.started.waitUntilOpen())
        let thirdTask = third.start()
        #expect(await thirdTask.completed.waitUntilOpen())
        #expect((await thirdTask.boundedValue())?.status == .capacityUnavailable)
        #expect((await thirdTask.boundedValue())?.cleanupConfirmed == true)
        #expect(third.driver.value == nil)
        #expect(coordinator.activeCaptureCount == 2)
        await first.finishSuccessfully()
        await second.finishSuccessfully()
        #expect(await firstTask.completed.waitUntilOpen())
        #expect(await secondTask.completed.waitUntilOpen())
        #expect((await firstTask.boundedValue())?.status == .succeeded)
        #expect((await secondTask.boundedValue())?.status == .succeeded)
        #expect(coordinator.activeCaptureCount == 0)
        await first.cleanup(captures: [firstTask])
        await second.cleanup(captures: [secondTask])
        await third.cleanup(captures: [thirdTask])
        #expect(coordinator.activeCaptureCount == 0)
    }

    @Test
    func completeEOFsStillWaitForBothReaderCancellationHandlers() async {
        let fixture = CaptureStateFixture()
        let task = fixture.start()
        #expect(await fixture.started.waitUntilOpen())
        await fixture.send([.launched, .spawnFinished(nil, writersClosed: true), .rootReaped(0),
                            .cleanupFinished(generation: 0, stopped: true), .eof(.stdout), .eof(.stderr)])
        #expect(!task.completed.isOpen)
        #expect(fixture.coordinator.activeCaptureCount == 1)
        await fixture.send([.readerClosed(.stdout)])
        #expect(!task.completed.isOpen)
        #expect(fixture.coordinator.activeCaptureCount == 1)
        await fixture.send([.readerClosed(.stderr)])
        #expect((await task.boundedValue())?.status == .succeeded)
        #expect(fixture.coordinator.activeCaptureCount == 0)
        await fixture.cleanup(captures: [task])
    }

    @Test
    func EOFDoesNotReleaseCapacityBeforeReaderAndWriterClosure() async {
        let fixture = CaptureStateFixture()
        let task = fixture.start()
        #expect(await fixture.started.waitUntilOpen())
        await fixture.send([.launched, .rootReaped(0), .cleanupFinished(generation: 0, stopped: true),
                            .eof(.stdout), .eof(.stderr)])
        #expect(!task.completed.isOpen)
        #expect(fixture.coordinator.activeCaptureCount == 1)
        await fixture.send([.readerClosed(.stdout), .readerClosed(.stderr)])
        #expect(!task.completed.isOpen)
        #expect(fixture.coordinator.activeCaptureCount == 1)
        // Failed writer closure is an error, even when all output is complete.
        await fixture.send([.spawnFinished(nil, writersClosed: false)])
        #expect(!task.completed.isOpen)
        #expect(fixture.coordinator.activeCaptureCount == 1)
        await fixture.send([.writersClosed])
        #expect((await task.boundedValue())?.status == .readFailed)
        #expect(fixture.coordinator.activeCaptureCount == 0)
        await fixture.cleanup(captures: [task])
    }

    @Test
    func queuedCancelledDeadlineCannotChangeFinishedResult() async {
        let fixture = CaptureStateFixture()
        let task = fixture.start()
        #expect(await fixture.started.waitUntilOpen())
        await fixture.finishSuccessfully()
        #expect(await task.completed.waitUntilOpen())
        await fixture.scheduler.fire(milliseconds: 1_000, includingCancelled: true)
        #expect(fixture.owner.state == .finished)
        #expect((await task.boundedValue())?.status == .succeeded)
        #expect(fixture.driver.value?.stopRequests == 0)
        await fixture.cleanup(captures: [task])
    }
}

final class CaptureTask<Value: Sendable>: Sendable {
    let completed: TestGate
    let task: Task<Value, Never>
    func boundedValue() async -> Value? {
        guard await completed.waitUntilOpen(timeout: .seconds(3)) else {
            task.cancel()
            Issue.record("Capture task failed to complete before its local deadline")
            return nil
        }
        // The gate opens after body returns, with no further suspension before
        // task completion. A failed gate never enters an unbounded value wait.
        return await task.value
    }
    init(_ body: @escaping @Sendable () async -> Value) {
        let gate = TestGate()
        completed = gate
        task = Task { let result = await body(); gate.open(); return result }
    }
}

final class CaptureBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private struct CaptureStateFixture: Sendable {
    let coordinator: MacProjectToolCoordinator
    let scheduler = CaptureManualScheduler()
    let driver = CaptureBox<CaptureControlledDriver?>(nil)
    let tearingDown = CaptureBox(false)
    let started = TestGate()
    let owner: MacProjectToolCapture
    init(coordinator: MacProjectToolCoordinator = MacProjectToolCoordinator()) {
        self.coordinator = coordinator
        let driver = driver
        let started = started
        let tearingDown = tearingDown
        owner = MacProjectToolCapture(
            registry: ManagedProcessRegistry(), moduleID: ModuleID("test.capture.state"),
            coordinator: coordinator, scheduler: scheduler,
            driverFactory: { _, queue, emit in
                let value = CaptureControlledDriver(queue: queue, emit: emit, started: started)
                driver.value = value
                if tearingDown.value { value.forceFinish() }
                return value
            }
        )
    }
    func start() -> CaptureTask<LanguageProjectToolResult> {
        CaptureTask {
            await owner.capture(LanguageProjectToolRequest(
                operationID: "fixture", executablePath: "/fixture/tool", workingDirectory: "/fixture", environment: [:], timeoutMilliseconds: 1_000
            ))
        }
    }
    func send(_ events: [MacProjectToolEvent]) async {
        #expect(await driver.value?.send(events) == true)
    }
    func cleanup(captures: [CaptureTask<LanguageProjectToolResult>], stops: [CaptureTask<Bool>] = []) async {
        // Assertions are nonthrowing, so every test reaches this async finally
        // path even after an expectation/deadline failure. Fakes have no OS
        // resources; explicitly complete their launch/close/cleanup boundaries.
        tearingDown.value = true
        captures.forEach { $0.task.cancel() }
        let stop = CaptureTask { await owner.stopAndWait() }
        if driver.value != nil {
            await send([.launched, .spawnFinished(nil, writersClosed: true), .rootReaped(0),
                        .cleanupFinished(generation: UInt64.max, stopped: true),
                        .eof(.stdout), .readerClosed(.stdout), .eof(.stderr), .readerClosed(.stderr)])
        }
        #expect(await stop.boundedValue() == true)
        for capture in captures { #expect(await capture.boundedValue() != nil) }
        for waiter in stops { #expect(await waiter.boundedValue() != nil) }
        #expect(!owner.state.isActive)
    }
    func finishSuccessfully() async {
        await send([.launched, .spawnFinished(nil, writersClosed: true), .rootReaped(0),
                    .cleanupFinished(generation: 0, stopped: true), .eof(.stdout), .readerClosed(.stdout),
                    .eof(.stderr), .readerClosed(.stderr)])
    }
}

/// Fakes carry no subprocesses or descriptors. Every emission stays on the
/// production owner queue; gate deadlines bound a failed ordering assertion.
private final class CaptureControlledDriver: MacProjectToolDriver, @unchecked Sendable {
    let queue: DispatchQueue
    let emit: @Sendable (MacProjectToolEvent) -> Void
    let started: TestGate
    let retried = TestGate()
    private let requests = CaptureBox(0)
    private var closing = false
    var stopRequests: Int { requests.value }
    init(queue: DispatchQueue, emit: @escaping @Sendable (MacProjectToolEvent) -> Void, started: TestGate) {
        self.queue = queue; self.emit = emit; self.started = started
    }
    func start() { started.open() }
    func requestStop() -> UInt64? {
        requests.value += 1
        if requests.value >= 2 { retried.open() }
        return UInt64(requests.value)
    }
    func closeReaders() {
        guard !closing else { return }
        closing = true
        queue.async { [emit] in emit(.readerClosed(.stdout)); emit(.readerClosed(.stderr)) }
    }
    func dispose() {}
    func forceFinish() {
        queue.async { [emit] in
            [.launched, .spawnFinished(nil, writersClosed: true), .rootReaped(0),
             .cleanupFinished(generation: UInt64.max, stopped: true),
             .eof(.stdout), .readerClosed(.stdout), .eof(.stderr), .readerClosed(.stderr)]
                .forEach(emit)
        }
    }
    func send(_ events: [MacProjectToolEvent]) async -> Bool {
        let done = TestGate()
        queue.async { [emit] in events.forEach(emit); done.open() }
        return await done.waitUntilOpen()
    }
}

final class CaptureManualScheduler: MacProjectToolScheduling, @unchecked Sendable {
    private struct Entry {
        let milliseconds: Int
        let queue: DispatchQueue
        let action: @Sendable () -> Void
        let token: Token
    }
    private final class Token: MacProjectToolDeadline, @unchecked Sendable {
        let cancelled = CaptureBox(false)
        func cancel() { cancelled.value = true }
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    func schedule(afterMilliseconds: Int, queue: DispatchQueue, action: @escaping @Sendable () -> Void) -> any MacProjectToolDeadline {
        let token = Token()
        lock.withLock { entries.append(Entry(milliseconds: afterMilliseconds, queue: queue, action: action, token: token)) }
        return token
    }
    func fire(milliseconds: Int, includingCancelled: Bool = false, requireScheduled: Bool = true) async {
        let selected = lock.withLock { () -> [Entry] in
            let values = entries.filter { $0.milliseconds == milliseconds }
            entries.removeAll { $0.milliseconds == milliseconds }
            return values
        }
        if requireScheduled { #expect(!selected.isEmpty) }
        for entry in selected {
            let done = TestGate()
            entry.queue.async {
                if includingCancelled || !entry.token.cancelled.value { entry.action() }
                done.open()
            }
            #expect(await done.waitUntilOpen())
        }
    }
}
