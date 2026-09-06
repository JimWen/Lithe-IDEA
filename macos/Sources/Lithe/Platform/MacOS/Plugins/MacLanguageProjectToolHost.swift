import LitheCoreContracts
import LitheModuleAPI

@MainActor
final class MacLanguageProjectToolHost: LanguageProjectToolHostProviding {
    private let registry: ManagedProcessRegistry
    private let coordinator: MacProjectToolCoordinator

    init(registry: ManagedProcessRegistry, coordinator: MacProjectToolCoordinator = .shared) {
        self.registry = registry
        self.coordinator = coordinator
    }

    func makeProjectToolSession(ownerModuleID: ModuleID) -> any LanguageProjectToolSession {
        MacLanguageProjectToolSession(capture: MacProjectToolCapture(
            registry: registry, moduleID: ownerModuleID, coordinator: coordinator
        ))
    }
}

@MainActor
private final class MacLanguageProjectToolSession: LanguageProjectToolSession {
    var state: LanguageProjectToolState { captureOwner.state }
    var onStateChange: (@MainActor @Sendable (LanguageProjectToolState) -> Void)?
    private let captureOwner: MacProjectToolCapture
    private var deliveredRevision: UInt64 = 0

    init(capture: MacProjectToolCapture) {
        captureOwner = capture
        capture.onStateChange = { [weak self] revision, state in
            Task { @MainActor [weak self] in
                guard let self, revision > deliveredRevision else { return }
                deliveredRevision = revision
                onStateChange?(state)
            }
        }
    }

    func capture(_ request: LanguageProjectToolRequest) async -> LanguageProjectToolResult {
        await captureOwner.capture(request)
    }

    func stopAndWait() async -> Bool { await captureOwner.stopAndWait() }
}
