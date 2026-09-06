import Darwin
import Foundation
import SwiftTerm

/// One launch's PTY callbacks. The renderer outlives this connection, but the
/// LocalProcess must not: a delayed EOF mutates its running state and descriptor.
@MainActor
final class MacTerminalProcessConnection: @preconcurrency LocalProcessDelegate {
    private(set) var process: LocalProcess!
    private weak var view: LitheTerminalView?
    private var isActive = true
    private var reportedTermination = false
    var onOutput: ((MacTerminalProcessConnection, ArraySlice<UInt8>) -> Void)?
    var onTermination: ((MacTerminalProcessConnection, Int32?) -> Void)?

    init(view: LitheTerminalView) {
        self.view = view
        process = LocalProcess(delegate: self)
    }

    func invalidate() {
        isActive = false
        view = nil
        onOutput = nil
        onTermination = nil
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard isActive, source === process, !reportedTermination else { return }
        reportedTermination = true
        onTermination?(self, exitCode)
        // EOF and queued output may follow the exit event. Keep accepting the
        // final bytes until explicit stop or the next launch invalidates us.
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        guard isActive else { return }
        onOutput?(self, slice)
    }

    func getWindowSize() -> winsize {
        view?.terminalWindowSize() ?? winsize()
    }
}
