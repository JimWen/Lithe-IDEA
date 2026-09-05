import AppKit
import Combine
import Foundation
import Testing
@testable import Lithe

@Suite("Project command state")
@MainActor
struct ProjectCommandStateTests {
    @Test
    func samplesAfterWillChangeAndCoalescesUnrelatedEvents() {
        let scheduler = ManualCommandScheduler()
        let source = ObservableObjectPublisher()
        var facts = ProjectCommandState()
        var samples = 0
        let model = ProjectCommandStateFeatureModel(scheduler: scheduler, project: {
            samples += 1
            return facts
        }, sources: [source])
        defer { model.stop() }
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        source.send()
        facts.enabled.insert(.save)
        for _ in 0..<1_000 { source.send() }
        #expect(!model.state.enabled.contains(.save))
        #expect(samples == 1)
        scheduler.drain()
        #expect(model.state.enabled.contains(.save))
        #expect(samples == 2)
        #expect(publications == 1)

        for _ in 0..<1_000 { source.send() }
        scheduler.drain()
        #expect(samples == 3)
        #expect(publications == 1)
    }

    @Test
    func findCountUsesPostMutationFactsButMatchNavigationDoesNotRepublish() {
        let chrome = EditorChromeModel()
        let scheduler = ManualCommandScheduler()
        let model = ProjectCommandStateFeatureModel(scheduler: scheduler, project: {
            var state = ProjectCommandState()
            if chrome.isFindBarVisible && chrome.findMatchCount > 0 {
                state.enabled.formUnion([.findNext, .findPrevious])
            }
            return state
        }, sources: [chrome.objectWillChange])
        defer { model.stop() }
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        chrome.setFindBarVisible(true)
        chrome.updateFindState(currentIndex: 1, count: 3)
        scheduler.drain()
        #expect(model.state.enabled.contains(.findNext))
        chrome.updateFindState(currentIndex: 2, count: 3)
        scheduler.drain()
        #expect(publications == 1)
        chrome.updateFindState(currentIndex: 0, count: 0)
        scheduler.drain()
        #expect(!model.state.enabled.contains(.findNext))
        #expect(publications == 2)
    }

    @Test
    func stoppingInvalidatesPendingSamplingAndReleasesSourceSubscriptions() {
        let scheduler = ManualCommandScheduler()
        let source = ObservableObjectPublisher()
        var samples = 0
        var model: ProjectCommandStateFeatureModel? = ProjectCommandStateFeatureModel(
            scheduler: scheduler, project: { samples += 1; return ProjectCommandState() }, sources: [source]
        )
        weak let released = model
        source.send()
        model?.stop()
        model = nil
        scheduler.drain()
        source.send()
        scheduler.drain()
        #expect(released == nil)
        #expect(samples == 1)
    }

    @Test
    func nestedMenuTrackingDoesNotRestoreAnInvalidProjectFocus() {
        let environment = CommandEnvironmentFeatureModel()
        defer { environment.stop() }
        let origin = context()
        let first = NSObject()
        let second = NSObject()
        environment.update(context: origin, isApplicationActive: true, isModal: false)
        environment.beginTracking(first)
        environment.beginTracking(first)
        environment.beginTracking(second)
        #expect(environment.permitsProjectCommand(from: origin))

        // Settings takes focus while the menu's displayed context is frozen.
        environment.update(context: nil, isApplicationActive: true, isModal: false)
        #expect(!environment.permitsProjectCommand(from: origin))
        #expect(environment.permitsApplicationCommand)
        environment.endTracking(first)
        environment.endTracking(first)
        #expect(environment.isTrackingMenu)
        environment.endTracking(second)
        #expect(!environment.isTrackingMenu)
        #expect(!environment.permitsProjectCommand(from: origin))
        environment.update(context: origin, isApplicationActive: true, isModal: true)
        #expect(!environment.permitsProjectCommand(from: origin))
        #expect(!environment.permitsApplicationCommand)
    }

    @Test(arguments: [EditorTabItem.document(UUID()), .media(UUID()), .terminal(UUID())])
    func oldCloseRequestCannotCloseAnotherEditorKind(_ item: EditorTabItem) {
        let request = ProjectCommandRequest(
            command: .closeEditor, context: context(), documentID: nil, editorItem: item, referenceID: nil
        )
        var state = ProjectCommandState()
        state.activeEditorItem = item
        #expect(request.matches(state))
        state.activeEditorItem = .document(UUID())
        #expect(!request.matches(state))
        state.activeEditorItem = .media(UUID())
        #expect(!request.matches(state))
        state.activeEditorItem = .terminal(UUID())
        #expect(!request.matches(state))
    }

    @Test
    func staleDocumentAndBranchPayloadsAreRejected() {
        var state = ProjectCommandState()
        state.activeDocumentID = UUID()
        state.currentReferenceID = "refs/heads/example"
        let save = ProjectCommandRequest(
            command: .save, context: context(), documentID: state.activeDocumentID,
            editorItem: nil, referenceID: nil
        )
        let push = ProjectCommandRequest(
            command: .push, context: context(), documentID: nil,
            editorItem: nil, referenceID: state.currentReferenceID
        )
        #expect(save.matches(state))
        #expect(push.matches(state))
        state.activeDocumentID = UUID()
        state.currentReferenceID = "refs/heads/another"
        #expect(!save.matches(state))
        #expect(!push.matches(state))
    }

    @Test
    func stoppedNativeObserverRejectsLateWindowRegistrationAndRefresh() {
        let environment = CommandEnvironmentFeatureModel()
        let origin = context()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let observer = MacCommandEnvironmentObserver(feature: environment, readNativeState: {
            .init(keyWindow: window, isActive: true, isModal: false)
        })
        defer { observer.stop() }
        observer.start()
        observer.register(window, id: origin.windowID) { origin }
        #expect(environment.permitsProjectCommand(from: origin))
        observer.stop()
        let generation = environment.generation
        observer.register(window, id: origin.windowID) { origin }
        observer.refresh()
        #expect(!environment.permitsApplicationCommand)
        #expect(!environment.permitsProjectCommand(from: origin))
        #expect(environment.generation == generation)
    }

    private func context() -> ProjectCommandContext {
        ProjectCommandContext(windowID: UUID(), sessionID: UUID(), workspaceGeneration: 1, standaloneGeneration: 0)
    }
}

@MainActor
final class ManualCommandScheduler: CommandProjectionScheduling {
    private struct Entry {
        let id: UUID
        let delay: TimeInterval
        let action: @MainActor @Sendable () -> Void
    }
    private var entries: [Entry] = []

    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        schedule(after: 0, action)
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        let id = UUID()
        entries.append(Entry(id: id, delay: delay, action: action))
        return { [weak self] in self?.entries.removeAll { $0.id == id } }
    }

    func drain(includingDeadlines: Bool = false) {
        let selected = entries.filter { includingDeadlines || $0.delay == 0 }
        let selectedIDs = Set(selected.map(\.id))
        entries.removeAll { selectedIDs.contains($0.id) }
        for entry in selected { entry.action() }
    }
}
