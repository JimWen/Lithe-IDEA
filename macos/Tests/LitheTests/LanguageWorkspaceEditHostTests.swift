import Combine
import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("Language workspace edit host", .serialized)
@MainActor
struct LanguageWorkspaceEditHostTests {
    @Test(arguments: [false, true])
    func editingSnapshotAcknowledgesOnlySuccessfullySynchronizedNativeChanges(syncFails: Bool) async throws {
        try await withFixture { fixture in
            #expect(fixture.document.applyLiveEditorEdit(replacedRange: NSRange(location: 3, length: 0), replacement: "!"))
            fixture.session.failNextSynchronization = syncFails
            fixture.model.requestLanguageRename(line: 0, utf16Column: 0, newName: "new")
            // This is the same consumption boundary as the deferred native
            // editor callback. A full accepted snapshot must cover its delta.
            let pending = fixture.document.takePendingLanguageServerChanges()
            #expect(pending.count == (syncFails ? 1 : 0))
            if syncFails {
                #expect(fixture.session.renames.isEmpty)
            } else {
                let version = fixture.session.synchronizedDocumentSnapshot(for: fixture.document.url)?.version
                let response = fixture.edit()
                fixture.model.documentDidChange(fixture.document)
                #expect(fixture.session.synchronizedDocumentSnapshot(for: fixture.document.url)?.version == version)
                let reply = try #require(fixture.session.renames.first)
                reply(.success(response))
                await fixture.model.languageEditTask?.value
                #expect(fixture.document.text == "new!")
            }
        }
    }

    @Test
    func renameUsesOriginalVersionAndRejectsChangeAwayAndBack() async throws {
        try await withFixture { fixture in
            fixture.model.requestLanguageRename(line: 0, utf16Column: 0, newName: "new")
            let reply = try #require(fixture.session.renames.first)
            fixture.document.text = "other"
            fixture.document.text = "old"
            reply(.success(fixture.edit()))
            #expect(fixture.model.languageEditTask == nil)
            #expect(fixture.document.text == "old")
            fixture.model.requestLanguageRename(line: 0, utf16Column: 0, newName: "new")
            let currentReply = try #require(fixture.session.renames.last)
            currentReply(.success(fixture.edit()))
            await fixture.model.languageEditTask?.value
            #expect(fixture.document.text == "new")
            #expect(fixture.document.isDirty)
            #expect(fixture.model.services.workspaceTextEditUndoController.canUndo)
        }
    }

    @Test
    func actionCommandWaitsForDiskCommitAndSeesSynchronizedPostEditSource() async throws {
        try await withFixture(gatedWrite: true) { fixture in
            fixture.session.actions = [fixture.action(edit: fixture.edit(includeClosed: true))]
            fixture.model.requestLanguageCodeActions(line: 0, utf16Column: 0) { fixture.selectedActions = $0 }
            fixture.model.applyLanguageCodeAction(try #require(fixture.selectedActions.first))
            try #require(await fixture.files.entered.waitUntilOpen())
            #expect(fixture.session.commands.isEmpty)
            #expect(fixture.document.text == "old")
            fixture.files.release.open()
            await fixture.model.languageEditTask?.value
            #expect(fixture.document.text == "new")
            #expect(await fixture.files.text("closed.go") == "new")
            #expect(fixture.session.commands == ["fixture.followup"])
            #expect(fixture.session.commandSource == "new")
        }
    }

    @Test
    func staleRenameReplyCannotCancelAValidTransaction() async throws {
        try await withFixture(gatedWrite: true) { fixture in
            fixture.model.requestLanguageRename(line: 0, utf16Column: 0, newName: "old-request")
            let oldReply = try #require(fixture.session.renames.first)
            fixture.document.text = "other"
            fixture.document.text = "old"
            fixture.model.requestLanguageRename(line: 0, utf16Column: 0, newName: "new")
            let currentReply = try #require(fixture.session.renames.last)
            currentReply(.success(fixture.edit(includeClosed: true)))
            try #require(await fixture.files.entered.waitUntilOpen())
            oldReply(.success(fixture.edit()))
            fixture.files.release.open()
            await fixture.model.languageEditTask?.value
            #expect(fixture.document.text == "new")
            #expect(await fixture.files.text("closed.go") == "new")
        }
    }

    @Test
    func resourceOperationAfterTextPreventsEveryWriteAndCommand() async throws {
        try await withFixture { fixture in
            let edit = LanguageServerWorkspaceEdit(operations: fixture.edit(includeClosed: true).operations + [
                .deleteFile(.init(uri: fixture.root.appendingPathComponent("closed.go").absoluteString))])
            fixture.session.actions = [fixture.action(edit: edit)]
            fixture.model.requestLanguageCodeActions(line: 0, utf16Column: 0) { fixture.selectedActions = $0 }
            fixture.model.applyLanguageCodeAction(try #require(fixture.selectedActions.first))
            await fixture.model.languageEditTask?.value
            #expect(fixture.document.text == "old")
            #expect(await fixture.files.captureCount == 0)
            #expect(await fixture.files.writeCount == 0)
            #expect(fixture.session.commands.isEmpty)
        }
    }

    @Test
    func restartedSessionCannotResolveAnOldActionEvenWithSameDocumentVersion() async throws {
        try await withFixture { fixture in
            fixture.session.actions = [fixture.action(edit: nil, data: .object(["opaque": .string("keep")]))]
            fixture.model.requestLanguageCodeActions(line: 0, utf16Column: 0) { fixture.selectedActions = $0 }
            fixture.model.applyLanguageCodeAction(try #require(fixture.selectedActions.first))
            let resolved = try #require(fixture.session.resolutions.first)
            let old = try #require(fixture.session.synchronizedDocumentSnapshot(for: fixture.document.url))
            fixture.manager.stopLanguageServer(providerID: "go")
            try fixture.manager.synchronizeLanguageServer(for: fixture.document.url, text: fixture.document.text, rootURL: fixture.root)
            let current = try #require(fixture.session.synchronizedDocumentSnapshot(for: fixture.document.url))
            #expect(current.version == old.version)
            #expect(current.sessionIdentity != old.sessionIdentity)
            let prepared = try fixture.manager.prepareEditingSession(fileURL: fixture.document.url, text: fixture.document.text, rootURL: fixture.root)
            let token = try #require(prepared)
            #expect(fixture.manager.isCurrentEditingSession(token))
            resolved(.success(fixture.action(edit: fixture.edit())))
            #expect(fixture.model.languageEditTask == nil)
            #expect(fixture.document.text == "old")
            #expect(fixture.session.commands.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func projectTeardownWaitsForCompensationAndRejectsLateReplies(switchProject: Bool) async throws {
        try await withFixture(gatedWrite: true, gatedRestore: true) { fixture in
            fixture.model.requestLanguageRename(line: 0, utf16Column: 0, newName: "new")
            let reply = try #require(fixture.session.renames.first)
            reply(.success(fixture.edit(includeClosed: true)))
            let editTask = try #require(fixture.model.languageEditTask)
            try #require(await fixture.files.entered.waitUntilOpen())
            var shutdown: Task<Void, Never>?
            let shutdownFinished = TestGate()
            defer { shutdown?.cancel(); fixture.files.release.open(); fixture.files.restoreRelease.open() }
            if switchProject {
                fixture.model.openProjectDirectly(fixture.otherRoot)
                #expect(fixture.model.workspaceURL == fixture.root)
                #expect(!fixture.model.acceptsLanguageEdits)
            } else {
                let started = TestGate()
                shutdown = Task { started.open(); await fixture.model.shutdownProjectSession(); shutdownFinished.open() }
                try #require(await started.waitUntilOpen())
                #expect(!fixture.model.acceptsLanguageEdits)
            }
            reply(.success(fixture.edit()))
            try #require(await fixture.files.restoreEntered.waitUntilOpen())
            #expect(fixture.model.workspaceURL == fixture.root)
            #expect(fixture.session.isRunning)
            #expect(fixture.document.hasMutationLease)
            #expect(!shutdownFinished.isOpen)
            fixture.files.release.open()
            fixture.files.restoreRelease.open()
            await editTask.value
            await shutdown?.value
            #expect(fixture.document.text == "old")
            #expect(await fixture.files.text("closed.go") == "old")
            #expect(!fixture.document.hasMutationLease)
            #expect(fixture.session.commands.isEmpty)
            if switchProject { #expect(fixture.model.workspaceURL == fixture.otherRoot) }
        }
    }

    @Test
    func currentLocalAndServerCompletionsSurviveContextCapacityBoundary() async throws {
        try await withFixture { fixture in
            fixture.document.text = "fu"
            fixture.session.actions = [fixture.action(edit: nil)]
            for _ in 0..<15 {
                fixture.model.requestLanguageCodeActions(line: 0, utf16Column: 0) { fixture.selectedActions = $0 }
            }
            #expect(fixture.model.languageEditContexts.count == 15)
            fixture.session.completionItems = [.init(label: "future", detail: nil, documentation: nil,
                insertText: "future", sortText: nil, filterText: nil, kind: nil, textEdit: nil, additionalTextEdits: [], data: nil)]
            var items: [LanguageServerCompletionItem] = []
            fixture.model.requestLanguageCompletions(line: 0, utf16Column: 2) { items = $0 }
            let local = try #require(items.first(where: { $0.label == "func" }))
            let server = try #require(items.first(where: { $0.label == "future" }))
            #expect(fixture.model.languageEditContexts[try #require(local.requestContextID)] != nil)
            #expect(fixture.model.languageEditContexts[try #require(server.requestContextID)] != nil)
            fixture.model.applyLanguageCompletion(local, fallbackRange: .init(start: .init(line: 0, utf16Column: 0), end: .init(line: 0, utf16Column: 2)))
            #expect(fixture.document.text == "func")
        }
    }

    @Test
    func projectChangeAfterCommitKeepsAppliedEditButCancelsFollowUpCommand() async throws {
        try await withFixture { fixture in
            fixture.session.actions = [fixture.action(edit: fixture.edit(includeClosed: true))]
            fixture.model.requestLanguageCodeActions(line: 0, utf16Column: 0) { fixture.selectedActions = $0 }
            let observation = fixture.document.textDidChange.sink {
                fixture.model.openProjectDirectly(fixture.otherRoot)
            }
            defer { observation.cancel() }
            fixture.model.applyLanguageCodeAction(try #require(fixture.selectedActions.first))
            let editTask = try #require(fixture.model.languageEditTask)
            await editTask.value
            #expect(fixture.document.text == "new")
            #expect(await fixture.files.text("closed.go") == "new")
            #expect(fixture.session.commands.isEmpty)
            #expect(fixture.model.workspaceURL == fixture.otherRoot)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func unchangedDiskTargetRemainsAGuardedPrecondition(externalChange: Bool, changesBuffer: Bool) async throws {
        try await withFixture { fixture in
            await fixture.files.gateInitialCapture()
            let position = LanguageServerPosition(line: 0, utf16Column: 0)
            let noop = LanguageServerWorkspaceOperation.edit(.init(
                uri: fixture.root.appendingPathComponent("closed.go").absoluteString, version: 0,
                edits: [.init(range: .init(start: position, end: .init(line: 0, utf16Column: 3)), newText: "old")]))
            let operations = (changesBuffer ? fixture.edit().operations : []) + [noop]
            fixture.session.actions = [fixture.action(edit: .init(operations: operations))]
            fixture.model.requestLanguageCodeActions(line: 0, utf16Column: 0) { fixture.selectedActions = $0 }
            fixture.model.applyLanguageCodeAction(try #require(fixture.selectedActions.first))
            try #require(await fixture.files.captureEntered.waitUntilOpen())
            if externalChange { await fixture.files.changeExternally("other") }
            fixture.files.captureRelease.open()
            await fixture.model.languageEditTask?.value
            #expect(fixture.document.text == (!externalChange && changesBuffer ? "new" : "old"))
            #expect(fixture.session.commands.count == (externalChange ? 0 : 1))
            #expect(await fixture.files.writeCount == 0, "No-op validation must not rewrite disk")
            #expect(fixture.model.services.workspaceTextEditUndoController.canUndo == (!externalChange && changesBuffer))
        }
    }

    @Test
    func unchangedOpenTargetDrainsItsDeferredExternalChangeAfterLeaseRelease() async throws {
        try await withFixture(gatedWrite: true) { fixture in
            let refreshed = TestGate()
            let observation = fixture.document.textDidChange.sink {
                if fixture.document.text == "external" { refreshed.open() }
            }
            defer { observation.cancel(); fixture.files.release.open() }
            var operations = fixture.edit(includeClosed: true).operations
            operations[0] = .edit(.init(uri: fixture.document.url.absoluteString,
                version: fixture.session.synchronizedDocumentSnapshot(for: fixture.document.url)?.version,
                edits: []))
            fixture.model.requestLanguageRename(line: 0, utf16Column: 0, newName: "new")
            let reply = try #require(fixture.session.renames.first)
            reply(.success(.init(operations: operations)))
            try #require(await fixture.files.entered.waitUntilOpen())
            #expect(fixture.document.hasMutationLease)
            try "external".write(to: fixture.document.url, atomically: true, encoding: .utf8)
            #expect(!fixture.model.documentFeature.processExternalChanges([fixture.document.url]))
            #expect(fixture.document.text == "old")
            fixture.files.release.open()
            await fixture.model.languageEditTask?.value
            // Do not reinject/reconcile the event: endBufferMutation must
            // drain the sole event delivered while the no-op target was leased.
            #expect(await refreshed.waitUntilOpen(timeout: .seconds(2)))
            #expect(fixture.document.text == "external")
            #expect(!fixture.document.hasMutationLease)
        }
    }

    @Test(arguments: [false, true])
    func projectTeardownAlsoWaitsForDiskUndoCompensation(switchProject: Bool) async throws {
        try await withFixture(gatedRestore: true) { fixture in
            fixture.model.requestLanguageRename(line: 0, utf16Column: 0, newName: "new")
            let reply = try #require(fixture.session.renames.first)
            reply(.success(fixture.edit(includeClosed: true)))
            await fixture.model.languageEditTask?.value
            let controller = fixture.model.services.workspaceTextEditUndoController
            await fixture.files.gateReplayWrite()
            #expect(controller.undo())
            try #require(await fixture.files.replayEntered.waitUntilOpen())
            var shutdown: Task<Void, Never>?
            let finished = TestGate()
            defer { shutdown?.cancel(); fixture.files.replayRelease.open(); fixture.files.restoreRelease.open() }
            if switchProject {
                fixture.model.openProjectDirectly(fixture.otherRoot)
            } else {
                let started = TestGate()
                shutdown = Task { started.open(); await fixture.model.shutdownProjectSession(); finished.open() }
                try #require(await started.waitUntilOpen())
            }
            try #require(await fixture.files.restoreEntered.waitUntilOpen())
            #expect(fixture.model.workspaceURL == fixture.root)
            #expect(fixture.session.isRunning)
            #expect(fixture.document.hasMutationLease)
            #expect(!finished.isOpen)
            fixture.files.replayRelease.open()
            fixture.files.restoreRelease.open()
            _ = await controller.waitForCurrentOperation()
            await fixture.model.languageEditTask?.value
            await shutdown?.value
            #expect(fixture.document.text == "new")
            #expect(await fixture.files.text("closed.go") == "new")
            #expect(!fixture.document.hasMutationLease)
            if switchProject { #expect(fixture.model.workspaceURL == fixture.otherRoot) }
        }
    }

    private func withFixture(gatedWrite: Bool = false, gatedRestore: Bool = false,
                             _ body: @MainActor (LanguageEditHostFixture) async throws -> Void) async throws {
        let fixture = try LanguageEditHostFixture(gatedWrite: gatedWrite, gatedRestore: gatedRestore)
        do {
            try await fixture.start()
            try await body(fixture)
            await fixture.cleanUp()
        } catch { await fixture.cleanUp(); throw error }
    }
}

@MainActor
private final class LanguageEditHostFixture {
    let root: URL
    let otherRoot: URL
    let session = HostEditSession()
    let files: HostEditFiles
    let model: AppModel
    let manager: LanguageToolingSessionManager
    let runtime = ModuleRuntime()
    let backing: MacServiceContainer
    var selectedActions: [LanguageServerCodeAction] = []
    var document: EditorDocument!

    init(gatedWrite: Bool, gatedRestore: Bool) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("language-host-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        otherRoot = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try "old".write(to: root.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        files = HostEditFiles(gatedWrite: gatedWrite, gatedRestore: gatedRestore)
        let descriptor = LanguageProviderDescriptor(id: "go", displayName: "Go fixture", fileExtensions: ["go"],
            capabilities: [.languageServer, .formatting], activationPolicy: .onDemand, languageIdentifier: "go")
        manager = LanguageToolingSessionManager(catalog: .init(descriptors: [descriptor]),
                                               runtimes: [HostEditRuntime(descriptor: descriptor, session: session)])
        let tools = LanguageServerToolService(runtimeService: HostEditTools(), commandRunner: HostEditCommandRunner(), settingsStore: HostEditToolSettings())
        let graph = LanguageIntelligenceFeatureGraph(sessions: manager, tools: tools)
        let module = LanguageIntelligenceModule(makeGraph: { graph })
        let workspace = HostEditWorkspaceModule()
        try runtime.register(ModuleFactory(manifest: workspace.manifest) { workspace })
        try runtime.register(ModuleFactory(manifest: module.manifest, contributions: LanguageIntelligenceModule.moduleContributions) { module })
        let store = HostEditStore()
        let settings = AppSettings(store: store)
        settings.autoSave = false
        backing = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode,
                                      workspaceOperations: LanguageEditFixtureWorkspaceOperations())
        backing.moduleLifecycleCoordinator.stop()
        model = AppModel(settings: settings, services: Self.services(copying: backing.services, moduleRuntime: runtime, files: files))
        model.services.workspaceTextEditUndoController.sharedUndoManager.groupsByEvent = false
    }

    func start() async throws {
        model.openProjectDirectly(root)
        await model.awaitModuleRuntimeShutdown()
        let capability = try #require(await runtime.activateCapability(.languageIntelligence) as? LanguageIntelligenceCapability)
        model.bindLanguageIntelligenceCapability(capability)
        await model.documentFeature.openFileAsync(root.appendingPathComponent("main.go"), isReadOnly: false, displayPath: nil, activateWhenReady: true)
        let openedDocument = try #require(model.activeDocument)
        document = openedDocument
        try manager.synchronizeLanguageServer(for: openedDocument.url, text: openedDocument.text, rootURL: root)
    }

    func edit(includeClosed: Bool = false) -> LanguageServerWorkspaceEdit {
        let text = LanguageServerTextEdit(range: .init(start: .init(line: 0, utf16Column: 0), end: .init(line: 0, utf16Column: 3)), newText: "new")
        var operations: [LanguageServerWorkspaceOperation] = [.edit(.init(uri: document.url.absoluteString,
            version: session.synchronizedDocumentSnapshot(for: document.url)?.version, edits: [text]))]
        if includeClosed { operations.append(.edit(.init(uri: root.appendingPathComponent("closed.go").absoluteString, version: 0, edits: [text]))) }
        return .init(operations: operations)
    }

    func action(edit: LanguageServerWorkspaceEdit?, data: ToolingJSONValue? = nil) -> LanguageServerCodeAction {
        .init(title: "Fixture action", kind: "quickfix", isPreferred: false, edit: edit,
              command: .init(title: "Follow up", command: "fixture.followup", arguments: []), data: data)
    }

    func cleanUp() async {
        files.release.open()
        files.restoreRelease.open()
        files.captureRelease.open()
        files.replayRelease.open()
        await model.shutdownProjectSession()
        model.documentFeature.reset()
        model.workspaceFeature.reset()
        session.renames.removeAll()
        session.resolutions.removeAll()
        backing.moduleLifecycleCoordinator.stop()
        await backing.services.moduleRuntime.shutdownAll()
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
    }
    private static func services(copying base: AppServices, moduleRuntime: ModuleRuntime, files: any WorkspaceTextEditFileOperations) -> AppServices {
        AppServices(
            moduleRuntime: moduleRuntime,
            pluginManager: base.pluginManager,
            pluginCatalog: base.pluginCatalog,
            languageProviderCatalogSource: base.languageProviderCatalogSource,
            workspaceLanguageServerPreferences: base.workspaceLanguageServerPreferences,
            languageProviderCatalogSnapshot: base.languageProviderCatalogSnapshot,
            debugLaunchConfigurationResolver: base.debugLaunchConfigurationResolver,
            debugPortAvailabilityChecker: base.debugPortAvailabilityChecker,
            javaTestResultServerFactory: { MacJavaTestResultServer() },
            debugBreakpointPersistence: nil,
            workspaceOperations: base.workspaceOperations,
            documentLifecycleDecider: HostEditLifecycleDecider(),
            lineEditing: base.lineEditing,
            javaOperations: base.javaOperations,
            markdownRenderer: base.markdownRenderer,
            markdownImageImporter: base.markdownImageImporter,
            store: base.store,
            fileStorage: base.fileStorage,
            fileOperations: HostEditDocumentFiles(base: base.fileOperations),
            workspaceTextEditFileOperations: files,
            binaryFileViewerRegistry: base.binaryFileViewerRegistry,
            projectRuntimeService: base.projectRuntimeService,
            gitWatchContextProvider: base.gitWatchContextProvider,
            githubService: base.githubService,
            secureStore: base.secureStore,
            databaseSecureStore: base.databaseSecureStore,
            credentialResolver: base.credentialResolver,
            aiConfigurationSources: [],
            recentProjectsStore: base.recentProjectsStore,
            workspaceSessionStore: base.workspaceSessionStore,
            directoryMarkStore: base.directoryMarkStore,
            workbenchLayoutStore: base.workbenchLayoutStore,
            workbenchBackgroundPlatform: base.workbenchBackgroundPlatform,
            directoryWatcherFactory: HostEditDirectoryWatchers(),
            platformUI: base.platformUI,
            shortcutDetectorFactory: base.shortcutDetectorFactory,
            commandProjectionScheduler: base.commandProjectionScheduler
        )
    }
}

private actor HostEditFiles: WorkspaceTextEditFileOperations {
    nonisolated let entered = TestGate()
    nonisolated let release = TestGate()
    nonisolated let restoreEntered = TestGate()
    nonisolated let restoreRelease = TestGate()
    nonisolated let captureEntered = TestGate()
    nonisolated let captureRelease = TestGate()
    nonisolated let replayEntered = TestGate()
    nonisolated let replayRelease = TestGate()
    private var gatesCapture = false
    private var gatesReplay = false
    let gatedWrite: Bool
    let gatedRestore: Bool
    var captureCount = 0
    var writeCount = 0
    var values = ["closed.go": "old"]
    init(gatedWrite: Bool, gatedRestore: Bool) { self.gatedWrite = gatedWrite; self.gatedRestore = gatedRestore }
    func text(_ path: String) -> String? { values[path] }
    func gateInitialCapture() { gatesCapture = true }
    func gateReplayWrite() { gatesReplay = true }
    func changeExternally(_ text: String) { values["closed.go"] = text }
    func capture(_ paths: [String], at workspaceURL: URL) async throws -> [WorkspaceTextEditSnapshot] {
        captureCount += 1
        let captured: [WorkspaceTextEditSnapshot] = try paths.map { path in
            guard let text = values[path] else { throw CocoaError(.fileNoSuchFile) }
            return .init(path: path, text: text, identity: "fixture-\(writeCount)")
        }
        if gatesCapture, captureCount == 1 {
            captureEntered.open()
            guard await captureRelease.waitUntilOpen(timeout: .seconds(2)) else { throw CancellationError() }
        }
        return captured
    }
    func replace(_ edit: WorkspaceTextEdit, expected snapshot: WorkspaceTextEditSnapshot, at workspaceURL: URL) async throws -> WorkspaceTextEditSnapshot {
        guard values[edit.path] == snapshot.text else { throw CocoaError(.fileWriteUnknown) }
        values[edit.path] = edit.replacementText
        writeCount += 1
        entered.open()
        if gatesReplay {
            replayEntered.open()
            let released = await replayRelease.waitUntilOpen(timeout: .seconds(2))
            if !released, !Task.isCancelled { Issue.record("Replay fixture did not leave its bounded gate") }
        }
        // Model a native write already committed when cancellation arrives.
        // Returning its identity lets the real coordinator compensate it.
        if gatedWrite {
            let released = await release.waitUntilOpen(timeout: .seconds(2))
            if !released, !Task.isCancelled { Issue.record("Native write fixture did not leave its bounded gate") }
        }
        return .init(path: edit.path, text: edit.replacementText, identity: "fixture-\(writeCount)")
    }
    func restore(_ snapshot: WorkspaceTextEditSnapshot, expected writtenSnapshot: WorkspaceTextEditSnapshot, at workspaceURL: URL) async throws {
        restoreEntered.open()
        if gatedRestore {
            // Compensation must finish even though its transaction is cancelled.
            // This owned asynchronous waiter has its own two-second deadline.
            let compensation = Task { await restoreRelease.waitUntilOpen(timeout: .seconds(2)) }
            defer { compensation.cancel() }
            guard await compensation.value else { throw CancellationError() }
        }
        guard values[snapshot.path] == writtenSnapshot.text else { throw CocoaError(.fileWriteUnknown) }
        values[snapshot.path] = snapshot.text
    }
}

@MainActor
private final class HostEditSession: LanguageServerSession {
    var isRunning = false
    var sessionIdentity: String?
    var javaTestRunnerURL: URL? { nil }
    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)?
    var onStateChange: ((LanguageServerSessionState) -> Void)?
    var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)?
    let features: LanguageServerFeatureSet = [.completion, .rename, .formatting, .codeActions, .codeActionResolve, .executeCommand]
    var snapshots: [URL: LanguageServerSynchronizedDocumentSnapshot] = [:]
    var renames: [(Result<LanguageServerWorkspaceEdit, Error>) -> Void] = []
    var resolutions: [(Result<LanguageServerCodeAction, Error>) -> Void] = []
    var actions: [LanguageServerCodeAction] = []
    var completionItems: [LanguageServerCompletionItem] = []
    var commands: [String] = []
    var commandSource: String?
    var failNextSynchronization = false
    func start(rootURL: URL, workspaceFingerprint: String?) throws {
        isRunning = true; sessionIdentity = UUID().uuidString; snapshots.removeAll()
        onStateChange?(.ready); onFeaturesChange?(features)
    }
    func stop() { isRunning = false; sessionIdentity = nil; onStateChange?(.stopped) }
    func synchronizedDocumentSnapshot(for fileURL: URL) -> LanguageServerSynchronizedDocumentSnapshot? { snapshots[fileURL.standardizedFileURL] }
    func synchronize(fileURL: URL, text: String, languageID: String) throws {
        if failNextSynchronization {
            failNextSynchronization = false
            throw CocoaError(.fileReadUnknown)
        }
        let id = try #require(sessionIdentity)
        let key = fileURL.standardizedFileURL
        if snapshots[key]?.sourceText.utf8.elementsEqual(text.utf8) == true { return }
        snapshots[key] = .init(sessionIdentity: id, version: (snapshots[key]?.version ?? 0) + 1, sourceText: text)
    }
    func completions(fileURL: URL, position: LanguageServerPosition, completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void) throws { completion(.success(completionItems)) }
    func hover(fileURL: URL, position: LanguageServerPosition, completion: @escaping (Result<LanguageServerHover?, Error>) -> Void) throws { completion(.success(nil)) }
    func navigate(method: String, fileURL: URL, position: LanguageServerPosition, completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void) throws { completion(.success([])) }
    func rename(fileURL: URL, position: LanguageServerPosition, newName: String, completion: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void) throws { renames.append(completion) }
    func format(fileURL: URL, completion: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void) throws { completion(.success([])) }
    func codeActions(fileURL: URL, range: LanguageServerRange, diagnostics: [LanguageServerDiagnostic], completion: @escaping (Result<[LanguageServerCodeAction], Error>) -> Void) throws { completion(.success(actions)) }
    func resolveCompletion(_ item: LanguageServerCompletionItem, fileURL: URL, completion: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void) throws { completion(.success(item)) }
    func resolveCodeAction(_ action: LanguageServerCodeAction, fileURL: URL, completion: @escaping (Result<LanguageServerCodeAction, Error>) -> Void) throws { resolutions.append(completion) }
    func execute(_ command: LanguageServerCommand, fileURL: URL, completion: @escaping (Result<Void, Error>) -> Void) throws {
        commands.append(command.command); commandSource = snapshots[fileURL.standardizedFileURL]?.sourceText; completion(.success(()))
    }
    func resolveVirtualDocument(uri: String, completion: @escaping (Result<String, Error>) -> Void) throws { throw CocoaError(.featureUnsupported) }
}

@MainActor
private final class HostEditRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    let session: HostEditSession
    let supportsLanguageServerSession = true
    var unavailableToolingMessage: String? { nil }
    init(descriptor: LanguageProviderDescriptor, session: HostEditSession) { self.descriptor = descriptor; self.session = session }
    func makeLanguageServerSession() -> (any LanguageServerSession)? { session }
}

@MainActor
private final class HostEditWorkspaceModule: LitheModule {
    let manifest = ModuleManifest(id: .workspace, displayName: "Workspace fixture", scope: .workspace)
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

private struct HostEditDirectoryWatchers: DirectoryWatcherFactory {
    func make(configuration: DirectoryWatchConfiguration, visibilityRules: FileVisibilityRules,
              onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void) -> any DirectoryChangeSource {
        HostEditDirectorySource()
    }
}

/// The regression observes delivery of the deferred event. Lifecycle reduction
/// is a separate Core contract; supply its clean-file decision in both lanes.
private struct HostEditLifecycleDecider: DocumentLifecycleDeciding {
    func decide(state: DocumentLifecycleState, event: DocumentLifecycleEvent,
                operationID: String) throws -> DocumentLifecycleDecision {
        guard event.type == .externalChanged, state.status == .clean else {
            Issue.record("Unexpected fixture lifecycle event \(event.type) in \(state.status)")
            throw CocoaError(.featureUnsupported)
        }
        return .init(state: state, action: .reloadFromDisk)
    }
}

private final class HostEditDirectorySource: DirectoryChangeSource {
    func start() {}
    func stop() {}
}

/// Events are injected explicitly; a duplicate native vnode notification must
/// not mask a missing drain of the one event queued while a buffer is leased.
private struct HostEditDocumentFiles: WorkspaceFileOperations {
    let base: any WorkspaceFileOperations
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { base.isDirectory(at: url) }
    func createFile(at url: URL) throws { try base.createFile(at: url) }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws { try base.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws { try base.copyItem(at: sourceURL, to: destinationURL) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws { try base.moveItem(at: sourceURL, to: destinationURL) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func trashItem(at url: URL) throws { try base.trashItem(at: url) }
    func writeText(_ text: String, to url: URL) throws { try base.writeText(text, to: url) }
    func readText(from url: URL) throws -> String { try base.readText(from: url) }
    func readDocumentTextAsync(from url: URL) async throws -> String? { try await base.readDocumentTextAsync(from: url) }
    func writeDocumentTextAsync(_ text: String, to url: URL, expectedContent: String?) async throws -> DocumentWriteResult {
        try await base.writeDocumentTextAsync(text, to: url, expectedContent: expectedContent)
    }
}

private final class HostEditStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class HostEditTools: LanguageToolRuntimePort {
    func executableOnPath(_ name: String) -> URL? { nil }
    func executableURL(at path: String) -> URL? { nil }
    func executableCandidates(_ name: String) -> [RuntimeToolCandidate] { [] }
    func languageToolProcessEnvironment() -> [String: String] { [:] }
    func missingLanguageToolMessage(_ name: String) -> String { name }
}

private final class HostEditToolSettings: LanguageToolSettingsStoring {
    func loadLanguageToolExecutablePaths() -> [String: String] { [:] }
    func saveLanguageToolExecutablePaths(_ paths: [String: String]) {}
}

private struct HostEditCommandRunner: LanguageToolCommandRunning {
    func runLanguageToolCommand(operationID: String, executableURL: URL, arguments: [String], environment: [String: String], timeoutMilliseconds: Int) -> LanguageToolCommandResult {
        .init(output: "", exitCode: 0)
    }
}
