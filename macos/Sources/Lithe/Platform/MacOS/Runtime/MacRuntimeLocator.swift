import Foundation

enum MacProcessArchitecture: Sendable {
    case arm64
    case x86_64
    case unsupported

    static var current: Self {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .unsupported
        #endif
    }

    var bundledJdkDirectoryName: String? {
        switch self {
        case .arm64: "jdk-arm64"
        case .x86_64: "jdk-x86_64"
        case .unsupported: nil
        }
    }
}

struct MacRuntimeLocator: RuntimeLocator {
    private let resourceURL: URL?
    private let processArchitecture: MacProcessArchitecture
    private let homeDirectoryURL: URL
    private let baseEnvironmentProvider: @Sendable () -> [String: String]
    private let shellEnvironmentProvider: @Sendable () -> [String: String]
    private let prepareShellEnvironment: @Sendable () async -> Void
    private let goEnvFileProvider: @Sendable (URL) -> String?
    private let fileExists: @Sendable (String) -> Bool
    private let isExecutableCheck: @Sendable (String) -> Bool

    init(
        resourceURL: URL? = Bundle.main.resourceURL,
        processArchitecture: MacProcessArchitecture = .current,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironmentProvider: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        shellEnvironmentProvider: @escaping @Sendable () -> [String: String] = {
            MacLoginShellEnvironmentCache.shared.cachedEnvironment()
        },
        prepareShellEnvironment: @escaping @Sendable () async -> Void = {
            await MacLoginShellEnvironmentCache.shared.awaitReady()
        },
        goEnvFileProvider: @escaping @Sendable (URL) -> String? = { url in
            try? String(contentsOf: url, encoding: .utf8)
        },
        fileExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        },
        isExecutableCheck: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.resourceURL = resourceURL
        self.processArchitecture = processArchitecture
        self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
        self.baseEnvironmentProvider = baseEnvironmentProvider
        self.shellEnvironmentProvider = shellEnvironmentProvider
        self.prepareShellEnvironment = prepareShellEnvironment
        self.goEnvFileProvider = goEnvFileProvider
        self.fileExists = fileExists
        self.isExecutableCheck = isExecutableCheck
    }

    func prepareEnvironment() async {
        await prepareShellEnvironment()
    }

    func environment() -> [String: String] {
        var environment = baseEnvironmentProvider()
        let shellEnvironment = shellEnvironmentProvider()

        // Finder-launched apps do not inherit shell startup files. Layer
        // allowlisted login-shell exports beneath explicit process variables so
        // GOPATH, GOMODCACHE, GOROOT, CARGO_HOME, and PATH match the user's
        // terminal without overriding explicit launches or tests.
        for (key, value) in shellEnvironment {
            guard !value.isEmpty else { continue }
            if key == "PATH" {
                environment["PATH"] = Self.mergePath(primary: environment["PATH"], secondary: value)
            } else if environment[key]?.isEmpty ?? true {
                environment[key] = value
            }
        }

        // Next consult Go's user env file (`go env -w`) for safe path keys
        // (`GOPATH`, `GOMODCACHE`, `GOCACHE`, `GOROOT`) only.
        let goEnvURL = MacLoginShellEnvironmentCache.goEnvFileURL(
            environment: environment,
            homeDirectoryURL: homeDirectoryURL
        )
        if let goEnvText = goEnvFileProvider(goEnvURL) {
            for (key, value) in MacLoginShellEnvironmentCache.parseGoEnvFile(goEnvText) {
                if environment[key]?.isEmpty ?? true {
                    environment[key] = value
                }
            }
        }

        if environment["GOROOT"]?.isEmpty ?? true {
            let roots = [
                homeDirectoryURL.appendingPathComponent(".g/go"),
                URL(fileURLWithPath: "/usr/local/go")
            ]
            if let root = roots.first(where: {
                isExecutableCheck($0.appendingPathComponent("bin/go").path)
            }) {
                environment["GOROOT"] = root.path
            }
        }
        if environment["GOPATH"]?.isEmpty ?? true {
            let defaultGoPath = homeDirectoryURL.appendingPathComponent("go")
            if fileExists(defaultGoPath.path) {
                environment["GOPATH"] = defaultGoPath.path
            }
        }
        return environment
    }

    private static func mergePath(primary: String?, secondary: String) -> String {
        var entries: [String] = []
        var seen: Set<String> = []
        for source in [primary ?? "", secondary] {
            for part in source.split(separator: ":") where !part.isEmpty {
                let entry = String(part)
                if seen.insert(entry).inserted {
                    entries.append(entry)
                }
            }
        }
        return entries.joined(separator: ":")
    }

    func discover() -> RuntimeDiscoveryResult {
        MacRuntimeDiscovery.discover(environment: environment())
    }

    func validJavaHome(path: String) -> URL? {
        MacRuntimeDiscovery.validJavaHome(path)
    }

    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? {
        MacRuntimeDiscovery.probeJavaHome(homeURL)
    }

    func isExecutable(at url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }




    /// Returns the bundled JDK matching the current process architecture.
    /// Universal apps carry separate runtimes because a JDK contains native
    /// libraries throughout its installation. Single-architecture and legacy
    /// bundles continue to use `LanguageServers/jdk`.
    func bundledJdkHome() -> URL? {
        guard let resourceURL else { return nil }
        let languageServers = resourceURL.appendingPathComponent(
            "LanguageServers",
            isDirectory: true
        )
        guard let architectureDirectory = processArchitecture.bundledJdkDirectoryName else {
            return nil
        }

        let architectureHome = languageServers
            .appendingPathComponent(architectureDirectory, isDirectory: true)
            .standardizedFileURL
        if isExecutableJava(in: architectureHome) {
            return architectureHome
        }

        // The presence of either suffixed directory marks the new universal
        // layout. Do not hide a missing runtime by falling back across layouts.
        let hasUniversalLayout = ["jdk-arm64", "jdk-x86_64"].contains { directory in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: languageServers.appendingPathComponent(directory).path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
        guard !hasUniversalLayout else { return nil }

        let legacyHome = languageServers
            .appendingPathComponent("jdk", isDirectory: true)
            .standardizedFileURL
        return isExecutableJava(in: legacyHome) ? legacyHome : nil
    }

    private func isExecutableJava(in home: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: home.appendingPathComponent("bin/java").path)
    }
}
