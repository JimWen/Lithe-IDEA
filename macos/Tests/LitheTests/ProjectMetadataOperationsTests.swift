import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Project metadata Swift Core boundary")
struct ProjectMetadataOperationsTests {
    @Test
    func cargoFixtureTraversesRealCoreAndPreservesPortableTopology() throws {
        let fixture = try MetadataFixture()
        let operationID = UUID().uuidString
        let result = try fixture.normalize(.cargo(capture(try fixture.cargoData())), operationID: operationID)
        let snapshot = result.snapshot
        #expect(result.operationID == operationID)
        #expect(snapshot.version == 1 && snapshot.language == .rust)
        #expect(snapshot.workspace.rootID == "workspace" && snapshot.workspace.relativePath == ".")
        let alpha = try #require(snapshot.members.first { $0.name == "alpha" })
        let beta = try #require(snapshot.members.first { $0.name == "beta" })
        #expect(alpha.id == fixture.expectedIDs("cargoMemberIDs")["alpha"])
        #expect(beta.id == fixture.expectedIDs("cargoMemberIDs")["beta"])
        #expect(snapshot.defaultMemberIDs == [alpha.id])
        #expect(alpha.defaultRun == "tool" && alpha.languageVersion == "2021")
        #expect(beta.manifest.rootID == "external" && beta.manifest.relativePath == "beta/Cargo.toml")
        #expect(alpha.features.map(\.name) == ["default", "fast"])
        #expect(alpha.features.map(\.enables) == [["fast"], []])
        let dependency = try #require(alpha.dependencies.first)
        #expect(dependency.rename == "local_lib" && dependency.kind == "dev")
        #expect(dependency.versionReq == "^1.0" && dependency.optional && !dependency.defaultFeatures)
        #expect(dependency.features == ["extras"] && dependency.target == "cfg(unix)")
        #expect(dependency.location?.rootID == "external" && dependency.location?.relativePath == "lib")
        let binary = try #require(alpha.targets.first { $0.kind == "bin" })
        #expect(binary.runnable && binary.testable && !binary.doctest)
        #expect(binary.sources.first?.location.relativePath == "alpha/entry.rs")
        #expect(binary.sources.first?.role == "root")
        let restricted = try #require(alpha.targets.first { !$0.requiredFeatures.isEmpty })
        #expect(restricted.requiredFeatures == ["fast"])
        let library = try #require(alpha.targets.first { $0.kind == "lib" })
        #expect(library.crateTypes == ["cdylib", "rlib"] && !library.runnable)
        let unknown = try #require(alpha.targets.first { $0.kind == "unknown" })
        #expect(unknown.rawKinds == ["future-kind"] && unknown.crateTypes == ["future-crate"])
        #expect(!unknown.runnable && !unknown.testable)
        #expect(alpha.targets.first { $0.kind == "custom-build" }?.testable == false)
    }

    @Test(arguments: ["missing", "null", "empty"])
    func cargoDefaultsKeepAbsentAndExplicitEmptyDistinct(_ form: String) throws {
        let fixture = try MetadataFixture()
        var cargo = fixture.cargo
        switch form {
        case "missing": cargo.removeValue(forKey: "workspace_default_members")
        case "null": cargo["workspace_default_members"] = NSNull()
        default: cargo["workspace_default_members"] = [String]()
        }
        let snapshot = try fixture.normalize(.cargo(capture(try json(cargo)))).snapshot
        #expect(snapshot.defaultMemberIDs == (form == "empty" ? [] : nil))
    }

    @Test
    func canonicallyEquivalentCargoFeatureNamesRemainDifferentThroughRealCore() throws {
        let fixture = try MetadataFixture()
        let raw = try #require(String(data: fixture.cargoData(), encoding: .utf8))
        // Inject directly into the JSON text: a Swift Dictionary used to build
        // this input would collapse the two names before Core even sees them.
        let replacement = "\"features\":" + (try #require(fixture.object["unicodeFeatureMapJSON"] as? String))
        let changed = raw.replacingOccurrences(of: #""features":{}"#, with: replacement)
        #expect(changed != raw)
        let snapshot = try fixture.normalize(.cargo(capture(Data(changed.utf8)))).snapshot
        let beta = try #require(snapshot.members.first { $0.name == "beta" })
        let entries = beta.features
        #expect(entries.count == 3)
        #expect(entries.map { Array($0.name.utf8) } == [Array("YWJj".utf8), [0x65, 0xCC, 0x81], [0xC3, 0xA9]])
        #expect(entries.map(\.enables) == [["literal-base64"], ["decomp"], ["pre"]])
        #expect(Set(entries.map(\.id)).count == 3)
        let alpha = try #require(snapshot.members.first { $0.name == "alpha" })
        #expect(alpha.features.map(\.name) == ["default", "fast"])
        #expect(alpha.dependencies.first?.features == ["extras"])
        #expect(alpha.targets.contains { $0.requiredFeatures == ["fast"] })
    }

    @Test
    func featureActivationChangesCompareOriginalUnicodeBytes() throws {
        let fixture = try MetadataFixture()
        let raw = try #require(String(data: fixture.cargoData(), encoding: .utf8))
        let firstRaw = raw.replacingOccurrences(of: #""features":{}"#, with: #""features":{"default":["é"]}"#)
        let secondRaw = raw.replacingOccurrences(of: #""features":{}"#, with: #""features":{"default":["e\u0301"]}"#)
        let first = try fixture.normalize(.cargo(capture(Data(firstRaw.utf8)))).snapshot
        let second = try fixture.normalize(.cargo(capture(Data(secondRaw.utf8)))).snapshot
        let firstFeatures = try #require(first.members.first { $0.name == "beta" }).features
        let secondFeatures = try #require(second.members.first { $0.name == "beta" }).features
        #expect(firstFeatures.count == 1 && secondFeatures.count == 1)
        #expect(firstFeatures != secondFeatures && first != second)
        #expect(Array(try #require(firstFeatures.first?.enables.first).utf8) == [0xC3, 0xA9])
        #expect(Array(try #require(secondFeatures.first?.enables.first).utf8) == [0x65, 0xCC, 0x81])
    }

    @Test
    func goCompleteStreamsKeepImportsDiagnosticsAndRealEmptyOutput() throws {
        let fixture = try MetadataFixture()
        let modules = capture(try fixture.goModulesData())
        let packages = try fixture.goPackages.map { capture(try json($0)) }
        let snapshot = try fixture.normalize(.go(modules: modules, packages: packages)).snapshot
        #expect(snapshot.language == .go)
        let alpha = try #require(snapshot.members.first { $0.name == "example.invalid/alpha" })
        #expect(alpha.id == fixture.expectedIDs("goMemberIDs")[alpha.name])
        #expect(snapshot.defaultMemberIDs?.count == 2)
        let main = try #require(alpha.targets.first { $0.importPath == "example.invalid/alpha" })
        #expect(main.runnable && main.testable)
        #expect(main.imports == ["fmt"] && main.testImports == ["testing"] && main.externalTestImports == ["testing"])
        #expect(main.sources.contains { $0.location.relativePath == "alpha/入口.go" && $0.role == "go" })
        #expect(main.sources.contains { $0.role == "ignored" && $0.location.relativePath == "alpha/tagged.go" })
        let broken = try #require(alpha.targets.first { $0.importPath == "example.invalid/alpha/broken" })
        #expect(broken.incomplete && !broken.runnable && !broken.testable)
        #expect(broken.diagnostics.contains { $0.details.contains("dependency is unavailable") })
        #expect(snapshot.diagnostics.contains { $0.details.contains("pattern has no mapped directory") })
        #expect(alpha.targets.contains { $0.importPath == "example.invalid/alpha/foo.test" && $0.runnable })

        // A completed query may legitimately report no packages. An omitted
        // query is separately rejected, even though Core accepts an empty stream.
        let empty = try fixture.normalize(.go(modules: modules, packages: [capture(Data())])).snapshot
        #expect(empty.members.count == 2 && empty.members.allSatisfy { $0.targets.isEmpty })
    }

    @Test(arguments: [
        LanguageProjectToolStatus.processFailed, .startFailed, .cancelled, .timedOut,
        .outputLimit, .readFailed, .cleanupFailed, .invalidRequest, .capacityUnavailable, .unavailable,
    ])
    func rejectedCapturePreservesStatusIdentityAndBothRawStreams(_ status: LanguageProjectToolStatus) throws {
        let fixture = try MetadataFixture()
        let failed = capture(Data("{partial".utf8), status: status, exitCode: 9)
        do {
            _ = try fixture.normalize(.go(
                modules: capture(try fixture.goModulesData()),
                packages: [capture(try json(fixture.goPackages[0])), failed]
            ))
            Issue.record("A failed process must not produce a metadata tree")
        } catch ProjectMetadataFailure.captureRejected(let stage, let retained) {
            #expect(stage == .goPackages(1))
            #expect(retained.operationID == failed.operationID && retained.status == status)
            #expect(retained.stdout == failed.stdout && retained.stderr == failed.stderr)
            #expect(retained.exitCode == 9)
        }
    }

    @Test(arguments: ["stdout", "stderr", "cleanup", "exit", "missingExit", "cause"])
    func succeededLabelCannotHideIncompleteCapture(_ missing: String) throws {
        let fixture = try MetadataFixture()
        let result = capture(
            try fixture.cargoData(), cause: missing == "cause" ? .readFailed : nil,
            exitCode: missing == "missingExit" ? nil : (missing == "exit" ? 1 : 0),
            stdoutEOF: missing != "stdout", stderrEOF: missing != "stderr", cleanup: missing != "cleanup"
        )
        do {
            _ = try fixture.normalize(.cargo(result))
            Issue.record("All success evidence is required")
        } catch ProjectMetadataFailure.captureRejected(let stage, let retained) {
            #expect(stage == .cargo && retained.operationID == result.operationID)
            #expect(retained.cause == result.cause && retained.cleanupConfirmed == result.cleanupConfirmed)
        }
    }

    @Test
    func allCaptureFailuresAreCheckedBeforeDecodingEarlierOutput() throws {
        let fixture = try MetadataFixture()
        let failed = capture(Data(), status: .timedOut)
        do {
            _ = try fixture.normalize(.go(modules: capture(Data([0xFF])), packages: [failed]))
            Issue.record("A failed stage must be retained before any UTF-8 decode")
        } catch ProjectMetadataFailure.captureRejected(let stage, let retained) {
            #expect(stage == .goPackages(0) && retained.operationID == failed.operationID)
        }
    }

    @Test(arguments: [Data([0xFF]), Data([0xE4, 0xB8]), Data([0xED, 0xA0, 0x80])])
    func malformedUTF8NeverUsesReplacementCharacters(_ bytes: Data) throws {
        let fixture = try MetadataFixture()
        try expectInvalidInput { try fixture.normalize(.cargo(capture(bytes))) }
    }

    @Test(arguments: [0, 129])
    func absentOrUnboundedGoCapturesAreRejected(_ count: Int) throws {
        let fixture = try MetadataFixture()
        try expectInvalidInput {
            try fixture.normalize(.go(modules: capture(try fixture.goModulesData()), packages: Array(repeating: capture(Data()), count: count)))
        }
    }

    @Test
    func cargoExactlyAtCombinedLimitSucceedsAndOneExtraByteFails() throws {
        let fixture = try MetadataFixture()
        let limit = 16 * 1_024 * 1_024
        var bytes = try fixture.cargoData()
        bytes.append(Data(repeating: 0x20, count: limit - bytes.count))
        let snapshot = try fixture.normalize(.cargo(capture(bytes))).snapshot
        #expect(snapshot.members.count == 2)
        bytes.append(0x20)
        try expectInvalidInput { try fixture.normalize(.cargo(capture(bytes))) }
    }

    @Test
    func goBudgetIncludesModulesAndTheInsertedPackageSeparator() throws {
        let fixture = try MetadataFixture()
        let modules = try fixture.goModulesData()
        var packages = try fixture.goPackagesData()
        let limit = 16 * 1_024 * 1_024
        packages.append(Data(repeating: 0x20, count: limit - modules.count - packages.count - 1))
        let snapshot = try fixture.normalize(.go(modules: capture(modules), packages: [capture(packages), capture(Data())])).snapshot
        #expect(snapshot.members.count == 2)
        // Raw stdout alone fits, but the separator is part of the Core input.
        packages.append(0x20)
        try expectInvalidInput {
            try fixture.normalize(.go(modules: capture(modules), packages: [capture(packages), capture(Data())]))
        }
    }

    @Test
    func malformedRecordsAndUnmappedRootsRetainCoreErrorCategories() throws {
        let fixture = try MetadataFixture()
        var cargo = fixture.cargo
        var packages = try #require(cargo["packages"] as? [[String: Any]])
        packages[0]["targets"] = "invalid targets"
        cargo["packages"] = packages
        for (input, roots, expectedCode) in [
            (try json(cargo), fixture.roots, "parse_failed"),
            (try fixture.cargoData(), Array(fixture.roots.prefix(1)), "permission_denied"),
        ] {
            do {
                _ = try fixture.normalize(.cargo(capture(input)), roots: roots)
                Issue.record("Malformed or unmapped data must fail the whole snapshot")
            } catch ProjectMetadataFailure.core(let code, let message, let details) {
                #expect(code == expectedCode && !message.isEmpty)
                #expect(details == nil)
            }
        }
    }

    @Test(arguments: [0, -1, 30_001])
    func zeroOrOutOfRangeDeadlineCannotBecomeUnlimited(_ timeout: Int) throws {
        let fixture = try MetadataFixture()
        try expectInvalidInput { try fixture.normalize(.cargo(capture(try fixture.cargoData())), timeout: timeout) }
    }

    @Test(arguments: ["", "has\0nul", String(repeating: "界", count: 43)])
    func operationIdentityIsBoundedUTF8WithoutCStrTruncation(_ operationID: String) throws {
        let fixture = try MetadataFixture()
        try expectInvalidInput { try fixture.normalize(.cargo(capture(try fixture.cargoData())), operationID: operationID) }
        #expect(!RustProjectMetadataOperations(core: RustCoreBridge()).cancel(operationID: operationID))
    }

    @Test(arguments: ["count", "empty", "id", "path", "workspace"])
    func rootMappingAllocationIsBoundedBeforeEncoding(_ overflow: String) throws {
        let fixture = try MetadataFixture()
        var roots = fixture.roots
        var workspace = fixture.workspace
        switch overflow {
        case "count": roots = Array(repeating: roots[0], count: 129)
        case "empty": roots = []
        case "id": roots[0] = ProjectMetadataRoot(id: String(repeating: "界", count: 22), path: roots[0].path)
        case "path": roots[0] = ProjectMetadataRoot(id: "workspace", path: "/" + String(repeating: "x", count: 8_192))
        default: workspace = "/" + String(repeating: "x", count: 8_192)
        }
        try expectInvalidInput {
            try fixture.normalize(.cargo(capture(try fixture.cargoData())), roots: roots, workspace: workspace)
        }
    }

    @Test
    func productionEncoderForwardsDeadlineAndKeepsLegacyNilDefault() throws {
        let core = RustCoreBridge()
        let operationID = UUID().uuidString
        let command = "execution.normalizeProjectMetadata"
        let data = try core.encodeRequest(command: command, payload: ["language": "go"], operationID: operationID, timeoutMilliseconds: 23)
        let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(envelope["id"] as? String == operationID && envelope["operationId"] as? String == operationID)
        #expect(envelope["command"] as? String == command && envelope["timeoutMilliseconds"] as? Int == 23)
        #expect((envelope["payload"] as? [String: String]) == ["language": "go"])
        let legacy = try core.encodeRequest(command: "github.parseRemote", payload: ["remoteUrl": "https://example.invalid/repo"])
        let legacyEnvelope = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        #expect(legacyEnvelope["timeoutMilliseconds"] == nil)
        #expect(legacyEnvelope["id"] as? String == legacyEnvelope["operationId"] as? String)
        #expect(UUID(uuidString: try #require(legacyEnvelope["id"] as? String)) != nil)
        #expect(!RustProjectMetadataOperations(core: core).cancel(operationID: UUID().uuidString))
    }

    @Test
    func legacyCoreErrorsKeepDetailsAndOldMetadataCannotFallBackToADictionary() throws {
        let core = RustCoreBridge()
        try #require(core.isAvailable)
        let command = "execution.unsupportedMetadataFixture"
        let response: Result<ProjectMetadataSnapshot, RustCoreBridge.CoreCallError> = core.executeResult(
            command: command, payload: [String: String]()
        )
        switch response {
        case .success: Issue.record("An unsupported command must preserve its Core error")
        case .failure(let error):
            #expect(error.code == "not_supported" && error.details == command)
        }
        let legacy = #"{"id":"member","name":"member","directory":{"rootID":"workspace","relativePath":"."},"manifest":{"rootID":"workspace","relativePath":"Cargo.toml"},"targets":[],"features":{},"dependencies":[],"incomplete":false,"diagnostics":[]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProjectMetadataMember.self, from: Data(legacy.utf8))
        }
    }
}

private func capture(
    _ stdout: Data, status: LanguageProjectToolStatus = .succeeded,
    cause: LanguageProjectToolStatus? = nil, exitCode: Int32? = 0,
    stdoutEOF: Bool = true, stderrEOF: Bool = true, cleanup: Bool = true
) -> LanguageProjectToolResult {
    LanguageProjectToolResult(
        operationID: UUID().uuidString, status: status, cause: cause,
        stdout: stdout, stderr: Data("warning: not metadata {\n".utf8), exitCode: exitCode,
        stdoutReachedEOF: stdoutEOF, stderrReachedEOF: stderrEOF, cleanupConfirmed: cleanup
    )
}

private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func expectInvalidInput(_ body: () throws -> ProjectMetadataNormalization) throws {
    do {
        _ = try body()
        Issue.record("Invalid input must be rejected before Core encoding")
    } catch ProjectMetadataFailure.invalidInput(let message) {
        #expect(!message.isEmpty)
    }
}

private struct MetadataFixture {
    let object: [String: Any]
    let workspace: String
    let roots: [ProjectMetadataRoot]
    let cargo: [String: Any]
    let goPackages: [[String: Any]]

    init() throws {
        // Require actual linkage: an unavailable bridge must not silently pass
        // a lane that claims to test the production C ABI.
        try #require(RustCoreBridge().isAvailable)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/execution/project-metadata-v1.json"))
        object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        workspace = try #require(object["workspaceDirectory"] as? String)
        roots = try JSONDecoder().decode([ProjectMetadataRoot].self, from: json(try #require(object["roots"])))
        cargo = try #require(object["cargo"] as? [String: Any])
        goPackages = try #require(object["goPackages"] as? [[String: Any]])
    }

    func cargoData() throws -> Data { try json(cargo) }
    func goModulesData() throws -> Data { try stream(try #require(object["goModules"] as? [[String: Any]])) }
    func goPackagesData() throws -> Data { try stream(goPackages) }
    func expectedIDs(_ name: String) -> [String: String] {
        (object["expected"] as? [String: [String: String]])?[name] ?? [:]
    }
    func normalize(
        _ captures: ProjectMetadataCaptures, roots: [ProjectMetadataRoot]? = nil,
        workspace: String? = nil, operationID: String = UUID().uuidString, timeout: Int = 5_000
    ) throws -> ProjectMetadataNormalization {
        try RustProjectMetadataOperations(core: RustCoreBridge()).normalize(
            captures, workspaceDirectory: workspace ?? self.workspace, roots: roots ?? self.roots,
            operationID: operationID, timeoutMilliseconds: timeout
        )
    }
    private func stream(_ objects: [[String: Any]]) throws -> Data {
        var result = Data()
        for object in objects {
            result.append(try json(object))
            result.append(0x0A)
        }
        return result
    }
}
