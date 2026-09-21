import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
struct LanguageToolingFeatureModelTests {
    @Test
    func discoveryWaitRetriesWithoutReportingAMissingExecutable() {
        let source = FixedLanguageCatalogSource()
        let model = LanguageToolingFeatureModel(
            catalogSource: source, catalogSnapshot: source.load(workspaceURL: nil),
            preferences: FeatureLanguagePreferences(),
            sessionsProvider: { nil }
        )
        model.reloadCatalog(for: URL(fileURLWithPath: "/fixture/go-workspace"))
        var messages: [String] = []
        model.configure(
            documentsProvider: { [] },
            activateDocument: { _ in false }, notify: { messages.append($0) }
        )

        model.awaitCandidates(providerID: "go")
        #expect(model.shouldRetryCandidate(providerID: "go"))
        #expect(model.startupFailures.isEmpty)
        #expect(messages.isEmpty)
        model.markActivationSucceeded(providerID: "go")
        #expect(!model.shouldRetryCandidate(providerID: "go"))

        model.awaitCandidates(providerID: "go")
        model.setEnabled(false, providerID: "go")
        #expect(!model.shouldRetryCandidate(providerID: "go"))
        model.awaitCandidates(providerID: "go")
        model.resetWorkspaceState()
        #expect(!model.shouldRetryCandidate(providerID: "go"))
    }

    @Test
    func activeCatalogProjectionRetainsSourceDiagnosticsAndRevertsOnUnbind() {
        let source = FixedLanguageCatalogSource()
        let snapshot = source.load(workspaceURL: nil)
        let model = LanguageToolingFeatureModel(
            catalogSource: source, catalogSnapshot: snapshot,
            preferences: FeatureLanguagePreferences(), sessionsProvider: { nil }
        )
        let descriptor = LanguageProviderDescriptor(
            id: "go", displayName: "Go", fileExtensions: ["go"],
            capabilities: [.languageServer], activationPolicy: .onDemand,
            languageServerLaunch: LanguageServerLaunchDescriptor(executableNames: ["gopls"])
        )
        model.updateSessionCatalog(LanguageProviderCatalog(descriptors: [descriptor]))
        #expect(model.catalog.descriptors == [descriptor])
        #expect(model.catalogSnapshot.origin == snapshot.origin)
        #expect(model.catalogSnapshot.issues == snapshot.issues)
        #expect(model.catalogSnapshot.schemaVersion == snapshot.schemaVersion)
        model.updateSessionCatalog(nil)
        #expect(model.catalog.descriptors == snapshot.catalog.descriptors)
    }
}

private struct FixedLanguageCatalogSource: LanguageProviderCatalogSource {
    func load(workspaceURL _: URL?) -> LanguageProviderCatalogSnapshot {
        LanguageProviderCatalogSnapshot(
            catalog: LanguageProviderCatalog(descriptors: []), schemaVersion: 2,
            origin: .builtin,
            issues: [.init(path: "fixture", message: "Rejected fixture override")]
        )
    }
}

private final class FeatureLanguagePreferences: WorkspaceLanguageServerPreferencesStoring {
    private var values: [URL: Set<String>] = [:]
    func disabledProviderIDs(for workspaceURL: URL) -> Set<String> {
        values[workspaceURL.standardizedFileURL] ?? []
    }
    func saveDisabledProviderIDs(_ providerIDs: Set<String>, for workspaceURL: URL) {
        values[workspaceURL.standardizedFileURL] = providerIDs
    }
}
