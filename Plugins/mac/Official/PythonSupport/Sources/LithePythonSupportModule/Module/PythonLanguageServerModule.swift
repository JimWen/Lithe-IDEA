import LitheCoreContracts
import LitheModuleAPI

@MainActor
public final class PythonLanguageServerModule: LitheModule {
    public static let moduleManifest = OfficialPluginCatalog.moduleManifestV2(
        for: .languageServerExtension(pythonLanguageID)
    )!

    public let manifest = moduleManifest
    private var capability: PythonLanguageServerCapability?

    public init() {}

    public func activate(context: ModuleContext) async throws {
        let lifecycle = PythonLanguageServerLifecycle()
        context.resources.register(PythonLanguageServerResource(lifecycle: lifecycle))
        capability = PythonLanguageServerCapability(lifecycle: lifecycle)
    }

    public func prepareForSleep() async throws {}
    public func sleep() async { releaseCapability() }
    public func shutdown() async { releaseCapability() }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        capability.map { [.languageServerExtension(pythonLanguageID): $0] } ?? [:]
    }

    private func releaseCapability() {
        capability?.lifecycle.stop()
        capability = nil
    }
}

@MainActor
private final class PythonLanguageServerResource: ModuleResource {
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
