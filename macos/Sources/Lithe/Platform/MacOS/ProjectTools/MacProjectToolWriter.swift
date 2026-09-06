import Foundation

/// Access is transferred from the spawn worker to the serial capture queue
/// only after spawn returns. A failed close never becomes implicit success.
final class MacProjectToolWriter {
    let handle: FileHandle
    private let closeHandle: (FileHandle) throws -> Void
    private var confirmedClosed = false
    private var attemptedClose = false

    init(descriptor: Int32, closeHandle: @escaping (FileHandle) throws -> Void = { try $0.close() }) {
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.closeHandle = closeHandle
    }

    func close() -> Bool {
        if confirmedClosed { return true }
        // Even reading fileDescriptor after Foundation invalidates a failed
        // wrapper can throw an Objective-C exception. Never touch it again or
        // re-close a raw number which the OS may already have reused.
        guard !attemptedClose else { return false }
        attemptedClose = true
        do {
            try closeHandle(handle)
            confirmedClosed = true
            return true
        } catch {
            NSLog("Lithe project tool writer did not close: %@", error.localizedDescription)
            return false
        }
    }
}
