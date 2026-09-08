import Foundation
import LitheCoreContracts
import LitheSearchModule
import Testing
@testable import Lithe

struct ScopedSearchContractTests {
    @Test
    func sharedScopedFixturesCrossTheRealRustBridge() throws {
        let core = RustCoreBridge()
        try #require(core.isAvailable, "Scoped search contract tests require the linked Rust Core")
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            repository.appendingPathComponent("shared/fixtures/search/scoped-preview-v1.json")))
        for scenario in fixture.cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                core.invalidateSearchIndex(at: root)
                do { try FileManager.default.removeItem(at: root) }
                catch { Issue.record("Search fixture cleanup failed: \(error)") }
            }
            for (path, source) in scenario.files {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(source.utf8).write(to: url)
            }
            var payload = scenario.request
            payload["root"] = .string(root.path)
            let result: Result<RustCoreBridge.ReplacementPreviewPayload, RustCoreBridge.CoreCallError> = core.executeResult(
                command: "workspace.replacePreview", payload: ToolingJSONValue.object(payload), timeoutMilliseconds: 3_000)
            if let errorCode = scenario.errorCode {
                guard case .failure(let error) = result else {
                    Issue.record("Expected engine failure for \(scenario.name)")
                    continue
                }
                #expect(error.code == errorCode)
                continue
            }
            let response = try result.get()
            #expect(response.status?.rawValue == scenario.status)
            let files = response.makeModels(at: root)
            let expected = try #require(scenario.expected)
            #expect(files.count == expected.count)
            for (file, expected) in zip(files, expected) {
                #expect(file.relativePath == expected.path)
                #expect(file.url == root.appendingPathComponent(expected.path))
                let source = try #require(file.sourceText)
                let replacement = try #require(file.replacementText)
                #expect(Array(source.utf8) == Array(expected.sourceText.utf8))
                #expect(Array(replacement.utf8) == Array(expected.replacementText.utf8))
                #expect(file.edits.map { [$0.utf16Start, $0.utf16Length] } == expected.ranges)
                #expect(Set(file.edits.map(\.id)).count == file.edits.count)
            }
            for (path, source) in scenario.files {
                #expect(try Data(contentsOf: root.appendingPathComponent(path)) == Data(source.utf8))
            }
        }
    }

    @Test
    func typedHostRequestEncodesEveryScopeAndPreservesEngineFailure() throws {
        let core = RustCoreBridge()
        try #require(core.isAvailable)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer {
            core.invalidateSearchIndex(at: root)
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Search fixture cleanup failed: \(error)") }
        }
        try Data("plain".utf8).write(to: root.appendingPathComponent("src/file.go"))
        let operations = RustWorkspaceOperations(core: core)
        let rules = SearchVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: [])
        for scope: ProjectTextScope in [.project, .directory("src"), .files(["src/file.go"])] {
            let outcome = try operations.textPreview(ProjectTextPreviewRequest(rootURL: root, scope: scope, purpose: .search,
                query: " x ", options: .default, textOverrides: ["src/file.go": " x "], visibilityRules: rules)).get()
            #expect(outcome.status == .complete)
            #expect(outcome.files.map(\.relativePath) == ["src/file.go"])
            #expect(outcome.files.first?.sourceText == " x ")
        }
        let outcome = operations.textPreview(ProjectTextPreviewRequest(rootURL: root, scope: .project, purpose: .replace,
            query: "(?<=x)y", options: ProjectSearchOptions(regularExpression: true), textOverrides: [:], visibilityRules: rules))
        guard case .failure(let error) = outcome else { Issue.record("Expected Rust regex failure"); return }
        #expect(error.code == "parse_failed")
        #expect(error.details?.contains("look-around") == true)
    }

    @Test @MainActor
    func documentSnapshotsRetainUnicodeNormalizationAsARealEdit() {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let document = EditorDocument(url: URL(fileURLWithPath: "/search-fixture/unicode.txt"),
            text: composed, modificationDate: nil)
        document.applyLiveEditorText(decomposed)
        #expect(document.isDirty)
        #expect(document.lifecycleState.revision == 1)
        #expect(Array(document.text.utf8) == Array(decomposed.utf8))
        document.text = composed
        #expect(!document.isDirty)
        #expect(document.lifecycleState.revision == 2)
        #expect(Array(document.text.utf8) == Array(composed.utf8))
    }

    private struct Fixture: Decodable { let cases: [Scenario] }
    private struct Scenario: Decodable {
        let name: String
        let files: [String: String]
        let request: [String: ToolingJSONValue]
        let status: String?
        let expected: [Expected]?
        let errorCode: String?
    }
    private struct Expected: Decodable {
        let path: String
        let sourceText: String
        let replacementText: String
        let ranges: [[Int]]
    }
}
