import Foundation
import LitheModuleAPI
import LitheTerminalModule
import Testing
@testable import Lithe

@Suite("Terminal tab placement")
@MainActor
struct TerminalPlacementFeatureModelTests {
    @Test
    func shellExitClosesTabAndHidesPanelForLastToolTerminal() async throws {
        let context = makeTerminalCloseContext()
        let model = context.model
        let feature = try #require(model.terminalFeature)
        defer { feature.stopAllSessions() }
        try await settleTerminalCallbacks()
        model.terminalPlacementFeature.moveToTool(context.session.id)
        model.isTerminalVisible = true
        model.configureInteractiveTerminalSession(context.session)

        context.transport.onTermination?(0)
        try await settleTerminalCallbacks()

        #expect(model.terminalSessions.isEmpty)
        #expect(!model.isTerminalVisible)
        #expect(!context.session.isRunning)
        #expect(context.transport.stopCount == 1)
    }

    @Test
    func shellExitKeepsPanelAndSurvivingToolTerminalsRunning() async throws {
        let context = makeTerminalCloseContext()
        let model = context.model
        let feature = try #require(model.terminalFeature)
        defer { feature.stopAllSessions() }
        let survivor = feature.createSession(
            in: URL(fileURLWithPath: "/tmp/lithe-terminal-close-tests"), shellPath: "/bin/zsh"
        )
        model.terminalPlacementFeature.registerSession(survivor.id)
        model.terminalPlacementFeature.moveToTool(context.session.id)
        model.terminalPlacementFeature.moveToTool(survivor.id)
        try await settleTerminalCallbacks()
        model.isTerminalVisible = true
        model.configureInteractiveTerminalSession(context.session)

        context.transport.onTermination?(0)
        try await settleTerminalCallbacks()

        #expect(model.isTerminalVisible)
        #expect(model.toolTerminalSessions.map(\.id) == [survivor.id])
        #expect(survivor.isRunning)
    }

    @Test
    func shellExitClosesEditorAreaTerminalTab() async throws {
        let context = makeTerminalCloseContext()
        let model = context.model
        let feature = try #require(model.terminalFeature)
        defer { feature.stopAllSessions() }
        try await settleTerminalCallbacks()
        model.configureInteractiveTerminalSession(context.session)

        context.transport.onTermination?(0)
        try await settleTerminalCallbacks()

        #expect(model.terminalSessions.isEmpty)
        #expect(model.terminalPlacementFeature.editorSessionIDs.isEmpty)
        #expect(model.terminalPlacementFeature.toolSessionIDs.isEmpty)
    }

    @Test
    func restartAfterShellExitKeepsTheRestartedSession() async throws {
        let context = makeTerminalCloseContext()
        let model = context.model
        let feature = try #require(model.terminalFeature)
        defer { feature.stopAllSessions() }
        model.terminalPlacementFeature.moveToTool(context.session.id)
        try await settleTerminalCallbacks()
        model.isTerminalVisible = true
        model.configureInteractiveTerminalSession(context.session)

        context.transport.onTermination?(0)
        context.session.restart()
        try await settleTerminalCallbacks()

        #expect(model.toolTerminalSessions.map(\.id) == [context.session.id])
        #expect(context.session.isRunning)
        #expect(model.isTerminalVisible)
    }

    @Test
    func unsuccessfulShellExitKeepsDiagnosticsVisible() async throws {
        let context = makeTerminalCloseContext()
        defer { context.model.terminalFeature?.stopAllSessions() }
        context.model.configureInteractiveTerminalSession(context.session)
        context.transport.onTermination?(127)
        try await settleTerminalCallbacks()
        #expect(context.model.terminalSessions.contains { $0.id == context.session.id })
        #expect(context.session.lastError != nil)
    }

    private func settleTerminalCallbacks() async throws {
        let finished = TestGate()
        DispatchQueue.main.async { finished.open() }
        try #require(await finished.waitUntilOpen())
    }

    @Test
    func reordersTerminalToolTabs() {
        let model = TerminalPlacementFeatureModel()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        [first, second, third].forEach(model.registerSession)

        model.moveToTool(first, after: third)
        #expect(model.toolSessionIDs == [second, third, first])

        model.moveToTool(first, before: second)
        #expect(model.toolSessionIDs == [first, second, third])
        #expect(model.editorSessionIDs.isEmpty)
    }

    @Test
    func movesAUniqueSessionBetweenToolAndEditor() {
        let model = TerminalPlacementFeatureModel()
        let sessionID = UUID()
        model.registerSession(sessionID)

        model.moveToEditor(sessionID)
        #expect(model.toolSessionIDs.isEmpty)
        #expect(model.editorSessionIDs == [sessionID])
        #expect(model.activeEditorSessionID == sessionID)

        model.moveToTool(sessionID)
        #expect(model.toolSessionIDs == [sessionID])
        #expect(model.editorSessionIDs.isEmpty)
        #expect(model.activeEditorSessionID == nil)
    }

    @Test
    func reordersEditorTerminalTabsAndSelectsTheMovedSession() {
        let model = TerminalPlacementFeatureModel()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        [first, second, third].forEach(model.registerSession)
        [first, second, third].forEach(model.moveToEditor)

        model.moveToEditor(first, after: third)

        #expect(model.editorSessionIDs == [second, third, first])
        #expect(model.activeEditorSessionID == first)
        #expect(model.toolSessionIDs.isEmpty)
    }

    @Test
    func reconcilesEditorTerminalOrderWithTheMixedTabProjection() {
        let model = TerminalPlacementFeatureModel()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        [first, second, third].forEach(model.registerSession)
        [first, second, third].forEach(model.moveToEditor)

        model.reorderEditorSessions(orderedIDs: [third, first, second])

        #expect(model.editorSessionIDs == [third, first, second])
        #expect(model.activeEditorSessionID == third)
    }

    @Test
    func cancelingRunningTerminalCloseKeepsTheSessionAlive() {
        let context = makeTerminalCloseContext()

        #expect(context.model.requestCloseActiveWorkbenchItem())
        #expect(context.model.pendingTerminalCloseSessionID == context.session.id)
        #expect(context.model.terminalSessions.contains { $0.id == context.session.id })
        #expect(context.transport.stopCount == 0)

        context.model.cancelTerminalClose()

        #expect(context.model.pendingTerminalCloseSessionID == nil)
        #expect(context.model.terminalSessions.contains { $0.id == context.session.id })
        #expect(context.session.isRunning)
        #expect(context.transport.stopCount == 0)
    }

    @Test
    func confirmingRunningTerminalCloseStopsAndRemovesTheSession() {
        let context = makeTerminalCloseContext()

        #expect(context.model.requestCloseActiveWorkbenchItem())
        #expect(context.model.pendingTerminalCloseSessionID == context.session.id)
        #expect(context.transport.stopCount == 0)

        context.model.confirmTerminalClose()

        #expect(context.model.pendingTerminalCloseSessionID == nil)
        #expect(!context.model.terminalSessions.contains { $0.id == context.session.id })
        #expect(context.model.activeEditorTerminalSession == nil)
        #expect(!context.session.isRunning)
        #expect(context.transport.stopCount == 1)
    }

    private func makeTerminalCloseContext() -> (
        model: AppModel,
        session: TerminalSession,
        transport: PlacementTestTerminalTransport
    ) {
        let store = TerminalPlacementTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
        ).services
        let model = AppModel(settings: settings, services: services)
        let transport = PlacementTestTerminalTransport()
        var createdInitialTransport = false
        let feature = TerminalFeatureModel(terminalFactory: {
            if !createdInitialTransport { createdInitialTransport = true; return transport }
            return PlacementTestTerminalTransport()
        })
        model.cacheModuleCapability(
            TerminalModuleCapability(feature: feature),
            id: .terminalWorkspace,
            moduleID: .terminal
        )
        let session = feature.createSession(
            in: URL(fileURLWithPath: "/tmp/lithe-terminal-close-tests"),
            shellPath: "/bin/zsh"
        )
        model.terminalPlacementFeature.registerSession(session.id)
        model.terminalPlacementFeature.moveToEditor(session.id)
        return (model, session, transport)
    }

    @Test
    func movingPresentationNeverStopsOrRecreatesTheTerminalTransport() {
        let transport = PlacementTestTerminalTransport()
        let terminalFeature = TerminalFeatureModel(terminalFactory: { transport })
        let placement = TerminalPlacementFeatureModel()
        let session = terminalFeature.createSession(
            in: URL(fileURLWithPath: "/tmp/lithe-terminal-placement-tests"),
            shellPath: "/bin/zsh"
        )
        let nativeViewID = ObjectIdentifier(session.nativeView)
        placement.registerSession(session.id)

        placement.moveToEditor(session.id)
        placement.moveToTool(session.id)

        #expect(transport.startCount == 1)
        #expect(transport.stopCount == 0)
        #expect(session.isRunning)
        #expect(ObjectIdentifier(session.nativeView) == nativeViewID)

        terminalFeature.stopAllSessions()
        #expect(transport.stopCount == 1)
    }
}

@MainActor
private final class PlacementTestTerminalTransport: TerminalTransport {
    let nativeView: AnyObject = NSObject()
    var isRunning = false
    var processID: Int32? { isRunning ? 1234 : nil }
    var shellName = "Shell"
    var onTermination: ((Int32?) -> Void)?
    var onOutput: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectoryUpdate: ((String?) -> Void)?
    var onVirtualEnvironmentState: ((TerminalVirtualEnvironmentState) -> Void)?
    var onLink: ((String, [String: String]) -> Void)?
    var startCount = 0
    var stopCount = 0

    func applyDisplayConfiguration(_ configuration: TerminalDisplayConfiguration) -> [String] { [] }
    func defaultShellPath() -> String { "/bin/zsh" }
    func defaultEnvironment() -> [String: String] { [:] }

    func prepareShellLaunch(_ configuration: TerminalShellConfiguration, context: TerminalLaunchContext) throws -> TerminalShellLaunch {
        try configuration.launchPlan(context: context, systemShell: defaultShellPath(), homeDirectory: URL(fileURLWithPath: "/fake-home"), inheritedEnvironment: defaultEnvironment())
    }

    func resolveExecutablePath(_ executablePath: String, workingDirectory: String, environment: [String: String]) throws -> String { executablePath }

    func start(
        workingDirectory: String,
        shellPath: String,
        environment: [String: String]
    ) throws {
        startCount += 1
        isRunning = true
    }

    func startProcess(
        _ launch: TerminalProcessLaunch,
        environment: [String: String]
    ) throws -> Int32 {
        startCount += 1
        isRunning = true
        return 1234
    }

    func send(_ input: Data) throws {}
    func interrupt() throws {}
    func focus() {}
    func clear() {}

    func stop() {
        guard isRunning else { return }
        stopCount += 1
        isRunning = false
    }
}

private final class TerminalPlacementTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
