import Combine
import Foundation

/// Owns project sessions across native windows. Window tabbing changes only
/// presentation; it never recreates documents, terminals, or module sessions.
@MainActor
final class ProjectWindowManager: ObservableObject, UnsavedDocumentHandling {
    let initialWindowID = UUID()
    @Published private(set) var activeWindowID: UUID
    @Published private(set) var windowIDs: [UUID] = []
    var presentWindow: ((UUID) -> Void)?
    var focusWindow: ((UUID) -> Void)?
    var closeWindow: ((UUID) -> Void)?

    private let settings: AppSettings
    private let modelFactory: () -> AppModel
    private var managers: [UUID: ProjectSessionManager] = [:]
    private var managerObservations: [UUID: AnyCancellable] = [:]
    private var mostRecentSessions: ProjectSessionManager?
    private var pendingTabParents: [UUID: UUID] = [:]
    private var hasClaimedInitialWindow = false
    private var retiredWindowIDs: Set<UUID> = []
    private var closingWindows: [UUID: Task<Void, Never>] = [:]

    init(settings: AppSettings, modelFactory: @escaping () -> AppModel) {
        self.settings = settings
        self.modelFactory = modelFactory
        activeWindowID = initialWindowID
        mostRecentSessions = sessions(for: initialWindowID)
    }

    var activeSessions: ProjectSessionManager {
        managers[activeWindowID] ?? mostRecentSessions ?? sessions(for: initialWindowID)
    }

    /// Command lookup must never manufacture a replacement session or return
    /// a closing model merely because it was the most recently active one.
    func existingSessions(for id: UUID) -> ProjectSessionManager? {
        guard windowIDs.contains(id), closingWindows[id] == nil else { return nil }
        return managers[id]
    }

    /// WindowGroup may restore a prior process's UUID without calling its
    /// default-value factory. Accept that identity once, but never revive a
    /// window this process has closed or cancelled, even after teardown ends.
    @discardableResult
    func acceptRestoredScene(_ id: UUID) -> ProjectSessionManager? {
        guard !retiredWindowIDs.contains(id), closingWindows[id] == nil else { return nil }
        return sessions(for: id)
    }

    func commandModel(for context: ProjectCommandContext) -> AppModel? {
        guard let sessions = existingSessions(for: context.windowID),
              sessions.activeSessionID == context.sessionID,
              let model = sessions.sessions.first(where: { $0.id == context.sessionID }),
              model.commandContext(windowID: context.windowID) == context else { return nil }
        return model
    }

    func existingCommandHost(in presentedWindowIDs: Set<UUID>) -> (windowID: UUID, model: AppModel)? {
        let ordered = [activeWindowID] + windowIDs.filter { $0 != activeWindowID }
        for id in ordered {
            guard presentedWindowIDs.contains(id) else { continue }
            if let manager = existingSessions(for: id) { return (id, manager.activeModel) }
        }
        return nil
    }

    @discardableResult
    func openProjectFromApplication(_ url: URL) -> UUID? {
        if let existing = windowID(containing: url) {
            activate(existing)
            focusWindow?(existing)
            return existing
        }
        guard let presentWindow else { return nil }
        let id = UUID()
        sessions(for: id).openStartupProject(url)
        presentWindow(id)
        return id
    }

    @discardableResult
    func openFileFromApplication(_ url: URL) -> UUID? {
        guard let presentWindow else { return nil }
        let id = UUID()
        sessions(for: id).openStandaloneFile(url)
        presentWindow(id)
        return id
    }

    @discardableResult
    func presentWelcomeWindow(id: UUID = UUID()) -> UUID? {
        guard let presentWindow else { return nil }
        _ = sessions(for: id)
        presentWindow(id)
        return id
    }

    var hasUnsavedDocuments: Bool {
        managers.values.contains(where: \.hasUnsavedDocuments)
    }

    var unsavedDocumentNames: [String] {
        windowIDs.flatMap { managers[$0]?.unsavedDocumentNames ?? [] }
    }

    func defaultWindowID() -> UUID {
        guard hasClaimedInitialWindow else {
            hasClaimedInitialWindow = true
            return initialWindowID
        }
        let id = UUID()
        _ = sessions(for: id)
        return id
    }

    func sessions(for id: UUID) -> ProjectSessionManager {
        if let manager = managers[id] { return manager }
        let manager = ProjectSessionManager(
            settings: settings,
            modelFactory: modelFactory,
            newWindowOpener: { [weak self] url in
                self?.openProject(url, from: id, asTab: false)
            },
            tabOpener: { [weak self] url in
                self?.openProject(url, from: id, asTab: true)
            },
            windowCloser: { [weak self] in self?.closeWindow?(id) },
            activateExistingProject: { [weak self] url in
                self?.activateProject(url, excluding: id) ?? false
            },
            openProjectsProvider: { [weak self] in
                guard let self else { return [] }
                return self.windowIDs.flatMap { self.managers[$0]?.openProjects ?? [] }
            }
        )
        manager.activeModel.setProjectSessionActive(id == activeWindowID)
        managers[id] = manager
        managerObservations[id] = manager.objectWillChange.sink { [weak self] in
            guard let self, self.activeWindowID == id else { return }
            self.objectWillChange.send()
        }
        windowIDs.append(id)
        return manager
    }

    @discardableResult
    func openProject(_ url: URL, from source: UUID, asTab: Bool) -> UUID {
        if let existing = windowID(containing: url) {
            activate(existing)
            focusWindow?(existing)
            return existing
        }
        let id = UUID()
        let manager = sessions(for: id)
        manager.openStartupProject(url)
        if asTab, managers[source]?.activeModel.workspaceURL != nil {
            pendingTabParents[id] = source
        }
        presentWindow?(id)
        return id
    }

    func takeTabParent(for id: UUID) -> UUID? {
        pendingTabParents.removeValue(forKey: id)
    }

    func activate(_ id: UUID) {
        guard id != activeWindowID, let manager = managers[id], closingWindows[id] == nil else { return }
        // Shortcut detectors install application-wide AppKit event monitors.
        // Only the focused project's detector may consume editor commands.
        managers[activeWindowID]?.activeModel.setProjectSessionActive(false)
        manager.activeModel.setProjectSessionActive(true)
        mostRecentSessions = manager
        activeWindowID = id
    }

    func openStandaloneFile(_ url: URL) {
        activeSessions.openStandaloneFile(url)
        focusWindow?(activeWindowID)
    }

    @discardableResult
    func saveAllDocuments() async -> Bool {
        await DocumentSaveBatch.save { windowIDs.compactMap { managers[$0] } }
    }

    func windowClosed(_ id: UUID) {
        retiredWindowIDs.insert(id)
        guard let manager = managers[id], closingWindows[id] == nil else { return }
        pendingTabParents[id] = nil
        windowIDs.removeAll { $0 == id }
        if activeWindowID == id, let next = windowIDs.last { activate(next) }
        // Retain a closing manager until teardown finishes so application quit
        // can also await cleanup for windows that have just disappeared.
        closingWindows[id] = Task { @MainActor [weak self, manager] in
            await manager.stopAllSessions()
            self?.managers[id] = nil
            self?.managerObservations[id] = nil
            self?.closingWindows[id] = nil
        }
    }

    func stopAllSessions() async {
        for id in windowIDs {
            await managers[id]?.stopAllSessions()
        }
        let pending = Array(closingWindows.values)
        for task in pending { await task.value }
    }

    func resumeGitObservationAfterActivation() async {
        for id in windowIDs {
            await managers[id]?.resumeGitObservationAfterActivation()
        }
    }

    private func windowID(containing url: URL) -> UUID? {
        let normalized = url.standardizedFileURL
        return windowIDs.first { id in
            managers[id]?.openProjects.contains {
                $0.workspaceURL?.standardizedFileURL == normalized
            } == true
        }
    }

    private func activateProject(_ url: URL, excluding source: UUID) -> Bool {
        guard let id = windowID(containing: url), id != source,
              let manager = managers[id],
              let model = manager.openProjects.first(where: {
                  $0.workspaceURL?.standardizedFileURL == url.standardizedFileURL
              }) else { return false }
        manager.activateSession(model.id)
        activate(id)
        focusWindow?(id)
        return true
    }
}
