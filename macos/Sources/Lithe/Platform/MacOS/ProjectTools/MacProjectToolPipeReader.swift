import Darwin
import Foundation

/// A narrow syscall boundary; errno is captured before any callback can change it.
struct MacProjectToolPipeIO: Sendable {
    enum Read: Sendable { case bytes(Data), eof, error(Int32) }
    let read: @Sendable (Int32) -> Read
    let close: @Sendable (Int32) -> Int32?

    static let native = Self(read: { descriptor in
        var bytes = Data(count: 16 * 1_024)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
        if count > 0 { bytes.count = count; return .bytes(bytes) }
        if count == 0 { return .eof }
        return .error(errno)
    }, close: { Darwin.close($0) == 0 ? nil : errno })
}

/// The source's cancellation handler is the read descriptor's sole closer.
/// Writers remain blocking and have a separate owner until spawn returns.
final class MacProjectToolPipeReader: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let descriptor: Int32
    private let io: MacProjectToolPipeIO
    private let onData: @Sendable (Data) -> Void
    private let onEOF: @Sendable () -> Void
    private let onError: @Sendable (Int32) -> Void
    private var cancelled = false

    init(
        descriptor: Int32, queue: DispatchQueue, io: MacProjectToolPipeIO = .native,
        onData: @escaping @Sendable (Data) -> Void,
        onEOF: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Int32) -> Void,
        onClosed: @escaping @Sendable () -> Void,
        onCloseError: @escaping @Sendable (Int32) -> Void
    ) {
        self.descriptor = descriptor
        self.io = io
        self.onData = onData
        self.onEOF = onEOF
        self.onError = onError
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setCancelHandler {
            if let error = io.close(descriptor) { onCloseError(error) }
            else { onClosed() }
        }
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.activate()
    }

    /// All reader methods are confined to the capture's native owner queue.
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        source.cancel()
    }

    private func readAvailable() {
        // At most 64 KiB per event, including EINTR retries, so cancellation and
        // deadlines can run even when a child continuously fills the pipe.
        for _ in 0..<4 where !cancelled {
            switch io.read(descriptor) {
            case .bytes(let bytes):
                onData(bytes)
            case .eof:
                onEOF()
                cancel()
            case .error(let code):
                if code == EAGAIN || code == EWOULDBLOCK { return }
                if code == EINTR { continue }
                onError(code)
                cancel()
            }
        }
    }
}
