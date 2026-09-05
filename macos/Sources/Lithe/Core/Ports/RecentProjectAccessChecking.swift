import Foundation

enum RecentProjectAccess: Equatable, Sendable {
    case present
    case missing
    case unknown
}

/// Unknown includes access denial, cancellation and a bounded probe timeout;
/// only confirmed missing paths may be disabled in the menu.
@MainActor
protocol RecentProjectAccessChecking: AnyObject {
    func check(_ urls: [URL]) async -> [URL: RecentProjectAccess]
    func stop()
}
