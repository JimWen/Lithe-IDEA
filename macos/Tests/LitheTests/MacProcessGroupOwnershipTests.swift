import Darwin
import Foundation
import Testing
@testable import Lithe

@Suite("Process group incarnation ownership")
struct MacProcessGroupOwnershipTests {
    @Test
    func failedCleanupRetainsAnchorAndExplicitRetryCanFinish() {
        let root = member(41001)
        let child = member(41002)
        let backend = GroupIdentityBackend([root, child])
        let group = MacProcessGroup(processGroupID: root.pid, backend: backend)
        group.prepareForRootReap()
        backend.current = [child]
        #expect(!group.terminateAndWait(gracePeriod: 0, forcedTerminationTimeout: 0))
        #expect(backend.signals.map(\.pid) == [child.pid, child.pid])
        #expect(backend.signals.map(\.value) == [SIGTERM, SIGKILL])
        backend.removeSignalledMembers = true
        #expect(group.terminateAndWait(gracePeriod: 0, forcedTerminationTimeout: 0))
        #expect(backend.current.isEmpty)
        #expect(backend.signals.count == 3)
    }

    @Test
    func reusedPIDAndGroupAreNeverReadoptedAfterFailure() {
        let original = member(41001)
        let backend = GroupIdentityBackend([original])
        let group = MacProcessGroup(processGroupID: original.pid, backend: backend)
        group.prepareForRootReap()
        #expect(!group.terminateAndWait(gracePeriod: 0, forcedTerminationTimeout: 0))
        let previousSignals = backend.signals.count
        backend.current = [member(original.pid, start: 2)]
        #expect(!group.terminateAndWait(gracePeriod: 0, forcedTerminationTimeout: 0))
        #expect(backend.signals.count == previousSignals)
        backend.current = []
        #expect(group.terminateAndWait(gracePeriod: 0, forcedTerminationTimeout: 0))
        // Once absence is confirmed, even a subsequently reused group stays
        // outside this retired owner's signal authority.
        backend.current = [member(original.pid, start: 3)]
        #expect(group.terminateAndWait(gracePeriod: 0, forcedTerminationTimeout: 0))
        #expect(backend.signals.count == previousSignals)
    }

    @Test
    func anchorMustSurviveTheEntireEnumeration() {
        let original = member(41001)
        let backend = GroupIdentityBackend([original])
        let group = MacProcessGroup(processGroupID: original.pid, backend: backend)
        group.prepareForRootReap()
        backend.replaceDuringNextEnumeration = [member(original.pid, start: 2), member(41002, start: 2)]
        #expect(!group.terminateAndWait(gracePeriod: 0, forcedTerminationTimeout: 0))
        #expect(backend.signals.isEmpty)
    }

    @Test
    func unseenUnreapedRootStillAuthorizesInitialDescendantSnapshot() {
        // The caller still owns an unreaped child PID even if a short-lived
        // zombie root is absent from libproc's per-process query results.
        let child = member(41002)
        let backend = GroupIdentityBackend([child])
        let group = MacProcessGroup(processGroupID: 41001, backend: backend)
        group.prepareForRootReap()
        backend.removeSignalledMembers = true
        #expect(group.terminateAndWait(gracePeriod: 0, forcedTerminationTimeout: 0))
        #expect(backend.signals.map(\.pid) == [child.pid])
    }

    @Test
    func incompleteQueriesNeverProveAnEmptyGroup() {
        let backend = GroupIdentityBackend([member(41001)])
        backend.queriesUnavailable = true
        let group = MacProcessGroup(processGroupID: 41001, backend: backend)
        group.prepareForRootReap()
        #expect(!group.terminateAndWait(gracePeriod: 0, forcedTerminationTimeout: 0))
        #expect(backend.signals.isEmpty)
    }

    @Test
    func temporaryQueryFailureDoesNotDiscardTheOnlyLaterSurvivor() {
        let root = member(41001)
        let child = member(41002)
        let backend = GroupIdentityBackend([root, child])
        let group = MacProcessGroup(processGroupID: root.pid, backend: backend)
        group.prepareForRootReap()
        backend.hiddenPIDs = [child.pid]
        backend.enumerationUnavailable = true
        #expect(!group.terminateAndWait(gracePeriod: 0, forcedTerminationTimeout: 0))
        backend.current = [child]
        backend.hiddenPIDs = []
        backend.enumerationUnavailable = false
        backend.removeSignalledMembers = true
        #expect(group.terminateAndWait(gracePeriod: 0, forcedTerminationTimeout: 0))
        #expect(backend.current.isEmpty)
    }

    @Test
    func discoveredDescendantCanCarryOwnershipAfterRootReap() {
        let root = member(41001)
        let child = member(41002)
        let backend = GroupIdentityBackend([root, child])
        let group = MacProcessGroup(processGroupID: root.pid, backend: backend)
        group.prepareForRootReap()
        backend.current = [child, member(41003)]
        #expect(!group.terminateAndWait(gracePeriod: 0, forcedTerminationTimeout: 0))
        #expect(Set(backend.signals.map(\.pid)) == [41002, 41003])
        #expect(!backend.signals.contains { $0.pid == root.pid })
    }

    private func member(_ pid: pid_t, start: UInt64 = 1) -> MacProcessGroupMember {
        MacProcessGroupMember(pid: pid, groupID: 41001, startSeconds: start, startMicroseconds: 0)
    }
}

/// Used synchronously by one cleanup caller; no timing or real processes.
private final class GroupIdentityBackend: MacProcessGroupBackend, @unchecked Sendable {
    struct Signal { let pid: pid_t; let value: Int32 }
    var current: [MacProcessGroupMember]
    var replaceDuringNextEnumeration: [MacProcessGroupMember]?
    var removeSignalledMembers = false
    var queriesUnavailable = false
    var enumerationUnavailable = false
    var hiddenPIDs: Set<pid_t> = []
    private(set) var signals: [Signal] = []
    init(_ current: [MacProcessGroupMember]) { self.current = current }
    func presence(of groupID: pid_t) -> MacProcessGroupPresence {
        if queriesUnavailable { return .unknown }
        return current.contains { $0.groupID == groupID } ? .present : .absent
    }
    func members(of groupID: pid_t) -> [MacProcessGroupMember]? {
        if queriesUnavailable || enumerationUnavailable { return nil }
        if let replacement = replaceDuringNextEnumeration {
            current = replacement
            replaceDuringNextEnumeration = nil
        }
        return current.filter { $0.groupID == groupID }
    }
    func member(_ pid: pid_t) -> MacProcessGroupMember? {
        queriesUnavailable || hiddenPIDs.contains(pid) ? nil : current.first { $0.pid == pid }
    }
    func signal(_ value: Int32, to identity: MacProcessGroupMember) {
        guard member(identity.pid) == identity else { return }
        signals.append(Signal(pid: identity.pid, value: value))
        if removeSignalledMembers { current.removeAll { $0 == identity } }
    }
}
