import Combine
import Foundation
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("Workspace language server preferences")
@MainActor
struct WorkspaceLanguageServerPreferencesTests {
    private let workspace = URL(fileURLWithPath: "/example/lsp-project", isDirectory: true)

    @Test
    func disabledPluginServerRemainsConfigurableAfterReopeningWorkspace() throws {
        // Plugin launch metadata is attached only after activation. A persisted
        // disabled server must remain visible so the user can activate it again.
        let catalog = LanguageProviderCatalog.compatibilityFallback.applying(languageSupports: [
            LanguageSupportDeclaration(
                id: "go",
                displayName: "Go",
                fileExtensions: ["go"],
                languageServerModuleID: .languageServerExtension("go")
            )
        ])
        let store = LanguagePreferencesTestStore()
        let feature = makeFeature(store: store, catalog: catalog)
        feature.reloadCatalog(for: workspace)
        feature.setEnabled(false, providerID: "go")

        let reopened = makeFeature(store: store, catalog: catalog)
        reopened.reloadCatalog(for: workspace)
        let goDocument = document("main.go")
        let providers = LSPControlCenterPresenter.projectLanguageServers(
            catalog: reopened.catalog,
            files: [goDocument.url, workspace.appendingPathComponent("README.md")]
        )
        #expect(providers.map(\.id) == ["go"])
        let provider = try #require(providers.first)
        #expect(provider.languageServerLaunch == nil)
        #expect(LSPControlCenterPresenter.serverStatus(
            isDisabled: reopened.isDisabled(provider.id), sessionState: nil
        ) == .disabled)
        var activatedURLs: [URL] = []
        reopened.configure(
            documentsProvider: { [goDocument] },
            activateDocument: { [weak reopened] document in
                #expect(reopened?.isDisabled("go") == false)
                activatedURLs.append(document.url)
                return true
            },
            notify: { _ in }
        )
        reopened.setEnabled(true, providerID: provider.id)
        #expect(activatedURLs == [goDocument.url])
    }

    @Test
    func syntaxOnlyPluginDoesNotExposeLanguageServerSettings() {
        let catalog = LanguageProviderCatalog.compatibilityFallback.applying(languageSupports: [
            LanguageSupportDeclaration(id: "go", displayName: "Go", fileExtensions: ["go"])
        ])
        #expect(LSPControlCenterPresenter.projectLanguageServers(
            catalog: catalog, files: [workspace.appendingPathComponent("main.go")]
        ).isEmpty)
    }

    @Test
    func disabledLanguagesSurviveNewPreferenceAndFeatureInstances() throws {
        let suiteName = "lithe-test-lsp-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feature = makeFeature(store: MacUserDefaultsStore(defaults: defaults))
        feature.reloadCatalog(for: workspace)
        #expect(!feature.isDisabled("python"))
        feature.setEnabled(false, providerID: "python")
        feature.setEnabled(false, providerID: "go")
        feature.setEnabled(false, providerID: "rust")
        // A temporarily unavailable plugin must keep its preference so a later
        // catalog update does not silently enable its language server again.
        feature.setEnabled(false, providerID: "example-plugin-language")

        let reopenedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let reopened = makeFeature(store: MacUserDefaultsStore(defaults: reopenedDefaults))
        reopened.reloadCatalog(for: workspace.appendingPathComponent("child/..", isDirectory: true))
        #expect(reopened.disabledProviderIDs == ["example-plugin-language", "go", "python", "rust"])

        reopened.reloadCatalog(for: URL(fileURLWithPath: "/example/another-project"))
        #expect(reopened.disabledProviderIDs.isEmpty)
        reopened.setEnabled(false, providerID: "python")
        reopened.reloadCatalog(for: workspace)
        #expect(reopened.disabledProviderIDs == ["example-plugin-language", "go", "python", "rust"])
    }

    @Test(arguments: ["python", "go", "rust"])
    func reenablingPersistsBeforeMatchingDocumentsAreActivated(_ providerID: String) throws {
        let store = LanguagePreferencesTestStore()
        let feature = makeFeature(store: store)
        feature.reloadCatalog(for: workspace)
        let documentsByProvider = [
            "python": document("main.py"),
            "go": document("main.go"),
            "rust": document("main.rs")
        ]
        for id in documentsByProvider.keys.sorted() {
            feature.setEnabled(false, providerID: id)
        }
        let enabledDocument = try #require(documentsByProvider[providerID])
        let remainingDisabled = Set(documentsByProvider.keys).subtracting([providerID])
        var activatedURLs: [URL] = []
        feature.configure(
            documentsProvider: { documentsByProvider.keys.sorted().compactMap { documentsByProvider[$0] } },
            activateDocument: { document in
                let reopened = makeFeature(store: store)
                reopened.reloadCatalog(for: workspace)
                #expect(!reopened.isDisabled(providerID))
                #expect(reopened.disabledProviderIDs == remainingDisabled)
                activatedURLs.append(document.url)
                return true
            },
            notify: { _ in }
        )

        feature.setEnabled(true, providerID: providerID)

        #expect(activatedURLs == [enabledDocument.url])
        #expect(store.values.values.compactMap { $0 as? [String] } == [remainingDisabled.sorted()])
    }

    @Test
    func runtimeResetAndToolChangesPreserveDisabledLanguages() {
        let store = LanguagePreferencesTestStore()
        let feature = makeFeature(store: store)
        feature.reloadCatalog(for: workspace)
        feature.setEnabled(false, providerID: "python")

        feature.resetWorkspaceState()
        feature.toolConfigurationDidChange(providerID: "python")
        #expect(feature.isDisabled("python"))

        feature.reloadCatalog(for: nil)
        #expect(feature.disabledProviderIDs.isEmpty)
        feature.reloadCatalog(for: workspace)
        #expect(feature.isDisabled("python"))
    }

    @Test
    func togglesPublishEvenWithoutARunningLanguageModule() {
        let feature = makeFeature(store: LanguagePreferencesTestStore())
        feature.reloadCatalog(for: workspace)
        var changes = 0
        let observation = feature.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        feature.setEnabled(false, providerID: "python")
        #expect(changes == 1)
        feature.setEnabled(true, providerID: "python")
        #expect(changes == 2)
    }

    @Test
    func togglesWithoutAWorkspaceDoNotOverwritePreferences() {
        let store = LanguagePreferencesTestStore()
        let feature = makeFeature(store: store)
        feature.setEnabled(false, providerID: "python")

        #expect(feature.disabledProviderIDs.isEmpty)
        #expect(store.values.isEmpty)
    }

    private func document(_ name: String) -> EditorDocument {
        EditorDocument(url: workspace.appendingPathComponent(name), text: "", modificationDate: nil)
    }

    private func makeFeature(
        store: any KeyValueStore,
        catalog: LanguageProviderCatalog = .compatibilityFallback
    ) -> LanguageToolingFeatureModel {
        let source = LanguagePreferencesTestCatalogSource(catalog: catalog)
        return LanguageToolingFeatureModel(
            catalogSource: source,
            catalogSnapshot: source.load(workspaceURL: nil),
            preferences: MacWorkspaceLanguageServerPreferencesStore(store: store),
            sessionsProvider: { nil }
        )
    }

}

private struct LanguagePreferencesTestCatalogSource: LanguageProviderCatalogSource {
    let catalog: LanguageProviderCatalog

    func load(workspaceURL: URL?) -> LanguageProviderCatalogSnapshot {
        LanguageProviderCatalogSnapshot(
            catalog: catalog,
            schemaVersion: nil,
            origin: .builtin,
            issues: []
        )
    }
}

private final class LanguagePreferencesTestStore: KeyValueStore {
    private(set) var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
