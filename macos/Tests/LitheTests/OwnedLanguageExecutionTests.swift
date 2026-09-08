import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

struct OwnedLanguageExecutionTests {
    @Test func stopFailureRetainsNativeOwnerUntilLateGroupCleanup() async throws {
        let coordinator = MacProjectToolCoordinator()
        let script = ExecutionDriverScript()
        let finished = TestGate()
        let output = ExecutionOutputRecorder()
        let engine = MacOwnedLanguageExecution(registry: ManagedProcessRegistry(), moduleID: .languageExecutionExtension("go"),
            coordinator: coordinator, driverFactory: { _, queue, emit in script.driver(queue: queue, emit: emit) },
            output: { output.append($0) }, termination: { _ in finished.open() }, stateChange: { _ in })
        defer { script.finishCleanup(); engine.stop() }
        try engine.start(.init(operationID: "native-stop", executablePath: "/fixture/go"))
        try #require(await script.started.waitUntilOpen())
        engine.stop()
        #expect(engine.isRunning)
        #expect(coordinator.activeCaptureCount == 1)
        #expect(!(await engine.stopAndWait()))
        #expect(engine.isRunning)
        #expect(coordinator.activeCaptureCount == 1)
        #expect(!finished.isOpen)
        script.finishCleanup()
        try #require(await finished.waitUntilOpen())
        #expect(!engine.isRunning)
        #expect(coordinator.activeCaptureCount == 0)
        #expect(script.disposed.isOpen)
        #expect(await engine.stopAndWait())
    }

    @Test func naturalExitDeliversBothStreamsBeforeCompletion() async throws {
        let script = ExecutionDriverScript()
        let finished = TestGate()
        let output = ExecutionOutputRecorder()
        let engine = MacOwnedLanguageExecution(registry: ManagedProcessRegistry(), moduleID: .languageExecutionExtension("go"),
            coordinator: MacProjectToolCoordinator(), driverFactory: { _, queue, emit in script.driver(queue: queue, emit: emit) },
            output: { output.append($0) }, termination: { _ in finished.open() }, stateChange: { _ in })
        defer { script.finishCleanup(); engine.stop() }
        try engine.start(.init(operationID: "natural", executablePath: "/fixture/go"))
        try #require(await script.started.waitUntilOpen())
        script.emit([
            .bytes(.stdout, Data([0xF0, 0x9F])), .rootReaped(0),
            .cleanupFinished(generation: 0, stopped: true),
            .bytes(.stdout, Data([0x98, 0x80])), .bytes(.stderr, Data(" error\n".utf8)),
            .eof(.stdout), .readerClosed(.stdout), .eof(.stderr), .readerClosed(.stderr)
        ])
        try #require(await finished.waitUntilOpen())
        #expect(output.text == "😀 error\n")
        #expect(!engine.isRunning)
        #expect(script.disposed.isOpen)
    }

    @Test func streamFailureCannotReportSuccessfulRootExit() async throws {
        let script = ExecutionDriverScript()
        let finished = TestGate()
        let output = ExecutionOutputRecorder()
        let engine = MacOwnedLanguageExecution(registry: ManagedProcessRegistry(), moduleID: .languageExecutionExtension("go"),
            coordinator: MacProjectToolCoordinator(), driverFactory: { _, queue, emit in script.driver(queue: queue, emit: emit) },
            output: { output.append($0) }, termination: { code in output.recordExit(code); finished.open() }, stateChange: { _ in })
        defer { script.finishCleanup(); engine.stop() }
        try engine.start(.init(operationID: "read-failure", executablePath: "/fixture/go"))
        try #require(await script.started.waitUntilOpen())
        script.emit([.readFailed(5), .rootReaped(0), .cleanupFinished(generation: UInt64.max, stopped: true)])
        try #require(await finished.waitUntilOpen())
        #expect(output.exitCode == -1)
        #expect(output.text.contains("Could not read process output"))
        #expect(!engine.isRunning)
    }

    @Test func decoderRetainsOnlyIncompleteScalarsAndFlushesMalformedTail() {
        var decoder = MacStreamingUTF8Decoder()
        #expect(decoder.decode(Data([0x61, 0xE4])) == "a")
        #expect(decoder.decode(Data([0xB8])) == "")
        #expect(decoder.decode(Data([0xAD, 0xF0, 0x9F])) == "中")
        #expect(decoder.decode(Data([0x98, 0x80, 0xFF])) == "😀�")
        #expect(decoder.decode(Data([0xC2])) == "")
        #expect(decoder.finish() == "�")
        #expect(decoder.finish().isEmpty)
    }
}

private final class ExecutionDriverScript: @unchecked Sendable {
    let started = TestGate()
    let disposed = TestGate()
    private let lock = NSLock()
    private var current: ScriptedExecutionDriver?
    private var cleanupRequested = false
    func driver(queue: DispatchQueue, emit: @escaping @Sendable (MacProjectToolEvent) -> Void) -> any MacProjectToolDriver {
        let value = ScriptedExecutionDriver(queue: queue, emit: emit, started: started, disposed: disposed)
        let cleanup = lock.withLock { current = value; return cleanupRequested }
        if cleanup { value.enqueue(Self.cleanupEvents) }
        return value
    }
    func emit(_ events: [MacProjectToolEvent]) { lock.withLock { current }?.enqueue(events) }
    private static let cleanupEvents: [MacProjectToolEvent] = [
        .rootReaped(0), .cleanupFinished(generation: UInt64.max, stopped: true),
        .readerClosed(.stdout), .readerClosed(.stderr)
    ]
    func finishCleanup() {
        let driver = lock.withLock { cleanupRequested = true; return current }
        driver?.enqueue(Self.cleanupEvents)
    }
}
private final class ScriptedExecutionDriver: MacProjectToolDriver, @unchecked Sendable {
    private let queue: DispatchQueue
    private let emit: @Sendable (MacProjectToolEvent) -> Void
    private let started: TestGate
    private let disposed: TestGate
    private var generation: UInt64 = 0
    init(queue: DispatchQueue, emit: @escaping @Sendable (MacProjectToolEvent) -> Void, started: TestGate, disposed: TestGate) {
        self.queue = queue; self.emit = emit; self.started = started; self.disposed = disposed
    }
    func start() { emit(.launched); emit(.spawnFinished(nil, writersClosed: true)); started.open() }
    func requestStop() -> UInt64? {
        generation += 1
        let current = generation
        queue.async { [emit] in emit(.cleanupFinished(generation: current, stopped: false)) }
        return current
    }
    func closeReaders() { emit(.readerClosed(.stdout)); emit(.readerClosed(.stderr)) }
    func dispose() { disposed.open() }
    func enqueue(_ events: [MacProjectToolEvent]) { queue.async { [emit] in events.forEach(emit) } }
}
private final class ExecutionOutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    private var exitValue: Int32?
    var exitCode: Int32? { lock.withLock { exitValue } }
    func recordExit(_ code: Int32) { lock.withLock { exitValue = code } }
    var text: String { lock.withLock { value } }
    func append(_ text: String) { lock.withLock { value += text } }
}
