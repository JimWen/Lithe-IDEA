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
                    CargoProjectHeader(isBusy: model.isCargoActivating)
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
        .background(LitheTheme.editor)
        .accessibilityIdentifier("cargo-tool-window")
    }
}

private struct CargoProjectHeader: View {
    @EnvironmentObject private var model: AppModel
    let isBusy: Bool

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: "Cargo", systemImage: "shippingbox",
                                 onMinimize: { model.isCargoVisible = false }) {
                Button { model.performShortcutCommand(id: "refresh-cargo") } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .litheIconButton()
                .disabled(isBusy || !model.canRefreshCargoProject)
                .help(commandHelp("Refresh Cargo", id: "refresh-cargo"))
                .accessibilityIdentifier("cargo-refresh")
                Button { model.performShortcutCommand(id: "cancel-cargo-refresh") } label: {
                    Image(systemName: "stop.fill")
                }
                .litheIconButton()
                .disabled(!model.canCancelCargoRefresh)
                .help(commandHelp("Cancel Cargo Refresh", id: "cancel-cargo-refresh"))
                .accessibilityIdentifier("cargo-cancel")
            }
            if let selected = model.cargoManifestURL {
                Picker("Manifest", selection: Binding(
                    get: { model.cargoManifestURL ?? selected },
                    set: { model.selectCargoManifest($0) }
                )) {
                    ForEach(model.cargoManifestURLs, id: \.self) { url in
                        Text(manifestLabel(url)).tag(url)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 11))
                .disabled(isBusy || !model.canRefreshCargoProject)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .accessibilityIdentifier("cargo-manifest")
            }
        }
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
    @ObservedObject var feature: CargoProjectFeatureModel
    @ObservedObject var presentation: CargoTreePresentation

    var body: some View {
        VStack(spacing: 0) {
            CargoProjectHeader(isBusy: feature.isActive)
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
        .onReceive(feature.$snapshot) { presentation.reconcile($0) }
    }

    private func tree(_ snapshot: ProjectMetadataSnapshot) -> some View {
        List(selection: $presentation.selectedNodeID) {
            DisclosureGroup(isExpanded: $presentation.isWorkspaceExpanded) {
                ForEach(snapshot.members, id: \.id) { member in
                    memberRow(member, isDefault: snapshot.defaultMemberIDs?.contains(member.id) == true)
                }
                if snapshot.members.isEmpty { Text("No workspace members.").foregroundStyle(LitheTheme.secondaryText) }
            } label: {
                Label("Workspace", systemImage: "shippingbox")
                    .font(.system(size: 12, weight: .semibold))
            }
            .tag("workspace")
            diagnostics(snapshot.diagnostics)
        }
        .listStyle(.sidebar)
        .font(.system(size: 12))
        .accessibilityIdentifier("cargo-project-tree")
    }

    private func memberRow(_ member: ProjectMetadataMember, isDefault: Bool) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { presentation.expandedMembers.contains(member.id) },
            set: { expanded in
                if expanded { presentation.expandedMembers.insert(member.id) }
                else { presentation.expandedMembers.remove(member.id) }
            }
        )) {
            ForEach(member.targets, id: \.id) { target in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Image(systemName: target.kind == "lib" ? "books.vertical" : "doc.text")
                            .foregroundStyle(LitheTheme.secondaryText)
                        Text(target.name).lineLimit(1)
                        Spacer(minLength: 3)
                        Text(target.kind).font(.system(size: 10)).foregroundStyle(LitheTheme.tertiaryText)
                    }
                    if let source = target.sources.first {
                        Text(source.location.relativePath)
                            .font(.system(size: 10)).foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .tag("target:" + target.id)
                .help(target.sources.map { $0.location.rootID + ": " + $0.location.relativePath }.joined(separator: "\n"))
                diagnostics(target.diagnostics)
            }
            diagnostics(member.diagnostics)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "shippingbox").foregroundStyle(LitheTheme.secondaryText)
                Text(member.name).lineLimit(1)
                if isDefault {
                    Text("default").font(.system(size: 10)).foregroundStyle(LitheTheme.tertiaryText)
                }
                Spacer(minLength: 3)
                if let version = member.version {
                    Text(version).font(.system(size: 10)).foregroundStyle(LitheTheme.secondaryText)
                }
            }
        }
        .tag("member:" + member.id)
        .help(member.manifest.rootID + ": " + member.manifest.relativePath)
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
