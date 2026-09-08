import Foundation
import LitheCoreContracts

/// Passive Go preparation for one metadata refresh.
///
/// Like the Cargo preparer, this adapter never launches a process: it plans
/// staged `go` commands and freezes file identities so `validate()` can prove
/// nothing changed mid-refresh. The staging exists because the package-list
/// commands depend on earlier rounds: the workspace must be located before the
/// host knows how many `go list -e -json ./...` commands to run, or which
/// directories they run in.
///
/// Workspace-mode package listing writes `go.work.sum` next to the go.work it
/// resolves, so when a go.work exists the preparer immediately creates a
/// byte-faithful isolated copy (B7a2c3) and every workspace command after the
/// location round resolves through it. The single-module path needs no copy:
/// `GOWORK=off` keeps the module directory untouched.
struct MacGoMetadataPreparer: ProjectMetadataNativePreparing {
    func prepare(_ request: CargoMetadataPreparationRequest) throws -> any ProjectMetadataNativeSession {
        let manifest = try ProjectToolFileIdentity.regularFile(at: request.manifestURL, role: "go.mod")
        let workspaceURL = request.workspaceURL.resolvingSymlinksInPath().standardizedFileURL

        // A cache or module root inside the workspace would turn a metadata
        // read into a workspace write no matter which flags are pinned, so it
        // is rejected instead of silently redirected.
        let workspacePrefix = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        for name in ["GOMODCACHE", "GOCACHE", "GOPATH"] {
            guard let value = request.environment[name], !value.isEmpty else { continue }
            let resolved = URL(fileURLWithPath: value)
                .resolvingSymlinksInPath().standardizedFileURL.path
            if resolved == workspaceURL.path || resolved.hasPrefix(workspacePrefix) {
                throw ProjectMetadataFailure.invalidInput(
                    message: name
                        + " points inside the project, so a metadata read could write there."
                        + " Move it outside the workspace and refresh Go again."
                )
            }
        }

        // An explicit user choice is authoritative: if it is unusable the refresh
        // fails instead of quietly falling back to a different toolchain.
        let go: ProjectToolFileIdentity
        if let custom = request.customCargoURL {
            go = try ProjectToolFileIdentity.nativeExecutable(at: custom, role: "the configured Go")
        } else {
            go = try firstUsableExecutable(request.cargoCandidates, role: "Go")
        }

        let environment = GoMetadataEnvironment.make(from: request.environment)
        var goWork: ProjectToolFileIdentity?
        var isolation: MacGoWorkspaceIsolation?
        var useManifests: [ProjectToolFileIdentity] = []
        var useDirectories: [URL] = []
        let goWorkURL = workspaceURL.appendingPathComponent("go.work")
        if FileManager.default.fileExists(atPath: goWorkURL.path) {
            goWork = try ProjectToolFileIdentity.regularFile(at: goWorkURL, role: "go.work")
            isolation = try MacGoWorkspaceIsolation.create(workspaceURL: workspaceURL, sourceGoWorkURL: goWorkURL)
            // Every use module's manifest is frozen at preparation time, so no
            // edit made after the refresh started can silently become the new
            // baseline. The work-edit round later has to agree with this list.
            useDirectories = try MacGoWorkspaceIsolation.useDirectories(sourceGoWorkURL: goWorkURL)
            for directory in useDirectories {
                useManifests.append(try ProjectToolFileIdentity.regularFile(
                    at: directory.appendingPathComponent("go.mod"), role: "a use module's go.mod"
                ))
            }
        }
        return MacGoMetadataSession(
            workspaceURL: workspaceURL,
            manifestDirectory: manifest.resolvedURL.deletingLastPathComponent(),
            manifest: manifest,
            goWork: goWork,
            go: go,
            environment: environment,
            isolation: isolation,
            useDirectories: useDirectories,
            useManifests: useManifests
        )
    }

    private func firstUsableExecutable(_ candidates: [URL], role: String) throws -> ProjectToolFileIdentity {
        var lastFailure: Error?
        for candidate in candidates {
            do { return try ProjectToolFileIdentity.nativeExecutable(at: candidate, role: role) }
            catch { lastFailure = error }
        }
        if let lastFailure, !candidates.isEmpty { throw lastFailure }
        throw ProjectMetadataFailure.invalidInput(
            message: "\(role) was not found. Install it or set its path in the project's tool settings."
        )
    }
}

/// One refresh's staged Go capture plan. Created immutable; identities for
/// modules discovered by the `go work edit` round are frozen when that round's
/// output arrives. The feature model calls every method on one serial worker;
/// the lock defends the `Sendable` contract, not a concurrency strategy.
private final class MacGoMetadataSession: ProjectMetadataNativeSession, ProjectMetadataSessionCleaning,
    @unchecked Sendable {
    private enum Mode {
        case workspace
        case singleModule
    }

    private enum State {
        case locating
        case staged(Mode)
    }

    private let lock = NSLock()
    private let workspaceURL: URL
    private let manifestDirectory: URL
    private let manifest: ProjectToolFileIdentity
    private let goWork: ProjectToolFileIdentity?
    private let go: ProjectToolFileIdentity
    /// Whitelist plus fixed flags; `GOWORK` is added per command, never inherited.
    private let environment: [String: String]
    private let isolation: MacGoWorkspaceIsolation?

    private var state: State = .locating
    private var moduleDirectories: [URL] = []
    /// Frozen at preparation from the go.work text; `go work edit -json` must
    /// agree with this list before any package capture is planned.
    private let frozenUseManifests: [ProjectToolFileIdentity]
    private let frozenUseDirectories: [URL]
    private var modulesOutput: Data?

    init(
        workspaceURL: URL, manifestDirectory: URL, manifest: ProjectToolFileIdentity,
        goWork: ProjectToolFileIdentity?, go: ProjectToolFileIdentity,
        environment: [String: String], isolation: MacGoWorkspaceIsolation?,
        useDirectories: [URL], useManifests: [ProjectToolFileIdentity]
    ) {
        self.workspaceURL = workspaceURL
        self.manifestDirectory = manifestDirectory
        self.manifest = manifest
        self.goWork = goWork
        self.go = go
        self.environment = environment
        self.isolation = isolation
        self.frozenUseDirectories = useDirectories
        self.frozenUseManifests = useManifests
    }

    deinit {
        // Safety net only. The owning feature model deletes the isolation copy
        // on every exit path so the diagnostic from a failed deletion stays visible.
        isolation?.cleanup()
    }

    var initialStage: ProjectMetadataCaptureStage {
        ProjectMetadataCaptureStage(id: "go-locate", commands: [
            ProjectMetadataCommand(
                executablePath: go.resolvedURL.path,
                arguments: ["env", "-json", "GOWORK", "GOMOD"],
                workingDirectory: workspaceURL.path,
                environment: environment
            )
        ])
    }

    func advance(
        stage: ProjectMetadataCaptureStage, outputs: [Data]
    ) throws -> ProjectMetadataStageOutcome {
        guard outputs.count == stage.commands.count else {
            throw ProjectMetadataFailure.invalidInput(
                message: "Go metadata capture outputs do not match the issued command plan."
            )
        }
        lock.lock()
        defer { lock.unlock() }
        switch (state, stage.id) {
        case (.locating, "go-locate"):
            return try advanceLocation(outputs[0])
        case (.staged(.workspace), "go-work"):
            return try advanceWorkspace(outputs[0])
        case (.staged, "go-modules"):
            return try advanceModules(outputs[0])
        case (.staged, "go-packages"):
            return try finishPackages(outputs)
        default:
            throw ProjectMetadataFailure.invalidInput(
                message: "Go metadata received a stage it did not issue."
            )
        }
    }

    func normalizationInput(_ source: ProjectMetadataNormalizationSource) throws
        -> ProjectMetadataNativeInput {
        lock.lock()
        defer { lock.unlock() }
        switch source {
        case .cargo:
            throw ProjectMetadataFailure.invalidInput(
                message: "Go metadata cannot normalize Cargo captures."
            )
        case .go:
            return ProjectMetadataNativeInput(
                workspaceDirectory: workspaceURL.path,
                roots: try roots()
            )
        }
    }

    func validate() throws {
        lock.lock()
        defer { lock.unlock() }
        try manifest.validate(role: "go.mod")
        try go.validate(role: "Go")
        try goWork?.validate(role: "go.work")
        for (index, useManifest) in frozenUseManifests.enumerated() {
            try useManifest.validate(role: "the go.mod of use module \(index + 1)")
        }
    }

    // MARK: Stage transitions

    /// Deletes the isolated workspace copy, conforming to
    /// `ProjectMetadataSessionCleaning`. Every owner exit path — cancel,
    /// timeout, failure, project close and completion — must call this through
    /// the protocol; the returned diagnostic is nonempty when deletion failed
    /// visibly. The deinit below is only a last-resort safety net.
    func cleanupSessionResources() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return isolation?.cleanup()
    }

    /// `go env -json GOWORK GOMOD` decides the mode. The discovered workspace
    /// must be the go.work this refresh froze; anything else means the tree
    /// changed mid-refresh or the selection was wrong.
    private func advanceLocation(_ output: Data) throws -> ProjectMetadataStageOutcome {
        let document: GoEnvDocument
        do { document = try JSONDecoder().decode(GoEnvDocument.self, from: output) }
        catch {
            throw ProjectMetadataFailure.invalidInput(message: "go env output was not valid JSON.")
        }
        if document.GOWORK.isEmpty {
            guard goWork == nil else {
                throw ProjectMetadataFailure.invalidInput(
                    message: "go.work exists but Go did not select it. Refresh Go metadata again."
                )
            }
            state = .staged(.singleModule)
            return .more(modulesStage(mode: .singleModule))
        }
        let discovered = URL(fileURLWithPath: document.GOWORK).resolvingSymlinksInPath().standardizedFileURL
        guard let goWork, discovered.path == goWork.resolvedURL.path, isolation != nil else {
            throw ProjectMetadataFailure.invalidInput(
                message: "Go selected a workspace outside the refreshed project. Refresh Go metadata again."
            )
        }
        state = .staged(.workspace)
        return .more(workspaceStage())
    }

    /// The `go work edit -json` round must name exactly the module set that
    /// was frozen from the go.work text at preparation time. A different set
    /// means the workspace changed mid-refresh, so nothing captured after it
    /// can be trusted.
    private func advanceWorkspace(_ output: Data) throws -> ProjectMetadataStageOutcome {
        let document: GoWorkDocument
        do { document = try JSONDecoder().decode(GoWorkDocument.self, from: output) }
        catch {
            throw ProjectMetadataFailure.invalidInput(message: "go work edit output was not valid JSON.")
        }
        guard (1...512).contains(document.Use.count) else {
            throw ProjectMetadataFailure.invalidInput(
                message: "The Go workspace lists \(document.Use.count) modules; at most 512 are supported."
            )
        }
        var directories: [URL] = []
        for entry in document.Use {
            directories.append(
                URL(fileURLWithPath: entry.DiskPath, relativeTo: workspaceURL)
                    .resolvingSymlinksInPath().standardizedFileURL
            )
        }
        let frozen = Set(frozenUseDirectories.map(\.path))
        guard directories.count == frozenUseDirectories.count,
              Set(directories.map(\.path)) == frozen else {
            throw ProjectMetadataFailure.invalidInput(
                message: "The Go workspace's module list changed during the refresh. Refresh Go again."
            )
        }
        moduleDirectories = directories
        return .more(modulesStage(mode: .workspace))
    }

    private func advanceModules(_ output: Data) throws -> ProjectMetadataStageOutcome {
        modulesOutput = output
        return .more(packagesStage())
    }

    private func finishPackages(_ outputs: [Data]) throws -> ProjectMetadataStageOutcome {
        guard let modulesOutput else {
            throw ProjectMetadataFailure.invalidInput(
                message: "Go metadata package capture ran before the module list."
            )
        }
        return .done(.go(modules: modulesOutput, packages: outputs))
    }

    // MARK: Stage plans

    /// The module list never runs at the go.work root through the isolated
    /// copy — the root is not a module — and the single-module variant uses
    /// `GOWORK=off` so a missing go.sum surfaces as a package-level error
    /// instead of any write.
    private func modulesStage(mode: Mode) -> ProjectMetadataCaptureStage {
        let workingDirectory: String
        var environment = self.environment
        switch mode {
        case .workspace:
            workingDirectory = workspaceURL.path
            if let goWork { environment["GOWORK"] = goWork.resolvedURL.path }
        case .singleModule:
            workingDirectory = manifestDirectory.path
            environment["GOWORK"] = "off"
        }
        return ProjectMetadataCaptureStage(id: "go-modules", commands: [
            command(arguments: ["list", "-m", "-json"], workingDirectory: workingDirectory, environment: environment)
        ])
    }

    /// One package list per module directory — never one at the go.work root —
    /// resolving through the isolated go.work copy so a `go.work.sum` write
    /// lands in the host's temporary directory.
    private func packagesStage() -> ProjectMetadataCaptureStage {
        var environment = self.environment
        let directories: [URL]
        switch state {
        case .staged(.workspace):
            environment["GOWORK"] = isolation?.goWorkURL.path ?? "off"
            directories = moduleDirectories
        default:
            environment["GOWORK"] = "off"
            directories = [manifestDirectory]
        }
        let commands = directories.map { directory in
            command(
                arguments: ["list", "-e", "-json", "./..."],
                workingDirectory: directory.path,
                environment: environment
            )
        }
        return ProjectMetadataCaptureStage(id: "go-packages", commands: commands)
    }

    private func workspaceStage() -> ProjectMetadataCaptureStage {
        ProjectMetadataCaptureStage(id: "go-work", commands: [
            command(
                arguments: ["work", "edit", "-json"],
                workingDirectory: workspaceURL.path,
                environment: environment
            )
        ])
    }

    private func command(
        arguments: [String], workingDirectory: String, environment: [String: String]
    ) -> ProjectMetadataCommand {
        ProjectMetadataCommand(
            executablePath: go.resolvedURL.path,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }

    /// Authorizes the workspace plus only the use-module directories that live
    /// outside it, mirroring the Cargo preparer's root policy: no ancestor is
    /// mapped by accident and `/` is never mapped.
    private func roots() throws -> [ProjectMetadataRoot] {
        let workspacePrefix = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        var external: Set<String> = []
        for directory in moduleDirectories where directory.path != workspaceURL.path
            && !directory.path.hasPrefix(workspacePrefix) {
            guard directory.path != "/" else {
                throw ProjectMetadataFailure.invalidInput(
                    message: "The Go workspace referenced the filesystem root, which cannot be authorized."
                )
            }
            external.insert(directory.path)
        }
        var roots = [ProjectMetadataRoot(id: "workspace", path: workspaceURL.path)]
        for (index, path) in external.sorted().enumerated() {
            _ = try ProjectToolFileIdentity.existing(at: URL(fileURLWithPath: path), role: "a Go module directory")
            roots.append(ProjectMetadataRoot(id: "external\(index + 1)", path: path))
        }
        return roots
    }
}

/// Built from an empty dictionary: only the variables Go needs to find its own
/// cache, toolchain and proxy configuration are copied, and the toolchain,
/// proxy and sum database are pinned off so a metadata read can never fetch or
/// write. Inherited `GOFLAGS` is overridden rather than extended; credentials
/// and proxy bypass variables never reach a metadata read.
private enum GoMetadataEnvironment {
    private static let allowed = [
        "HOME", "PATH", "GOMODCACHE", "GOPATH", "GOCACHE"
    ]

    static func make(from inherited: [String: String]) -> [String: String] {
        var environment: [String: String] = [:]
        for name in allowed {
            guard let value = inherited[name], !value.contains("\0") else { continue }
            environment[name] = value
        }
        // GOENV=off makes the process environment the only configuration
        // source: values a user once saved with `go env -w` (proxy bypass,
        // cache programs) must not resurrect themselves behind the whitelist.
        environment["GOENV"] = "off"
        environment["GOTOOLCHAIN"] = "local"
        environment["GOFLAGS"] = "-mod=readonly"
        environment["GOPROXY"] = "off"
        environment["GOSUMDB"] = "off"
        return environment
    }
}

/// Only the fields the staged plan reads. `GOWORK` empty means no go.work was
/// selected from the working directory.
private struct GoEnvDocument: Decodable {
    let GOWORK: String
    let GOMOD: String
}

/// Only the `Use` entries the staged plan needs; `Replace` and toolchain
/// fields stay in the captured output for the normalizer.
private struct GoWorkDocument: Decodable {
    struct Use: Decodable {
        let DiskPath: String
    }
    let Use: [Use]
}
