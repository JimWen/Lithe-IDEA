import Darwin
import Foundation

/// Globally bounded native filesystem work. Logical cancellation never frees
/// a worker slot while a potentially blocked filesystem call is still running.
@MainActor
final class MacTerminalVirtualEnvironmentProbe {
    enum Result: Equatable, Sendable { case found(String), missing, unknown, unsupportedPath }
    enum Presence: Sendable { case present, missing, unknown }
    static let shared = MacTerminalVirtualEnvironmentProbe()
    private static let maximumWorkers = 2
    private static let responseTimeout: TimeInterval = 1
    private let worker = DispatchQueue(label: "app.lithe.terminal-venv", qos: .utility, attributes: .concurrent)
    private let probe: @Sendable (String) -> Presence
    private let scheduleTimeout: (@escaping @MainActor @Sendable () -> Void) -> () -> Void
    private var inFlight = 0
    private var requests: [UUID: Request] = [:]

    private final class Request {
        let paths: [String]
        let completion: (Result) -> Void
        var nextIndex = 0
        var cancelTimeout: (() -> Void)?
        init(paths: [String], completion: @escaping (Result) -> Void) {
            self.paths = paths; self.completion = completion
        }
    }

    init(probe: @escaping @Sendable (String) -> Presence = { MacTerminalVirtualEnvironmentProbe.probe($0) },
         scheduleTimeout: ((@escaping @MainActor @Sendable () -> Void) -> () -> Void)? = nil) {
        self.probe = probe
        self.scheduleTimeout = scheduleTimeout ?? { action in
            let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.responseTimeout, execute: item)
            return { item.cancel() }
        }
    }

    func check(_ paths: [String], completion: @escaping (Result) -> Void) -> () -> Void {
        guard !paths.isEmpty else { completion(.missing); return {} }
        guard inFlight < Self.maximumWorkers else { completion(.unknown); return {} }
        let id = UUID(), request = Request(paths: paths, completion: completion)
        requests[id] = request
        request.cancelTimeout = scheduleTimeout { [weak self] in self?.complete(id, .unknown) }
        advance(id)
        return { [weak self] in
            guard let request = self?.requests.removeValue(forKey: id) else { return }
            request.cancelTimeout?()
        }
    }

    private func advance(_ id: UUID) {
        guard let request = requests[id] else { return }
        guard request.nextIndex < request.paths.count else { complete(id, .missing); return }
        let path = request.paths[request.nextIndex]
        request.nextIndex += 1
        guard !path.contains(":") else { complete(id, .unsupportedPath); return }
        inFlight += 1
        let probe = probe
        worker.async { [weak self] in
            let result = probe(path)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight -= 1
                    guard self.requests[id] != nil else { return }
                    switch result {
                    case .present: self.complete(id, .found(path))
                    case .missing: self.advance(id)
                    case .unknown: self.complete(id, .unknown)
                    }
                }
            }
        }
    }

    private func complete(_ id: UUID, _ result: Result) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.cancelTimeout?()
        request.completion(result)
    }

    nonisolated private static func probe(_ path: String) -> Presence {
        func metadata(_ path: String, kind: mode_t) -> Presence {
            var info = stat()
            guard fstatat(AT_FDCWD, path, &info, 0) == 0 else {
                return errno == ENOENT || errno == ENOTDIR ? .missing : .unknown
            }
            return (info.st_mode & S_IFMT) == kind ? .present : .missing
        }
        let directory = metadata(path, kind: S_IFDIR)
        guard case .present = directory else { return directory }
        let config = metadata(path + "/pyvenv.cfg", kind: S_IFREG)
        guard case .present = config else { return config }
        var unknown = false
        for name in ["python", "python3"] {
            let executable = path + "/bin/" + name
            switch metadata(executable, kind: S_IFREG) {
            case .present:
                if access(executable, X_OK) == 0 { return .present }
                if errno != EACCES && errno != ENOENT { unknown = true }
            case .missing: break
            case .unknown: unknown = true
            }
        }
        return unknown ? .unknown : .missing
    }
}
