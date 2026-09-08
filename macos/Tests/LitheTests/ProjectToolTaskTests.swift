import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI
@testable import LitheExecutionModule
import Testing

@MainActor
struct ProjectToolTaskTests {
    private let root = URL(fileURLWithPath: "/workspace/go-tools")

    @Test func concurrentTasksHaveIndependentOutputAndStop() async throws {
        let provider = ToolTaskTestProvider()
        let feature = makeFeature(provider)
        defer { feature.retire(); provider.finishAll() }
        let first = try #require(feature.start(.init(action: .build, directory: "one"), workspaceURL: root, workspaceGeneration: 1))
        let second = try #require(feature.start(.init(action: .test, directory: "two"), workspaceURL: root, workspaceGeneration: 1))
        try #require(await wait(feature) { $0.count == 2 && $0.allSatisfy { $0.state == .running } })
        #expect(first != second)
        let one = try #require(provider.session(id: first))
        let two = try #require(provider.session(id: second))
        one.onOutput?("one.go:2:3: bad declaration\n")
        two.onOutput?("PASS\n")
        feature.stop(first)
        try #require(await wait(feature) { $0.first { $0.id == first }?.state == .cancelled })
        #expect(two.isRunning)
        #expect(two.stopCalls == 0)
        two.finish(0)
        try #require(await wait(feature) { $0.allSatisfy { $0.state.isTerminal } })
        let snapshots = feature.tasks
        #expect(snapshots.first { $0.id == first }?.output == "one.go:2:3: bad declaration\n")
        #expect(snapshots.first { $0.id == second }?.output == "PASS\n")
        #expect(snapshots.first { $0.id == first }?.workingDirectory == root.appendingPathComponent("one"))
        #expect(snapshots.first { $0.id == second }?.state == .succeeded)
        #expect(!feature.isActive)
        #expect(await feature.stopAndWait())
    }

    @Test func cancellationDuringPreparationNeverStartsNativeSession() async throws {
        let provider = ToolTaskTestProvider()
        let entered = TestGate(), release = TestGate()
        let feature = makeFeature(provider) {
            entered.open()
            guard release.waitSynchronously() else { throw CocoaError(.userCancelled) }
        }
        defer { release.open(); feature.retire(); provider.finishAll() }
        let id = try #require(feature.start(.init(action: .build, directory: "."), workspaceURL: root, workspaceGeneration: 1))
        try #require(await entered.waitUntilOpen())
        feature.stop(id)
        #expect(feature.isActive)
        release.open()
        try #require(await wait(feature) { $0.first?.state == .cancelled })
        #expect(provider.sessions.isEmpty)
        #expect(!feature.isActive)
    }

    @Test func failedStopRetainsTaskUntilActualExitAndRetirementClosesIngress() async throws {
        let provider = ToolTaskTestProvider()
        provider.stopSucceeds = false
        let feature = makeFeature(provider)
        let context = ToolTaskTestContext()
        feature.activate(context: context.context)
        defer { feature.retire(); provider.finishAll() }
        let id = try #require(feature.start(.init(action: .vet, directory: "."), workspaceURL: root, workspaceGeneration: 2))
        try #require(await wait(feature) { $0.first?.state == .running })
        feature.retire()
        try #require(await wait(feature) { $0.first?.state == .cleanupRequired })
        #expect(feature.isActive)
        #expect(feature.start(.init(action: .test, directory: "."), workspaceURL: root, workspaceGeneration: 2) == nil)
        let session = try #require(provider.session(id: id))
        #expect(session.isRunning)
        #expect(context.activeLeases.count == 1)
        session.finish(9)
        try #require(await wait(feature) { $0.first?.state == .cancelled })
        #expect(!feature.isActive)
        #expect(context.activeLeases.isEmpty)
    }

    @Test func workspaceInvalidationRejectsLatePreparationAndLimitsConcurrency() async throws {
        let provider = ToolTaskTestProvider()
        let entered = TestGate(), release = TestGate()
        let feature = makeFeature(provider) {
            entered.open()
            guard release.waitSynchronously() else { throw CocoaError(.userCancelled) }
        }
        defer { release.open(); feature.retire(); provider.finishAll() }
        for _ in 0..<ProjectToolTaskFeatureModel.activeTaskLimit {
            #expect(feature.start(.init(action: .test, directory: "."), workspaceURL: root, workspaceGeneration: 1) != nil)
        }
        #expect(feature.start(.init(action: .test, directory: "."), workspaceURL: root, workspaceGeneration: 1) == nil)
        try #require(await entered.waitUntilOpen())
        feature.invalidateWorkspace()
        release.open()
        try #require(await wait(feature) { $0.allSatisfy { $0.state == .cancelled } })
        #expect(provider.sessions.isEmpty)
    }

    @Test func completedHistoryIsBoundedWithoutEvictingLiveTask() async throws {
        let provider = ToolTaskTestProvider()
        let feature = makeFeature(provider)
        defer { feature.retire(); provider.finishAll() }
        let live = try #require(feature.start(.init(action: .build, directory: "."), workspaceURL: root, workspaceGeneration: 1))
        try #require(await wait(feature) { $0.first?.state == .running })
        for _ in 0..<(ProjectToolTaskFeatureModel.completedTaskLimit + 2) {
            let id = try #require(feature.start(.init(action: .test, directory: "."), workspaceURL: root, workspaceGeneration: 1))
            try #require(await wait(feature) { $0.first { $0.id == id }?.state == .running })
            let session = try #require(provider.session(id: id))
            session.finish(0)
            try #require(await wait(feature) { $0.first { $0.id == id }?.state == .succeeded })
        }
        #expect(feature.tasks.count == ProjectToolTaskFeatureModel.completedTaskLimit + 1)
        #expect(feature.tasks.first { $0.id == live }?.state == .running)
        #expect(await feature.stopAndWait())
        #expect(!feature.isActive)
    }

    @Test func outputBudgetPreservesUnicodeAndStopsSchedulingOnceExhausted() {
        let buffer = ProjectToolOutputBuffer(limit: 7)
        #expect(buffer.append("😀"))
        #expect(!buffer.append("😀"))
        let first = buffer.drain()
        #expect(first.0 == "😀")
        #expect(first.1)
        #expect(!buffer.append("😀"))
        let second = buffer.drain()
        #expect(second.0.isEmpty)
        #expect(second.1)
    }

    private func makeFeature(_ provider: ToolTaskTestProvider,
        prepare: @escaping @Sendable () throws -> Void = {}) -> ProjectToolTaskFeatureModel {
        ProjectToolTaskFeatureModel(activateProvider: { provider }, makePreparation: { owner, plan, id in
            return {
                try prepare()
                return PreparedProjectToolTask(request: .init(operationID: id.uuidString,
                    executablePath: "/fixture/go", arguments: plan.arguments,
                    workingDirectory: owner.workspaceURL.appendingPathComponent(plan.workingDirectory).standardizedFileURL.path), validate: {})
            }
        })
    }
    private func wait(_ feature: ProjectToolTaskFeatureModel,
                      until predicate: @escaping ([ProjectToolTaskSnapshot]) -> Bool) async -> Bool {
        let reached = TestGate()
        let observation = feature.$tasks.sink { if predicate($0) { reached.open() } }
        defer { observation.cancel() }
        return await reached.waitUntilOpen()
    }
}

@MainActor
private final class ToolTaskTestProvider: ProjectToolActionProviding {
    let languageID = "go"
    var sessions: [ToolTaskTestSession] = []
    var stopSucceeds = true
    func toolPlan(for request: ProjectToolActionRequest) throws -> ProjectToolTaskPlan {
        .init(title: request.action.rawValue, executable: .languageToolchain, arguments: [request.action.rawValue],
              workingDirectory: request.directory, diagnosticSource: "go-tool")
    }
    func launchPlan(for _: LanguageRunExtensionRequest) throws -> LanguageRunExtensionPlan { throw CocoaError(.featureUnsupported) }
    func makeExecutionSession() -> any LanguageExecutionSession {
        let session = ToolTaskTestSession(stopSucceeds: stopSucceeds)
        sessions.append(session)
        return session
    }
    func session(id: UUID) -> ToolTaskTestSession? { sessions.first { $0.request?.operationID == id.uuidString } }
    func finishAll() { sessions.forEach { $0.finish(0) } }
}

@MainActor
private final class ToolTaskTestSession: LanguageExecutionSession {
    var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?
    let stopSucceeds: Bool
    var stopCalls = 0
    var request: LanguageExecutionProcessRequest?
    init(stopSucceeds: Bool) { self.stopSucceeds = stopSucceeds }
    func start(_ request: LanguageExecutionProcessRequest) throws { self.request = request; isRunning = true }
    func stop() { stopCalls += 1; if stopSucceeds { finish(0) } }
    func stopAndWait() async -> Bool { stop(); return !isRunning }
    func finish(_ code: Int32) {
        guard isRunning else { return }
        isRunning = false
        onTermination?(code)
    }
}

@MainActor
private final class ToolTaskTestContext: ModuleCapabilityResolver, ModuleEventPublishing,
    ModuleResourceManaging, ModuleLeaseManaging, ModuleContributionPublishing {
    var activeLeases = Set<UUID>()
    var context: ModuleContext {
        ModuleContext(moduleID: .execution, workspaceURL: nil, capabilities: self,
            events: self, resources: self, leases: self, contributions: self)
    }
    func capability(_: ModuleCapabilityID) -> AnyObject? { nil }
    func publish(_: ModuleEvent) {}
    func register(_: any ModuleResource) -> UUID { UUID() }
    func unregisterResource(id: UUID) {}
    func resourceSnapshots() -> [ModuleResourceSnapshot] { [] }
    func acquireLease(reason: String) -> ModuleLease {
        let id = UUID(); activeLeases.insert(id)
        return ModuleLease(id: id, reason: reason) { [weak self] in self?.activeLeases.remove($0) }
    }
    func register(_: ModuleContribution, for _: ModuleID) {}
    func removeContributions(for _: ModuleID) {}
    func contributions() -> [ModuleID: [ModuleContribution]] { [:] }
}
