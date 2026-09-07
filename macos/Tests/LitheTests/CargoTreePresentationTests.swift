import Foundation
import LitheCoreContracts
import Testing

@testable import Lithe

/// Regression coverage for the Cargo tree presentation: the RustRover node
/// shape (a project node that absorbs the root package's targets group and
/// wraps only the remaining members), default expansion, expand/collapse all,
/// and stale-node pruning across refreshes.
@MainActor
struct CargoTreePresentationTests {
    /// A lone package is the root package of its own workspace, so its targets
    /// hang directly off the project node and it never gains a member row.
    /// The project takes the package's name, not the literal "Workspace". The
    /// anchor is the attached manifest's directory: the normalized workspace
    /// location is always the host root and can never identify the package.
    @Test
    func aRootPackageIsAbsorbedIntoTheProjectNode() throws {
        let nested = try decodeSnapshot(json: Self.singlePackageJSON(
            workspaceRelative: "simple/scrap_url",
            manifestRelative: "simple/scrap_url/Cargo.toml",
            targetID: "t-bin",
            targetSource: "simple/scrap_url/src/main.rs"
        ))
        let nestedLayout = CargoTreePresentation.layout(
            nested, manifestDirectory: "simple/scrap_url", workspaceName: "host"
        )
        #expect(nestedLayout.projectName == "scrap_url")
        #expect(nestedLayout.rootMember?.id == "m")
        #expect(nestedLayout.nestedMembers.isEmpty)

        let atRoot = try decodeSnapshot(json: Self.singlePackageJSON(
            workspaceRelative: ".",
            manifestRelative: "Cargo.toml",
            targetID: "t-bin",
            targetSource: "src/main.rs"
        ))
        let rootLayout = CargoTreePresentation.layout(
            atRoot, manifestDirectory: ".", workspaceName: "host"
        )
        #expect(rootLayout.projectName == "scrap_url")
        #expect(rootLayout.rootMember?.id == "m")
        #expect(rootLayout.nestedMembers.isEmpty)
    }

    /// Attaching a member manifest of a multi-member workspace focuses the
    /// project on that member: its targets lift into the project node and the
    /// siblings keep their rows.
    @Test
    func attachingAMemberManifestAbsorbsThatMember() throws {
        let snapshot = try decodeSnapshot(json: Self.multiMemberJSON())
        let layout = CargoTreePresentation.layout(
            snapshot, manifestDirectory: "beta", workspaceName: "host"
        )
        #expect(layout.projectName == "beta")
        #expect(layout.rootMember?.id == "beta")
        #expect(layout.nestedMembers.map(\.id) == ["alpha"])
    }

    /// The mixed case RustRover handles and a member-count test cannot: a
    /// workspace whose root package also ships targets shows those targets
    /// under the project node while its siblings stay wrapped.
    @Test
    func aWorkspaceWithARootPackageHoistsOnlyThatPackage() throws {
        let snapshot = try decodeSnapshot(json: Self.rootPackageWorkspaceJSON())
        let layout = CargoTreePresentation.layout(
            snapshot, manifestDirectory: ".", workspaceName: "host"
        )
        #expect(layout.projectName == "host-crate")
        #expect(layout.rootMember?.id == "host")
        #expect(layout.nestedMembers.map(\.id) == ["alpha"])
    }

    /// The root package owns a targets group but no member row, so expansion
    /// state must cover the group without inventing a member node for it.
    @Test
    func rootPackageOwnsATargetsGroupButNoMemberRow() throws {
        let presentation = CargoTreePresentation()
        presentation.reconcile(try decodeSnapshot(json: Self.rootPackageWorkspaceJSON()), manifestDirectory: ".")

        presentation.expandAll()
        #expect(presentation.expandedTargetGroups == ["host", "alpha"])
        #expect(presentation.expandedMembers == ["alpha"])

        // A selection on the absent member row is pruned; the group survives.
        presentation.selectedNodeID = "member:host"
        presentation.reconcile(try decodeSnapshot(json: Self.rootPackageWorkspaceJSON()), manifestDirectory: ".")
        #expect(presentation.selectedNodeID == nil)

        presentation.selectedNodeID = "targets:host"
        presentation.reconcile(try decodeSnapshot(json: Self.rootPackageWorkspaceJSON()), manifestDirectory: ".")
        #expect(presentation.selectedNodeID == "targets:host")
    }

    @Test
    func cargoBinaryConfigurationIDsMatchDetectorDirectories() throws {
        let snapshot = try decodeSnapshot(json: Self.singlePackageJSON(
            workspaceRelative: "simple/scrap_url",
            manifestRelative: "simple/scrap_url/Cargo.toml",
            targetID: "t-bin",
            targetSource: "simple/scrap_url/src/main.rs"
        ))
        let member = try #require(snapshot.members.first)
        let target = try #require(member.targets.first)
        #expect(CargoTreePresentation.cargoBinaryConfigurationID(
            memberDirectory: member.directory.relativePath, target: target
        ) == "cargo.binary:simple/scrap_url/t-bin")

        let rootSnapshot = try decodeSnapshot(json: Self.singlePackageJSON(
            workspaceRelative: ".",
            manifestRelative: "Cargo.toml",
            targetID: "root-bin",
            targetSource: "src/main.rs"
        ))
        let rootMember = try #require(rootSnapshot.members.first)
        let rootTarget = try #require(rootMember.targets.first)
        #expect(CargoTreePresentation.cargoBinaryConfigurationID(
            memberDirectory: rootMember.directory.relativePath, target: rootTarget
        ) == "cargo.binary:root-bin")
    }

    @Test
    func nonBinaryTargetsDoNotInventRunConfigurations() throws {
        let snapshot = try decodeSnapshot(json: Self.singlePackageJSON(
            workspaceRelative: ".",
            manifestRelative: "Cargo.toml",
            targetID: "lib",
            targetSource: "src/lib.rs"
        )
        .replacingOccurrences(of: "\"kind\":\"bin\"", with: "\"kind\":\"lib\"")
        .replacingOccurrences(of: "\"runnable\":true", with: "\"runnable\":false"))
        let member = try #require(snapshot.members.first)
        let target = try #require(member.targets.first)
        #expect(CargoTreePresentation.cargoBinaryConfigurationID(
            memberDirectory: member.directory.relativePath, target: target
        ) == nil)
    }

    @Test
    func firstSnapshotExpandsDefaultMembersAndEveryTargetsGroup() throws {
        let presentation = CargoTreePresentation()
        let snapshot = try decodeSnapshot(json: Self.rootPackageWorkspaceJSON())
        presentation.reconcile(snapshot, manifestDirectory: ".")

        #expect(presentation.expandedTargetGroups == ["host", "alpha"])
        // Only nested default members start expanded; the rest stay collapsed.
        #expect(presentation.expandedMembers == ["alpha"])
        #expect(presentation.isProjectExpanded)
    }

    @Test
    func expandAndCollapseAllCoverEveryNodeKind() throws {
        let presentation = CargoTreePresentation()
        let snapshot = try decodeSnapshot(json: Self.multiMemberJSON())
        presentation.reconcile(snapshot, manifestDirectory: "beta")

        presentation.collapseAll()
        #expect(!presentation.isProjectExpanded)
        #expect(presentation.expandedMembers.isEmpty)
        #expect(presentation.expandedTargetGroups.isEmpty)

        presentation.expandAll()
        #expect(presentation.isProjectExpanded)
        // The absorbed root package owns no member row of its own.
        #expect(presentation.expandedMembers == ["alpha"])
        #expect(presentation.expandedTargetGroups == ["beta", "alpha"])
    }

    @Test
    func refreshPrunesSelectionsThatNoLongerExist() throws {
        let presentation = CargoTreePresentation()
        presentation.reconcile(try decodeSnapshot(json: Self.singlePackageJSON(
            workspaceRelative: "simple/scrap_url",
            manifestRelative: "simple/scrap_url/Cargo.toml",
            targetID: "t-bin",
            targetSource: "simple/scrap_url/src/main.rs"
        )), manifestDirectory: "simple/scrap_url")
        presentation.selectedNodeID = "target:t-bin"
        presentation.expandedTargetGroups.insert("gone")

        presentation.reconcile(try decodeSnapshot(json: Self.singlePackageJSON(
            workspaceRelative: "simple/scrap_url",
            manifestRelative: "simple/scrap_url/Cargo.toml",
            targetID: "t-bin-renamed",
            targetSource: "simple/scrap_url/src/main.rs"
        )), manifestDirectory: "simple/scrap_url")

        #expect(presentation.selectedNodeID == nil)
        // "m" is the root package, so it owns a targets group and no member
        // row; the group keeps its expansion and only stale ids are pruned.
        #expect(presentation.expandedMembers.isEmpty)
        #expect(presentation.expandedTargetGroups == ["m"])
    }

    @Test
    func resetReturnsToTheFreshState() throws {
        let presentation = CargoTreePresentation()
        presentation.reconcile(try decodeSnapshot(json: Self.multiMemberJSON()), manifestDirectory: "beta")
        presentation.expandAll()
        presentation.selectedNodeID = "member:alpha"

        presentation.reset()

        #expect(presentation.selectedNodeID == nil)
        #expect(presentation.expandedMembers.isEmpty)
        #expect(presentation.expandedTargetGroups.isEmpty)
        #expect(presentation.isProjectExpanded)
        // A following snapshot is treated as first-seen again.
        let snapshot = try decodeSnapshot(json: Self.multiMemberJSON())
        presentation.reconcile(snapshot, manifestDirectory: "beta")
        #expect(presentation.expandedMembers.isEmpty)
        #expect(presentation.expandedTargetGroups == ["beta", "alpha"])
    }

    // MARK: - Fixtures

    private func decodeSnapshot(json: String) throws -> ProjectMetadataSnapshot {
        try JSONDecoder().decode(ProjectMetadataSnapshot.self, from: Data(json.utf8))
    }

    /// A lone package whose manifest lives in the Cargo workspace root.
    private static func singlePackageJSON(
        workspaceRelative: String,
        manifestRelative: String,
        targetID: String,
        targetSource: String
    ) -> String {
        """
        {"version":1,"language":"rust",
         "workspace":{"rootID":"workspace","relativePath":"\(workspaceRelative)"},
         "members":[{"id":"m","name":"scrap_url","version":"0.1.0","languageVersion":"2024",
           "directory":{"rootID":"workspace","relativePath":"\(workspaceRelative)"},
           "manifest":{"rootID":"workspace","relativePath":"\(manifestRelative)"},
           "defaultRun":null,"targets":[\(targetJSON(id: targetID, source: targetSource))],
           "featureEntries":[],"dependencies":[],"incomplete":false,"diagnostics":[]}],
         "defaultMemberIDs":["m"],"diagnostics":[]}
        """
    }

    private static func multiMemberJSON() -> String {
        """
        {"version":1,"language":"rust",
         "workspace":{"rootID":"workspace","relativePath":"."},
         "members":[
           {"id":"alpha","name":"alpha","version":null,"languageVersion":null,
            "directory":{"rootID":"workspace","relativePath":"alpha"},
            "manifest":{"rootID":"workspace","relativePath":"alpha/Cargo.toml"},
            "defaultRun":null,"targets":[\(targetJSON(id: "a-lib", source: "alpha/src/lib.rs"))],
            "featureEntries":[],"dependencies":[],"incomplete":false,"diagnostics":[]},
           {"id":"beta","name":"beta","version":"0.2.0","languageVersion":"2021",
            "directory":{"rootID":"workspace","relativePath":"beta"},
            "manifest":{"rootID":"workspace","relativePath":"beta/Cargo.toml"},
            "defaultRun":null,"targets":[\(targetJSON(id: "b-bin", source: "beta/src/main.rs"))],
            "featureEntries":[],"dependencies":[],"incomplete":false,"diagnostics":[]}],
         "defaultMemberIDs":["beta"],"diagnostics":[]}
        """
    }

    /// A workspace whose root directory also holds a package, alongside one
    /// nested member. Members arrive ordered by manifest path.
    private static func rootPackageWorkspaceJSON() -> String {
        """
        {"version":1,"language":"rust",
         "workspace":{"rootID":"workspace","relativePath":"."},
         "members":[
           {"id":"host","name":"host-crate","version":"1.0.0","languageVersion":"2021",
            "directory":{"rootID":"workspace","relativePath":"."},
            "manifest":{"rootID":"workspace","relativePath":"Cargo.toml"},
            "defaultRun":null,"targets":[\(targetJSON(id: "h-bin", source: "src/main.rs"))],
            "featureEntries":[],"dependencies":[],"incomplete":false,"diagnostics":[]},
           {"id":"alpha","name":"alpha","version":null,"languageVersion":null,
            "directory":{"rootID":"workspace","relativePath":"alpha"},
            "manifest":{"rootID":"workspace","relativePath":"alpha/Cargo.toml"},
            "defaultRun":null,"targets":[\(targetJSON(id: "a-lib", source: "alpha/src/lib.rs"))],
            "featureEntries":[],"dependencies":[],"incomplete":false,"diagnostics":[]}],
         "defaultMemberIDs":["host","alpha"],"diagnostics":[]}
        """
    }

    private static func targetJSON(id: String, source: String) -> String {
        """
        {"id":"\(id)","name":"\(id)","kind":"bin","rawKinds":["bin"],"crateTypes":["bin"],
         "edition":"2024","directory":{"rootID":"workspace","relativePath":"."},
         "sources":[{"location":{"rootID":"workspace","relativePath":"\(source)"},"role":"root"}],
         "importPath":null,"requiredFeatures":[],"runnable":true,"testable":true,"doctest":false,
         "incomplete":false,"imports":[],"testImports":[],"externalTestImports":[],"diagnostics":[]}
        """
    }
}
