import Darwin
import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("Project tool pipe ownership")
struct MacProjectToolPipeTests {
    @Test(arguments: [EINTR, EAGAIN, EIO])
    func readErrorsYieldToCancellationAndNeverInventEOF(_ error: Int32) async throws {
        let fixture = try PipeFixture()
        defer { fixture.closeWriter() }
        let reads = CaptureBox(0)
        let observed = CaptureBox<Int32?>(nil)
        let eof = CaptureBox(false)
        let reader = CaptureBox<MacProjectToolPipeReader?>(nil)
        let closed = TestGate()
        fixture.queue.async {
            reader.value = MacProjectToolPipeReader(
                descriptor: fixture.read, queue: fixture.queue,
                io: MacProjectToolPipeIO(read: { _ in
                    reads.value += 1
                    if reads.value == 1 {
                        fixture.queue.async { reader.value?.cancel() }
                    }
                    return .error(error)
                }, close: MacProjectToolPipeIO.native.close),
                onData: { _ in Issue.record("Unexpected data") }, onEOF: { eof.value = true },
                onError: { observed.value = $0 }, onClosed: { closed.open() },
                onCloseError: { _ in Issue.record("Close failed"); closed.open() }
            )
            fixture.makeReadable()
        }
        #expect(await closed.waitUntilOpen())
        #expect(reads.value == (error == EINTR ? 4 : 1))
        #expect(observed.value == (error == EIO ? EIO : nil))
        #expect(!eof.value)
        await fixture.finish(reader: reader, closed: closed)
    }

    @Test
    func queuedReadAfterCancellationDoesNotReadOrPublishEOF() async throws {
        let fixture = try PipeFixture()
        defer { fixture.closeWriter() }
        let reads = CaptureBox(0)
        let closed = TestGate()
        let reader = CaptureBox<MacProjectToolPipeReader?>(nil)
        fixture.queue.async {
            reader.value = MacProjectToolPipeReader(
                descriptor: fixture.read, queue: fixture.queue,
                io: MacProjectToolPipeIO(read: { _ in reads.value += 1; return .eof }, close: MacProjectToolPipeIO.native.close),
                onData: { _ in Issue.record("Unexpected data") }, onEOF: { Issue.record("Cancellation is not EOF") },
                onError: { _ in Issue.record("Unexpected read error") }, onClosed: { closed.open() },
                onCloseError: { _ in Issue.record("Close failed"); closed.open() }
            )
            fixture.makeReadable()
            reader.value?.cancel()
        }
        #expect(await closed.waitUntilOpen())
        #expect(reads.value == 0)
        await fixture.finish(reader: reader, closed: closed)
    }

    @Test
    func closeFailureNeverPublishesClosedAndDoesNotRetryRawDescriptor() async throws {
        let fixture = try PipeFixture()
        defer { fixture.closeWriter() }
        let attempts = CaptureBox(0)
        let closed = TestGate()
        let reader = CaptureBox<MacProjectToolPipeReader?>(nil)
        fixture.queue.async {
            reader.value = MacProjectToolPipeReader(
                descriptor: fixture.read, queue: fixture.queue,
                io: MacProjectToolPipeIO(read: MacProjectToolPipeIO.native.read, close: { descriptor in
                    attempts.value += 1
                    // Actually release the fixture fd, then simulate ambiguous
                    // syscall evidence. Production must never re-close its number.
                    #expect(Darwin.close(descriptor) == 0)
                    return EIO
                }),
                onData: { _ in }, onEOF: {}, onError: { _ in },
                onClosed: { Issue.record("Failed close cannot be confirmed"); closed.open() },
                onCloseError: { #expect($0 == EIO); closed.open() }
            )
            reader.value?.cancel()
            reader.value?.cancel()
        }
        #expect(await closed.waitUntilOpen())
        await fixture.finish(reader: reader, closed: closed)
        #expect(attempts.value == 1)
    }

    @Test(arguments: [1, 2])
    func preparationFailureKeepsAllocatedPipesOwnedUntilTheirCloseHandlersFinish(_ failedPipe: Int) async {
        let coordinator = MacProjectToolCoordinator()
        let registry = ManagedProcessRegistry()
        let module = ModuleID("test.capture.preparation")
        let calls = CaptureBox(0)
        let capture = MacProjectToolCapture(
            registry: registry, moduleID: module, coordinator: coordinator,
            driverFactory: { request, queue, emit in
                MacNativeProjectToolDriver(
                    request: request, queue: queue, registry: registry, moduleID: module,
                    preparePipe: {
                        calls.value += 1
                        var pipe = MacProjectToolPreparedPipe.make()
                        if calls.value == failedPipe { pipe.error = EIO }
                        return pipe
                    }, emit: emit
                )
            }
        )
        let result = await capture.capture(LanguageProjectToolRequest(
            operationID: "prepare", executablePath: "/usr/bin/true", workingDirectory: "/", environment: [:], timeoutMilliseconds: 1_000
        ))
        #expect(result.status == .startFailed && result.cleanupConfirmed)
        #expect(!result.stdoutReachedEOF && !result.stderrReachedEOF)
        #expect(calls.value == failedPipe)
        #expect(coordinator.activeCaptureCount == 0)
        #expect(registry.processIDs(for: module).isEmpty)
        #expect(await capture.stopAndWait())
    }

    @Test
    func failedWriterCloseRemainsUnconfirmedAfterWrapperLosesDescriptor() throws {
        let fixture = try PipeFixture()
        defer { #expect(Darwin.close(fixture.read) == 0) }
        var attempts = 0
        let writer = MacProjectToolWriter(descriptor: fixture.write) { handle in
            attempts += 1
            try handle.close()
            throw POSIXError(.EIO)
        }
        #expect(!writer.close())
        #expect(!writer.close())
        #expect(attempts == 1)
    }
}

private struct PipeFixture: Sendable {
    let read: Int32
    let write: Int32
    let queue = DispatchQueue(label: "test.project-tool.pipe")
    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        read = descriptors[0]; write = descriptors[1]
    }
    func makeReadable() {
        var byte: UInt8 = 1
        #expect(Darwin.write(write, &byte, 1) == 1)
    }
    func closeWriter() { #expect(Darwin.close(write) == 0) }
    func finish(reader: CaptureBox<MacProjectToolPipeReader?>, closed: TestGate) async {
        let released = TestGate()
        queue.async {
            reader.value?.cancel()
            reader.value = nil
            released.open()
        }
        #expect(await released.waitUntilOpen())
        #expect(await closed.waitUntilOpen())
    }
}
