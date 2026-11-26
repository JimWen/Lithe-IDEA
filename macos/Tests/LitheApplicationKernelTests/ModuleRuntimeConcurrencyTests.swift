import Foundation
import LitheApplicationKernel
import LitheModuleAPI
import Testing

@MainActor
@Suite("ModuleRuntime activation deduplication")
struct ModuleRuntimeConcurrencyTests {
    @Test
    func concurrentActivateInvokesFactoryOnlyOnceAndReturnsSameInstance() async throws {
        let gate = ActivationTestGate()
        let counter = ActivationCallCounter()
        let runtime = ModuleRuntime()

        let baseManifest = ModuleManifest(
            id: .workspace,
            displayName: "Workspace",
            scope: .workspace
        )
        let depManifest = ModuleManifest(
            id: .languageIntelligence,
            displayName: "Language Intelligence",
            scope: .workspace,
            dependencies: [.module(.workspace)],
            providedCapabilities: [.languageIntelligence]
        )

        try runtime.register(ModuleFactory(manifest: baseManifest) {
            DelayedActivationModule(manifest: baseManifest, gate: gate, counter: counter, capability: nil)
        })
        let capability = DummyCapabilityObject()
        try runtime.register(ModuleFactory(manifest: depManifest) {
            DelayedActivationModule(
                manifest: depManifest,
                gate: nil,
                counter: counter,
                capability: (.languageIntelligence, capability)
            )
        })

        var firstInstance: (any LitheModule)?
        var secondInstance: (any LitheModule)?
        let first = Task<Void, Error> { @MainActor in
            firstInstance = try await runtime.activate(.languageIntelligence)
        }
        let second = Task<Void, Error> { @MainActor in
            secondInstance = try await runtime.activate(.languageIntelligence)
        }

        try #require(await gate.waitForEntry(timeout: .seconds(2)))
        gate.release()

        try await first.value
        try await second.value

        #expect(firstInstance != nil)
        #expect(firstInstance === secondInstance)
        #expect(counter.creations[.workspace] == 1)
        #expect(counter.creations[.languageIntelligence] == 1)
        #expect(counter.activations[.workspace] == 1)
        #expect(counter.activations[.languageIntelligence] == 1)
        #expect(runtime.capability(.languageIntelligence) === capability)
    }

    @Test
    func shutdownDoesNotDeadlockDuringGatedActivationAndAllowsCleanShutdownAfterwards() async throws {
        let gate = ActivationTestGate()
        let counter = ActivationCallCounter()
        let runtime = ModuleRuntime()

        let manifest = ModuleManifest(
            id: .languageIntelligence,
            displayName: "Language Intelligence",
            scope: .workspace
        )
        try runtime.register(ModuleFactory(manifest: manifest) {
            DelayedActivationModule(manifest: manifest, gate: gate, counter: counter, capability: nil)
        })

        let activation = Task<Void, Error> { @MainActor in
            _ = try await runtime.activate(.languageIntelligence)
        }
        try #require(await gate.waitForEntry(timeout: .seconds(2)))

        // Shutdown during a gated activation must return immediately without
        // blocking callers such as project-switch teardown.
        try await runtime.shutdown(.languageIntelligence)

        gate.release()
        try await activation.value
        #expect(counter.creations[.languageIntelligence] == 1)

        try await runtime.shutdown(.languageIntelligence)
        let snapshot = try runtime.snapshot(for: .languageIntelligence)
        #expect(snapshot.state == .inactive)
        #expect(!snapshot.isInstantiated)
        #expect(counter.shutdowns[.languageIntelligence] == 1)
    }
}

private final class DummyCapabilityObject: NSObject {}

@MainActor
private final class ActivationCallCounter {
    var creations: [ModuleID: Int] = [:]
    var activations: [ModuleID: Int] = [:]
    var shutdowns: [ModuleID: Int] = [:]
}

@MainActor
private final class DelayedActivationModule: LitheModule {
    let manifest: ModuleManifest
    private let gate: ActivationTestGate?
    private let counter: ActivationCallCounter
    private let capability: (ModuleCapabilityID, AnyObject)?

    init(
        manifest: ModuleManifest,
        gate: ActivationTestGate?,
        counter: ActivationCallCounter,
        capability: (ModuleCapabilityID, AnyObject)?
    ) {
        self.manifest = manifest
        self.gate = gate
        self.counter = counter
        self.capability = capability
        counter.creations[manifest.id, default: 0] += 1
    }

    func activate(context: ModuleContext) async throws {
        counter.activations[manifest.id, default: 0] += 1
        if let gate {
            await gate.enterAndWait()
        }
    }

    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {
        counter.shutdowns[manifest.id, default: 0] += 1
    }

    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [capability.0: capability.1]
    }
}

@MainActor
private final class ActivationTestGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = Array(entryWaiters.values)
        let tasks = Array(timeoutTasks.values)
        entryWaiters.removeAll()
        timeoutTasks.removeAll()
        tasks.forEach { $0.cancel() }
        for waiter in waiters { waiter.resume(returning: true) }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitForEntry(timeout: Duration) async -> Bool {
        if entered { return true }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            entryWaiters[waiterID] = continuation
            timeoutTasks[waiterID] = Task { @MainActor [weak self] in
                // test-stability: allow(swift-real-sleep) reason: the gate deadline bounds a failed asynchronous test while successful signaling remains continuation-driven.
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self,
                      let waiter = self.entryWaiters.removeValue(forKey: waiterID) else { return }
                self.timeoutTasks.removeValue(forKey: waiterID)
                waiter.resume(returning: false)
            }
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
