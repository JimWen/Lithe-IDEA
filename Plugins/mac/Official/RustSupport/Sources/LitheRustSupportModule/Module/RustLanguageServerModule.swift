import LitheCoreContracts
import LitheModuleAPI

@MainActor
public final class RustLanguageServerModule: LitheModule {
    public static let moduleManifest = OfficialPluginCatalog.moduleManifestV2(
        for: .languageServerExtension(rustLanguageID)
    )!

    public let manifest = moduleManifest
    private var capability: RustLanguageServerCapability?

    public init() {}

    public func activate(context: ModuleContext) async throws {
        let lifecycle = RustLanguageServerLifecycle()
        context.resources.register(RustLanguageServerResource(lifecycle: lifecycle))
        capability = RustLanguageServerCapability(lifecycle: lifecycle)
    }

    public func prepareForSleep() async throws {}
    public func sleep() async { releaseCapability() }
    public func shutdown() async { releaseCapability() }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        capability.map { [.languageServerExtension(rustLanguageID): $0] } ?? [:]
    }

    private func releaseCapability() {
        capability?.lifecycle.stop()
        capability = nil
    }
}

@MainActor
private final class RustLanguageServerResource: ModuleResource {
    let moduleResourceKind = "language-server-session"
    private let lifecycle: any LanguageServerExtensionLifecycle

    init(lifecycle: any LanguageServerExtensionLifecycle) {
        self.lifecycle = lifecycle
    }

    var isModuleResourceActive: Bool { lifecycle.isRunning }

    func stopModuleResource() async {
        lifecycle.stop()
        await lifecycle.waitUntilStopped()
    }
}
