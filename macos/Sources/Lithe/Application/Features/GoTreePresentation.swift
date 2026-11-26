import Combine
import Foundation
import LitheCoreContracts

/// The node shape for one Go project in the Go Modules tool window.
///
/// GoLand never hides the top level: every module renders its own row even
/// when the workspace has a single module, and packages hang off their module
/// as flat rows. A package carries a Targets group only when it has runnable
/// entries, matching the GoLand tree where plain libraries have nothing to
/// launch.
struct GoTreeLayout {
    let workspaceName: String
    /// Every module in snapshot order; the top level is never absorbed.
    let modules: [ProjectMetadataMember]
}

/// One launchable row under a package's Targets group.
struct GoTargetEntry: Equatable {
    enum Kind: Equatable {
        case application
        case test
    }

    let id: String
    let name: String
    let kind: Kind
}

/// Project-owned presentation survives hiding the tool window. Selection and
/// expansion publish only to the tree, not to the full workbench.
@MainActor
final class GoTreePresentation: ObservableObject {
    @Published var expandedModules: Set<String> = []
    @Published var expandedPackages: Set<String> = []
    @Published var expandedTargetGroups: Set<String> = []
    @Published var isProjectExpanded = true
    @Published var selectedNodeID: String?
    /// go.mod candidates for one applied workspace scan.
    ///
    /// Recognition is read during view updates by the header and every
    /// disabled state, while the scan behind it is linear in the workspace.
    /// The memo is project-owned Go state with the same owner, lifetime and
    /// actor as the tree, and is deliberately not `@Published`.
    var manifestCache: GoManifestCache?
    private var hasSnapshot = false
    private var moduleIDs: Set<String> = []
    private var packageIDs: Set<String> = []
    private var targetGroupIDs: Set<String> = []

    /// Splits a snapshot into the Go node shape.
    static func layout(
        _ snapshot: ProjectMetadataSnapshot, workspaceName: String
    ) -> GoTreeLayout {
        GoTreeLayout(workspaceName: workspaceName, modules: snapshot.members)
    }

    /// Returns true when the cached snapshot still contains diagnostics or
    /// incomplete modules/packages (for example, missing local module cache at
    /// initial prewarm) so reopening Go Tools refreshes automatically.
    static func hasDiagnosticsOrIncomplete(_ snapshot: ProjectMetadataSnapshot) -> Bool {
        if !snapshot.diagnostics.isEmpty { return true }
        return snapshot.members.contains { member in
            member.incomplete
                || !member.diagnostics.isEmpty
                || member.targets.contains { $0.incomplete || !$0.diagnostics.isEmpty }
        }
    }

    /// The packages of one module, which the metadata carries as targets of
    /// kind `package`; every other kind stays invisible to this tree.
    static func packages(of member: ProjectMetadataMember) -> [ProjectMetadataTarget] {
        member.targets.filter { $0.kind == "package" }
    }

    /// The launch entries one package contributes: a `main` application when
    /// the package is runnable, and a test entry when it is testable. Test
    /// execution itself arrives with the independent tool-task batch; the row
    /// exists so the tree already shows what GoLand shows.
    static func entries(for target: ProjectMetadataTarget) -> [GoTargetEntry] {
        var entries: [GoTargetEntry] = []
        if target.runnable {
            entries.append(GoTargetEntry(id: target.id + ":main", name: "main", kind: .application))
        }
        if target.testable {
            let name = "go test " + (target.importPath ?? target.name)
            entries.append(GoTargetEntry(id: target.id + ":test", name: name, kind: .test))
        }
        return entries
    }

    /// Returns the generated run-configuration id for a package's `main`
    /// entry, mirroring the Rust detector exactly: a module root (the package
    /// directory is the member's manifest directory) always produces
    /// `go.main` because the detector checks `go.mod` first, other directories
    /// under `cmd/<name>` produce `go.command`, everything else `go.main`, and
    /// the label is the directory's own name (the workspace name for the
    /// root). A package outside the workspace or not runnable has none.
    static func goMainConfigurationID(
        member: ProjectMetadataMember, target: ProjectMetadataTarget, workspaceName: String
    ) -> String? {
        guard target.runnable, target.kind == "package", target.directory.rootID == "workspace" else {
            return nil
        }
        func normalized(_ relative: String) -> String {
            relative.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/")
                .filter { !$0.isEmpty && $0 != "." }
                .joined(separator: "/")
        }
        let directory = normalized(target.directory.relativePath)
        let components = directory.split(separator: "/")
        let label = components.last.map(String.init) ?? workspaceName
        let isModuleRoot = directory == normalized(member.directory.relativePath)
        let parentIsCommand = components.count >= 2 && components[components.count - 2] == "cmd"
        let provider = !isModuleRoot && parentIsCommand ? "go.command" : "go.main"
        let prefix = directory.isEmpty ? "" : directory + "/"
        return provider + ":" + prefix + label
    }

    func reconcile(_ snapshot: ProjectMetadataSnapshot?) {
        guard let snapshot else { return }
        moduleIDs = Set(snapshot.members.map(\.id))
        packageIDs = Set(
            snapshot.members.flatMap { member in
                Self.packages(of: member).map(\.id)
            }
        )
        // The Targets group exists only where a package still offers entries;
        // a package that turned incomplete loses the group and any state or
        // selection attached to it.
        targetGroupIDs = Set(
            snapshot.members.flatMap { member in
                Self.packages(of: member).filter { !Self.entries(for: $0).isEmpty }.map(\.id)
            }
        )
        if !hasSnapshot {
            expandedModules = moduleIDs
            expandedPackages = packageIDs
            expandedTargetGroups = targetGroupIDs
            hasSnapshot = true
        } else {
            expandedModules.formIntersection(moduleIDs)
            expandedPackages.formIntersection(packageIDs)
            expandedTargetGroups.formIntersection(targetGroupIDs)
        }
        var nodes: Set<String> = ["project"]
        nodes.formUnion(moduleIDs.map { "module:" + $0 })
        nodes.formUnion(packageIDs.map { "package:" + $0 })
        nodes.formUnion(targetGroupIDs.map { "targets:" + $0 })
        for member in snapshot.members {
            for target in Self.packages(of: member) {
                nodes.formUnion(Self.entries(for: target).map { "entry:" + $0.id })
            }
        }
        if let selectedNodeID, !nodes.contains(selectedNodeID) { self.selectedNodeID = nil }
    }

    func expandAll() {
        isProjectExpanded = true
        expandedModules = moduleIDs
        expandedPackages = packageIDs
        expandedTargetGroups = targetGroupIDs
    }

    func collapseAll() {
        isProjectExpanded = false
        expandedModules = []
        expandedPackages = []
        expandedTargetGroups = []
    }

    func reset() {
        expandedModules = []
        expandedPackages = []
        expandedTargetGroups = []
        isProjectExpanded = true
        selectedNodeID = nil
        hasSnapshot = false
        moduleIDs = []
        packageIDs = []
    }
}

/// The result of one go.mod candidate scan, keyed by the scan that produced it.
struct GoManifestCache {
    let workspace: URL
    /// nil when no scan has been applied yet, which is a cacheable answer too.
    let snapshotID: UUID?
    let urls: [URL]
}

/// Formats serialized Rust Core Go diagnostic payloads (`{"Err":...}`) into
/// concise, deduplicated messages for the Go Tools tree.
struct GoFormattedDiagnostic: Equatable, Identifiable {
    let id: String
    let summary: String
    let tooltip: String
    let count: Int
}

enum GoDiagnosticFormatting {
    private struct Payload: Decodable {
        let err: String?
        let pos: String?
        let importStack: [String]?
        let query: String?

        enum CodingKeys: String, CodingKey {
            case err = "Err"
            case pos = "Pos"
            case importStack = "ImportStack"
            case query = "Query"
        }
    }

    static func entries(from items: [ProjectMetadataDiagnostic]) -> [GoFormattedDiagnostic] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var summaries: [String: String] = [:]
        var tooltips: [String: String] = [:]

        for item in items {
            let formatted = format(item)
            let key = formatted.summary
            if counts[key] == nil {
                order.append(key)
                summaries[key] = formatted.summary
                tooltips[key] = formatted.tooltip
            }
            counts[key, default: 0] += 1
        }

        return order.map { key in
            GoFormattedDiagnostic(
                id: key,
                summary: summaries[key] ?? key,
                tooltip: tooltips[key] ?? key,
                count: counts[key] ?? 1
            )
        }
    }

    private static func format(_ item: ProjectMetadataDiagnostic) -> (summary: String, tooltip: String) {
        guard let data = item.details.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let rawError = payload.err?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawError.isEmpty else {
            return (item.details, item.details)
        }

        let position = payload.pos?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var summary = position.isEmpty ? rawError : "\(position): \(rawError)"
        if rawError.localizedCaseInsensitiveContains("module lookup disabled by GOPROXY=off") {
            summary += " (Not in local Go module cache — run Go Mod Download or check GOPATH/GOMODCACHE)"
        }

        var tooltipLines = [summary]
        if let stack = payload.importStack, !stack.isEmpty {
            tooltipLines.append("Import stack: " + stack.joined(separator: " -> "))
        }
        if let query = payload.query, !query.isEmpty {
            tooltipLines.append("Query: " + query)
        }
        return (summary, tooltipLines.joined(separator: "\n"))
    }
}

/// Uses only the applied inventory, so recognition never probes a toolchain
/// or opens files while a toolbar/menu is being rendered.
enum GoManifestSelection {
    static func candidates(workspace: URL, files: [URL]) -> [URL] {
        let root = workspace.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        // Names are matched before standardizing, mirroring the Cargo
        // selection: standardizing first would resolve every file in the
        // project to find a handful of manifests.
        return files.filter { $0.lastPathComponent == "go.mod" }
            .map(\.standardizedFileURL)
            .filter { $0.path.hasPrefix(prefix) }
            .sorted {
            let left = String($0.path.dropFirst(prefix.count))
            let right = String($1.path.dropFirst(prefix.count))
            let leftDepth = left.split(separator: "/").count
            let rightDepth = right.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return left.utf8.lexicographicallyPrecedes(right.utf8)
        }
    }
}
