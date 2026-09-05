import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
package final class ExecutionFeatureGraph: NSObject, ExecutionServiceGraph {
    package let run: RunService
    package let tests: LanguageTestService
    package let runFeature: RunFeatureModel
    package let projectDevelopment: ProjectDevelopmentFeatureModel
    private var activityObservers: Set<AnyCancellable> = []
    private var runLease: ModuleLease?
    private var testLease: ModuleLease?

    package init(run: RunService, tests: LanguageTestService) {
        self.run = run; self.tests = tests
        runFeature = RunFeatureModel(service: run)
        projectDevelopment = ProjectDevelopmentFeatureModel(runFeature: runFeature)
    }

    package var isActive: Bool { run.isRunning || tests.isRunning }
    package var hasActiveExecutionWork: Bool { isActive }
    package func activate(context: ModuleContext) {
        configureModuleLeases { reason in context.leases.acquireLease(reason: reason) }
    }
    package func prepareForSleep() async throws {
        guard !isActive else { throw ExecutionModuleSleepError.activeWork }
    }

    package func configureModuleLeases(acquire: @escaping @MainActor (String) -> ModuleLease) {
        run.$isRunning.removeDuplicates().sink { [weak self] active in
            guard let self else { return }
            if active, runLease == nil { runLease = acquire("Run configuration is running") }
            if !active { runLease?.release(); runLease = nil }
        }.store(in: &activityObservers)
        tests.$state.map { $0 == .running }.removeDuplicates().sink { [weak self] active in
            guard let self else { return }
            if active, testLease == nil { testLease = acquire("Test run is active") }
            if !active { testLease?.release(); testLease = nil }
        }.store(in: &activityObservers)
    }

    package func stop() {
        run.stop(); tests.stop()
        releaseLeases()
        activityObservers.removeAll()
    }

    private func releaseLeases() {
        runLease?.release(); runLease = nil
        testLease?.release(); testLease = nil
    }
}


private struct ExecutionModuleSleepError: LocalizedError {
    let errorDescription: String? = "Build, run, or test work is still active."
    static let activeWork = Self()
}
