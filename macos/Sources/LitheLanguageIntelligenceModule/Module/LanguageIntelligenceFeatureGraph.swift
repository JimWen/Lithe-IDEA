import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
package final class LanguageIntelligenceFeatureGraph: NSObject, LanguageIntelligenceServiceGraph {
    package let sessions: LanguageToolingSessionManager
    package let tools: LanguageServerToolService
    private var catalogObservation: AnyCancellable?
    private var discoveryDescriptors: [String: LanguageProviderDescriptor] = [:]
    private var discoveryTasks: [String: Task<Void, Never>] = [:]
    private var hasEnabledDiscovery = false

    package init(sessions: LanguageToolingSessionManager, tools: LanguageServerToolService) {
        self.sessions = sessions
        self.tools = tools
    }

    package var isActive: Bool { !sessions.activeLanguageServerIDs.isEmpty }
    package var hasActiveLanguageServers: Bool { isActive }

    package func activate(context: ModuleContext) {
        // Lightweight Mode activates this module for in-process symbols, hover,
        // completions, and navigation without spawning external LSP probes.
        // Discovery starts lazily only when Precision LSP mode or LSP settings
        // explicitly request executable validation.
        catalogObservation = sessions.$catalogSnapshot.sink { [weak self] catalog in
            guard let self, self.hasEnabledDiscovery else { return }
            self.refreshDiscovery(for: catalog)
        }
    }

    /// Starts or refreshes lazy LSP executable discovery for one provider or the full catalog.
    package func ensureDiscoveryStarted(for providerID: String? = nil) {
        if let providerID {
            guard let descriptor = sessions.catalogSnapshot.descriptors.first(where: { $0.id == providerID }),
                  descriptor.capabilities.contains(.languageServer),
                  descriptor.languageServerLaunch != nil else { return }
            if discoveryDescriptors[providerID] == descriptor, discoveryTasks[providerID] != nil {
                return
            }
            scheduleDiscovery(for: descriptor)
            discoveryDescriptors[providerID] = descriptor
            return
        }
        hasEnabledDiscovery = true
        refreshDiscovery(for: sessions.catalogSnapshot)
    }

    private func refreshDiscovery(for catalog: LanguageProviderCatalog) {
        let descriptors = Dictionary(uniqueKeysWithValues: catalog.descriptors
            .filter { $0.capabilities.contains(.languageServer) && $0.languageServerLaunch != nil }
            .map { ($0.id, $0) })
        for providerID in Set(discoveryDescriptors.keys).union(descriptors.keys)
        where discoveryDescriptors[providerID] != descriptors[providerID] {
            if let descriptor = descriptors[providerID] {
                scheduleDiscovery(for: descriptor)
            } else {
                discoveryTasks[providerID]?.cancel()
                tools.invalidateCandidates(for: providerID)
                discoveryTasks[providerID] = nil
            }
        }
        discoveryDescriptors = descriptors
    }

    private func scheduleDiscovery(for descriptor: LanguageProviderDescriptor) {
        let providerID = descriptor.id
        discoveryTasks[providerID]?.cancel()
        tools.invalidateCandidates(for: providerID)
        let previousTask = discoveryTasks[providerID]
        // Retain superseded work until its bounded validation exits, so
        // module shutdown owns every discovery process as well as LSP.
        discoveryTasks[providerID] = Task { [tools] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await tools.refreshCandidates(for: descriptor)
        }
    }

    package func prepareForSleep() async throws {
        guard !isActive else {
            throw LanguageIntelligenceSleepError.activeServers(
                "Language servers are still active and cannot be put to sleep."
            )
        }
    }

    package func stop() async {
        catalogObservation = nil
        hasEnabledDiscovery = false
        let tasks = Array(discoveryTasks.values)
        for (providerID, task) in discoveryTasks {
            task.cancel()
            tools.invalidateCandidates(for: providerID)
        }
        discoveryTasks.removeAll()
        discoveryDescriptors.removeAll()
        for task in tasks { await task.value }
        sessions.stopAll()
        sessions.clearDiagnostics()
    }
}

private enum LanguageIntelligenceSleepError: LocalizedError {
    case activeServers(String)

    var errorDescription: String? {
        switch self {
        case .activeServers(let message): message
        }
    }
}
