import Foundation
import LitheCoreContracts
import LitheDebugModule
import LitheModuleAPI

/// Creates DAP sessions for the Debug module without constructing or retaining
/// a language-server runtime. Provider descriptors remain shared catalog data;
/// the adapter process and session are owned exclusively by Debug.
@MainActor
final class DebugAdapterRuntimeFactory {
    private let runtimeService: ProjectRuntimeService
    private let transportFactory: (URL, [String], [String: String]) -> any DebugAdapterTransport
    private let dlvTransportFactory: ((URL, [String: String]) -> any DebugAdapterTransport)?
    private let nodeTransportFactory: ((URL, [String: String]) -> any DebugAdapterTransport)?
    private let launches: [String: StdioDebugAdapterLaunch]
    private var extensionLaunches: [String: LanguageDebugAdapterLaunch] = [:]
    private let sessionFactories: [String: () -> (any DebugAdapterSession)?]

    init(
        runtimeService: ProjectRuntimeService,
        transportFactory: @escaping (URL, [String], [String: String]) -> any DebugAdapterTransport,
        launches: [String: StdioDebugAdapterLaunch],
        sessionFactories: [String: () -> (any DebugAdapterSession)?] = [:],
        dlvTransportFactory: ((URL, [String: String]) -> any DebugAdapterTransport)? = nil,
        nodeTransportFactory: ((URL, [String: String]) -> any DebugAdapterTransport)? = nil
    ) {
        self.runtimeService = runtimeService
        self.transportFactory = transportFactory
        self.dlvTransportFactory = dlvTransportFactory
        self.nodeTransportFactory = nodeTransportFactory
        self.launches = launches
        self.sessionFactories = sessionFactories
    }

    @discardableResult
    func registerExtension(
        _ provider: any LanguageDebugExtensionProviding,
        support: LanguageSupportDeclaration
    ) -> Bool {
        let launch = provider.debugAdapterLaunch
        guard provider.languageID == support.id,
              !launch.adapterID.isEmpty,
              !launch.executableNames.isEmpty else {
            return false
        }
        extensionLaunches[support.id] = launch
        return true
    }

    func unregisterExtension(languageID: String) {
        extensionLaunches.removeValue(forKey: languageID)
    }

    func makeSession(
        for descriptor: DebugProviderDescriptor,
        rootURL _: URL
    ) -> (any DebugAdapterSession)? {
        if let sessionFactory = sessionFactories[descriptor.id] {
            return sessionFactory()
        }
        if let extensionLaunch = extensionLaunches[descriptor.id] {
            return makeExtensionSession(for: extensionLaunch, languageID: descriptor.id)
        }
        guard let launch = launches[descriptor.id] else { return nil }

        let direct = launch.executableNames.lazy.compactMap { name in
            self.runtimeService.executableOnPath(name).map { ($0, launch.arguments) }
        }.first
        let fallback = launch.fallbacks.lazy.compactMap { fallback in
            self.runtimeService.executableOnPath(fallback.executableName).map {
                ($0, fallback.argumentPrefix + launch.arguments)
            }
        }.first
        guard let (executableURL, arguments) = direct ?? fallback else { return nil }

        return DebugAdapterProtocolSession(
            adapterID: launch.adapterID,
            transport: transportFactory(
                executableURL,
                arguments,
                enrichedEnvironment(for: descriptor.id)
            )
        )
    }

    private func makeExtensionSession(
        for launch: LanguageDebugAdapterLaunch,
        languageID: String
    ) -> (any DebugAdapterSession)? {
        let environment = enrichedEnvironment(for: languageID)
        switch launch.transport {
        case .dlvServer:
            guard let executableURL = launch.executableNames.lazy.compactMap({
                self.runtimeService.executableOnPath($0)
            }).first else { return nil }
            let transport = dlvTransportFactory?(executableURL, environment)
                ?? transportFactory(executableURL, launch.arguments, environment)
            return DebugAdapterProtocolSession(adapterID: launch.adapterID, transport: transport)
        case .nodeServer:
            guard let executableURL = launch.executableNames.lazy.compactMap({
                self.runtimeService.executableOnPath($0)
            }).first else { return nil }
            let transport = nodeTransportFactory?(executableURL, environment)
                ?? transportFactory(executableURL, launch.arguments, environment)
            return DebugAdapterProtocolSession(adapterID: launch.adapterID, transport: transport)
        case .stdio:
            let direct = launch.executableNames.lazy.compactMap { name in
                self.runtimeService.executableOnPath(name).map { ($0, launch.arguments) }
            }.first
            let fallback = launch.fallbacks.lazy.compactMap { fallback in
                self.runtimeService.executableOnPath(fallback.executableName).map {
                    ($0, fallback.argumentPrefix + launch.arguments)
                }
            }.first
            guard let (executableURL, arguments) = direct ?? fallback else { return nil }
            return DebugAdapterProtocolSession(
                adapterID: launch.adapterID,
                transport: transportFactory(executableURL, arguments, environment)
            )
        }
    }

    /// Ensures toolchains spawned by adapters (for example `go` invoked by `dlv dap`
    /// from a Finder-launched app) appear ahead of system PATH.
    private func enrichedEnvironment(for languageID: String) -> [String: String] {
        var environment = runtimeService.processEnvironment()
        if languageID == "go",
           let goExecutable = runtimeService.executableOnPath("go") {
            let goBin = goExecutable.deletingLastPathComponent().path
            let currentPath = environment["PATH"] ?? ""
            let parts = currentPath.split(separator: ":").map(String.init)
            if !parts.contains(goBin) {
                environment["PATH"] = currentPath.isEmpty ? goBin : "\(goBin):\(currentPath)"
            }
        }
        return environment
    }
}
