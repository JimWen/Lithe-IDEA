import Combine
import Foundation

/// UI-facing projection for the diagnostic-bundle export flow. Owns sheet
/// presentation state so Views depend on this feature model instead of the
/// underlying service directly.
@MainActor
final class DiagnosticsFeatureModel: ObservableObject {
    private let service: DiagnosticsExportService?
    private var observation: AnyCancellable?
    private var preparationTask: Task<Void, Never>?

    @Published private(set) var state: DiagnosticsExportService.ExportState
    @Published var isPresented = false

    init(service: DiagnosticsExportService?) {
        self.service = service
        _state = Published(initialValue: service?.state ?? .idle)
        // objectWillChange fires before the new state is installed. Consume
        // the published value so completion cannot lag one transition behind.
        observation = service?.$state.sink { [weak self] state in
            self?.state = state
        }
    }

    func presentExport() {
        isPresented = true
        guard let service else {
            state = .failed("Diagnostic export is unavailable in this session.")
            return
        }
        preparationTask?.cancel()
        preparationTask = Task { await service.prepare() }
    }

    func dismiss() {
        preparationTask?.cancel()
        preparationTask = nil
        service?.cancel()
        isPresented = false
    }

    func export(to destinationURL: URL) async {
        await service?.export(to: destinationURL)
    }

    deinit { preparationTask?.cancel() }
}
