import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheLanguageExtensionSupport
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("AI Agent Markdown Renderer & Plugin Isolation")
@MainActor
struct AIAgentMarkdownAndPluginIsolationTests {
    @Test
    func markdownParserParsesHeadingsListsTasksQuotesTablesAndFencedCode() {
        let source = #"""
        # Summary

        Intro paragraph with `inline()` and **bold**.

        - First bullet
        - [x] Done task
        - [ ] Pending task

        1. Step one
        2. Step two

        > Quoted note

        | Language | Bundle | Status |
        | :--- | :---: | ---: |
        | Go | GoSupport | Ready |
        | Rust | RustSupport | Ready |

        ---

        ```go
        func main() {
            var s string = "ok"
            _ = s
        }
        ```
        """#

        let blocks = AIAgentMarkdownParser.parse(source)
        #expect(blocks.contains(.heading(level: 1, text: "Summary")))
        #expect(blocks.contains(.paragraph(text: "Intro paragraph with `inline()` and **bold**.")))
        #expect(blocks.contains(.bulletList(items: [
            AIAgentMarkdownListItem(text: "First bullet", indentLevel: 0, isTask: false, isChecked: false),
            AIAgentMarkdownListItem(text: "Done task", indentLevel: 0, isTask: true, isChecked: true),
            AIAgentMarkdownListItem(text: "Pending task", indentLevel: 0, isTask: true, isChecked: false)
        ])))
        #expect(blocks.contains(.orderedList(start: 1, items: [
            AIAgentMarkdownListItem(text: "Step one", indentLevel: 0, isTask: false, isChecked: false),
            AIAgentMarkdownListItem(text: "Step two", indentLevel: 0, isTask: false, isChecked: false)
        ])))
        #expect(blocks.contains(.blockquote(lines: ["Quoted note"])))
        #expect(blocks.contains(.table(
            headers: ["Language", "Bundle", "Status"],
            alignments: [.leading, .center, .trailing],
            rows: [
                ["Go", "GoSupport", "Ready"],
                ["Rust", "RustSupport", "Ready"]
            ]
        )))
        #expect(blocks.contains(.thematicBreak))
        #expect(blocks.contains(.codeBlock(
            language: "go",
            code: "func main() {\n    var s string = \"ok\"\n    _ = s\n}",
            isClosed: true
        )))
    }

    @Test
    func markdownParserHandlesStreamingUnclosedCodeFenceCleanly() {
        let partial = "Working on fix:\n```rust\nfn main() {"
        let blocks = AIAgentMarkdownParser.parse(partial)
        #expect(blocks == [
            .paragraph(text: "Working on fix:"),
            .codeBlock(language: "rust", code: "fn main() {", isClosed: false)
        ])
    }

    @Test
    func markdownTablePreservesNonPipeBackslashesAndUnescapesPipes() {
        let source = #"""
        | Pattern | Escaped Pipe | Code |
        | --- | --- | --- |
        | \d+\s and \n | a \| b | `\d+ \| \w+` |
        """#
        let blocks = AIAgentMarkdownParser.parse(source)
        #expect(blocks == [
            .table(
                headers: ["Pattern", "Escaped Pipe", "Code"],
                alignments: [.leading, .leading, .leading],
                rows: [
                    [#"\d+\s and \n"#, "a | b", #"`\d+ | \w+`"#]
                ]
            )
        ])
    }

    @Test
    func officialLanguagePluginManifestsAndSyntaxJSONMatchCatalog() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cases: [(folder: String, expectedProfile: LanguageSyntaxProfile)] = [
            ("GoSupport", .go),
            ("RustSupport", .rust),
            ("PythonSupport", .python)
        ]

        let decoder = JSONDecoder()
        for entry in cases {
            let packageDir = repoRoot
                .appendingPathComponent("Plugins/mac/Official/\(entry.folder)", isDirectory: true)
            let manifestData = try Data(contentsOf: packageDir.appendingPathComponent("plugin.json"))
            let manifest = try decoder.decode(PluginManifest.self, from: manifestData)
            #expect(OfficialPluginCatalog.manifests.contains(manifest))
            #expect(manifest.metadata?.summary?.isEmpty == false)
            let profiles = try MacPluginPackageStore.loadSyntaxProfiles(at: packageDir, manifest: manifest)
            #expect(profiles == [entry.expectedProfile])
        }
    }

    @Test
    func declarativeConfigOnlyPluginInstallsLoadsAndTogglesWithoutNativeBundleOrRestart() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-declarative-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sourcePackage = tempRoot.appendingPathComponent("acme-src", isDirectory: true)
        let resourcesDir = sourcePackage.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

        let pluginJSON = #"""
        {
          "schemaVersion": 1,
          "id": "dev.lithe.plugin.acme-dsl",
          "displayName": "Acme DSL",
          "version": "0.3.1",
          "apiVersion": 1,
          "hostCompatibility": { "minimum": "0.3.1", "maximumExclusive": "0.4.0" },
          "vendor": { "id": "dev.lithe", "displayName": "Lithe", "signatureRequirement": "sameTeamAsHost" },
          "entrypoint": { "kind": "declarative" },
          "modules": [],
          "languageSupports": [
            {
              "id": "acme",
              "displayName": "Acme DSL",
              "fileExtensions": ["acme"],
              "fileNames": [],
              "projectFileNames": ["acme.toml"],
              "syntaxProfilePath": "Resources/syntax.json"
            }
          ],
          "metadata": {
            "summary": "Zero-code declarative syntax support for Acme DSL.",
            "iconSystemName": "doc.text.fill",
            "category": "declarative-language"
          }
        }
        """#
        let syntaxJSON = #"""
        {
          "languageID": "acme",
          "displayName": "Acme DSL",
          "fileExtensions": ["acme"],
          "supportsHashComments": true,
          "supportsSlashComments": false,
          "supportsBlockComments": false,
          "keywords": ["pipeline", "stage", "emit"],
          "builtinTypes": ["Record", "Stream"]
        }
        """#
        try Data(pluginJSON.utf8).write(to: sourcePackage.appendingPathComponent("plugin.json"))
        try Data(syntaxJSON.utf8).write(to: resourcesDir.appendingPathComponent("syntax.json"))

        let storeRoot = tempRoot.appendingPathComponent("store", isDirectory: true)
        let packageStore = MacPluginPackageStore(rootURL: storeRoot)
        _ = try packageStore.installPackage(from: sourcePackage)

        let kv = IsolatedPluginKeyValueStore()
        let configStore = MacModuleConfigurationStore(store: kv)
        let startup = MacPluginStartupLoader(packageStore: packageStore).load(
            policy: MacPluginLoadPolicy(
                configurationStore: configStore,
                recoveryStore: configStore,
                launchMode: .normal
            )
        )
        #expect(startup.issues.isEmpty)
        #expect(startup.activeNativeManifests.isEmpty)
        #expect(startup.syntaxProfilesByPlugin[PluginID("dev.lithe.plugin.acme-dsl")]?.first?.languageID == "acme")

        let isolatedRegistry = LanguageSyntaxProfileRegistry()
        let manager = MacPluginManager(
            packageStore: packageStore,
            moduleRuntime: ModuleRuntime(configurationStore: configStore, recoveryStore: configStore),
            configurationStore: configStore,
            launchMode: .normal,
            startup: startup,
            syntaxProfileRegistry: isolatedRegistry
        )

        #expect(isolatedRegistry.profile(forFileName: "job.acme", fileExtension: "acme").languageID == "acme")
        #expect(isolatedRegistry.profile(forFileName: "job.acme", fileExtension: "acme").keywords.contains("pipeline"))

        let pluginID = PluginID("dev.lithe.plugin.acme-dsl")
        let initialSnapshot = try #require(manager.snapshots.first { $0.id == pluginID })
        #expect(initialSnapshot.isEnabled)
        #expect(!initialSnapshot.requiresRestart)

        try await manager.setEnabled(false, for: pluginID)
        let disabledSnapshot = try #require(manager.snapshots.first { $0.id == pluginID })
        #expect(!disabledSnapshot.isEnabled)
        #expect(!disabledSnapshot.requiresRestart)
        #expect(isolatedRegistry.profile(forFileName: "job.acme", fileExtension: "acme").languageID == "generic")

        try await manager.setEnabled(true, for: pluginID)
        #expect(isolatedRegistry.profile(forFileName: "job.acme", fileExtension: "acme").languageID == "acme")
    }

    @Test
    func installingAndUninstallingDeclarativePluginActivatesAndCleansUpImmediatelyWithoutRestart() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-declarative-install-\(UUID().uuidString)", isDirectory: true)
        let sourcePackage = tempRoot.appendingPathComponent("source", isDirectory: true)
        let resourcesDir = sourcePackage.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let pluginJSON = #"""
        {
          "schemaVersion": 1,
          "id": "dev.lithe.plugin.beta-dsl",
          "displayName": "Beta DSL",
          "version": "0.3.1",
          "apiVersion": 1,
          "hostCompatibility": { "minimum": "0.3.1", "maximumExclusive": "0.4.0" },
          "vendor": { "id": "dev.lithe", "displayName": "Lithe", "signatureRequirement": "sameTeamAsHost" },
          "entrypoint": { "kind": "declarative" },
          "modules": [],
          "languageSupports": [
            {
              "id": "betadsl",
              "displayName": "Beta DSL",
              "fileExtensions": ["beta"],
              "fileNames": [],
              "projectFileNames": ["beta.toml"],
              "syntaxProfilePath": "Resources/syntax.json"
            }
          ],
          "metadata": {
            "summary": "Immediate zero-code declarative syntax plugin.",
            "iconSystemName": "doc.text.fill",
            "category": "declarative-language"
          }
        }
        """#
        let syntaxJSON = #"""
        {
          "languageID": "betadsl",
          "displayName": "Beta DSL",
          "fileExtensions": ["beta"],
          "supportsHashComments": true,
          "supportsSlashComments": false,
          "supportsBlockComments": false,
          "keywords": ["workflow", "step", "emit"]
        }
        """#
        try Data(pluginJSON.utf8).write(to: sourcePackage.appendingPathComponent("plugin.json"))
        try Data(syntaxJSON.utf8).write(to: resourcesDir.appendingPathComponent("syntax.json"))

        let storeRoot = tempRoot.appendingPathComponent("store", isDirectory: true)
        let packageStore = MacPluginPackageStore(rootURL: storeRoot)
        let kv = IsolatedPluginKeyValueStore()
        let configStore = MacModuleConfigurationStore(store: kv)
        let isolatedRegistry = LanguageSyntaxProfileRegistry()
        let manager = MacPluginManager(
            packageStore: packageStore,
            moduleRuntime: ModuleRuntime(configurationStore: configStore, recoveryStore: configStore),
            configurationStore: configStore,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [],
                activeNativeManifests: [],
                factoriesByPlugin: [:],
                syntaxProfilesByPlugin: [:],
                issues: []
            ),
            syntaxProfileRegistry: isolatedRegistry
        )

        #expect(isolatedRegistry.profile(forFileName: "app.beta", fileExtension: "beta").languageID == "generic")

        // Installing via the production MacPluginManager.installPackage(at:) path must activate immediately.
        try manager.installPackage(at: sourcePackage)
        let pluginID = PluginID("dev.lithe.plugin.beta-dsl")
        let installedSnap = try #require(manager.snapshots.first { $0.id == pluginID })
        #expect(installedSnap.isEnabled)
        #expect(installedSnap.isRunning)
        #expect(!installedSnap.requiresRestart)
        #expect(isolatedRegistry.profile(forFileName: "app.beta", fileExtension: "beta").languageID == "betadsl")
        #expect(isolatedRegistry.profile(forFileName: "app.beta", fileExtension: "beta").keywords.contains("workflow"))

        // Uninstalling a declarative plugin must clean up immediately without requiring a restart.
        try await manager.uninstall(pluginID)
        #expect(manager.snapshots.first { $0.id == pluginID } == nil)
        #expect(isolatedRegistry.profile(forFileName: "app.beta", fileExtension: "beta").languageID == "generic")
    }

    @Test
    func upgradingAndRollingBackDeclarativePluginUnregistersObsoleteLanguagesAndRespectsSafeMode() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-declarative-upgrade-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        func makePackage(dirName: String, version: String, langID: String, ext: String) throws -> URL {
            let pkg = tempRoot.appendingPathComponent(dirName, isDirectory: true)
            let res = pkg.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
            let pluginJSON = #"""
            {
              "schemaVersion": 1,
              "id": "dev.lithe.plugin.evolving-dsl",
              "displayName": "Evolving DSL",
              "version": "\#(version)",
              "apiVersion": 1,
              "hostCompatibility": { "minimum": "0.3.1", "maximumExclusive": "0.4.0" },
              "vendor": { "id": "dev.lithe", "displayName": "Lithe", "signatureRequirement": "sameTeamAsHost" },
              "entrypoint": { "kind": "declarative" },
              "modules": [],
              "languageSupports": [
                {
                  "id": "\#(langID)",
                  "displayName": "\#(langID.uppercased())",
                  "fileExtensions": ["\#(ext)"],
                  "fileNames": [],
                  "projectFileNames": [],
                  "syntaxProfilePath": "Resources/syntax.json"
                }
              ]
            }
            """#
            let syntaxJSON = #"""
            {
              "languageID": "\#(langID)",
              "displayName": "\#(langID.uppercased())",
              "fileExtensions": ["\#(ext)"],
              "keywords": ["rule"],
              "builtinFunctions": ["eval"]
            }
            """#
            try Data(pluginJSON.utf8).write(to: pkg.appendingPathComponent("plugin.json"))
            try Data(syntaxJSON.utf8).write(to: res.appendingPathComponent("syntax.json"))
            return pkg
        }

        let v1Pkg = try makePackage(dirName: "v1", version: "0.3.1", langID: "langa", ext: "langa")
        let v2Pkg = try makePackage(dirName: "v2", version: "0.3.2", langID: "langb", ext: "langb")

        let storeRoot = tempRoot.appendingPathComponent("store", isDirectory: true)
        let packageStore = MacPluginPackageStore(rootURL: storeRoot)
        let kv = IsolatedPluginKeyValueStore()
        let configStore = MacModuleConfigurationStore(store: kv)
        let isolatedRegistry = LanguageSyntaxProfileRegistry()
        let rev0 = isolatedRegistry.revision
        let manager = MacPluginManager(
            packageStore: packageStore,
            moduleRuntime: ModuleRuntime(configurationStore: configStore, recoveryStore: configStore),
            configurationStore: configStore,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [],
                activeNativeManifests: [],
                factoriesByPlugin: [:],
                issues: []
            ),
            syntaxProfileRegistry: isolatedRegistry
        )

        // Install v1 (langa).
        try manager.installPackage(at: v1Pkg)
        #expect(isolatedRegistry.revision > rev0)
        #expect(isolatedRegistry.profile(forFileName: "a.langa", fileExtension: "langa").languageID == "langa")
        #expect(isolatedRegistry.enrichment(for: "langa").builtinFunctions.contains("eval"))

        // Upgrade to v2 (langb): obsolete langa MUST be unregistered immediately.
        let rev1 = isolatedRegistry.revision
        try manager.installPackage(at: v2Pkg)
        #expect(isolatedRegistry.revision > rev1)
        #expect(isolatedRegistry.profile(forFileName: "a.langa", fileExtension: "langa").languageID == "generic")
        #expect(isolatedRegistry.profile(forFileName: "b.langb", fileExtension: "langb").languageID == "langb")

        // Rollback to v1 (langa): obsolete langb MUST be unregistered and langa restored.
        let pluginID = PluginID("dev.lithe.plugin.evolving-dsl")
        try manager.rollback(pluginID)
        #expect(isolatedRegistry.profile(forFileName: "b.langb", fileExtension: "langb").languageID == "generic")
        #expect(isolatedRegistry.profile(forFileName: "a.langa", fileExtension: "langa").languageID == "langa")

        // Safe Mode: toggling declarative plugin enabled must NOT activate its syntax profile.
        let safeRegistry = LanguageSyntaxProfileRegistry()
        let safeStartup = MacPluginStartupLoader(packageStore: packageStore).load(
            policy: MacPluginLoadPolicy(
                configurationStore: configStore,
                recoveryStore: configStore,
                launchMode: .safeMode
            )
        )
        let safeManager = MacPluginManager(
            packageStore: packageStore,
            moduleRuntime: ModuleRuntime(configurationStore: configStore, recoveryStore: configStore),
            configurationStore: configStore,
            launchMode: .safeMode,
            startup: safeStartup,
            syntaxProfileRegistry: safeRegistry
        )
        #expect(safeRegistry.profile(forFileName: "a.langa", fileExtension: "langa").languageID == "generic")
        try await safeManager.setEnabled(false, for: pluginID)
        try await safeManager.setEnabled(true, for: pluginID)
        let safeSnap = try #require(safeManager.snapshots.first { $0.id == pluginID })
        #expect(safeSnap.isSuppressedBySafeMode)
        #expect(!safeSnap.isRunning)
        #expect(safeRegistry.profile(forFileName: "a.langa", fileExtension: "langa").languageID == "generic")
    }

    @Test
    func replacingLoadedNativePluginWithDeclarativePackageDefersActivationAndRetiresActiveModulesOnDisable() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-native-to-declarative-\(UUID().uuidString)", isDirectory: true)
        let declSource = tempRoot.appendingPathComponent("decl-src", isDirectory: true)
        let resDir = declSource.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let pluginID = PluginID("dev.lithe.plugin.hybrid-test")
        let moduleID = ModuleID("dev.lithe.hybrid.exec")
        let moduleManifest = ModuleManifest(
            id: moduleID,
            displayName: "Hybrid Exec",
            scope: .workspace,
            defaultState: .enabled,
            activationPolicy: .onDemand,
            sleepPolicy: .never,
            dependencies: [],
            providedCapabilities: [ModuleCapabilityID("dev.lithe.capability.hybrid.exec")],
            isRequired: false
        )
        let nativeManifest = PluginManifest(
            schemaVersion: 1,
            id: pluginID,
            displayName: "Hybrid Test",
            version: PluginVersion(major: 0, minor: 3, patch: 1),
            apiVersion: 1,
            hostCompatibility: PluginHostCompatibility(
                minimum: PluginVersion(major: 0, minor: 3, patch: 1),
                maximumExclusive: PluginVersion(major: 0, minor: 4, patch: 0)
            ),
            vendor: PluginVendor(id: "dev.lithe", displayName: "Lithe", signatureRequirement: .sameTeamAsHost),
            entrypoint: PluginEntrypoint(
                kind: .nativeBundle,
                bundleIdentifier: "dev.lithe.plugin.hybrid-test.bundle",
                principalClass: "HybridEntrypoint",
                bundlePath: "Hybrid.bundle"
            ),
            modules: [PluginModuleDeclaration(manifest: moduleManifest)]
        )

        let declPluginJSON = #"""
        {
          "schemaVersion": 1,
          "id": "dev.lithe.plugin.hybrid-test",
          "displayName": "Hybrid Test",
          "version": "0.3.2",
          "apiVersion": 1,
          "hostCompatibility": { "minimum": "0.3.1", "maximumExclusive": "0.4.0" },
          "vendor": { "id": "dev.lithe", "displayName": "Lithe", "signatureRequirement": "sameTeamAsHost" },
          "entrypoint": { "kind": "declarative" },
          "modules": [],
          "languageSupports": [
            {
              "id": "hybrid",
              "displayName": "Hybrid",
              "fileExtensions": ["hyb"],
              "fileNames": [],
              "projectFileNames": [],
              "syntaxProfilePath": "Resources/syntax.json"
            }
          ]
        }
        """#
        let syntaxJSON = #"""
        {
          "languageID": "hybrid",
          "displayName": "Hybrid",
          "fileExtensions": ["hyb"],
          "keywords": ["hybrid"]
        }
        """#
        try Data(declPluginJSON.utf8).write(to: declSource.appendingPathComponent("plugin.json"))
        try Data(syntaxJSON.utf8).write(to: resDir.appendingPathComponent("syntax.json"))

        let kv = IsolatedPluginKeyValueStore()
        let configStore = MacModuleConfigurationStore(store: kv)
        let runtime = ModuleRuntime(configurationStore: configStore, recoveryStore: configStore)
        let shutdownCounter = HybridModuleShutdownCounter()
        try runtime.register(ModuleFactory(manifest: moduleManifest) {
            HybridActiveTestModule(manifest: moduleManifest, counter: shutdownCounter)
        })
        _ = try await runtime.activate(moduleID)

        let storeRoot = tempRoot.appendingPathComponent("store", isDirectory: true)
        let packageStore = MacPluginPackageStore(rootURL: storeRoot)
        let installedNative = InstalledPluginPackage(
            manifest: nativeManifest,
            installation: PluginInstallationRecord(
                pluginID: pluginID,
                activeVersion: nativeManifest.version,
                origin: .bundled
            ),
            packageURL: tempRoot
        )
        let isolatedRegistry = LanguageSyntaxProfileRegistry()
        let manager = MacPluginManager(
            packageStore: packageStore,
            moduleRuntime: runtime,
            configurationStore: configStore,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [installedNative],
                activeNativeManifests: [nativeManifest],
                factoriesByPlugin: [:],
                issues: []
            ),
            syntaxProfileRegistry: isolatedRegistry
        )

        // Installing a declarative replacement over a loaded native plugin MUST require restart.
        try manager.installPackage(at: declSource)
        let replacedSnap = try #require(manager.snapshots.first { $0.id == pluginID })
        #expect(replacedSnap.requiresRestart)
        #expect(replacedSnap.isRunning)

        // Disabling the plugin MUST still shut down the live native module instead of taking declarative-only branch.
        try await manager.setEnabled(false, for: pluginID)
        #expect(shutdownCounter.shutdownCount == 1)
        #expect(try runtime.snapshot(for: moduleID).state == .disabled)
    }

    @Test
    func disablingOfficialLanguagePluginIsolatesSyntaxAndRunnableDiscovery() async throws {
        let goManifest = try #require(OfficialPluginCatalog.manifests.first { $0.id == PluginID("dev.lithe.plugin.go-support") })
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-go-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let installed = InstalledPluginPackage(
            manifest: goManifest,
            installation: PluginInstallationRecord(
                pluginID: goManifest.id,
                activeVersion: goManifest.version,
                origin: .bundled
            ),
            packageURL: tempRoot
        )
        let kv = IsolatedPluginKeyValueStore()
        let configStore = MacModuleConfigurationStore(store: kv)
        let isolatedRegistry = LanguageSyntaxProfileRegistry()
        let manager = MacPluginManager(
            packageStore: MacPluginPackageStore(rootURL: tempRoot),
            moduleRuntime: ModuleRuntime(configurationStore: configStore, recoveryStore: configStore),
            configurationStore: configStore,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [installed],
                activeNativeManifests: [goManifest],
                factoriesByPlugin: [:],
                syntaxProfilesByPlugin: [goManifest.id: [.go]],
                issues: []
            ),
            syntaxProfileRegistry: isolatedRegistry
        )

        #expect(isolatedRegistry.profile(forFileName: "main.go", fileExtension: "go").languageID == "go")
        try await manager.setEnabled(false, for: goManifest.id)
        #expect(isolatedRegistry.isLanguageDisabled("go"))
        #expect(isolatedRegistry.profile(forFileName: "main.go", fileExtension: "go").languageID == "generic")

        let goRunnablesEnabled = DocumentRunnableDiscovery.discover(
            in: "package main\nfunc main() {}\n",
            url: URL(fileURLWithPath: "/tmp/demo/main.go"),
            isLanguageEnabled: { $0 == "go" }
        )
        let goRunnablesDisabled = DocumentRunnableDiscovery.discover(
            in: "package main\nfunc main() {}\n",
            url: URL(fileURLWithPath: "/tmp/demo/main.go"),
            isLanguageEnabled: { _ in false }
        )
        #expect(goRunnablesEnabled.count == 1)
        #expect(goRunnablesDisabled.isEmpty)
    }
}

private final class IsolatedPluginKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}


@MainActor
private final class HybridModuleShutdownCounter {
    var shutdownCount = 0
}

@MainActor
private final class HybridActiveTestModule: LitheModule {
    let manifest: ModuleManifest
    private let counter: HybridModuleShutdownCounter
    private let capability = NSObject()

    init(manifest: ModuleManifest, counter: HybridModuleShutdownCounter) {
        self.manifest = manifest
        self.counter = counter
    }

    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async { counter.shutdownCount += 1 }
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        [ModuleCapabilityID("dev.lithe.capability.hybrid.exec"): capability]
    }
    func contributions() -> [ModuleContribution] { [] }
}
