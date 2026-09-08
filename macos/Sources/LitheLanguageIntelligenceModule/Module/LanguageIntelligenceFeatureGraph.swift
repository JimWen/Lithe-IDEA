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

    package init(sessions: LanguageToolingSessionManager, tools: LanguageServerToolService) {
        self.sessions = sessions
        self.tools = tools
    }

    package var isActive: Bool { !sessions.activeLanguageServerIDs.isEmpty }
    package var hasActiveLanguageServers: Bool { isActive }

    package func activate(context: ModuleContext) {
        catalogObservation = sessions.$catalogSnapshot.sink { [weak self] catalog in
            self?.refreshDiscovery(for: catalog)
        }
    }

    private func refreshDiscovery(for catalog: LanguageProviderCatalog) {
        let descriptors = Dictionary(uniqueKeysWithValues: catalog.descriptors
            .filter { $0.capabilities.contains(.languageServer) && $0.languageServerLaunch != nil }
            .map { ($0.id, $0) })
        for providerID in Set(discoveryDescriptors.keys).union(descriptors.keys)
        where discoveryDescriptors[providerID] != descriptors[providerID] {
            discoveryTasks[providerID]?.cancel()
            tools.invalidateCandidates(for: providerID)
            let previousTask = discoveryTasks[providerID]
            // Retain superseded work until its bounded validation exits, so
            // module shutdown owns every discovery process as well as LSP.
            discoveryTasks[providerID] = Task { [tools] in
                await previousTask?.value
                guard !Task.isCancelled, let descriptor = descriptors[providerID] else { return }
                await tools.refreshCandidates(for: descriptor)
            }
        }
        discoveryDescriptors = descriptors
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
