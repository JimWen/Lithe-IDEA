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

    init(
        resourceURL: URL? = Bundle.main.resourceURL,
        processArchitecture: MacProcessArchitecture = .current
    ) {
        self.resourceURL = resourceURL
        self.processArchitecture = processArchitecture
    }

    func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Finder-launched apps do not inherit shell startup files. Mirror the
        // Go tool's well-known installation roots so the later GOROOT/GOPATH
        // candidates have the same priority as `go env` in a terminal.
        if environment["GOROOT"] == nil {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let roots = [
                home.appendingPathComponent(".g/go"),
                URL(fileURLWithPath: "/usr/local/go")
            ]
            if let root = roots.first(where: {
                FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("bin/go").path)
            }) {
                environment["GOROOT"] = root.path
            }
        }
        if environment["GOPATH"] == nil {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let roots = [
                home.appendingPathComponent("go"),
                home.appendingPathComponent("Repository/gopath")
            ]
            if let root = roots.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                environment["GOPATH"] = root.path
            }
        }
        return environment
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
