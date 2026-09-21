import Foundation
import Testing
@testable import Lithe

@Suite("Run configuration category persistence")
struct RunConfigurationCategoryPersistenceTests {
    @Test(arguments: [nil, "project", "infrastructure"] as [String?])
    func generationPayloadRoundTripPreservesOptionalCategory(category: String?) throws {
        var configuration: [String: Any] = [
            "id": "fixture:run", "name": "Fixture", "provider": "compose.service",
            "execution": "service", "toolchains": [:] as [String: String], "disabled": false
        ]
        if let category { configuration["category"] = category }
        let document: [String: Any] = [
            "generated": [
                "version": 2,
                "generator": ["fingerprint": "sha256:fixture", "inputs": ["compose.yaml": "sha256:input"]],
                "configurations": [configuration]
            ],
            "toolchainRequirements": ["version": 1, "toolchains": [:] as [String: String]],
            "entryCount": 1
        ]
        let data = try JSONSerialization.data(withJSONObject: document)
        let payload = try JSONDecoder().decode(RustCoreBridge.RunConfigurationGeneratePayload.self, from: data)
        // MacRunConfigurationStore persists this decoded document, not the raw Core response.
        let persisted = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload.generated)) as? [String: Any])
        let configurations = try #require(persisted["configurations"] as? [[String: Any]])
        let entry = try #require(configurations.first)
        #expect(entry["category"] as? String == category)
        #expect(entry["execution"] as? String == "service")
        #expect(entry["id"] as? String == "fixture:run")
        let generator = try #require(persisted["generator"] as? [String: Any])
        #expect(generator["fingerprint"] as? String == "sha256:fixture")
        #expect(generator["inputs"] as? [String: String] == ["compose.yaml": "sha256:input"])
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_RUN_RUN_CONFIGURATION_INTEGRATION"] == "1"))
    func realCoreGenerationPersistsComposeCategoryWithoutChangingProjectProviders() throws {
        let core = RustCoreBridge()
        try #require(core.isAvailable, "The explicit linked lane must use real Rust Core")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-run-category-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = [
            "infra-a/compose.yaml": "services:\n  cache:\n    image: example/cache\n",
            "infra-b/compose.yaml": "services:\n  cache:\n    image: example/cache\n",
            "go.mod": "module example.test/category\n\ngo 1.21\n",
            "main.go": "package main\nfunc main() {}\n",
            "worker/Cargo.toml": "[package]\nname = \"worker\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
            "worker/src/main.rs": "fn main() {}\n",
            "python/pyproject.toml": "[project]\nname = \"fixture\"\nversion = \"0.1.0\"\n[project.scripts]\nfixture = \"main:main\"\n",
            "python/main.py": "def main():\n    pass\n"
        ]
        for (path, text) in contents {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let paths = contents.keys.sorted()
        let coreResult = try core.generateRunConfiguration(at: root, paths: paths, modulePaths: []).get()
        let store = MacRunConfigurationStore(core: core, storage: MacFileStorage(), preferences: CategoryTestPreferences())
        let result = try store.generate(at: root, files: paths.map { root.appendingPathComponent($0) }, modulePaths: [])
        let generatedURL = root.appendingPathComponent(".lithe/run/generated.json")
        let firstData = try Data(contentsOf: generatedURL)
        let document = try #require(try JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        let entries = try #require(document["configurations"] as? [[String: Any]])
        #expect(result.entryCount == entries.count && result.entryCount == coreResult.entryCount)
        let compose = entries.filter { ($0["provider"] as? String)?.hasPrefix("compose.") == true }
        #expect(compose.count == 4)
        #expect(compose.allSatisfy { $0["category"] as? String == "infrastructure" })
        #expect(compose.allSatisfy { $0["execution"] as? String == "service" })
        #expect(Set(compose.compactMap { $0["name"] as? String }).count == 4)
        for prefix in ["go.", "cargo.", "python."] {
            let projectEntries = entries.filter { ($0["provider"] as? String)?.hasPrefix(prefix) == true }
            #expect(!projectEntries.isEmpty, "Missing project provider \(prefix)")
            #expect(projectEntries.allSatisfy { $0["category"] == nil })
        }
        let generator = try #require(document["generator"] as? [String: Any])
        #expect(generator["fingerprint"] as? String == coreResult.generated.generator?.fingerprint)
        #expect(generator["inputs"] as? [String: String] == coreResult.generated.generator?.inputs)
        // Repeat the actual adapter write: generated IDs, metadata and bytes remain stable.
        _ = try store.generate(at: root, files: paths.map { root.appendingPathComponent($0) }, modulePaths: [])
        #expect(try Data(contentsOf: generatedURL) == firstData)
    }
}

private final class CategoryTestPreferences: KeyValueStore {
    func data(forKey _: String) -> Data? { nil }
    func object(forKey _: String) -> Any? { nil }
    func string(forKey _: String) -> String? { nil }
    func stringArray(forKey _: String) -> [String]? { nil }
    func set(_: Any?, forKey _: String) {}
}
