import Foundation
import Testing
@testable import Lithe

@Suite("Recent project access", .serialized)
@MainActor
struct RecentProjectAccessTests {
    @Test
    func timeoutKeepsOneRealWorkerAndOnlyTheNewestQueuedRequest() async throws {
        let worker = ControlledRecentProjectProbe()
        let scheduler = ManualCommandScheduler()
        let secondQueued = TestGate()
        let thirdQueued = TestGate()
        var scheduled = 0
        let checker = MacRecentProjectAccessChecker(probe: { worker.probe($0) }, scheduleTimeout: { action in
            scheduled += 1
            if scheduled == 2 { secondQueued.open() }
            if scheduled == 3 { thirdQueued.open() }
            return scheduler.schedule(after: 1, action)
        })
        let firstURL = URL(fileURLWithPath: "/fixture/first")
        let secondURL = URL(fileURLWithPath: "/fixture/second")
        let thirdURL = URL(fileURLWithPath: "/fixture/third")
        try await withRequests(checker: checker, worker: worker) { requests in
            let first = requests.start([firstURL])
            try #require(await worker.entered.waitUntilOpen())
            scheduler.drain(includingDeadlines: true)
            let firstResult = try await first.result()
            #expect(firstResult[firstURL] == .unknown)
            #expect(worker.calls == 1)

            let second = requests.start([secondURL])
            try #require(await secondQueued.waitUntilOpen())
            let third = requests.start([thirdURL])
            try #require(await thirdQueued.waitUntilOpen())
            let secondResult = try await second.result()
            #expect(secondResult[secondURL] == .unknown)
            #expect(worker.calls == 1)
            worker.release.open()
            let thirdResult = try await third.result()
            #expect(thirdResult[thirdURL] == .present)
            #expect(worker.calls == 2)
            #expect(!worker.ranOnMainThread)
            #expect(!worker.timedOut)
        }
    }

    @Test
    func stoppingResumesWaitersAndDoesNotStartQueuedDiskWork() async throws {
        let worker = ControlledRecentProjectProbe()
        let scheduler = ManualCommandScheduler()
        let queued = TestGate()
        var scheduled = 0
        let checker = MacRecentProjectAccessChecker(probe: { worker.probe($0) }, scheduleTimeout: { action in
            scheduled += 1
            if scheduled == 2 { queued.open() }
            return scheduler.schedule(after: 1, action)
        })
        let firstURL = URL(fileURLWithPath: "/fixture/first")
        let secondURL = URL(fileURLWithPath: "/fixture/second")
        try await withRequests(checker: checker, worker: worker) { requests in
            let first = requests.start([firstURL])
            try #require(await worker.entered.waitUntilOpen())
            let second = requests.start([secondURL])
            try #require(await queued.waitUntilOpen())
            checker.stop()
            let firstResult = try await first.result()
            let secondResult = try await second.result()
            #expect(firstResult[firstURL] == .unknown)
            #expect(secondResult[secondURL] == .unknown)
            worker.release.open()
            try #require(await worker.exited.waitUntilOpen())
            scheduler.drain(includingDeadlines: true)
            #expect(worker.calls == 1)
            #expect(!worker.timedOut)
        }
    }

    @Test
    func localDirectoryAndSymlinkAreAvailableButMissingPathsAreNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-recent-access-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("project")
        let link = root.appendingPathComponent("alias")
        let missing = root.appendingPathComponent("missing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let checker = MacRecentProjectAccessChecker()
        try await withRequests(checker: checker) { requests in
            let values = try await requests.start([directory, link, missing]).result()
            #expect(values[directory.standardizedFileURL] == .present)
            #expect(values[link.standardizedFileURL] == .present)
            #expect(values[missing.standardizedFileURL] == .missing)
        }
    }

    private func withRequests(
        checker: MacRecentProjectAccessChecker,
        worker: ControlledRecentProjectProbe? = nil,
        body: (RecentAccessRequests) async throws -> Void
    ) async throws {
        let requests = RecentAccessRequests(checker: checker)
        do {
            try await body(requests)
        } catch {
            worker?.release.open()
            await requests.stop()
            if let worker, worker.entered.isOpen { #expect(await worker.exited.waitUntilOpen()) }
            throw error
        }
        worker?.release.open()
        await requests.stop()
        if let worker, worker.entered.isOpen { #expect(await worker.exited.waitUntilOpen()) }
    }

}

/// The blocking boundary is deliberately the injected platform stat, never the
/// main actor. A bounded gate releases it on success and on every teardown path.
private final class ControlledRecentProjectProbe: @unchecked Sendable {
    let entered = TestGate()
    let release = TestGate()
    let exited = TestGate()
    private let lock = NSLock()
    private var callCount = 0
    private var usedMainThread = false
    private var waitFailed = false

    var calls: Int { lock.withLock { callCount } }
    var ranOnMainThread: Bool { lock.withLock { usedMainThread } }
    var timedOut: Bool { lock.withLock { waitFailed } }

    func probe(_ url: URL) -> RecentProjectAccess {
        let first = lock.withLock {
            callCount += 1
            usedMainThread = usedMainThread || Thread.isMainThread
            return callCount == 1
        }
        if first {
            defer { exited.open() }
            entered.open()
            let released = release.waitSynchronously(timeout: 3)
            lock.withLock { waitFailed = !released }
        }
        return .present
    }
}


/// A checker regression must fail at the independent gate, rather than hang
/// awaiting the very continuation whose timeout/stop behavior is under test.
@MainActor
private final class RecentAccessRequests {
    struct Request {
        let task: Task<[URL: RecentProjectAccess], Never>
        let finished: TestGate

        func result() async throws -> [URL: RecentProjectAccess] {
            try #require(await finished.waitUntilOpen(), "Recent project request did not complete")
            return await task.value
        }
    }

    private let checker: MacRecentProjectAccessChecker
    private var requests: [Request] = []

    init(checker: MacRecentProjectAccessChecker) { self.checker = checker }

    func start(_ urls: [URL]) -> Request {
        let finished = TestGate()
        let task = Task { [checker] in
            let result = await checker.check(urls)
            finished.open()
            return result
        }
        let request = Request(task: task, finished: finished)
        requests.append(request)
        return request
    }

    func stop() async {
        requests.forEach { $0.task.cancel() }
        checker.stop()
        for request in requests {
            let finished = await request.finished.waitUntilOpen()
            #expect(finished, "Cancelled recent project request did not terminate")
            if finished { _ = await request.task.value }
        }
    }
}
