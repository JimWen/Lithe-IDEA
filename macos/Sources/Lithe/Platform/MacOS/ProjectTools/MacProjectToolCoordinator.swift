import Foundation

/// Application-wide admission and ownership, shared by every workspace host.
/// Failed cleanup retains the owner here even if a caller drops its session.
final class MacProjectToolCoordinator: @unchecked Sendable {
    static let shared = MacProjectToolCoordinator()
    private let maximumActive: Int
    init(maximumActive: Int = 2) { self.maximumActive = maximumActive }
    private let lock = NSLock()
    private var owners: [UUID: AnyObject] = [:]

    var activeCaptureCount: Int { lock.withLock { owners.count } }

    func acquire(owner: AnyObject) -> UUID? {
        lock.withLock {
            guard owners.count < maximumActive else { return nil }
            let id = UUID()
            owners[id] = owner
            return id
        }
    }

    func release(_ id: UUID) { _ = lock.withLock { owners.removeValue(forKey: id) } }
}

protocol MacProjectToolDeadline: Sendable { func cancel() }
protocol MacProjectToolScheduling: Sendable {
    func schedule(
        afterMilliseconds: Int, queue: DispatchQueue, action: @escaping @Sendable () -> Void
    ) -> any MacProjectToolDeadline
}

struct MacProjectToolScheduler: MacProjectToolScheduling {
    func schedule(
        afterMilliseconds: Int, queue: DispatchQueue, action: @escaping @Sendable () -> Void
    ) -> any MacProjectToolDeadline {
        let item = DispatchWorkItem(block: action)
        queue.asyncAfter(deadline: .now() + .milliseconds(afterMilliseconds), execute: item)
        return Deadline(item)
    }

    private final class Deadline: MacProjectToolDeadline, @unchecked Sendable {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
        deinit { item.cancel() }
    }
}
