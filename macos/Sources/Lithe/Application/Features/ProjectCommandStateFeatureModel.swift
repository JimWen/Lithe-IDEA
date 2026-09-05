import Combine
import Foundation

/// Coalesces willChange events without sampling partially written source state.
/// The owner chooses its actual sources; no platform setup belongs here.
@MainActor
final class ProjectCommandStateFeatureModel: ObservableObject {
    @Published private(set) var state: ProjectCommandState
    private let scheduler: any CommandProjectionScheduling
    private let project: () -> ProjectCommandState
    private var observations: [AnyCancellable] = []
    private var cancelPending: (() -> Void)?
    private var generation = 0
    private var stopped = false

    init(
        scheduler: any CommandProjectionScheduling,
        project: @escaping () -> ProjectCommandState,
        sources: [ObservableObjectPublisher]
    ) {
        self.scheduler = scheduler
        self.project = project
        state = project()
        observations = sources.map { source in
            source.sink { [weak self] in self?.invalidate() }
        }
    }

    func invalidate() {
        guard !stopped, cancelPending == nil else { return }
        let expectedGeneration = generation
        cancelPending = scheduler.schedule { [weak self] in
            guard let self, !self.stopped, self.generation == expectedGeneration else { return }
            self.cancelPending = nil
            let next = self.project()
            if next != self.state { self.state = next }
        }
    }

    func stop() {
        stopped = true
        generation += 1
        cancelPending?()
        cancelPending = nil
        observations.removeAll()
    }
}
