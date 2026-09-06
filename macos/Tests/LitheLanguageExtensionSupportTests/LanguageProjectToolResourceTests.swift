import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheLanguageExtensionSupport
import LitheModuleAPI
import Testing

@Suite("Language project tool module ownership")
@MainActor
struct LanguageProjectToolResourceTests {
    @Test
    func nativeSessionIsLazyAndSuccessfulCaptureReleasesActivity() async throws {
        let fixture = CaptureFixture()
        let resource = try fixture.register()
        let capability = resource.makeCapability(languageID: "go")
        let session = capability.makeProjectToolSession()
        #expect(capability.languageID == "go")
        #expect(fixture.host.ownerIDs.isEmpty)
        #expect(fixture.scope.activeLeaseReasons.isEmpty)
        #expect(!resource.isModuleResourceActive)

        let result = await session.capture(fixture.request)
        #expect(result.status == .succeeded)
        #expect(result.stdout == Data("metadata".utf8))
        #expect(result.stderr == Data("diagnostic".utf8))
        #expect(fixture.host.ownerIDs == [fixture.scope.moduleID])
        #expect(session.state == .finished)
        #expect(!resource.isModuleResourceActive)
        #expect(fixture.scope.activeLeaseReasons.isEmpty)
        #expect(fixture.events.names == [ModuleEvent.activityStartedName, ModuleEvent.activityEndedName])
        #expect(await session.capture(fixture.request).status == .invalidRequest)
        #expect(fixture.native.captureCalls == 1)
        await resource.stopModuleResource()
    }

    @Test
    func retiredCapabilityAndPrecreatedSessionsCannotEnterANewActivation() async throws {
        let fixture = CaptureFixture()
        let old = try fixture.register()
        let capability = old.makeCapability(languageID: "rust")
        let precreated = capability.makeProjectToolSession()
        old.retire()
        #expect(fixture.scope.resourceSnapshots().isEmpty)
        #expect(await precreated.capture(fixture.request).status == .unavailable)
        #expect(await capability.makeProjectToolSession().capture(fixture.request).status == .unavailable)
        #expect(fixture.host.ownerIDs.isEmpty)

        let fresh = try fixture.register()
        #expect(await fresh.makeCapability(languageID: "rust").makeProjectToolSession()
            .capture(fixture.request).status == .succeeded)
        #expect(await capability.makeProjectToolSession().capture(fixture.request).status == .unavailable)
        #expect(fixture.host.ownerIDs.count == 1)
        await fresh.stopModuleResource()
    }

    @Test
    func cleanupFailureRetainsLeaseAndScopeBlocksAnotherOwnerUntilLateFinish() async throws {
        let fixture = CaptureFixture(status: .cleanupFailed, cleanupConfirmed: false)
        let resource = try fixture.register()
        let session = resource.makeCapability(languageID: "go").makeProjectToolSession()
        let result = await session.capture(fixture.request)
        #expect(result.status == .cleanupFailed)
        #expect(result.cause == .timedOut)
        #expect(!result.cleanupConfirmed)
        #expect(resource.isModuleResourceActive)
        #expect(fixture.scope.activeLeaseReasons.count == 1)
        resource.retire()
        fixture.scope.releaseStoppedResources()
        #expect(fixture.scope.resourceSnapshots().filter(\.isActive).count == 1)
        #expect(throws: ModuleRuntimeError.self) { try fixture.register() }

        fixture.native.emit(.finished)
        fixture.native.emit(.finished)
        fixture.native.emit(.running)
        #expect(session.state == .finished)
        #expect(!resource.isModuleResourceActive)
        #expect(fixture.scope.activeLeaseReasons.isEmpty)
        #expect(fixture.events.names == [ModuleEvent.activityStartedName, ModuleEvent.activityEndedName])
        #expect(fixture.scope.resourceSnapshots().isEmpty)
        fixture.scope.releaseStoppedResources()
        let fresh = try fixture.register()
        await fresh.stopModuleResource()
    }

    @Test
    func failedStopKeepsOwnershipAndAnExplicitRetryCanReleaseIt() async throws {
        let fixture = CaptureFixture(status: .cleanupFailed, cleanupConfirmed: false)
        fixture.native.stopResults = [false, true]
        let resource = try fixture.register()
        let session = resource.makeCapability(languageID: "rust").makeProjectToolSession()
        _ = await session.capture(fixture.request)
        await resource.stopModuleResource()
        #expect(resource.isModuleResourceActive)
        #expect(fixture.scope.activeLeaseReasons.count == 1)
        #expect(fixture.native.stopCalls == 1)
        #expect(await resource.makeCapability(languageID: "rust").makeProjectToolSession()
            .capture(fixture.request).status == .unavailable)

        await resource.stopModuleResource()
        #expect(!resource.isModuleResourceActive)
        #expect(fixture.scope.activeLeaseReasons.isEmpty)
        #expect(fixture.native.stopCalls == 2)
        #expect(fixture.events.names.filter { $0 == ModuleEvent.activityEndedName }.count == 1)
    }

    @Test
    func concurrentResourceAndSessionStopsJoinEvenWhenAWaiterIsCancelled() async throws {
        let fixture = CaptureFixture(status: .cleanupFailed, cleanupConfirmed: false)
        let release = SupportTestGate()
        fixture.native.stopRelease = release
        fixture.native.stopResults = [false, true]
        let resource = try fixture.register()
        let session = resource.makeCapability(languageID: "go").makeProjectToolSession()
        _ = await session.capture(fixture.request)
        let secondEntered = SupportTestGate()
        let directEntered = SupportTestGate()
        defer { release.open(); secondEntered.open(); directEntered.open() }

        let first = Task { @MainActor in await resource.stopModuleResource() }
        #expect(await fixture.native.stopEntered.waitUntilOpen(timeout: .seconds(2)))
        let second = Task { @MainActor in
            secondEntered.open()
            await resource.stopModuleResource()
        }
        #expect(await secondEntered.waitUntilOpen(timeout: .seconds(2)))
        let direct = Task { @MainActor in
            directEntered.open()
            return await session.stopAndWait()
        }
        #expect(await directEntered.waitUntilOpen(timeout: .seconds(2)))
        first.cancel()
        release.open()
        await first.value
        await second.value
        #expect(await direct.value == false)
        #expect(fixture.native.stopCalls == 1)
        #expect(!fixture.native.stopWasCancelled)
        #expect(resource.isModuleResourceActive)
        #expect(fixture.scope.activeLeaseReasons.count == 1)
        await resource.stopModuleResource()
        #expect(fixture.native.stopCalls == 2)
        #expect(!resource.isModuleResourceActive)
        #expect(!fixture.native.deadlineExpired)
    }

    @Test
    func everySessionReceivesStopBeforeTheFirstCleanupCompletes() async throws {
        let fixture = CaptureFixture(status: .cleanupFailed, cleanupConfirmed: false)
        let secondNative = ControlledCaptureSession(status: .cleanupFailed, cleanupConfirmed: false)
        fixture.host.enqueue(secondNative)
        let firstRelease = SupportTestGate()
        fixture.native.stopRelease = firstRelease
        fixture.native.stopResults = [false, true]
        secondNative.stopResults = [false, true]
        let resource = try fixture.register()
        let capability = resource.makeCapability(languageID: "go")
        _ = await capability.makeProjectToolSession().capture(fixture.request)
        _ = await capability.makeProjectToolSession().capture(fixture.request)
        #expect(fixture.scope.activeLeaseReasons.count == 2)
        defer { firstRelease.open() }

        let stop = Task { @MainActor in await resource.stopModuleResource() }
        #expect(await fixture.native.stopEntered.waitUntilOpen(timeout: .seconds(2)))
        #expect(await secondNative.stopEntered.waitUntilOpen(timeout: .seconds(2)))
        #expect(fixture.native.stopCalls == 1 && secondNative.stopCalls == 1)
        firstRelease.open()
        await stop.value
        #expect(resource.isModuleResourceActive)
        #expect(fixture.scope.activeLeaseReasons.count == 2)
        #expect(!fixture.native.deadlineExpired && !secondNative.deadlineExpired)
        await resource.stopModuleResource()
        #expect(!resource.isModuleResourceActive)
        #expect(fixture.scope.activeLeaseReasons.isEmpty)
        #expect(fixture.native.stopCalls == 2 && secondNative.stopCalls == 2)
    }

    @Test
    func nativeStopSuccessKeepsActivityUntilCaptureActuallyReturns() async throws {
        let fixture = CaptureFixture()
        let release = SupportTestGate()
        fixture.native.captureRelease = release
        fixture.native.finishCaptureOnStop = false
        let resource = try fixture.register()
        let session = resource.makeCapability(languageID: "rust").makeProjectToolSession()
        defer { release.open() }
        let capture = Task { @MainActor in await session.capture(fixture.request) }
        #expect(await fixture.native.captureEntered.waitUntilOpen(timeout: .seconds(2)))

        await resource.stopModuleResource()
        #expect(fixture.native.state == .finished)
        #expect(resource.isModuleResourceActive)
        #expect(fixture.scope.activeLeaseReasons.count == 1)
        #expect(fixture.scope.resourceSnapshots().filter(\.isActive).count == 1)
        #expect(throws: ModuleRuntimeError.self) { try fixture.register() }
        // Native stop may resume before the caller's capture continuation. Keep
        // the runtime's conservative active-resource error/retry in this window.
        release.open()
        #expect(await capture.value.cleanupConfirmed)
        #expect(!resource.isModuleResourceActive)
        #expect(fixture.scope.activeLeaseReasons.isEmpty)
        #expect(fixture.scope.resourceSnapshots().isEmpty)
        #expect(!fixture.native.deadlineExpired)
    }

    @Test
    func stateObserverCanRetireBeforeNativeCaptureIsCreated() async throws {
        let fixture = CaptureFixture()
        let resource = try fixture.register()
        let session = resource.makeCapability(languageID: "go").makeProjectToolSession()
        session.onStateChange = { state in if state == .starting { resource.retire() } }
        let result = await session.capture(fixture.request)
        #expect(result.status == .unavailable)
        #expect(result.cleanupConfirmed)
        #expect(fixture.host.ownerIDs.isEmpty)
        #expect(!resource.isModuleResourceActive)
        #expect(fixture.scope.activeLeaseReasons.isEmpty)
        #expect(fixture.events.names.count == 2)
        await resource.stopModuleResource()
    }

    @Test
    func captureCancellationReachesTheNativeOwnerAndCompletesCleanup() async throws {
        let fixture = CaptureFixture()
        let release = SupportTestGate()
        fixture.native.captureRelease = release
        let resource = try fixture.register()
        let session = resource.makeCapability(languageID: "go").makeProjectToolSession()
        defer { release.open() }
        let capture = Task { @MainActor in await session.capture(fixture.request) }
        #expect(await fixture.native.captureEntered.waitUntilOpen(timeout: .seconds(2)))
        #expect(resource.isModuleResourceActive)
        #expect(fixture.scope.activeLeaseReasons.count == 1)
        capture.cancel()
        let result = await capture.value
        #expect(result.status == .cancelled)
        #expect(fixture.native.captureWasCancelled)
        #expect(!resource.isModuleResourceActive)
        #expect(fixture.scope.activeLeaseReasons.isEmpty)
        #expect(!fixture.native.deadlineExpired)
        await resource.stopModuleResource()
    }

    @Test
    func finishedBeforeCaptureReturnsCannotBeOverwrittenByItsOlderFailure() async throws {
        let fixture = CaptureFixture(status: .cleanupFailed, cleanupConfirmed: false)
        let release = SupportTestGate()
        fixture.native.captureRelease = release
        let resource = try fixture.register()
        let session = resource.makeCapability(languageID: "rust").makeProjectToolSession()
        defer { release.open() }
        let capture = Task { @MainActor in await session.capture(fixture.request) }
        #expect(await fixture.native.captureEntered.waitUntilOpen(timeout: .seconds(2)))
        fixture.native.emit(.finished)
        release.open()
        let result = await capture.value
        #expect(result.status == .cleanupFailed)
        #expect(session.state == .finished)
        #expect(!resource.isModuleResourceActive)
        #expect(fixture.scope.activeLeaseReasons.isEmpty)
        #expect(fixture.events.names.count == 2)
        #expect(!fixture.native.deadlineExpired)
        await resource.stopModuleResource()
    }

    @Test
    func scopeGuardUsesSnapshotsAndDoesNotBlockAnotherWorkspace() async throws {
        let fixture = CaptureFixture()
        let orphan = RetainedCaptureResource()
        fixture.scope.register(orphan)
        #expect(throws: ModuleRuntimeError.self) { try fixture.register() }
        let anotherWorkspace = CaptureFixture()
        let independent = try anotherWorkspace.register()
        #expect(!independent.isModuleResourceActive)
        await orphan.stopModuleResource()
        fixture.scope.releaseStoppedResources()
        let recovered = try fixture.register()
        await recovered.stopModuleResource()
        await independent.stopModuleResource()
    }

    @Test
    func stoppingAnIdleSessionPermanentlyConsumesItWithoutCreatingNativeResources() async throws {
        let fixture = CaptureFixture()
        let resource = try fixture.register()
        let session = resource.makeCapability(languageID: "go").makeProjectToolSession()
        #expect(await session.stopAndWait())
        #expect(await session.capture(fixture.request).status == .invalidRequest)
        #expect(fixture.host.ownerIDs.isEmpty)
        #expect(fixture.scope.activeLeaseReasons.isEmpty)
        await resource.stopModuleResource()
    }
}

@MainActor
private final class CaptureFixture {
    let scope = ModuleResourceScope(moduleID: ModuleID("dev.lithe.fixture.language-execution"))
    let events = CaptureEvents()
    let native: ControlledCaptureSession
    let host: CaptureHost
    let request = LanguageProjectToolRequest(
        operationID: "fixture-capture", executablePath: "/fixture/tool",
        workingDirectory: "/fixture/workspace", environment: [:]
    )

    init(status: LanguageProjectToolStatus = .succeeded, cleanupConfirmed: Bool = true) {
        native = ControlledCaptureSession(status: status, cleanupConfirmed: cleanupConfirmed)
        host = CaptureHost(session: native)
    }

    func register() throws -> LanguageProjectToolResource {
        try LanguageProjectToolResource.register(host: host, context: ModuleContext(
            moduleID: scope.moduleID, workspaceURL: nil, capabilities: EmptyCaptureCapabilities(),
            events: events, resources: scope, leases: scope, contributions: EmptyCaptureContributions()
        ))
    }
}

@MainActor
private final class CaptureHost: LanguageProjectToolHostProviding {
    private var sessions: [ControlledCaptureSession]
    private(set) var ownerIDs: [ModuleID] = []
    init(session: ControlledCaptureSession) { sessions = [session] }
    func enqueue(_ session: ControlledCaptureSession) { sessions.append(session) }
    func makeProjectToolSession(ownerModuleID: ModuleID) -> any LanguageProjectToolSession {
        ownerIDs.append(ownerModuleID)
        return sessions[min(ownerIDs.count - 1, sessions.count - 1)]
    }
}

@MainActor
private final class ControlledCaptureSession: LanguageProjectToolSession {
    private(set) var state: LanguageProjectToolState = .idle
    var onStateChange: (@MainActor @Sendable (LanguageProjectToolState) -> Void)?
    let captureEntered = SupportTestGate()
    let stopEntered = SupportTestGate()
    var captureRelease: SupportTestGate?
    var stopRelease: SupportTestGate?
    var stopResults: [Bool] = [true]
    var finishCaptureOnStop = true
    private let resultStatus: LanguageProjectToolStatus
    private let resultCleanup: Bool
    private(set) var captureCalls = 0
    private(set) var stopCalls = 0
    private(set) var captureWasCancelled = false
    private(set) var stopWasCancelled = false
    private(set) var deadlineExpired = false

    init(status: LanguageProjectToolStatus, cleanupConfirmed: Bool) {
        resultStatus = status
        resultCleanup = cleanupConfirmed
    }

    func capture(_ request: LanguageProjectToolRequest) async -> LanguageProjectToolResult {
        captureCalls += 1
        emit(.running)
        captureEntered.open()
        if let captureRelease, !(await captureRelease.waitUntilOpen(timeout: .seconds(2))) {
            captureWasCancelled = Task.isCancelled
            deadlineExpired = !captureWasCancelled
            emit(.finished)
            return LanguageProjectToolResult(
                operationID: request.operationID,
                status: captureWasCancelled ? .cancelled : .timedOut, cleanupConfirmed: true
            )
        }
        emit(resultCleanup ? .finished : .cleanupFailed)
        return LanguageProjectToolResult(
            operationID: request.operationID, status: resultStatus,
            cause: resultStatus == .cleanupFailed ? .timedOut : nil,
            stdout: Data("metadata".utf8), stderr: Data("diagnostic".utf8), exitCode: 0,
            stdoutReachedEOF: true, stderrReachedEOF: true, cleanupConfirmed: resultCleanup
        )
    }

    func stopAndWait() async -> Bool {
        stopCalls += 1
        stopEntered.open()
        if let stopRelease, !(await stopRelease.waitUntilOpen(timeout: .seconds(2))) {
            stopWasCancelled = Task.isCancelled
            deadlineExpired = !stopWasCancelled
            return false
        }
        stopWasCancelled = Task.isCancelled
        let result = stopResults.isEmpty ? true : stopResults.removeFirst()
        emit(result ? .finished : .cleanupFailed)
        if result, finishCaptureOnStop { captureRelease?.open() }
        return result
    }

    func emit(_ next: LanguageProjectToolState) {
        state = next
        onStateChange?(next)
    }
}

@MainActor
private final class CaptureEvents: ModuleEventPublishing {
    private(set) var names: [String] = []
    func publish(_ event: ModuleEvent) { names.append(event.name) }
}

@MainActor
private final class EmptyCaptureCapabilities: ModuleCapabilityResolver {
    func capability(_ id: ModuleCapabilityID) -> AnyObject? { nil }
}

@MainActor
private final class EmptyCaptureContributions: ModuleContributionPublishing {
    func register(_ contribution: ModuleContribution, for moduleID: ModuleID) {}
    func removeContributions(for moduleID: ModuleID) {}
    func contributions() -> [ModuleID: [ModuleContribution]] { [:] }
}

@MainActor
private final class RetainedCaptureResource: ModuleResource {
    let moduleResourceKind = LanguageProjectToolResource.resourceKind
    private(set) var isModuleResourceActive = true
    func stopModuleResource() async { isModuleResourceActive = false }
}

/// Events control test order; the timer only bounds a broken test or fake.
@MainActor
private final class SupportTestGate {
    private var opened = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]

    func open() {
        opened = true
        for id in Array(waiters.keys) { finish(id, result: true) }
    }

    func waitUntilOpen(timeout: Duration) async -> Bool {
        if Task.isCancelled { return false }
        if opened { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                deadlines[id] = Task { @MainActor [weak self] in
                    // test-stability: allow(swift-real-sleep) reason: this gate's local deadline only fails missing events; test ordering is controlled by explicit open/cancel actions.
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finish(id, result: false)
                }
                if Task.isCancelled { finish(id, result: false) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, result: false) }
        }
    }

    private func finish(_ id: UUID, result: Bool) {
        let continuation = waiters.removeValue(forKey: id)
        deadlines.removeValue(forKey: id)?.cancel()
        continuation?.resume(returning: result)
    }
}
