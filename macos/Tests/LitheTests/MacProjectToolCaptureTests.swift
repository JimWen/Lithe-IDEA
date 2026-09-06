import Darwin
import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("Project tool native capture")
struct MacProjectToolCaptureTests {
    @Test
    func separateStreamsLargerThanPipeCapacityArriveCompletely() async {
        let fixture = NativeCaptureFixture()
        let result = await fixture.capture(arguments: ["-c", "head -c 131072 /dev/zero & head -c 98304 /dev/zero >&2; wait"])
        #expect(result.status == .succeeded)
        #expect(result.stdout == Data(repeating: 0, count: 131_072))
        #expect(result.stderr == Data(repeating: 0, count: 98_304))
        #expect(result.stdoutReachedEOF && result.stderrReachedEOF)
        #expect(result.cleanupConfirmed)
        #expect(fixture.registry.processCount(for: fixture.module) == 0)
        #expect(fixture.coordinator.activeCaptureCount == 0)
        #expect(await fixture.owner.stopAndWait())
    }

    @Test
    func shortLivedFailurePreservesFinalUnicodeJSONAndIndependentStderr() async {
        let fixture = NativeCaptureFixture()
        let json = "{\"message\":\"你好🙂\"}"
        let result = await fixture.capture(arguments: [
            "-c", "printf '%s' \"$1\"; printf '%s' warning >&2; exit 7", "capture", json
        ])
        #expect(result.status == .processFailed)
        #expect(result.exitCode == 7)
        #expect(result.stdout == Data(json.utf8))
        #expect(result.stderr == Data("warning".utf8))
        #expect(result.stdoutReachedEOF && result.stderrReachedEOF && result.cleanupConfirmed)
        #expect(await fixture.owner.stopAndWait())
    }

    @Test(arguments: [256, 257])
    func exactOutputLimitIsValidButOneExtraByteStopsCapture(_ count: Int) async {
        let fixture = NativeCaptureFixture()
        let result = await fixture.capture(arguments: ["-c", "head -c \(count) /dev/zero"], stdoutLimit: 256)
        #expect(result.status == (count == 256 ? .succeeded : .outputLimit))
        #expect(result.stdout.count == 256)
        #expect(result.cleanupConfirmed)
        #expect(fixture.coordinator.activeCaptureCount == 0)
        #expect(await fixture.owner.stopAndWait())
    }

    @Test
    func timeoutStopsTerminationResistantProcessWithoutRequiringArtificialEOF() async {
        let registry = ManagedProcessRegistry()
        let coordinator = MacProjectToolCoordinator()
        let module = ModuleID("test.capture.timeout")
        let scheduler = CaptureManualScheduler()
        let ready = TestGate()
        let output = CaptureBox(Data())
        let owner = MacProjectToolCapture(
            registry: registry, moduleID: module, coordinator: coordinator, scheduler: scheduler,
            driverFactory: { request, queue, emit in
                MacNativeProjectToolDriver(request: request, queue: queue, registry: registry, moduleID: module) { event in
                    emit(event)
                    if case .bytes(.stdout, let bytes) = event {
                        output.value.append(bytes)
                        if output.value == Data("ready".utf8) { ready.open() }
                    }
                }
            }
        )
        let capture = CaptureTask {
            await owner.capture(LanguageProjectToolRequest(
                operationID: "timeout", executablePath: "/bin/sh",
                arguments: ["-c", "trap '' TERM; printf ready; while :; do :; done"],
                workingDirectory: FileManager.default.temporaryDirectory.path,
                environment: [:], timeoutMilliseconds: 1_000
            ))
        }
        #expect(await ready.waitUntilOpen(timeout: .seconds(3)))
        await scheduler.fire(milliseconds: 1_000)
        let result = await capture.boundedValue()
        #expect(result?.status == .timedOut)
        #expect(result?.stdout == Data("ready".utf8))
        #expect(result?.cleanupConfirmed == true)
        // Always request real cleanup, even when readiness/result assertions fail.
        capture.task.cancel()
        let stop = CaptureTask { await owner.stopAndWait() }
        let stopped = await stop.boundedValue()
        if stopped == nil {
            await scheduler.fire(milliseconds: 2_500, requireScheduled: false)
            #expect(await stop.boundedValue() == true)
        } else { #expect(stopped == true) }
        #expect(await capture.boundedValue() != nil)
        #expect(registry.processCount(for: module) == 0)
        #expect(coordinator.activeCaptureCount == 0)
    }

    @Test(arguments: ["stdout", "stderr", "closed"])
    func naturalRootExitCleansTerminationResistantDescendantsBeforeReturning(_ retainedStream: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let pidFile = directory.appendingPathComponent("child.pid")
        let fixture = NativeCaptureFixture()
        let redirects = retainedStream == "stdout" ? "2>/dev/null" : retainedStream == "stderr" ? ">/dev/null" : ">/dev/null 2>&1"
        // A physical child writes its own PID before the root exits. TERM is
        // ignored before fork/exec; cleanup must escalate even with both EOFs.
        let result = await fixture.capture(arguments: [
            "-c", "trap '' TERM; /bin/sh -c 'printf %s \"$$\" > \"$1\"; while :; do :; done' child \"$1\" \(redirects) & while [ ! -s \"$1\" ]; do :; done; exit 0",
            "root", pidFile.path
        ])
        #expect(await fixture.owner.stopAndWait())
        #expect(result.status == .succeeded)
        #expect(result.stdoutReachedEOF && result.stderrReachedEOF && result.cleanupConfirmed)
        #expect(fixture.coordinator.activeCaptureCount == 0)
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))
        #expect(pid != nil)
        if let pid { #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH) }
    }

    @Test
    func failedExecutableAndDirectoryCloseAllOwnedPipes() async {
        // Initialize Dispatch/process support before measuring the serial test's
        // pipe baseline; only FIFO descriptors are counted, not runtime kqueues.
        let warmup = NativeCaptureFixture()
        #expect(await warmup.capture(arguments: ["-c", "exit 0"]).cleanupConfirmed)
        #expect(await warmup.owner.stopAndWait())
        let before = openPipeCount()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        for invalidExecutable in [true, false] {
            let fixture = NativeCaptureFixture()
            let result = await fixture.owner.capture(LanguageProjectToolRequest(
                operationID: UUID().uuidString,
                executablePath: invalidExecutable ? missing : "/usr/bin/true",
                workingDirectory: invalidExecutable ? FileManager.default.temporaryDirectory.path : missing,
                environment: [:], timeoutMilliseconds: 1_000
            ))
            #expect(result.status == .startFailed)
            #expect(result.cleanupConfirmed)
            #expect(fixture.coordinator.activeCaptureCount == 0)
            #expect(fixture.registry.processCount(for: fixture.module) == 0)
            #expect(await fixture.owner.stopAndWait())
        }
        #expect(openPipeCount() == before)
    }

    @Test
    func stoppingIdleSessionPreventsADeferredCapture() async {
        let fixture = NativeCaptureFixture()
        #expect(await fixture.owner.stopAndWait())
        let result = await fixture.capture(arguments: ["-c", "exit 99"])
        #expect(result.status == .cancelled)
        #expect(result.cleanupConfirmed)
        #expect(fixture.coordinator.activeCaptureCount == 0)
    }

    @Test
    func ownedMonitoringTokensDoNotRemoveAnotherOwnerWithTheSamePID() {
        let registry = ManagedProcessRegistry()
        let firstModule = ModuleID("test.capture.first")
        let secondModule = ModuleID("test.capture.second")
        let first = registry.registerOwnedProcess(pid: 12345, category: .service, moduleID: firstModule)
        let second = registry.registerOwnedProcess(pid: 12345, category: .service, moduleID: secondModule)
        defer { registry.unregisterOwnedProcess(first); registry.unregisterOwnedProcess(second) }
        registry.unregisterOwnedProcess(first)
        registry.unregisterOwnedProcess(first)
        #expect(registry.processIDs(for: firstModule).isEmpty)
        #expect(registry.processIDs(for: secondModule) == [12345])
        #expect(registry.processIDs(for: .service) == [12345])
        registry.unregisterOwnedProcess(second)
        #expect(registry.processIDs(for: .service).isEmpty)
    }

    private func openPipeCount() -> Int {
        (0..<1_024).reduce(0) { count, descriptor in
            var info = stat()
            return count + (Darwin.fstat(Int32(descriptor), &info) == 0 && info.st_mode & S_IFMT == S_IFIFO ? 1 : 0)
        }
    }
}

private struct NativeCaptureFixture: Sendable {
    let registry = ManagedProcessRegistry()
    let coordinator = MacProjectToolCoordinator()
    let module = ModuleID("test.project-tools")
    let owner: MacProjectToolCapture
    init() { owner = MacProjectToolCapture(registry: registry, moduleID: module, coordinator: coordinator) }
    func capture(arguments: [String], stdoutLimit: Int = 16 * 1_024 * 1_024, timeout: Int = 2_000) async -> LanguageProjectToolResult {
        await owner.capture(LanguageProjectToolRequest(
            operationID: UUID().uuidString, executablePath: "/bin/sh", arguments: arguments,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            environment: ["PATH": "/usr/bin:/bin"], timeoutMilliseconds: timeout, stdoutByteLimit: stdoutLimit
        ))
    }
}
