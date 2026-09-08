import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
final class MacLanguageExecutionHost: LanguageExecutionHostProviding {
    private let processRegistry: ManagedProcessRegistry
    init(processRegistry: ManagedProcessRegistry) { self.processRegistry = processRegistry }
    func makeSession(ownerModuleID: ModuleID) -> any LanguageExecutionSession {
        MacLanguageExecutionSession(registry: processRegistry, moduleID: ownerModuleID)
    }
}

@MainActor
private final class MacLanguageExecutionSession: LanguageExecutionSession {
    var isRunning: Bool { execution?.isRunning == true }
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?
    private let registry: ManagedProcessRegistry
    private let moduleID: ModuleID
    private var execution: MacOwnedLanguageExecution?
    init(registry: ManagedProcessRegistry, moduleID: ModuleID) { self.registry = registry; self.moduleID = moduleID }
    func start(_ request: LanguageExecutionProcessRequest) throws {
        guard !isRunning else { throw MacLanguageExecutionError.alreadyRunning }
        let output = onOutput, termination = onTermination, state = onStateChange
        let execution = MacOwnedLanguageExecution(registry: registry, moduleID: moduleID,
            output: { output?($0) }, termination: { termination?($0) }, stateChange: { state?($0) })
        self.execution = execution
        try execution.start(request)
    }
    func stop() { execution?.stop() }
    func stopAndWait() async -> Bool { await execution?.stopAndWait() ?? true }
}

private enum MacLanguageExecutionError: LocalizedError {
    case alreadyRunning
    var errorDescription: String? { "The previous process is still running or cleaning up. Stop it before starting again." }
}
