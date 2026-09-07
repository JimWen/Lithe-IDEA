import SwiftUI
import LitheCoreContracts
import LitheExecutionModule

struct CargoToolWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let feature = model.cargoProjectFeatureIfActive {
                CargoProjectView(feature: feature, presentation: model.cargoTreePresentation)
            } else {
                VStack(spacing: 0) {
                    CargoProjectHeader(isBusy: model.isCargoActivating, presentation: nil)
                    Spacer()
                    if model.isCargoActivating {
                        ProgressView("Loading Cargo…")
                    } else {
                        Text(model.cargoActivationError ?? String(localized: "Refresh to load Cargo targets."))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                    Spacer()
                }
            }
        }
        // Cargo is a tool-window surface, not an editor canvas. Hiding the
        // system list material keeps the tree background stable and lets the
        // tool-window palette remain readable in both active and inactive
        // states.
        .litheWorkbenchSurface(LitheTheme.sidebar)
        .accessibilityIdentifier("cargo-tool-window")
    }
}

private struct CargoProjectHeader: View {
    @EnvironmentObject private var model: AppModel
    let isBusy: Bool
    /// nil in the pre-refresh empty state, where expand/collapse has no target.
    let presentation: CargoTreePresentation?

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(
                title: "Cargo",
                systemImage: "shippingbox",
                ideaAssetPath: "toolwindows/toolWindowCargo.svg",
                onMinimize: { model.isCargoVisible = false }) {
                optionsMenu
            }
            toolbarRow
        }
    }

    // GoLand keeps the chrome row to a kebab menu and the hide button; every
    // command lives in the toolbar row below it.
    private var optionsMenu: some View {
        Menu {
            Button("Refresh Cargo") {
                model.performShortcutCommand(id: "refresh-cargo")
            }
            .disabled(isBusy || !model.canRefreshCargoProject)
            Button("Cancel Refresh") {
                model.performShortcutCommand(id: "cancel-cargo-refresh")
            }
            .disabled(!model.canCancelCargoRefresh)
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
        .accessibilityIdentifier("cargo-options")
        .help("Cargo Options")
    }

    private var toolbarRow: some View {
        HStack(spacing: 9) {
            Button {
                model.performShortcutCommand(id: "refresh-cargo")
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .litheIconButton()
            .disabled(isBusy || !model.canRefreshCargoProject)
            .help(commandHelp("Refresh Cargo Projects", id: "refresh-cargo"))
            .accessibilityIdentifier("cargo-refresh")

            attachMenu

            Button {
                model.resetCargoManifestSelection()
            } label: {
                Image(systemName: "minus")
            }
            .litheIconButton()
            .disabled(isBusy || !model.canRefreshCargoProject || model.selectedCargoManifestURL == nil)
            .help("Detach Cargo Project")
            .accessibilityIdentifier("cargo-detach")

            if let presentation {
                Button {
                    presentation.expandAll()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .litheIconButton()
                .help("Expand All")
                .accessibilityLabel("Expand All")
                .accessibilityIdentifier("cargo-expand-all")

                Button {
                    presentation.collapseAll()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .litheIconButton()
                .help("Collapse All")
                .accessibilityLabel("Collapse All")
                .accessibilityIdentifier("cargo-collapse-all")
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 5)
    }

    /// GoLand's "+" attach action; Lithe's equivalent choice is the manifest.
    private var attachMenu: some View {
        Menu {
            ForEach(model.cargoManifestURLs, id: \.self) { url in
                Button {
                    model.selectCargoManifest(url)
                } label: {
                    if model.cargoManifestURL == url {
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
        .disabled(isBusy || !model.canRefreshCargoProject || model.cargoManifestURLs.isEmpty)
        .help("Attach Cargo Project")
        .accessibilityIdentifier("cargo-attach")
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

private struct CargoProjectView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: CargoProjectFeatureModel
    @ObservedObject var presentation: CargoTreePresentation

    var body: some View {
        VStack(spacing: 0) {
            CargoProjectHeader(isBusy: feature.isActive, presentation: presentation)
            if feature.state == .loading || feature.state == .stopping {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(feature.state == .stopping ? "Stopping Cargo…" : "Loading Cargo…")
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
                .accessibilityIdentifier("cargo-error")
            }
            if let snapshot = feature.snapshot {
                tree(snapshot)
            } else {
                Spacer()
                if feature.state == .idle {
                    Text("Refresh to load Cargo targets.")
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
                presentation.reconcile(snapshot, manifestDirectory: manifestDirectory)
            }
        }
    }

    /// Directory of the manifest the user attached, relative to the host
    /// workspace root. This — not the normalized workspace location, which is
    /// always the host root — anchors the root-package absorption in the tree.
    private var manifestDirectory: String? {
        guard let manifest = model.cargoManifestURL,
              let root = model.workspaceURL?.standardizedFileURL.path else { return nil }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard manifest.path.hasPrefix(prefix) else { return nil }
        let directory = (String(manifest.path.dropFirst(prefix.count)) as NSString)
            .deletingLastPathComponent
        return directory.isEmpty ? "." : directory
    }

    private func tree(_ snapshot: ProjectMetadataSnapshot) -> some View {
        let layout = CargoTreePresentation.layout(
            snapshot,
            manifestDirectory: manifestDirectory,
            workspaceName: model.workspaceURL?.lastPathComponent ?? String(localized: "Workspace")
        )
        return List(selection: $presentation.selectedNodeID) {
            // RustRover always renders the project node and lifts the root
            // package's targets into it, so a package at the workspace root
            // never gains a member row of its own.
            DisclosureGroup(isExpanded: $presentation.isProjectExpanded) {
                if let root = layout.rootMember {
                    targetsGroup(root)
                    diagnostics(root.diagnostics)
                }
                ForEach(layout.nestedMembers, id: \.id) { member in
                    memberRow(member)
                }
                if snapshot.members.isEmpty {
                    Text("No workspace members.").foregroundStyle(LitheTheme.secondaryText)
                }
            } label: {
                HStack(spacing: 7) {
                    Label(layout.projectName, systemImage: "shippingbox")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .tag("project")
            .contextMenu {
                refreshButton
            }
            diagnostics(snapshot.diagnostics)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(LitheTheme.sidebar)
        .tint(LitheTheme.accent)
        .font(.system(size: 12))
        .accessibilityIdentifier("cargo-project-tree")
    }

    private func memberRow(_ member: ProjectMetadataMember) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { presentation.expandedMembers.contains(member.id) },
            set: { expanded in
                if expanded { presentation.expandedMembers.insert(member.id) }
                else { presentation.expandedMembers.remove(member.id) }
            }
        )) {
            targetsGroup(member)
            diagnostics(member.diagnostics)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "shippingbox").foregroundStyle(LitheTheme.secondaryText)
                Text(member.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .tag("member:" + member.id)
        .help(member.manifest.rootID + ": " + member.manifest.relativePath)
        .contextMenu {
            Button("Open Cargo.toml") { openManifest(member) }
                .disabled(model.cargoFileURL(for: member.manifest) == nil)
            refreshButton
        }
    }

    /// The group row every member owns, rendered either under a member row or
    /// directly under the project node for the root package.
    private func targetsGroup(_ member: ProjectMetadataMember) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { presentation.expandedTargetGroups.contains(member.id) },
            set: { expanded in
                if expanded { presentation.expandedTargetGroups.insert(member.id) }
                else { presentation.expandedTargetGroups.remove(member.id) }
            }
        )) {
            ForEach(member.targets, id: \.id) { target in
                targetRow(target, member: member)
            }
        } label: {
            HStack(spacing: 7) {
                Label("Targets", systemImage: "gearshape")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .tag("targets:" + member.id)
    }

    private func targetRow(
        _ target: ProjectMetadataTarget,
        member: ProjectMetadataMember
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: target.kind == "lib" ? "books.vertical" : "doc.text")
                .foregroundStyle(LitheTheme.secondaryText)
            Text(target.name).lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .tag("target:" + target.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(target.name)
        .accessibilityValue(target.kind == "bin" ? "Binary target" : "\(target.kind) target")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activateTarget(target, member: member) }
        .help(sourceHelp(target))
        // The plain row keeps List's single-click selection, and a count-2 tap
        // on that same row is the double-click that has been verified to reach
        // this handler; wrapping the row in a Button swallows the gesture.
        .onTapGesture(count: 2) { activateTarget(target, member: member) }
        .contextMenu {
            if CargoTreePresentation.cargoBinaryConfigurationID(
                memberDirectory: member.directory.relativePath, target: target
            ) != nil {
                Button("Run \(target.name)") { activateTarget(target, member: member) }
            }
            Button("Go to Source") { openSource(target) }
                .disabled(target.sources.first.map { model.cargoFileURL(for: $0.location) } == nil)
        }
    }

    private var refreshButton: some View {
        Button("Refresh Cargo") {
            model.performShortcutCommand(id: "refresh-cargo")
        }
        .disabled(model.isCargoActivating || !model.canRefreshCargoProject)
    }

    private func openSource(_ target: ProjectMetadataTarget) {
        guard let source = target.sources.first,
              let url = model.cargoFileURL(for: source.location) else { return }
        model.openFile(url)
    }

    private func openManifest(_ member: ProjectMetadataMember) {
        guard let url = model.cargoFileURL(for: member.manifest) else { return }
        model.openFile(url)
    }

    /// RustRover's double-click either launches the target or does nothing; it
    /// never navigates. A kind that has no generated run configuration — a
    /// library, test, bench, example or build script — stays inert here, and
    /// "Go to Source" in the context menu remains the way to open it.
    ///
    /// Only the metadata is inspected here. Whether the configuration exists is
    /// decided by the model after the execution module is awake, because that
    /// answer is not available synchronously during a click.
    private func activateTarget(_ target: ProjectMetadataTarget, member: ProjectMetadataMember) {
        guard let id = CargoTreePresentation.cargoBinaryConfigurationID(
            memberDirectory: member.directory.relativePath, target: target
        ) else { return }
        model.startCargoTarget(configurationID: id, name: target.name)
    }

    private func sourceHelp(_ target: ProjectMetadataTarget) -> String {
        target.sources.map { $0.location.rootID + ": " + $0.location.relativePath }.joined(separator: "\n")
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
