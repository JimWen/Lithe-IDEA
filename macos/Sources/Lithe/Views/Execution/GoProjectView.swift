import SwiftUI
import LitheCoreContracts
import LitheExecutionModule

struct GoToolWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let feature = model.goProjectFeatureIfActive {
                GoProjectView(feature: feature, presentation: model.goTreePresentation)
            } else {
                VStack(spacing: 0) {
                    GoProjectHeader(isBusy: model.isGoActivating, presentation: nil)
                    Spacer()
                    if model.isGoActivating {
                        ProgressView("Loading Go…")
                    } else {
                        Text(model.goActivationError ?? String(localized: "Refresh to load Go modules."))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                    Spacer()
                }
            }
        }
        // Go Tools is a tool-window surface, not an editor canvas. Hiding the
        // system list material keeps the tree background stable and lets the
        // tool-window palette remain readable in both active and inactive
        // states.
        .litheWorkbenchSurface(LitheTheme.sidebar)
        .accessibilityIdentifier("go-tool-window")
    }
}

private struct GoProjectHeader: View {
    @EnvironmentObject private var model: AppModel
    let isBusy: Bool
    /// nil in the pre-refresh empty state, where expand/collapse has no target.
    let presentation: GoTreePresentation?

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(
                title: "Go Tools",
                systemImage: "chevron.left.forwardslash.chevron.right",
                ideaAssetPath: "toolwindows/toolWindowGo.svg",
                onMinimize: { model.isGoVisible = false }) {
                optionsMenu
            }
            toolbarRow
        }
    }

    // GoLand keeps the chrome row to a kebab menu and the hide button; every
    // command lives in the toolbar row below it.
    private var optionsMenu: some View {
        Menu {
            Button("Refresh Go") {
                model.performShortcutCommand(id: "refresh-go")
            }
            .disabled(isBusy || !model.canRefreshGoProject)
            Button("Cancel Refresh") {
                model.performShortcutCommand(id: "cancel-go-refresh")
            }
            .disabled(!model.canCancelGoRefresh)
            if let presentation {
                Divider()
                Button("Expand All") { presentation.expandAll() }
                Button("Collapse All") { presentation.collapseAll() }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .litheIconButton()
        .accessibilityIdentifier("go-options")
        .help("Go Tools Options")
    }

    private var toolbarRow: some View {
        HStack(spacing: 9) {
            Button {
                model.performShortcutCommand(id: "refresh-go")
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .litheIconButton()
            .disabled(isBusy || !model.canRefreshGoProject)
            .help(commandHelp("Refresh Go Projects", id: "refresh-go"))
            .accessibilityIdentifier("go-refresh")

            attachMenu

            Button {
                model.resetGoManifestSelection()
            } label: {
                Image(systemName: "minus")
            }
            .litheIconButton()
            .disabled(isBusy || !model.canRefreshGoProject || model.selectedGoManifestURL == nil)
            .help("Detach Go Project")
            .accessibilityIdentifier("go-detach")

            if let presentation {
                Button {
                    presentation.expandAll()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .litheIconButton()
                .help("Expand All")
                .accessibilityLabel("Expand All")
                .accessibilityIdentifier("go-expand-all")

                Button {
                    presentation.collapseAll()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .litheIconButton()
                .help("Collapse All")
                .accessibilityLabel("Collapse All")
                .accessibilityIdentifier("go-collapse-all")
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 5)
    }

    /// GoLand's "+" attach action; Lithe's equivalent choice is the module.
    private var attachMenu: some View {
        Menu {
            ForEach(model.goManifestURLs, id: \.self) { url in
                Button {
                    model.selectGoManifest(url)
                } label: {
                    if model.goManifestURL == url {
                        Label(manifestLabel(url), systemImage: "checkmark")
                    } else {
                        Text(manifestLabel(url))
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .litheIconButton()
        .disabled(isBusy || !model.canRefreshGoProject || model.goManifestURLs.isEmpty)
        .help("Attach Go Project")
        .accessibilityIdentifier("go-attach")
    }

    private func manifestLabel(_ url: URL) -> String {
        guard let root = model.workspaceURL?.standardizedFileURL.path else { return url.lastPathComponent }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private func commandHelp(_ title: String, id: String) -> Text {
        let title = Text(LocalizedStringKey(title))
        guard let binding = model.keyboardShortcutFeature.displayText(for: id) else { return title }
        return title + Text(" (\(binding))")
    }
}

private struct GoProjectView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: GoProjectFeatureModel
    @ObservedObject var presentation: GoTreePresentation

    var body: some View {
        VStack(spacing: 0) {
            GoProjectHeader(isBusy: feature.isActive, presentation: presentation)
            if feature.state == .loading || feature.state == .stopping {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(feature.state == .stopping ? "Stopping Go…" : "Loading Go…")
                    Spacer()
                }
                .font(.system(size: 11))
                .padding(10)
            }
            if let error = feature.errorMessage {
                ScrollView {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.error)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 110)
                .accessibilityIdentifier("go-error")
            }
            if let cleanup = feature.cleanupDiagnostic {
                ScrollView {
                    Text(cleanup)
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 70)
                .accessibilityIdentifier("go-cleanup")
            }
            if let snapshot = feature.snapshot {
                tree(snapshot)
            } else {
                Spacer()
                if feature.state == .idle {
                    Text("Refresh to load Go modules.")
                        .font(.system(size: 12))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
            }
        }
        .onReceive(feature.$snapshot) { snapshot in
            // Published changes can arrive while SwiftUI is reconciling the
            // view tree. Defer the presentation update by one main-actor turn
            // so reconciliation cannot publish from inside a view update.
            Task { @MainActor in
                await Task.yield()
                presentation.reconcile(snapshot)
            }
        }
    }

    private func tree(_ snapshot: ProjectMetadataSnapshot) -> some View {
        let layout = GoTreePresentation.layout(
            snapshot,
            workspaceName: model.workspaceURL?.lastPathComponent ?? String(localized: "Workspace")
        )
        return List(selection: $presentation.selectedNodeID) {
            // GoLand never hides the top level: every module renders its own
            // row, including a workspace with a single module.
            DisclosureGroup(isExpanded: $presentation.isProjectExpanded) {
                if layout.modules.isEmpty {
                    Text("No Go modules.").foregroundStyle(LitheTheme.secondaryText)
                }
                ForEach(layout.modules, id: \.id) { member in
                    moduleRow(member)
                }
            } label: {
                HStack(spacing: 7) {
                    Label(layout.workspaceName, systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .contextMenu { refreshButton }
            }
            .tag("project")
            diagnostics(snapshot.diagnostics)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(LitheTheme.sidebar)
        .tint(LitheTheme.accent)
        .font(.system(size: 12))
        .accessibilityIdentifier("go-project-tree")
    }

    private func moduleRow(_ member: ProjectMetadataMember) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { presentation.expandedModules.contains(member.id) },
            set: { expanded in
                if expanded { presentation.expandedModules.insert(member.id) }
                else { presentation.expandedModules.remove(member.id) }
            }
        )) {
            ForEach(GoTreePresentation.packages(of: member), id: \.id) { target in
                packageRow(target, member: member)
            }
            diagnostics(member.diagnostics)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(member.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            // A menu on the DisclosureGroup itself also covers descendant rows.
            .contextMenu {
                Button("Open go.mod") { openManifest(member) }
                    .disabled(model.goFileURL(for: member.manifest) == nil)
                if let location = moduleDirectory(member) { GoToolActionsMenu(location: location, includesModuleActions: true) }
                refreshButton
            }
        }
        .tag("module:" + member.id)
        .help(member.manifest.rootID + ": " + member.manifest.relativePath)
    }

    private func packageRow(
        _ target: ProjectMetadataTarget,
        member: ProjectMetadataMember
    ) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { presentation.expandedPackages.contains(target.id) },
            set: { expanded in
                if expanded { presentation.expandedPackages.insert(target.id) }
                else { presentation.expandedPackages.remove(target.id) }
            }
        )) {
            targetsGroup(target, member: member)
            diagnostics(target.diagnostics)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "shippingbox").foregroundStyle(LitheTheme.secondaryText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.name).lineLimit(1)
                    if let importPath = target.importPath, importPath != target.name {
                        Text(importPath)
                            .font(.system(size: 10))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            // A menu on the DisclosureGroup itself also covers descendant rows.
            .contextMenu {
                GoToolActionsMenu(location: target.directory, includesModuleActions: false)
                Button("Go to Source") { openSource(target) }
                    .disabled(target.sources.first.map { model.goFileURL(for: $0.location) } == nil)
                Button("Open go.mod") { openManifest(member) }
                    .disabled(model.goFileURL(for: member.manifest) == nil)
                refreshButton
            }
        }
        .tag("package:" + target.id)
        .help(target.directory.rootID + ": " + target.directory.relativePath)
    }

    /// The group row a package owns, rendered only when the package has
    /// runnable entries; a plain library shows nothing to launch.
    private func targetsGroup(
        _ target: ProjectMetadataTarget,
        member: ProjectMetadataMember
    ) -> some View {
        let entries = GoTreePresentation.entries(for: target)
        return Group {
            if !entries.isEmpty {
                DisclosureGroup(isExpanded: Binding(
                    get: { presentation.expandedTargetGroups.contains(target.id) },
                    set: { expanded in
                        if expanded { presentation.expandedTargetGroups.insert(target.id) }
                        else { presentation.expandedTargetGroups.remove(target.id) }
                    }
                )) {
                    ForEach(entries, id: \.id) { entry in
                        entryRow(entry, target: target, member: member)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Label("Targets", systemImage: "gearshape")
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .tag("targets:" + target.id)
            }
        }
    }

    private func entryRow(
        _ entry: GoTargetEntry,
        target: ProjectMetadataTarget,
        member: ProjectMetadataMember
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: entry.kind == .application ? "play.circle" : "checkmark.circle")
                .foregroundStyle(LitheTheme.secondaryText)
            Text(entry.name).lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .tag("entry:" + entry.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.name)
        .accessibilityValue(entry.kind == .application ? "Application entry" : "Test entry")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activateEntry(entry, target: target, member: member) }
        .help(target.directory.rootID + ": " + target.directory.relativePath)
        // The plain row keeps List's single-click selection, and a count-2 tap
        // on that same row is the double-click that has been verified to reach
        // this handler; wrapping the row in a Button swallows the gesture.
        .onTapGesture(count: 2) { activateEntry(entry, target: target, member: member) }
        .contextMenu {
            Button(entry.kind == .application ? "Run \(entry.name)" : "Run Tests") {
                activateEntry(entry, target: target, member: member)
            }
            if entry.kind == .application,
               let configurationID = GoTreePresentation.goMainConfigurationID(
                   member: member, target: target,
                   workspaceName: model.workspaceURL?.lastPathComponent ?? "Workspace"
               ) {
                Button("Debug \(entry.name)") {
                    model.debugGoTarget(configurationID: configurationID, name: entry.name)
                }
                Button("Modify Run Configuration…") {
                    model.showRunConfigurationEditor()
                }
            }
            Button("Go to Source") { openSource(target) }
                .disabled(target.sources.first.map { model.goFileURL(for: $0.location) } == nil)
        }
    }

    private var refreshButton: some View {
        Button("Refresh Go") {
            model.performShortcutCommand(id: "refresh-go")
        }
        .disabled(model.isGoActivating || !model.canRefreshGoProject)
    }

    private func openSource(_ target: ProjectMetadataTarget) {
        guard let source = target.sources.first,
              let url = model.goFileURL(for: source.location) else { return }
        model.openFile(url)
    }

    private func openManifest(_ member: ProjectMetadataMember) {
        guard let url = model.goFileURL(for: member.manifest) else { return }
        model.openFile(url)
    }

    /// Applications retain the ordinary Run flow; test targets use an
    /// independent package tool task and do not replace another running job.
    private func activateEntry(
        _ entry: GoTargetEntry,
        target: ProjectMetadataTarget,
        member: ProjectMetadataMember
    ) {
        if entry.kind == .test {
            model.startGoTool(.test, location: target.directory)
            return
        }
        guard entry.kind == .application,
              let id = GoTreePresentation.goMainConfigurationID(
            member: member, target: target,
            workspaceName: model.workspaceURL?.lastPathComponent ?? "Workspace"
        ) else { return }
        model.startGoTarget(configurationID: id, name: entry.name)
    }

    private func moduleDirectory(_ member: ProjectMetadataMember) -> ProjectMetadataLocation? {
        guard member.manifest.rootID == "workspace" else { return nil }
        let components = member.manifest.relativePath.split(separator: "/").dropLast()
        return ProjectMetadataLocation(rootID: "workspace", relativePath: components.isEmpty ? "." : components.joined(separator: "/"))
    }

    private func diagnostics(_ items: [ProjectMetadataDiagnostic]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            Label(item.details, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.error)
                .textSelection(.enabled)
        }
    }
}
