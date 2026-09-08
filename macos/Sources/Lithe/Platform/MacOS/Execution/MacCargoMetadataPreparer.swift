import Foundation
import LitheCoreContracts

/// Passive Cargo preparation for one metadata refresh.
///
/// This adapter never launches a process: it only inspects the filesystem and
/// returns command plans that the Rust language module executes through its own
/// capture session. Everything it records is frozen at preparation time so a
/// later `validate()` can prove the tools and files did not change mid-refresh.
struct MacCargoMetadataPreparer: ProjectMetadataNativePreparing {
    func prepare(_ request: CargoMetadataPreparationRequest) throws -> any ProjectMetadataNativeSession {
        let manifest = try ProjectToolFileIdentity.regularFile(at: request.manifestURL, role: "Cargo.toml")
        let workingDirectory = request.manifestURL.deletingLastPathComponent().standardizedFileURL

        // An explicit user choice is authoritative: if it is unusable the refresh
        // fails instead of quietly falling back to a different toolchain.
        let cargo: ProjectToolFileIdentity
        if let custom = request.customCargoURL {
            cargo = try ProjectToolFileIdentity.nativeExecutable(at: custom, role: "the configured Cargo")
        } else {
            cargo = try firstUsableExecutable(request.cargoCandidates, role: "Cargo")
        }

        let rustup = try rustupProxy(for: cargo, candidates: request.rustupCandidates)
        let environment = CargoMetadataEnvironment.make(from: request.environment)
        return MacCargoMetadataSession(
            workspaceURL: request.workspaceURL.standardizedFileURL,
            manifestURL: request.manifestURL.standardizedFileURL,
            manifest: manifest,
            workingDirectory: workingDirectory,
            cargo: cargo,
            rustupProxy: rustup,
            environment: environment
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

    /// rustup installs its proxies as hard links to, or symlinks of, the rustup
    /// binary. Detecting that is what decides whether the real toolchain still
    /// has to be resolved before `cargo metadata` may run.
    private func rustupProxy(
        for cargo: ProjectToolFileIdentity, candidates: [URL]
    ) throws -> ProjectToolFileIdentity? {
        let rustups = candidates.compactMap { try? ProjectToolFileIdentity.nativeExecutable(at: $0, role: "rustup") }
        if cargo.resolvedURL.lastPathComponent == "rustup" {
            return rustups.first { $0.isSameFile(as: cargo) } ?? cargo
        }
        guard let linked = rustups.first(where: { $0.isSameFile(as: cargo) }) else { return nil }
        return linked
    }
}

/// Immutable for the whole refresh. The feature model calls every method on one
/// serial worker, so no method mutates state and the identities stay comparable.
///
/// The staged adaptation keeps the historical two-phase sequence byte for byte:
/// the optional rustup resolution round, then the single `cargo metadata`
/// command built from its outputs.
private struct MacCargoMetadataSession: ProjectMetadataNativeSession {
    private static let resolutionStageID = "cargo-resolution"
    private static let metadataStageID = "cargo-metadata"

    let workspaceURL: URL
    let manifestURL: URL
    let manifest: ProjectToolFileIdentity
    let workingDirectory: URL
    let cargo: ProjectToolFileIdentity
    let rustupProxy: ProjectToolFileIdentity?
    let environment: [String: String]

    var initialStage: ProjectMetadataCaptureStage {
        guard let rustupProxy else {
            return ProjectMetadataCaptureStage(id: Self.resolutionStageID, commands: [])
        }
        // Both proxies are asked in one plan so the pair can be checked against
        // each other; RUSTUP_AUTO_INSTALL=0 keeps a missing toolchain an error
        // rather than a silent download.
        let commands = ["cargo", "rustc"].map { tool in
            ProjectMetadataCommand(
                executablePath: rustupProxy.resolvedURL.path,
                arguments: ["which", tool],
                workingDirectory: workingDirectory.path,
                environment: environment
            )
        }
        return ProjectMetadataCaptureStage(id: Self.resolutionStageID, commands: commands)
    }

    func advance(
        stage: ProjectMetadataCaptureStage, outputs: [Data]
    ) throws -> ProjectMetadataStageOutcome {
        guard outputs.count == stage.commands.count else {
            throw ProjectMetadataFailure.invalidInput(
                message: "Cargo metadata capture outputs do not match the issued command plan."
            )
        }
        switch stage.id {
        case Self.resolutionStageID:
            let command = try metadataCommand(resolutionOutputs: outputs)
            return .more(ProjectMetadataCaptureStage(id: Self.metadataStageID, commands: [command]))
        case Self.metadataStageID:
            guard let output = outputs.first else {
                throw ProjectMetadataFailure.invalidInput(
                    message: "Cargo metadata capture produced no metadata output."
                )
            }
            return .done(.cargo(output))
        default:
            throw ProjectMetadataFailure.invalidInput(
                message: "Cargo metadata received a stage it did not issue."
            )
        }
    }

    func normalizationInput(_ source: ProjectMetadataNormalizationSource) throws
        -> ProjectMetadataNativeInput {
        switch source {
        case .cargo(let metadata):
            return try normalizationInput(metadata: metadata)
        case .go:
            throw ProjectMetadataFailure.invalidInput(
                message: "Cargo metadata cannot normalize Go captures."
            )
        }
    }

    func validate() throws {
        try manifest.validate(role: "Cargo.toml")
        try cargo.validate(role: "Cargo")
        try rustupProxy?.validate(role: "rustup")
    }

    private func metadataCommand(resolutionOutputs: [Data]) throws -> ProjectMetadataCommand {
        let executable: ProjectToolFileIdentity
        if rustupProxy == nil {
            guard resolutionOutputs.isEmpty else {
                throw ProjectMetadataFailure.invalidInput(
                    message: "Cargo toolchain resolution returned unexpected output."
                )
            }
            executable = cargo
        } else {
            guard resolutionOutputs.count == 2 else {
                throw ProjectMetadataFailure.invalidInput(
                    message: "Cargo toolchain resolution did not return both tool paths."
                )
            }
            let resolvedCargo = try ProjectToolFileIdentity.nativeExecutable(
                at: try singlePath(resolutionOutputs[0], role: "cargo"), role: "the resolved Cargo"
            )
            let resolvedRustc = try ProjectToolFileIdentity.nativeExecutable(
                at: try singlePath(resolutionOutputs[1], role: "rustc"), role: "the resolved rustc"
            )
            guard resolvedCargo.resolvedURL.deletingLastPathComponent()
                == resolvedRustc.resolvedURL.deletingLastPathComponent() else {
                throw ProjectMetadataFailure.invalidInput(
                    message: "The resolved Cargo and rustc do not belong to the same toolchain."
                )
            }
            executable = resolvedCargo
        }
        try executable.validate(role: "Cargo")
        return ProjectMetadataCommand(
            executablePath: executable.resolvedURL.path,
            arguments: [
                "metadata", "--format-version", "1", "--no-deps", "--frozen",
                "--color", "never", "--manifest-path", manifestURL.path
            ],
            workingDirectory: workingDirectory.path,
            environment: environment
        )
    }

    /// Authorizes only what the typed metadata actually referenced. Everything
    /// inside the host workspace is covered by the single workspace root; each
    /// remaining location is mapped on its own so no ancestor is authorized by
    /// accident, and `/` is never mapped.
    private func roots(directories: Set<String>, files: Set<String>) throws -> [ProjectMetadataRoot] {
        let workspacePrefix = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        var external: Set<String> = []
        for path in directories.union(files) where path != workspaceURL.path && !path.hasPrefix(workspacePrefix) {
            guard path != "/" else {
                throw ProjectMetadataFailure.invalidInput(
                    message: "Cargo metadata referenced the filesystem root, which cannot be authorized."
                )
            }
            external.insert(path)
        }
        // A file only needs its own mapping when its directory is not mapped.
        let externalDirectories = external.filter { directories.contains($0) }
        let mapped = externalDirectories.union(external.filter { path in
            !externalDirectories.contains(where: { path.hasPrefix($0 + "/") })
        })
        var roots = [ProjectMetadataRoot(id: "workspace", path: workspaceURL.path)]
        for (index, path) in mapped.sorted().enumerated() {
            _ = try ProjectToolFileIdentity.existing(at: URL(fileURLWithPath: path), role: "a Cargo workspace location")
            roots.append(ProjectMetadataRoot(id: "external\(index + 1)", path: path))
        }
        return roots
    }

    private func normalizationInput(metadata: Data) throws -> ProjectMetadataNativeInput {
        let document: CargoMetadataDocument
        do { document = try JSONDecoder().decode(CargoMetadataDocument.self, from: metadata) }
        catch {
            throw ProjectMetadataFailure.invalidInput(message: "Cargo metadata was not valid JSON.")
        }
        let members = Set(document.workspaceMembers)
        let workspacePackages = document.packages.filter { members.contains($0.id) }
        guard !workspacePackages.isEmpty else {
            throw ProjectMetadataFailure.invalidInput(message: "Cargo metadata reported no workspace members.")
        }
        // The manifest the user picked has to be the workspace root or one of its
        // members; anything else means the returned workspace is not the one the
        // refresh asked for.
        let manifestPaths = workspacePackages.map { standardized($0.manifestPath) }
        guard manifestPaths.contains(manifestURL.path)
            || standardized(document.workspaceRoot + "/Cargo.toml") == manifestURL.path else {
            throw ProjectMetadataFailure.invalidInput(
                message: "Cargo returned a workspace that does not contain the selected manifest."
            )
        }

        var directories: Set<String> = [standardized(document.workspaceRoot)]
        var files: Set<String> = []
        for package in workspacePackages {
            let manifestPath = standardized(package.manifestPath)
            files.insert(manifestPath)
            directories.insert((manifestPath as NSString).deletingLastPathComponent)
            for target in package.targets { files.insert(standardized(target.srcPath)) }
            for dependency in package.dependencies {
                guard let path = dependency.path else { continue }
                directories.insert(standardized(path))
            }
        }
        return ProjectMetadataNativeInput(
            workspaceDirectory: workspaceURL.path,
            roots: try roots(directories: directories, files: files)
        )
    }

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// rustup's `which` prints exactly one absolute path. Anything else means the
    /// output cannot be trusted to name a toolchain.
    private func singlePath(_ output: Data, role: String) throws -> URL {
        guard let text = String(data: output, encoding: .utf8) else {
            throw ProjectMetadataFailure.invalidInput(
                message: "The resolved \(role) path was not valid UTF-8."
            )
        }
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }
        guard lines.count == 1, lines[0].hasPrefix("/") else {
            throw ProjectMetadataFailure.invalidInput(
                message: "The resolved \(role) path was not a single absolute path."
            )
        }
        return URL(fileURLWithPath: String(lines[0]))
    }
}

/// A file plus the identity fields that prove it is still the same file later.
/// Shared by the project tool preparers; the role names appear in failures.
struct ProjectToolFileIdentity: Sendable {
    let sourceURL: URL
    let resolvedURL: URL
    let device: Int
    let inode: UInt64
    let size: Int
    let modified: TimeInterval

    static func existing(at url: URL, role: String) throws -> ProjectToolFileIdentity {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path) else {
            throw ProjectMetadataFailure.invalidInput(message: "Could not read \(role) at \(resolved.path).")
        }
        return ProjectToolFileIdentity(
            sourceURL: url.standardizedFileURL, resolvedURL: resolved,
            device: (attributes[.systemNumber] as? Int) ?? -1,
            inode: (attributes[.systemFileNumber] as? UInt64) ?? 0,
            size: (attributes[.size] as? Int) ?? -1,
            modified: (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        )
    }

    static func regularFile(at url: URL, role: String) throws -> ProjectToolFileIdentity {
        let identity = try existing(at: url, role: role)
        let attributes = try FileManager.default.attributesOfItem(atPath: identity.resolvedURL.path)
        // A FIFO/socket/device is not a tool or manifest. In particular, opening
        // a FIFO to inspect its executable header would block a worker forever.
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ProjectMetadataFailure.invalidInput(message: "\(role) is not a regular file.")
        }
        return identity
    }

    /// Only a real Mach-O image is accepted. A script shim would run an
    /// interpreter the host never inspected, so it is rejected rather than
    /// executed on the user's behalf.
    static func nativeExecutable(at url: URL, role: String) throws -> ProjectToolFileIdentity {
        let identity = try regularFile(at: url, role: role)
        guard FileManager.default.isExecutableFile(atPath: identity.resolvedURL.path) else {
            throw ProjectMetadataFailure.invalidInput(message: "\(role) is not executable.")
        }
        guard let handle = FileHandle(forReadingAtPath: identity.resolvedURL.path) else {
            throw ProjectMetadataFailure.invalidInput(message: "Could not read \(role).")
        }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        guard magic.count == 4, machOMagics.contains(magic) else {
            throw ProjectMetadataFailure.invalidInput(
                message: "\(role) is not a native executable. Select the real tool instead of a wrapper script."
            )
        }
        return identity
    }

    func isSameFile(as other: ProjectToolFileIdentity) -> Bool {
        device == other.device && inode == other.inode && device != -1
    }

    func validate(role: String) throws {
        let current = try Self.existing(at: sourceURL, role: role)
        guard current.resolvedURL == resolvedURL, current.isSameFile(as: self), current.size == size, current.modified == modified else {
            throw ProjectMetadataFailure.invalidInput(
                message: "\(role) changed during the refresh. Refresh the project metadata again."
            )
        }
    }

    private static let machOMagics: Set<Data> = [
        Data([0xCF, 0xFA, 0xED, 0xFE]), Data([0xCE, 0xFA, 0xED, 0xFE]),
        Data([0xFE, 0xED, 0xFA, 0xCF]), Data([0xFE, 0xED, 0xFA, 0xCE]),
        Data([0xCA, 0xFE, 0xBA, 0xBE]), Data([0xBE, 0xBA, 0xFE, 0xCA])
    ]
}

/// Built from an empty dictionary: only the variables Cargo needs to find its
/// own configuration and registry index are copied. Compiler wrappers, dynamic
/// loader controls, credentials and Run-configuration variables never reach a
/// metadata read.
private enum CargoMetadataEnvironment {
    private static let allowed = [
        "HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
        "CARGO_HOME", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN", "SSL_CERT_FILE", "SSL_CERT_DIR"
    ]

    static func make(from inherited: [String: String]) -> [String: String] {
        var environment: [String: String] = [:]
        for name in allowed {
            guard let value = inherited[name], !value.contains("\0") else { continue }
            environment[name] = value
        }
        environment["CARGO_TERM_COLOR"] = "never"
        environment["RUSTUP_AUTO_INSTALL"] = "0"
        return environment
    }
}

/// Only the fields root authorization reads. Unknown members are ignored by the
/// decoder; the Rust Core still validates the full document separately.
private struct CargoMetadataDocument: Decodable {
    struct Package: Decodable {
        struct Target: Decodable {
            let srcPath: String
            enum CodingKeys: String, CodingKey { case srcPath = "src_path" }
        }
        struct Dependency: Decodable {
            let path: String?
        }
        let id: String
        let manifestPath: String
        let targets: [Target]
        let dependencies: [Dependency]
        enum CodingKeys: String, CodingKey {
            case id, targets, dependencies
            case manifestPath = "manifest_path"
        }
    }
    let packages: [Package]
    let workspaceMembers: [String]
    let workspaceRoot: String
    enum CodingKeys: String, CodingKey {
        case packages
        case workspaceMembers = "workspace_members"
        case workspaceRoot = "workspace_root"
    }
}
