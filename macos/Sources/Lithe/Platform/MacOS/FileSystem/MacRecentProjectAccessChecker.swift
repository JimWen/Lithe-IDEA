import Darwin
import Foundation

/// Keeps at most one actual stat in flight, even when its logical request has
/// timed out. A blocked network mount must not create an unbounded work queue.
@MainActor
final class MacRecentProjectAccessChecker: RecentProjectAccessChecking {
    private final class Request {
        let id: UUID
        let urls: [URL]
        let completion: CheckedContinuation<[URL: RecentProjectAccess], Never>
        var results: [URL: RecentProjectAccess] = [:]
        var nextIndex = 0
        var cancelTimeout: (() -> Void)?

        init(id: UUID, urls: [URL], completion: CheckedContinuation<[URL: RecentProjectAccess], Never>) {
            self.id = id
            self.urls = urls
            self.completion = completion
        }
    }

    private static let responseTimeout: TimeInterval = 1
    private let worker = DispatchQueue(label: "app.lithe.recent-project-access", qos: .utility)
    private let probe: @Sendable (URL) -> RecentProjectAccess
    private let scheduleTimeout: (@escaping @MainActor @Sendable () -> Void) -> () -> Void
    private var current: Request?
    private var queued: Request?
    private var inFlight: UUID?
    private var stopped = false

    init(
        probe: @escaping @Sendable (URL) -> RecentProjectAccess = { MacRecentProjectAccessChecker.probe($0) },
        scheduleTimeout: ((@escaping @MainActor @Sendable () -> Void) -> () -> Void)? = nil
    ) {
        self.probe = probe
        self.scheduleTimeout = scheduleTimeout ?? { action in
            let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.responseTimeout, execute: item)
            return { item.cancel() }
        }
    }

    func check(_ urls: [URL]) async -> [URL: RecentProjectAccess] {
        let id = UUID()
        let paths = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        guard !paths.isEmpty else { return [:] }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let request = Request(id: id, urls: paths, completion: continuation)
                guard !stopped, !Task.isCancelled else {
                    complete(request)
                    return
                }
                if let queued { complete(queued) }
                queued = request
                request.cancelTimeout = scheduleTimeout { [weak self] in self?.cancel(id) }
                advance()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    func stop() {
        stopped = true
        if let current { complete(current) }
        if let queued { complete(queued) }
        current = nil
        queued = nil
        // An OS stat cannot be interrupted. Keep inFlight until its callback;
        // stop never waits for that thread and no replacement worker is started.
    }

    private func advance() {
        guard !stopped, inFlight == nil else { return }
        if current == nil {
            current = queued
            queued = nil
        }
        guard let request = current else { return }
        guard request.nextIndex < request.urls.count else {
            current = nil
            complete(request)
            advance()
            return
        }
        let url = request.urls[request.nextIndex]
        request.nextIndex += 1
        let id = request.id
        inFlight = id
        let probe = probe
        worker.async { [weak self] in
            let result = probe(url)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight = nil
                    if let request = self.current, request.id == id {
                        request.results[url] = result
                    }
                    self.advance()
                }
            }
        }
    }

    private func cancel(_ id: UUID) {
        if let request = current, request.id == id {
            current = nil
            complete(request)
        }
        if let request = queued, request.id == id {
            queued = nil
            complete(request)
        }
        advance()
    }

    private func complete(_ request: Request) {
        request.cancelTimeout?()
        request.cancelTimeout = nil
        var results = request.results
        for url in request.urls where results[url] == nil { results[url] = .unknown }
        request.completion.resume(returning: results)
    }

    nonisolated private static func probe(_ url: URL) -> RecentProjectAccess {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return fstatat(AT_FDCWD, path, &metadata, 0)
        }
        if result == 0 { return (metadata.st_mode & S_IFMT) == S_IFDIR ? .present : .missing }
        return errno == ENOENT || errno == ENOTDIR ? .missing : .unknown
    }
}
