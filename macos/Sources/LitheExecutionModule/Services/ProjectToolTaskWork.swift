import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Native preparation captures toolchain and filesystem identity off the UI
/// executor. Validation runs again just before entering the plugin session.
package struct PreparedProjectToolTask: Sendable {
    package let request: LanguageExecutionProcessRequest
    package let validate: @Sendable () throws -> Void
    package let validateSelection: @MainActor @Sendable () throws -> Void
    package init(request: LanguageExecutionProcessRequest, validate: @escaping @Sendable () throws -> Void,
                 validateSelection: @escaping @MainActor @Sendable () throws -> Void = {}) {
        self.request = request; self.validate = validate; self.validateSelection = validateSelection
    }
}

/// Bounded accumulation on the native output queue. At most one delivery is
/// scheduled regardless of how many chunks a compiler emits before UI flush.
final class ProjectToolOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var pending = ""
    private var bytes = 0
    private var scheduled = false
    private var truncated = false
    init(limit: Int) { self.limit = limit }
    func append(_ chunk: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wasTruncated = truncated
        let remaining = limit - bytes
        if remaining > 0 {
            // Decode only complete Unicode scalars at the byte budget edge.
            var prefix = Array(chunk.utf8.prefix(remaining))
            while !prefix.isEmpty, String(bytes: prefix, encoding: .utf8) == nil { prefix.removeLast() }
            pending += String(decoding: prefix, as: UTF8.self)
            bytes += prefix.count
            if chunk.utf8.count > prefix.count { truncated = true }
        } else if !chunk.isEmpty { truncated = true }
        guard !scheduled, !pending.isEmpty || (truncated && !wasTruncated) else { return false }
        scheduled = true
        return true
    }
    func drain() -> (String, Bool) {
        lock.lock(); defer { lock.unlock() }
        let result = (pending, truncated)
        pending = ""; scheduled = false
        return result
    }
}

@MainActor
final class ProjectToolTaskOperation {
    let id = UUID()
    let owner: ProjectToolTaskOwner
    let epoch: Int
    let action: ProjectToolActionRequest
    let outputBuffer = ProjectToolOutputBuffer(limit: ProjectToolTaskFeatureModel.outputByteLimit)
    var title: String
    var directory: URL
    var source = "go-tool"
    var state = ProjectToolTaskState.preparing
    var output = ""
    var outputTruncated = false
    var exitCode: Int32?
    var message: String?
    var cancelled = false
    var pipelineFinished = false
    var pipeline: Task<Void, Never>?
    var session: (any LanguageExecutionSession)?
    var stopTask: Task<Void, Never>?
    var lease: ModuleLease?
    var outputTimer: (any ProjectToolDeadline)?
    var stopTimer: (any ProjectToolDeadline)?
    var preparationTimer: (any ProjectToolDeadline)?
    var stopWaiters: [CheckedContinuation<Bool, Never>] = []

    init(owner: ProjectToolTaskOwner, epoch: Int, action: ProjectToolActionRequest) {
        self.owner = owner; self.epoch = epoch; self.action = action
        title = "Go \(action.action.rawValue)"
        directory = owner.workspaceURL
    }
    var ownsWork: Bool { !pipelineFinished || stopTask != nil || session?.isRunning == true }
    var snapshot: ProjectToolTaskSnapshot {
        ProjectToolTaskSnapshot(id: id, owner: owner, action: action, title: title, state: state,
            output: output, outputTruncated: outputTruncated, workingDirectory: directory,
            diagnosticSource: source, exitCode: exitCode, message: message)
    }
    func resolveWaiters(_ success: Bool) {
        stopTimer?.cancel(); stopTimer = nil
        let waiting = stopWaiters; stopWaiters.removeAll()
        waiting.forEach { $0.resume(returning: success) }
    }
}
