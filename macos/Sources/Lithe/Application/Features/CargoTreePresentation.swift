import Combine
import LitheCoreContracts

/// Project-owned presentation survives hiding the tool window. Selection and
/// expansion publish only to the tree, not to the full workbench.
@MainActor
final class CargoTreePresentation: ObservableObject {
    @Published var expandedMembers: Set<String> = []
    @Published var isWorkspaceExpanded = true
    @Published var selectedNodeID: String?
    private var hasSnapshot = false

    func reconcile(_ snapshot: ProjectMetadataSnapshot?) {
        guard let snapshot else { return }
        let members = Set(snapshot.members.map(\.id))
        if !hasSnapshot {
            expandedMembers = Set(snapshot.defaultMemberIDs ?? []).intersection(members)
            hasSnapshot = true
        } else {
            expandedMembers.formIntersection(members)
        }
        var nodes = Set(snapshot.members.map { "member:" + $0.id })
        nodes.insert("workspace")
        for member in snapshot.members {
            nodes.formUnion(member.targets.map { "target:" + $0.id })
        }
        if let selectedNodeID, !nodes.contains(selectedNodeID) { self.selectedNodeID = nil }
    }

    func reset() {
        expandedMembers = []
        isWorkspaceExpanded = true
        selectedNodeID = nil
        hasSnapshot = false
    }
}
