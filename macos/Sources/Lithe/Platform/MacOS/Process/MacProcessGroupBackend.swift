import Darwin
import Foundation

@_silgen_name("proc_listpids")
private func managedGroupListPIDs(
    _ type: UInt32, _ group: UInt32, _ buffer: UnsafeMutableRawPointer?, _ size: Int32
) -> Int32

@_silgen_name("proc_pidinfo")
private func managedGroupPIDInfo(
    _ pid: pid_t, _ flavor: Int32, _ argument: UInt64,
    _ buffer: UnsafeMutableRawPointer?, _ size: Int32
) -> Int32

struct MacProcessGroupMember: Hashable, Sendable {
    let pid: pid_t
    let groupID: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

enum MacProcessGroupPresence: Sendable { case absent, present, unknown }

/// Native identity queries are separate from cleanup policy so reuse and query
/// failures can be verified without relying on real PID recycling.
protocol MacProcessGroupBackend: Sendable {
    func presence(of groupID: pid_t) -> MacProcessGroupPresence
    func members(of groupID: pid_t) -> [MacProcessGroupMember]?
    func member(_ pid: pid_t) -> MacProcessGroupMember?
    func signal(_ value: Int32, to member: MacProcessGroupMember)
}

struct MacNativeProcessGroupBackend: MacProcessGroupBackend {
    func presence(of groupID: pid_t) -> MacProcessGroupPresence {
        guard groupID > 0 else { return .unknown }
        if Darwin.kill(-groupID, 0) == 0 { return .present }
        switch errno {
        case ESRCH: return .absent
        case EPERM: return .present
        default: return .unknown
        }
    }

    func members(of groupID: pid_t) -> [MacProcessGroupMember]? {
        // A full buffer may have raced a fork. Retry with bounded growth rather
        // than treating a truncated enumeration as a complete empty group.
        let itemSize = MemoryLayout<pid_t>.stride
        let estimatedBytes = managedGroupListPIDs(UInt32(PROC_PGRP_ONLY), UInt32(groupID), nil, 0)
        guard estimatedBytes >= 0 else { return nil }
        var capacity = max(64, Int(estimatedBytes) / itemSize + 32)
        for _ in 0..<3 {
            guard capacity <= 65_536 else { return nil }
            var pids = [pid_t](repeating: 0, count: capacity)
            let byteCount = managedGroupListPIDs(
                UInt32(PROC_PGRP_ONLY), UInt32(groupID), &pids, Int32(capacity * itemSize)
            )
            guard byteCount >= 0 else { return nil }
            if Int(byteCount) >= capacity * itemSize { capacity *= 2; continue }
            return pids.prefix(Int(byteCount) / itemSize).compactMap { pid in
                guard let identity = member(pid), identity.groupID == groupID else { return nil }
                return identity
            }
        }
        return nil
    }

    func member(_ pid: pid_t) -> MacProcessGroupMember? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard managedGroupPIDInfo(pid, PROC_PIDTBSDINFO, 1, &info, size) == size else { return nil }
        // Zombies still anchor a group until waitpid releases their PID.
        return MacProcessGroupMember(
            pid: pid, groupID: pid_t(info.pbi_pgid),
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec
        )
    }

    func signal(_ value: Int32, to identity: MacProcessGroupMember) {
        // macOS has no pidfd signal API. Recheck immediately before a positive
        // PID signal; never send a delayed negative-PGID signal after root reap.
        guard member(identity.pid) == identity else { return }
        if Darwin.kill(identity.pid, value) != 0, errno != ESRCH {
            NSLog("Lithe could not signal owned process %d: %d", identity.pid, errno)
        }
    }
}
