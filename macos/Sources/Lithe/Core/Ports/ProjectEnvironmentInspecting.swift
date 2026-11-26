import Foundation

/// A resolved third-party or workspace dependency displayed in External Libraries
/// and in Go Tools / Cargo / Language Settings panels.
struct ProjectDependencyItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String
    let isDirect: Bool
    let replaceTarget: String?
    let sourceDirectoryURL: URL?
    let manifestURL: URL?

    var displaySubtitle: String {
        if let replaceTarget, !replaceTarget.isEmpty {
            return version.isEmpty ? "→ \(replaceTarget)" : "\(version) → \(replaceTarget)"
        }
        return version
    }
}

/// One lazy-loaded child row inside an External Libraries directory tree.
struct ExternalLibraryFileEntry: Identifiable, Equatable, Hashable, Sendable {
    var id: String { url.standardizedFileURL.path }
    let name: String
    let url: URL
    let isDirectory: Bool
}

struct GoProjectEnvironmentSnapshot: Equatable, Sendable {
    let executablePath: String?
    let version: String?
    let goRoot: String?
    let goPath: String?
    let goModCache: String?
    let goProxy: String?
    let goPrivate: String?
    let stdLibURL: URL?
    let moduleName: String?
    let goDirective: String?
    let manifestURL: URL?
    let dependencies: [ProjectDependencyItem]

    var directDependencies: [ProjectDependencyItem] {
        dependencies.filter(\.isDirect)
    }

    var indirectDependencies: [ProjectDependencyItem] {
        dependencies.filter { !$0.isDirect }
    }
}

struct RustProjectEnvironmentSnapshot: Equatable, Sendable {
    let cargoPath: String?
    let rustcPath: String?
    let rustcVersion: String?
    let activeToolchain: String?
    let cargoHome: String?
    let rustupHome: String?
    let sysrootPath: String?
    let stdLibURL: URL?
    let crateName: String?
    let manifestURL: URL?
    let dependencies: [ProjectDependencyItem]
}

struct PythonProjectEnvironmentSnapshot: Equatable, Sendable {
    let executablePath: String?
    let version: String?
    let prefixPath: String?
    let basePrefixPath: String?
    let isVirtualEnvironment: Bool
    let virtualEnvName: String?
    let stdLibURL: URL?
    let sitePackagesURLs: [URL]
    let pythonPath: String?
    let manifestURL: URL?
    let dependencies: [ProjectDependencyItem]
}

struct ProjectEnvironmentSnapshot: Equatable, Sendable {
    var go: GoProjectEnvironmentSnapshot?
    var rust: RustProjectEnvironmentSnapshot?
    var python: PythonProjectEnvironmentSnapshot?

    var isEmpty: Bool {
        go == nil && rust == nil && python == nil
    }
}

/// Platform-neutral port for bounded Go / Rust / Python SDK, environment,
/// dependency cache, and lazy External Libraries directory inspection.
protocol ProjectEnvironmentInspecting: Sendable {
    func inspectGo(
        workspaceURL: URL,
        manifestURL: URL?,
        executableURL: URL?,
        environment: [String: String],
        operationID: String
    ) -> GoProjectEnvironmentSnapshot

    func inspectRust(
        workspaceURL: URL,
        manifestURL: URL?,
        cargoURL: URL?,
        environment: [String: String],
        operationID: String
    ) -> RustProjectEnvironmentSnapshot

    func inspectPython(
        workspaceURL: URL,
        manifestURL: URL?,
        pythonURL: URL?,
        environment: [String: String],
        operationID: String
    ) -> PythonProjectEnvironmentSnapshot

    func cancelInspection(operationID: String)
    func listDirectory(at url: URL) -> [ExternalLibraryFileEntry]
}

extension ProjectEnvironmentInspecting {
    func cancelInspection(operationID _: String) {}
}

struct UnavailableProjectEnvironmentInspector: ProjectEnvironmentInspecting {
    func inspectGo(
        workspaceURL: URL,
        manifestURL: URL?,
        executableURL: URL?,
        environment: [String: String],
        operationID _: String = ""
    ) -> GoProjectEnvironmentSnapshot {
        GoProjectEnvironmentSnapshot(
            executablePath: executableURL?.path,
            version: nil,
            goRoot: environment["GOROOT"],
            goPath: environment["GOPATH"],
            goModCache: environment["GOMODCACHE"],
            goProxy: environment["GOPROXY"],
            goPrivate: environment["GOPRIVATE"],
            stdLibURL: nil,
            moduleName: nil,
            goDirective: nil,
            manifestURL: manifestURL,
            dependencies: []
        )
    }

    func inspectRust(
        workspaceURL: URL,
        manifestURL: URL?,
        cargoURL: URL?,
        environment: [String: String],
        operationID _: String = ""
    ) -> RustProjectEnvironmentSnapshot {
        RustProjectEnvironmentSnapshot(
            cargoPath: cargoURL?.path,
            rustcPath: nil,
            rustcVersion: nil,
            activeToolchain: environment["RUSTUP_TOOLCHAIN"],
            cargoHome: environment["CARGO_HOME"],
            rustupHome: environment["RUSTUP_HOME"],
            sysrootPath: nil,
            stdLibURL: nil,
            crateName: nil,
            manifestURL: manifestURL,
            dependencies: []
        )
    }

    func inspectPython(
        workspaceURL: URL,
        manifestURL: URL?,
        pythonURL: URL?,
        environment: [String: String],
        operationID _: String = ""
    ) -> PythonProjectEnvironmentSnapshot {
        PythonProjectEnvironmentSnapshot(
            executablePath: pythonURL?.path,
            version: nil,
            prefixPath: environment["VIRTUAL_ENV"],
            basePrefixPath: nil,
            isVirtualEnvironment: environment["VIRTUAL_ENV"] != nil,
            virtualEnvName: environment["VIRTUAL_ENV"].map { URL(fileURLWithPath: $0).lastPathComponent },
            stdLibURL: nil,
            sitePackagesURLs: [],
            pythonPath: environment["PYTHONPATH"],
            manifestURL: manifestURL,
            dependencies: []
        )
    }

    func listDirectory(at _: URL) -> [ExternalLibraryFileEntry] { [] }
}
