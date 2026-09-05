import Combine
import Foundation

/// UI-facing projection for project runtime settings and discovery.
@MainActor
final class RuntimeSettingsFeatureModel: ObservableObject {
    private let service: ProjectRuntimeService
    private var observation: AnyCancellable?

    @Published private(set) var javaRuntimes: [JavaRuntimeCandidate]
    @Published private(set) var javaEnvironmentReport: JavaEnvironmentReport?
    @Published private(set) var isDiscovering: Bool

    init(service: ProjectRuntimeService) {
        self.service = service
        _javaRuntimes = Published(initialValue: service.javaRuntimes)
        _javaEnvironmentReport = Published(initialValue: service.javaEnvironmentReport)
        _isDiscovering = Published(initialValue: service.isDiscovering)
        observation = service.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.javaRuntimes = self.service.javaRuntimes
            self.javaEnvironmentReport = self.service.javaEnvironmentReport
            self.isDiscovering = self.service.isDiscovering
        }
    }

    func openProject(at url: URL) { service.openProject(at: url) }
    func closeProject() { service.closeProject() }
    func refreshAvailableRuntimes() async { await service.refreshAvailableRuntimes() }
    func activeJavaRuntime() -> JavaRuntimeCandidate? { service.activeJavaRuntime() }
    func executableCandidates(_ command: String) -> [RuntimeToolCandidate] {
        service.executableCandidates(command)
    }
    func toolGuidance(_ command: String) -> RuntimeToolGuidance {
        service.toolGuidance(command)
    }
}
