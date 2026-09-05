import Combine
import Foundation

/// Native adapters update execution eligibility synchronously. Menu rendering
/// observes these facts through its own tracking-aware projection.
@MainActor
final class CommandEnvironmentFeatureModel: ObservableObject {
    @Published private(set) var context: ProjectCommandContext?
    @Published private(set) var isApplicationActive = false
    @Published private(set) var isModal = false
    @Published private(set) var isTrackingMenu = false
    private(set) var generation = 0
    private var trackingRoots: Set<ObjectIdentifier> = []

    var permitsApplicationCommand: Bool { isApplicationActive && !isModal }

    func update(context: ProjectCommandContext?, isApplicationActive: Bool, isModal: Bool) {
        guard self.context != context || self.isApplicationActive != isApplicationActive
                || self.isModal != isModal else { return }
        generation += 1
        self.context = context
        self.isApplicationActive = isApplicationActive
        self.isModal = isModal
    }

    func beginTracking(_ root: AnyObject) {
        guard trackingRoots.insert(ObjectIdentifier(root)).inserted else { return }
        if !isTrackingMenu {
            generation += 1
            isTrackingMenu = true
        }
    }

    func endTracking(_ root: AnyObject) {
        guard trackingRoots.remove(ObjectIdentifier(root)) != nil else { return }
        if trackingRoots.isEmpty {
            generation += 1
            isTrackingMenu = false
        }
    }

    func permitsProjectCommand(from origin: ProjectCommandContext) -> Bool {
        permitsApplicationCommand && context == origin
    }

    func stop() {
        trackingRoots.removeAll()
        generation += 1
        isTrackingMenu = false
        update(context: nil, isApplicationActive: false, isModal: false)
    }
}
