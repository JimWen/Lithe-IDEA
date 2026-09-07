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
    package let cargoProject: CargoProjectFeatureModel
    private var activityObservers: Set<AnyCancellable> = []
    private var runLease: ModuleLease?
    private var testLease: ModuleLease?

    package init(run: RunService, tests: LanguageTestService, cargoProject: CargoProjectFeatureModel) {
        self.run = run; self.tests = tests; self.cargoProject = cargoProject
        runFeature = RunFeatureModel(service: run)
        projectDevelopment = ProjectDevelopmentFeatureModel(runFeature: runFeature)
    }

    /// A metadata refresh owns a native capture and a module lease, so it counts
    /// as execution work for sleep and for resource-active checks.
    package var isActive: Bool { run.isRunning || tests.isRunning || cargoProject.isActive }
    package var hasActiveExecutionWork: Bool { isActive }
    package func activate(context: ModuleContext) {
        configureModuleLeases { reason in context.leases.acquireLease(reason: reason) }
        cargoProject.activate(context: context)
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

    /// Closes the metadata gate before waiting, so a refresh cannot be started
    /// again while this graph is being torn down. The wait is bounded by the
    /// feature's own stop deadline; a failed cleanup keeps its owner and lease.
    package func stop() async {
        run.stop(); tests.stop()
        cargoProject.retire()
        _ = await cargoProject.stopAndWait()
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
