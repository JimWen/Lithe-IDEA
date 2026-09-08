import Foundation
import LitheCoreContracts
import Testing

@testable import Lithe

/// Regression coverage for the Go Tools tree presentation: GoLand never hides
/// the top level, so every module keeps its own row even in a single-module
/// workspace; packages carry main/test entries by runnability; expansion
/// state prunes across refreshes; and the run-configuration projection
/// mirrors the Rust detector's `go.main` / `go.command` ids.
@MainActor
struct GoTreePresentationTests {
    /// Unlike the Cargo tree, a lone module is not absorbed into the project
    /// node: GoLand's Go Modules tree always shows the module row.
    @Test
    func aSingleModuleWorkspaceStillRendersItsModuleRow() throws {
        let snapshot = try decodeSnapshot(json: Self.workspaceJSON(modules: [
            Self.moduleJSON(id: "m", name: "example.com/single", directory: ".",
                            manifest: "go.mod", targets: [Self.packageJSON(
                id: "p-main", name: "main", importPath: "example.com/single",
                directory: ".", runnable: true, testable: true
            )])
        ]))
        let layout = GoTreePresentation.layout(snapshot, workspaceName: "host")
        #expect(layout.workspaceName == "host")
        #expect(layout.modules.map(\.id) == ["m"])
    }

    /// A package's entries follow its flags: a runnable main package offers
    /// `main` plus a test row, a plain library only the test row, and an
    /// incomplete package offers nothing.
    @Test
    func packageEntriesFollowRunnabilityAndTestability() throws {
        let main = GoTargetEntry(id: "p:main", name: "main", kind: .application)
        let test = { (id: String, path: String) in
            GoTargetEntry(id: id + ":test", name: "go test " + path, kind: .test)
        }

        let runnable = GoTreePresentation.entries(for: Self.target(
            id: "p", name: "main", importPath: "example.com/p",
            runnable: true, testable: true
        ))
        #expect(runnable == [main, test("p", "example.com/p")])

        let library = GoTreePresentation.entries(for: Self.target(
            id: "lib", name: "lib", importPath: "example.com/lib",
            runnable: false, testable: true
        ))
        #expect(library == [test("lib", "example.com/lib")])

        // An incomplete or failed package is neither runnable nor testable in
        // the normalized metadata, so it offers nothing.
        let broken = GoTreePresentation.entries(for: Self.target(
            id: "broken", name: "broken", importPath: "example.com/broken",
            runnable: false, testable: false
        ))
        #expect(broken.isEmpty)
    }

    /// The id projection mirrors the Rust detector: directories under
    /// `cmd/<name>` produce `go.command`, everything else `go.main`, the label
    /// is the directory's own name, the workspace root uses the workspace
    /// name, and anything not runnable or outside the workspace projects to
    /// nothing.
    @Test
    func goMainConfigurationIDMirrorsTheDetector() throws {
        let module = Self.moduleJSON(id: "m", name: "example.com/app", directory: ".",
                                     manifest: "go.mod", targets: [])
        _ = module

        func id(_ directory: (rootID: String, relative: String), runnable: Bool = true,
                moduleDirectory: String = ".") throws -> String? {
            let targetJSON = Self.targetJSON(
                id: "t", name: "main", importPath: "example.com/app",
                directoryRootID: directory.rootID, directoryRelative: directory.relative,
                runnable: runnable, testable: false
            )
            let member = try decodeMember(Self.moduleJSON(
                id: "m", name: "example.com/app", directory: moduleDirectory,
                manifest: moduleDirectory + "/go.mod", targets: [targetJSON]
            ))
            let target = try decodeTarget(targetJSON)
            return GoTreePresentation.goMainConfigurationID(
                member: member, target: target, workspaceName: "host"
            )
        }

        #expect(try id(("workspace", ".")) == "go.main:host")
        #expect(try id(("workspace", "server")) == "go.main:server/server")
        #expect(try id(("workspace", "cmd/migrate")) == "go.command:cmd/migrate/migrate")
        #expect(try id(("workspace", "cmd"), runnable: false) == nil)
        #expect(try id(("external1", "elsewhere/module")) == nil)

        // A module root living under cmd/<name> carries its own go.mod, so the
        // detector's manifest rule wins over the command-directory rule.
        #expect(try id(("workspace", "cmd/server"), moduleDirectory: "cmd/server")
            == "go.main:cmd/server/server")
        #expect(try id(("workspace", "cmd/server/interior"), moduleDirectory: "cmd/server")
            == "go.main:cmd/server/interior/interior")
    }

    /// Expansion defaults to fully open, a refresh prunes state for nodes that
    /// disappeared, and a selection on a removed node is dropped.
    @Test
    func reconciliationPrunesStaleNodesAndSelection() throws {
        let presentation = GoTreePresentation()
        let first = try decodeSnapshot(json: Self.workspaceJSON(modules: [
            Self.moduleJSON(id: "a", name: "example.com/a", directory: "a",
                            manifest: "a/go.mod", targets: [Self.packageJSON(
                id: "pa", name: "main", importPath: "example.com/a",
                directory: "a", runnable: true, testable: true
            )]),
            Self.moduleJSON(id: "b", name: "example.com/b", directory: "b",
                            manifest: "b/go.mod", targets: []),
        ]))
        presentation.reconcile(first)
        #expect(presentation.expandedModules == ["a", "b"])
        #expect(presentation.expandedPackages == ["pa"])
        #expect(presentation.expandedTargetGroups == ["pa"])

        presentation.selectedNodeID = "package:pa"
        let second = try decodeSnapshot(json: Self.workspaceJSON(modules: [
            Self.moduleJSON(id: "a", name: "example.com/a", directory: "a",
                            manifest: "a/go.mod", targets: []),
        ]))
        presentation.reconcile(second)
        #expect(presentation.expandedModules == ["a"])
        #expect(presentation.expandedPackages.isEmpty)
        #expect(presentation.expandedTargetGroups.isEmpty)
        #expect(presentation.selectedNodeID == nil)

        // Collapsing everything and re-expanding covers the toolbar actions.
        presentation.collapseAll()
        #expect(presentation.expandedModules.isEmpty && !presentation.isProjectExpanded)
        presentation.expandAll()
        #expect(presentation.expandedModules == ["a"] && presentation.isProjectExpanded)

        // A missing snapshot must not reset the tree, matching Cargo.
        presentation.reconcile(nil)
        #expect(presentation.expandedModules == ["a"])
    }

    /// A package that turns incomplete loses its Targets group entirely, so
    /// the group's expansion state and a selection on the group must be
    /// pruned instead of surviving on a row the view no longer renders.
    @Test
    func aPackageThatLosesItsEntriesLosesItsTargetsGroup() throws {
        let presentation = GoTreePresentation()
        let withEntries = try decodeSnapshot(json: Self.workspaceJSON(modules: [
            Self.moduleJSON(id: "a", name: "example.com/a", directory: "a",
                            manifest: "a/go.mod", targets: [Self.packageJSON(
                id: "pa", name: "main", importPath: "example.com/a",
                directory: "a", runnable: true, testable: true
            )])
        ]))
        presentation.reconcile(withEntries)
        presentation.selectedNodeID = "targets:pa"
        #expect(presentation.expandedTargetGroups == ["pa"])

        let withoutEntries = try decodeSnapshot(json: Self.workspaceJSON(modules: [
            Self.moduleJSON(id: "a", name: "example.com/a", directory: "a",
                            manifest: "a/go.mod", targets: [Self.packageJSON(
                id: "pa", name: "main", importPath: "example.com/a",
                directory: "a", runnable: false, testable: false
            )])
        ]))
        presentation.reconcile(withoutEntries)
        #expect(presentation.expandedTargetGroups.isEmpty)
        #expect(presentation.selectedNodeID == nil)

        // The group node returns with the package's entries, but stays
        // collapsed: refreshes preserve the user's expansion choices and only
        // prune, exactly like the Cargo tree.
        presentation.reconcile(withEntries)
        #expect(presentation.expandedTargetGroups.isEmpty)
        presentation.expandAll()
        #expect(presentation.expandedTargetGroups == ["pa"])
    }

    // MARK: - Fixtures

    private func decodeSnapshot(json: String) throws -> ProjectMetadataSnapshot {
        try JSONDecoder().decode(ProjectMetadataSnapshot.self, from: Data(json.utf8))
    }

    private static func workspaceJSON(modules: [String]) -> String {
        """
        {"version":1,"language":"go",
         "workspace":{"rootID":"workspace","relativePath":"."},
         "members":[\(modules.joined(separator: ","))],
         "defaultMemberIDs":null,"diagnostics":[]}
        """
    }

    private static func moduleJSON(
        id: String, name: String, directory: String, manifest: String, targets: [String]
    ) -> String {
        """
        {"id":"\(id)","name":"\(name)","version":null,"languageVersion":null,
          "directory":{"rootID":"workspace","relativePath":"\(directory)"},
          "manifest":{"rootID":"workspace","relativePath":"\(manifest)"},
          "defaultRun":null,"targets":[\(targets.joined(separator: ","))],
          "featureEntries":[],"dependencies":[],"incomplete":false,"diagnostics":[]}
        """
    }

    private static func packageJSON(
        id: String, name: String, importPath: String, directory: String,
        runnable: Bool, testable: Bool
    ) -> String {
        targetJSON(
            id: id, name: name, importPath: importPath,
            directoryRootID: "workspace", directoryRelative: directory,
            runnable: runnable, testable: testable
        )
    }

    private static func target(
        id: String, name: String, importPath: String,
        directoryRootID: String = "workspace", directoryRelative: String = ".",
        runnable: Bool, testable: Bool
    ) -> ProjectMetadataTarget {
        let json = targetJSON(
            id: id, name: name, importPath: importPath,
            directoryRootID: directoryRootID, directoryRelative: directoryRelative,
            runnable: runnable, testable: testable
        )
        return try! JSONDecoder().decode(ProjectMetadataTarget.self, from: Data(json.utf8))
    }

    private func decodeMember(_ json: String) throws -> ProjectMetadataMember {
        try JSONDecoder().decode(ProjectMetadataMember.self, from: Data(json.utf8))
    }

    private func decodeTarget(_ json: String) throws -> ProjectMetadataTarget {
        try JSONDecoder().decode(ProjectMetadataTarget.self, from: Data(json.utf8))
    }

    private static func targetJSON(
        id: String, name: String, importPath: String,
        directoryRootID: String, directoryRelative: String,
        runnable: Bool, testable: Bool
    ) -> String {
        """
        {"id":"\(id)","name":"\(name)","kind":"package","rawKinds":["package"],"crateTypes":[],
         "edition":null,"directory":{"rootID":"\(directoryRootID)","relativePath":"\(directoryRelative)"},
         "sources":[{"location":{"rootID":"workspace","relativePath":"\(directoryRelative)/main.go"},"role":"go"}],
         "importPath":"\(importPath)","requiredFeatures":[],"runnable":\(runnable),"testable":\(testable),
         "doctest":false,"incomplete":false,"imports":[],"testImports":[],"externalTestImports":[],
         "diagnostics":[]}
        """
    }
}
