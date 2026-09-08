import Foundation
import LitheCoreContracts
import Testing

@testable import Lithe

/// Unit coverage for the staged project-metadata preparers, which plan `go`
/// and `cargo` commands without launching processes. The staged protocol
/// exists so Go can decide its package-list round count from the workspace
/// round; the Cargo session must keep emitting its historical two-phase
/// sequence byte for byte through the same protocol. Process capture, Rust
/// normalization and GUI behavior are covered elsewhere.
struct ProjectMetadataPreparationTests {
    private let home = "/Users/test"
    private let fakeEnvironment = [
        "HOME": "/Users/test",
        "GOFLAGS": "-mod=mod",
        "GOPRIVATE": "corp.example",
        "GONOSUMDB": "off"
    ]

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-preparation-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A file with a Mach-O magic number and the executable bit: enough to
    /// pass native identity freezing, which is all these tests exercise.
    private func writeFakeExecutable(_ url: URL) throws {
        try write("not really mach-o", to: url)
        let magic = Data([0xCF, 0xFA, 0xED, 0xFE]) + Data(repeating: 0, count: 16)
        try magic.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }

    private func goRequest(workspaceURL: URL, manifestURL: URL, goURL: URL) -> CargoMetadataPreparationRequest {
        CargoMetadataPreparationRequest(
            workspaceURL: workspaceURL, manifestURL: manifestURL, workspaceGeneration: 1,
            cargoCandidates: [goURL], rustupCandidates: [], customCargoURL: nil,
            environment: fakeEnvironment,
            deadline: ContinuousClock().now.advanced(by: .seconds(30))
        )
    }

    /// The frozen environment is exactly the whitelist plus the pinned flags:
    /// inherited `GOFLAGS` is overridden, not extended, and proxy bypass or
    /// credential variables never reach a metadata read.
    private func assertPinnedFlags(_ environment: [String: String]) {
        #expect(environment["GOFLAGS"] == "-mod=readonly")
        #expect(environment["GOENV"] == "off")
        #expect(environment["GOTOOLCHAIN"] == "local")
        #expect(environment["GOPROXY"] == "off")
        #expect(environment["GOSUMDB"] == "off")
        #expect(environment["HOME"] == home)
        #expect(environment["GOPRIVATE"] == nil)
        #expect(environment["GONOSUMDB"] == nil)
    }

    // MARK: - Go workspace mode

    /// Workspace-mode staging runs locate → work edit → module list → one
    /// package list per use module, and every workspace command after the
    /// location round resolves through the isolated go.work copy so a
    /// `go.work.sum` write never lands in the user's tree.
    @Test
    func goWorkspaceModeStagesOnePackageListPerUseModule() throws {
        let root = temporaryRoot("ws-mode")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        try write("module example.com/a\n\ngo 1.24\n", to: workspace.appendingPathComponent("a/go.mod"))
        try write("module example.com/b\n\ngo 1.24\n", to: workspace.appendingPathComponent("b/go.mod"))
        let goWorkURL = workspace.appendingPathComponent("go.work")
        let goWorkText = "go 1.24\n\nuse (\n\t./a\n\t./b\n)\n"
        try write(goWorkText, to: goWorkURL)
        let goURL = root.appendingPathComponent("tools/go")
        try writeFakeExecutable(goURL)

        let session = try MacGoMetadataPreparer().prepare(
            goRequest(workspaceURL: workspace, manifestURL: workspace.appendingPathComponent("a/go.mod"), goURL: goURL)
        )
        defer { _ = session }

        let resolvedWorkspace = workspace.resolvingSymlinksInPath().standardizedFileURL
        let initial = session.initialStage
        #expect(initial.id == "go-locate")
        #expect(initial.commands.count == 1)
        #expect(initial.commands[0].arguments == ["env", "-json", "GOWORK", "GOMOD"])
        #expect(initial.commands[0].workingDirectory == resolvedWorkspace.path)
        assertPinnedFlags(initial.commands[0].environment)
        #expect(initial.commands[0].environment["GOWORK"] == nil)
        #expect(initial.commands[0].executablePath == goURL.resolvingSymlinksInPath().standardizedFileURL.path)

        let locateOutput = try JSONSerialization.data(withJSONObject: [
            "GOWORK": goWorkURL.resolvingSymlinksInPath().standardizedFileURL.path,
            "GOMOD": workspace.appendingPathComponent("a/go.mod").resolvingSymlinksInPath().standardizedFileURL.path
        ])
        let workStage = try expectMore(session.advance(stage: initial, outputs: [locateOutput]), id: "go-work")
        #expect(workStage.commands.count == 1)
        #expect(workStage.commands[0].arguments == ["work", "edit", "-json"])
        #expect(workStage.commands[0].workingDirectory == resolvedWorkspace.path)

        let workOutput = try JSONSerialization.data(withJSONObject: [
            "Go": "1.24",
            "Use": [["DiskPath": "./a"], ["DiskPath": "./b"]]
        ])
        let modulesStage = try expectMore(session.advance(stage: workStage, outputs: [workOutput]), id: "go-modules")
        #expect(modulesStage.commands.count == 1)
        #expect(modulesStage.commands[0].arguments == ["list", "-m", "-json"])
        #expect(modulesStage.commands[0].workingDirectory == resolvedWorkspace.path)
        #expect(modulesStage.commands[0].environment["GOWORK"]
            == goWorkURL.resolvingSymlinksInPath().standardizedFileURL.path)

        let modulesOutput = try JSONSerialization.data(withJSONObject: [["Path": "example.com/a"]])
        let packagesStage = try expectMore(
            session.advance(stage: modulesStage, outputs: [modulesOutput]), id: "go-packages"
        )
        #expect(packagesStage.commands.count == 2)
        let resolvedA = workspace.appendingPathComponent("a").resolvingSymlinksInPath().standardizedFileURL
        let resolvedB = workspace.appendingPathComponent("b").resolvingSymlinksInPath().standardizedFileURL
        #expect(packagesStage.commands.map(\.workingDirectory) == [resolvedA.path, resolvedB.path])
        for command in packagesStage.commands {
            #expect(command.arguments == ["list", "-e", "-json", "./..."])
            let isolated = command.environment["GOWORK"] ?? ""
            #expect(isolated.hasSuffix("/go.work"))
            #expect(isolated != goWorkURL.resolvingSymlinksInPath().standardizedFileURL.path)
            #expect(isolated.contains("lithe-go-workspace-"))
        }

        // The isolated copy keeps every non-use line byte for byte and rewrites
        // only the use paths to resolved absolutes.
        let isolatedGoWork = try String(
            contentsOf: URL(fileURLWithPath: packagesStage.commands[0].environment["GOWORK"]!), encoding: .utf8
        )
        #expect(isolatedGoWork == "go 1.24\n\nuse (\n\t\(resolvedA.path)\n\t\(resolvedB.path)\n)\n")

        let packageA = Data("package-a".utf8)
        let packageB = Data("package-b".utf8)
        guard case .done(let source) = try session.advance(stage: packagesStage, outputs: [packageA, packageB]) else {
            Issue.record("The package round must finish the capture")
            return
        }
        guard case .go(let modules, let packages) = source else {
            Issue.record("Go staging must produce a Go normalization source")
            return
        }
        #expect(modules == modulesOutput)
        #expect(packages == [packageA, packageB])

        try session.validate()
        try session.validate()
        let input = try session.normalizationInput(source)
        #expect(input.workspaceDirectory == resolvedWorkspace.path)
        #expect(input.roots == [ProjectMetadataRoot(id: "workspace", path: resolvedWorkspace.path)])
    }

    /// Without a go.work the whole capture runs with `GOWORK=off` inside the
    /// module directory and no isolation copy exists to clean up.
    @Test
    func goSingleModuleModeStaysInsideTheModuleWithWorkOff() throws {
        let root = temporaryRoot("single")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        try write("module example.com/single\n\ngo 1.24\n", to: workspace.appendingPathComponent("go.mod"))
        let goURL = root.appendingPathComponent("tools/go")
        try writeFakeExecutable(goURL)

        let session = try MacGoMetadataPreparer().prepare(
            goRequest(workspaceURL: workspace, manifestURL: workspace.appendingPathComponent("go.mod"), goURL: goURL)
        )
        defer { _ = session }

        let resolvedWorkspace = workspace.resolvingSymlinksInPath().standardizedFileURL
        let initial = session.initialStage
        let locateOutput = try JSONSerialization.data(withJSONObject: ["GOWORK": "", "GOMOD": resolvedWorkspace.path + "/go.mod"])
        let modulesStage = try expectMore(session.advance(stage: initial, outputs: [locateOutput]), id: "go-modules")
        #expect(modulesStage.commands.count == 1)
        #expect(modulesStage.commands[0].arguments == ["list", "-m", "-json"])
        #expect(modulesStage.commands[0].workingDirectory == resolvedWorkspace.path)
        #expect(modulesStage.commands[0].environment["GOWORK"] == "off")

        let modulesOutput = Data("module-list".utf8)
        let packagesStage = try expectMore(
            session.advance(stage: modulesStage, outputs: [modulesOutput]), id: "go-packages"
        )
        #expect(packagesStage.commands.count == 1)
        #expect(packagesStage.commands[0].workingDirectory == resolvedWorkspace.path)
        #expect(packagesStage.commands[0].environment["GOWORK"] == "off")

        let packagesOutput = Data("package-list".utf8)
        guard case .done(let source) = try session.advance(stage: packagesStage, outputs: [packagesOutput]) else {
            Issue.record("The package round must finish the capture")
            return
        }
        guard case .go(let modules, let packages) = source else {
            Issue.record("Go staging must produce a Go normalization source")
            return
        }
        #expect(modules == modulesOutput)
        #expect(packages == [packagesOutput])
        try session.validate()
    }

    /// A go.work that appeared after preparation, or a workspace outside the
    /// refreshed tree, must fail the refresh instead of being trusted.
    @Test
    func goLocationRejectsAWorkspaceItDidNotFreeze() throws {
        let root = temporaryRoot("foreign")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        try write("module example.com/a\n\ngo 1.24\n", to: workspace.appendingPathComponent("go.mod"))
        let goURL = root.appendingPathComponent("tools/go")
        try writeFakeExecutable(goURL)

        let session = try MacGoMetadataPreparer().prepare(
            goRequest(workspaceURL: workspace, manifestURL: workspace.appendingPathComponent("go.mod"), goURL: goURL)
        )
        defer { _ = session }
        let initial = session.initialStage
        let locateOutput = try JSONSerialization.data(withJSONObject: [
            "GOWORK": root.appendingPathComponent("elsewhere/go.work").path, "GOMOD": ""
        ])
        #expect(throws: ProjectMetadataFailure.self) {
            _ = try session.advance(stage: initial, outputs: [locateOutput])
        }
    }

    /// The whole refresh fails when a frozen file changes before publication;
    /// half of a changed workspace must never be published.
    @Test
    func goValidateFailsAfterAManifestChanges() throws {
        let root = temporaryRoot("identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        let manifestURL = workspace.appendingPathComponent("go.mod")
        try write("module example.com/single\n\ngo 1.24\n", to: manifestURL)
        let goURL = root.appendingPathComponent("tools/go")
        try writeFakeExecutable(goURL)

        let session = try MacGoMetadataPreparer().prepare(
            goRequest(workspaceURL: workspace, manifestURL: manifestURL, goURL: goURL)
        )
        defer { _ = session }
        try session.validate()
        try write("module example.com/single\n\ngo 1.24\n// changed\n", to: manifestURL)
        #expect(throws: ProjectMetadataFailure.self) { try session.validate() }
    }

    // MARK: - Isolation rewriting

    /// The isolated copy preserves toolchain, godebug, replace, comments,
    /// unknown directives, separators and a missing final newline byte for
    /// byte; only use paths become resolved absolutes.
    @Test
    func isolationKeepsEverythingExceptUsePathsByteForByte() throws {
        let root = temporaryRoot("iso-rewrite")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        try write("module a\n", to: workspace.appendingPathComponent("a/go.mod"))
        try write("module b\n", to: workspace.appendingPathComponent("b/go.mod"))
        let goWorkURL = workspace.appendingPathComponent("go.work")
        let original = """
        go 1.24

        toolchain go1.24.4

        use (
        \t./a
        \t./b // trailing comment
        )

        godebug default=go1.21

        replace example.com/x => ../x

        // keep this comment
        """
        try write(original, to: goWorkURL)

        let isolation = try MacGoWorkspaceIsolation.create(workspaceURL: workspace, sourceGoWorkURL: goWorkURL)
        defer { _ = isolation.cleanup() }

        let resolvedWorkspace = workspace.resolvingSymlinksInPath().standardizedFileURL
        let resolvedA = workspace.appendingPathComponent("a").resolvingSymlinksInPath().standardizedFileURL
        let resolvedB = workspace.appendingPathComponent("b").resolvingSymlinksInPath().standardizedFileURL
        let resolvedX = root.appendingPathComponent("x").resolvingSymlinksInPath().standardizedFileURL
        let copied = try String(contentsOf: isolation.goWorkURL, encoding: .utf8)
        // The relative replace target follows the relocation: Go resolves it
        // against the go.work directory, and a rewritten use list without a
        // rewritten replace would silently change dependency resolution.
        #expect(copied == """
        go 1.24

        toolchain go1.24.4

        use (
        \t\(resolvedA.path)
        \t\(resolvedB.path) // trailing comment
        )

        godebug default=go1.21

        replace example.com/x => \(resolvedX.path)

        // keep this comment
        """)
        #expect(copied.hasSuffix("\n") == original.hasSuffix("\n"))
        #expect(resolvedWorkspace.path.isEmpty == false)

        // A second cleanup is still clean: the directory is already gone.
        #expect(isolation.cleanup() == nil)
        #expect(FileManager.default.fileExists(atPath: isolation.directoryURL.path) == false)
    }

    /// Single-line `use` directives support several paths and keep their
    /// separators; quoted paths stay quoted around the resolved absolute.
    @Test
    func isolationRewritesSingleLineAndQuotedUseDirectives() throws {
        let root = temporaryRoot("iso-single-line")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        try write("module a\n", to: workspace.appendingPathComponent("a/go.mod"))
        let spaced = workspace.appendingPathComponent("a b")
        try write("module s\n", to: spaced.appendingPathComponent("go.mod"))
        let goWorkURL = workspace.appendingPathComponent("go.work")
        try write("use ./a\n\nuse \"./a b\"\n", to: goWorkURL)

        let isolation = try MacGoWorkspaceIsolation.create(workspaceURL: workspace, sourceGoWorkURL: goWorkURL)
        defer { _ = isolation.cleanup() }

        let resolvedA = workspace.appendingPathComponent("a").resolvingSymlinksInPath().standardizedFileURL
        let resolvedSpaced = spaced.resolvingSymlinksInPath().standardizedFileURL
        let copied = try String(contentsOf: isolation.goWorkURL, encoding: .utf8)
        #expect(copied == "use \(resolvedA.path)\n\nuse \"\(resolvedSpaced.path)\"\n")
    }

    // MARK: - Cargo compatibility

    /// The Cargo session through the staged protocol: no rustup proxy means an
    /// empty first round followed by the single frozen metadata command, and
    /// the normalization input stays the typed workspace mapping.
    @Test
    func cargoSessionKeepsItsTwoPhaseSequenceWithoutRustup() throws {
        let root = temporaryRoot("cargo-no-rustup")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        let manifestURL = workspace.appendingPathComponent("Cargo.toml")
        try write("[workspace]\nmembers = []\n", to: manifestURL)
        let cargoURL = root.appendingPathComponent("tools/cargo")
        try writeFakeExecutable(cargoURL)

        let request = CargoMetadataPreparationRequest(
            workspaceURL: workspace, manifestURL: manifestURL, workspaceGeneration: 1,
            cargoCandidates: [cargoURL], rustupCandidates: [], customCargoURL: nil,
            environment: fakeEnvironment, deadline: ContinuousClock().now.advanced(by: .seconds(30))
        )
        let session = try MacCargoMetadataPreparer().prepare(request)
        defer { _ = session }

        let initial = session.initialStage
        #expect(initial.id == "cargo-resolution")
        #expect(initial.commands.isEmpty)

        guard case .more(let metadataStage) = try session.advance(stage: initial, outputs: []) else {
            Issue.record("The resolution round must plan the metadata round")
            return
        }
        #expect(metadataStage.id == "cargo-metadata")
        #expect(metadataStage.commands.count == 1)
        #expect(metadataStage.commands[0].arguments == [
            "metadata", "--format-version", "1", "--no-deps", "--frozen",
            "--color", "never", "--manifest-path",
            manifestURL.standardizedFileURL.path
        ])
        #expect(metadataStage.commands[0].executablePath == cargoURL.resolvingSymlinksInPath().standardizedFileURL.path)
        assertPinnedCargoFlags(metadataStage.commands[0].environment)

        let metadataOutput = try JSONSerialization.data(withJSONObject: [
            "packages": [[
                "id": "ws 0.1.0 (path+file:\(workspace.path))",
                "manifest_path": manifestURL.standardizedFileURL.path,
                "targets": [["src_path": workspace.appendingPathComponent("src/main.rs").path]],
                "dependencies": []
            ]],
            "workspace_members": ["ws 0.1.0 (path+file:\(workspace.path))"],
            "workspace_root": workspace.standardizedFileURL.path
        ])
        guard case .done(let source) = try session.advance(stage: metadataStage, outputs: [metadataOutput]) else {
            Issue.record("The metadata round must finish the capture")
            return
        }
        guard case .cargo(let metadata) = source else {
            Issue.record("Cargo staging must produce a Cargo normalization source")
            return
        }
        #expect(metadata == metadataOutput)
        try session.validate()
        let input = try session.normalizationInput(source)
        #expect(input.workspaceDirectory == workspace.standardizedFileURL.path)
        #expect(input.roots == [ProjectMetadataRoot(id: "workspace", path: workspace.standardizedFileURL.path)])
        #expect(throws: ProjectMetadataFailure.self) {
            _ = try session.normalizationInput(.go(modules: Data(), packages: []))
        }
    }

    private func assertPinnedCargoFlags(_ environment: [String: String]) {
        #expect(environment["CARGO_TERM_COLOR"] == "never")
        #expect(environment["RUSTUP_AUTO_INSTALL"] == "0")
        #expect(environment["GOFLAGS"] == nil)
    }

    private func expectMore(
        _ outcome: ProjectMetadataStageOutcome, id: String
    ) throws -> ProjectMetadataCaptureStage {
        guard case .more(let stage) = outcome else {
            Issue.record("Expected another staged round (\(id)), got \(outcome)")
            throw ProjectMetadataFailure.invalidInput(message: "unexpected stage outcome")
        }
        #expect(stage.id == id)
        return stage
    }

    /// `use .` is the most common workspace layout, and CRLF files must keep
    /// their terminators while every use path still follows the relocation.
    @Test
    func isolationRewritesUseDotAndPreservesCRLFLineEndings() throws {
        let root = temporaryRoot("iso-use-dot")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        try write("module example.com/dot\n\ngo 1.24\n", to: workspace.appendingPathComponent("go.mod"))
        let goWorkURL = workspace.appendingPathComponent("go.work")
        let original = "go 1.24\r\n\r\nuse .\r\n"
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try original.data(using: .utf8)!.write(to: goWorkURL)

        let isolation = try MacGoWorkspaceIsolation.create(workspaceURL: workspace, sourceGoWorkURL: goWorkURL)
        defer { _ = isolation.cleanup() }

        let resolvedWorkspace = workspace.resolvingSymlinksInPath().standardizedFileURL
        let copied = try String(contentsOf: isolation.goWorkURL, encoding: .utf8)
        #expect(copied == "go 1.24\r\n\r\nuse \(resolvedWorkspace.path)\r\n")
    }

    /// The module list frozen from the go.work text at preparation is the
    /// contract; a work-edit round naming a different set must fail the
    /// refresh instead of capturing modules nobody validated.
    @Test
    func goWorkspaceRejectsAChangedModuleList() throws {
        let root = temporaryRoot("ws-changed")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        try write("module example.com/a\n\ngo 1.24\n", to: workspace.appendingPathComponent("a/go.mod"))
        try write("module example.com/b\n\ngo 1.24\n", to: workspace.appendingPathComponent("b/go.mod"))
        let goWorkURL = workspace.appendingPathComponent("go.work")
        try write("go 1.24\n\nuse (\n\t./a\n\t./b\n)\n", to: goWorkURL)
        let goURL = root.appendingPathComponent("tools/go")
        try writeFakeExecutable(goURL)

        let session = try MacGoMetadataPreparer().prepare(
            goRequest(workspaceURL: workspace, manifestURL: workspace.appendingPathComponent("a/go.mod"), goURL: goURL)
        )
        defer { _ = session }
        let initial = session.initialStage
        let locateOutput = try JSONSerialization.data(withJSONObject: [
            "GOWORK": goWorkURL.resolvingSymlinksInPath().standardizedFileURL.path, "GOMOD": ""
        ])
        let workStage = try expectMore(session.advance(stage: initial, outputs: [locateOutput]), id: "go-work")
        let workOutput = try JSONSerialization.data(withJSONObject: [
            "Go": "1.24",
            "Use": [["DiskPath": "./a"], ["DiskPath": "./c"]]
        ])
        #expect(throws: ProjectMetadataFailure.self) {
            _ = try session.advance(stage: workStage, outputs: [workOutput])
        }
    }

    /// A cache variable pointing into the workspace would turn the metadata
    /// read into a workspace write no matter which flags are pinned.
    @Test
    func goPrepareRejectsACacheInsideTheWorkspace() throws {
        let root = temporaryRoot("ws-cache-inside")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        try write("module example.com/single\n\ngo 1.24\n", to: workspace.appendingPathComponent("go.mod"))
        let goURL = root.appendingPathComponent("tools/go")
        try writeFakeExecutable(goURL)

        var environment = fakeEnvironment
        environment["GOCACHE"] = workspace.appendingPathComponent(".cache/go-build").path
        #expect(throws: ProjectMetadataFailure.self) {
            _ = try MacGoMetadataPreparer().prepare(CargoMetadataPreparationRequest(
                workspaceURL: workspace, manifestURL: workspace.appendingPathComponent("go.mod"),
                workspaceGeneration: 1, cargoCandidates: [goURL], rustupCandidates: [],
                customCargoURL: nil, environment: environment,
                deadline: ContinuousClock().now.advanced(by: .seconds(30))
            ))
        }
    }

    /// The isolation copy is released through the cleaning protocol, so an
    /// owning model can delete it and surface failures without knowing the
    /// concrete session type.
    @Test
    func goSessionExposesCleanupThroughTheCleaningProtocol() throws {
        let root = temporaryRoot("ws-cleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        try write("module example.com/a\n\ngo 1.24\n", to: workspace.appendingPathComponent("a/go.mod"))
        try write("go 1.24\n\nuse ./a\n", to: workspace.appendingPathComponent("go.work"))
        let goURL = root.appendingPathComponent("tools/go")
        try writeFakeExecutable(goURL)

        let session = try MacGoMetadataPreparer().prepare(
            goRequest(workspaceURL: workspace, manifestURL: workspace.appendingPathComponent("a/go.mod"), goURL: goURL)
        )
        let cleaner = session as? any ProjectMetadataSessionCleaning
        #expect(cleaner != nil)
        #expect(cleaner?.cleanupSessionResources() == nil)
    }

    /// The rustup branch of the Cargo sequence is part of the byte-identical
    /// guarantee: two `which` probes through the rustup proxy, then one
    /// metadata command executed by the resolved cargo.
    @Test
    func cargoSessionKeepsItsTwoPhaseSequenceThroughRustup() throws {
        let root = temporaryRoot("cargo-rustup")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        let manifestURL = workspace.appendingPathComponent("Cargo.toml")
        try write("[workspace]\nmembers = []\n", to: manifestURL)
        let rustupURL = root.appendingPathComponent("tools/rustup")
        try writeFakeExecutable(rustupURL)
        let toolchainDir = root.appendingPathComponent("tools/toolchain/bin")
        let resolvedCargo = toolchainDir.appendingPathComponent("cargo")
        let resolvedRustc = toolchainDir.appendingPathComponent("rustc")
        try writeFakeExecutable(resolvedCargo)
        try writeFakeExecutable(resolvedRustc)

        let request = CargoMetadataPreparationRequest(
            workspaceURL: workspace, manifestURL: manifestURL, workspaceGeneration: 1,
            cargoCandidates: [rustupURL], rustupCandidates: [], customCargoURL: nil,
            environment: fakeEnvironment, deadline: ContinuousClock().now.advanced(by: .seconds(30))
        )
        let session = try MacCargoMetadataPreparer().prepare(request)
        defer { _ = session }

        let initial = session.initialStage
        #expect(initial.id == "cargo-resolution")
        #expect(initial.commands.count == 2)
        #expect(initial.commands.map(\.arguments) == [["which", "cargo"], ["which", "rustc"]])
        #expect(initial.commands.map(\.executablePath)
            == [rustupURL, rustupURL].map { $0.resolvingSymlinksInPath().standardizedFileURL.path })

        let resolvedPath = { (url: URL) in Data(url.resolvingSymlinksInPath().standardizedFileURL.path.utf8) + Data([0x0A]) }
        guard case .more(let metadataStage) = try session.advance(
            stage: initial, outputs: [try resolvedPath(resolvedCargo), try resolvedPath(resolvedRustc)]
        ) else {
            Issue.record("The resolution round must plan the metadata round")
            return
        }
        #expect(metadataStage.id == "cargo-metadata")
        #expect(metadataStage.commands.count == 1)
        #expect(metadataStage.commands[0].executablePath
            == resolvedCargo.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(metadataStage.commands[0].arguments.contains("--manifest-path"))
    }
}
