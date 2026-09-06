import Darwin

/// Transfers even partially prepared descriptors to the capture owner.
struct MacProjectToolPreparedPipe: Sendable {
    var read: Int32?
    var write: Int32?
    var error: Int32?

    static func make() -> Self {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else { return Self(error: errno) }
        var result = Self(read: descriptors[0], write: descriptors[1])
        for descriptor in descriptors {
            guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
                result.error = errno
                return result
            }
        }
        let flags = Darwin.fcntl(descriptors[0], F_GETFL)
        guard flags != -1, Darwin.fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) != -1 else {
            result.error = errno
            return result
        }
        return result
    }
}
