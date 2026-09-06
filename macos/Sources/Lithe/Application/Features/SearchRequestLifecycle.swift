import Foundation

/// Invalidates requests even while their lazy module activation is suspended.
@MainActor
final class SearchRequestLifecycle {
    enum Kind: Hashable { case project, everywhere, replacement }
    struct Request: Equatable {
        fileprivate let kind: Kind
        fileprivate let generation: Int
    }

    private var generations: [Kind: Int] = [:]

    func begin(_ kind: Kind) -> Request {
        invalidate(kind)
        return Request(kind: kind, generation: generations[kind, default: 0])
    }

    func invalidate(_ kind: Kind) { generations[kind, default: 0] += 1 }

    func isCurrent(_ request: Request) -> Bool {
        !Task.isCancelled && generations[request.kind] == request.generation
    }

    /// Both checks are necessary: closing/reopening with identical input must
    /// not revive an earlier request or allow it to reach the newly active module.
    func activate<Value>(
        for request: Request,
        isValid: () -> Bool,
        operation: () async -> Value?
    ) async -> Value? {
        guard isCurrent(request), isValid() else { return nil }
        let value = await operation()
        guard isCurrent(request), isValid() else { return nil }
        return value
    }
}
