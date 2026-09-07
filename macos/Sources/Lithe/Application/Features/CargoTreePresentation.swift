import Combine
import LitheCoreContracts

/// The node shape RustRover renders for one Cargo project.
///
/// `CargoProjectTreeStructure.CargoSimpleNode.Project` splits a workspace into
/// the package rooted at the project directory and everything else: the root
/// package contributes its targets group directly, and only the remaining
/// members get a node of their own. Lithe attaches one manifest at a time, so
/// the project node is always singular here.
struct CargoTreeLayout {
    /// Label for the project node. RustRover names it after the Cargo project,
    /// which is the root package when the workspace has one.
    let projectName: String
    /// The member whose directory is the Cargo workspace root, when the
    /// workspace is not a virtual manifest. Its targets hang off the project
    /// node without an intervening member row.
    let rootMember: ProjectMetadataMember?
    /// Every member that is not the root package, in snapshot order.
    let nestedMembers: [ProjectMetadataMember]
}

/// Project-owned presentation survives hiding the tool window. Selection and
/// expansion publish only to the tree, not to the full workbench.
@MainActor
final class CargoTreePresentation: ObservableObject {
    @Published var expandedMembers: Set<String> = []
    /// The "Targets" group row under each member collapses independently,
    /// matching the GoLand/RustRover Cargo tree shape.
    @Published var expandedTargetGroups: Set<String> = []
    @Published var isProjectExpanded = true
    @Published var selectedNodeID: String?
    /// Manifest candidates for one applied workspace scan.
    ///
    /// Recognition is read during view updates by both activity rails and every
    /// disabled state in the Cargo header, while the scan behind it is linear in
    /// the size of the workspace. The memo is project-owned Cargo state with the
    /// same owner, lifetime and actor as the tree, so it is held here instead of
    /// in the UI aggregator. It is deliberately not `@Published`: writing it
    /// happens during `body`, and publishing would re-enter the view update.
    var manifestCache: CargoManifestCache?
    private var hasSnapshot = false
    /// Members that own a targets group, which is all of them.
    private var targetGroupOwnerIDs: Set<String> = []
    /// Members that render their own row, which excludes the root package.
    private var nestedMemberIDs: Set<String> = []

    /// Splits a snapshot into the RustRover node shape.
    ///
    /// `manifestDirectory` is the directory of the manifest the user attached,
    /// relative to the host workspace root. That attachment is the project
    /// anchor: a member rooted there is absorbed into the project node, and
    /// every other member renders its own row. `workspaceName` names the
    /// project when no member matches, for example a virtual manifest at the
    /// host workspace root.
    static func layout(
        _ snapshot: ProjectMetadataSnapshot,
        manifestDirectory: String?,
        workspaceName: String
    ) -> CargoTreeLayout {
        let root = rootMember(snapshot, manifestDirectory: manifestDirectory)
        return CargoTreeLayout(
            projectName: root?.name ?? workspaceName,
            rootMember: root,
            nestedMembers: snapshot.members.filter { $0.id != root?.id }
        )
    }

    /// The package rooted at the attached manifest's directory.
    ///
    /// The normalized `workspace` location is the host workspace root (`.` by
    /// contract), never the Cargo workspace root, so comparing a member
    /// against it can never match the root package of a nested workspace.
    static func rootMember(
        _ snapshot: ProjectMetadataSnapshot, manifestDirectory: String?
    ) -> ProjectMetadataMember? {
        guard let manifestDirectory else { return nil }
        return snapshot.members.first {
            $0.directory.rootID == "workspace"
                && $0.directory.relativePath == manifestDirectory
        }
    }

    /// Returns the generated run-configuration id for a Cargo binary target.
    ///
    /// Cargo detector ids are based on the package directory and target name,
    /// while metadata target ids are content-independent stable hashes. Keeping
    /// this projection here lets the tree route a double-click through the
    /// existing run service without duplicating detector identity rules in the
    /// view.
    ///
    /// Only `bin` maps to an id. A target's `runnable` flag states what Cargo
    /// could build — it also covers example binaries — while this projection
    /// states what the Cargo detector actually generated a configuration for,
    /// and that is binaries alone. Widening the kind here would produce ids
    /// that resolve to nothing.
    static func cargoBinaryConfigurationID(
        memberDirectory: String,
        target: ProjectMetadataTarget
    ) -> String? {
        guard target.runnable, target.kind == "bin" else { return nil }
        let directory = memberDirectory
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .filter { !$0.isEmpty && $0 != "." }
            .joined(separator: "/")
        let prefix = directory.isEmpty ? "" : directory + "/"
        return "cargo.binary:" + prefix + target.name
    }

    func reconcile(_ snapshot: ProjectMetadataSnapshot?, manifestDirectory: String?) {
        guard let snapshot else { return }
        let rootMemberID = Self.rootMember(snapshot, manifestDirectory: manifestDirectory)?.id
        targetGroupOwnerIDs = Set(snapshot.members.map(\.id))
        nestedMemberIDs = targetGroupOwnerIDs.subtracting([rootMemberID].compactMap { $0 })
        if !hasSnapshot {
            let defaults = Set(snapshot.defaultMemberIDs ?? []).intersection(nestedMemberIDs)
            expandedMembers = defaults
            expandedTargetGroups = targetGroupOwnerIDs
            hasSnapshot = true
        } else {
            expandedMembers.formIntersection(nestedMemberIDs)
            expandedTargetGroups.formIntersection(targetGroupOwnerIDs)
        }
        var nodes: Set<String> = ["project"]
        nodes.formUnion(nestedMemberIDs.map { "member:" + $0 })
        nodes.formUnion(targetGroupOwnerIDs.map { "targets:" + $0 })
        for member in snapshot.members {
            nodes.formUnion(member.targets.map { "target:" + $0.id })
        }
        if let selectedNodeID, !nodes.contains(selectedNodeID) { self.selectedNodeID = nil }
    }

    func expandAll() {
        isProjectExpanded = true
        expandedMembers = nestedMemberIDs
        expandedTargetGroups = targetGroupOwnerIDs
    }

    func collapseAll() {
        isProjectExpanded = false
        expandedMembers = []
        expandedTargetGroups = []
    }

    func reset() {
        expandedMembers = []
        expandedTargetGroups = []
        isProjectExpanded = true
        selectedNodeID = nil
        hasSnapshot = false
        targetGroupOwnerIDs = []
        nestedMemberIDs = []
    }
}
