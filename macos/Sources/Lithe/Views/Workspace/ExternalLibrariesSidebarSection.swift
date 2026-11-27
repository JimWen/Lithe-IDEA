import AppKit
import SwiftUI

/// JetBrains-aligned "External Libraries" root rendered beneath the workspace folder tree
/// in the Project sidebar. Directories expand lazily on demand and open files read-only
/// so large `GOMODCACHE`, Cargo registries, or Python `site-packages` trees never impact
/// cold-start memory or startup latency.
struct ExternalLibrariesSidebarSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let availableWidth: CGFloat
    let rowHeight: CGFloat

    @State private var isRootExpanded = false
    @State private var expandedGroupIDs: Set<String> = []
    @State private var expandedDirectoryPaths: Set<String> = []
    @State private var cachedChildrenByPath: [String: [ExternalLibraryFileEntry]] = [:]
    @State private var loadingPaths: Set<String> = []

    private var usesChinese: Bool { settings.language == .simplifiedChinese }
    private var snapshot: ProjectEnvironmentSnapshot { model.projectEnvironmentSnapshot }

    private var hasAnyLibraries: Bool {
        !snapshot.isEmpty
    }

    var body: some View {
        if hasAnyLibraries {
            VStack(alignment: .leading, spacing: LitheTheme.Metrics.projectTreeRowSpacing) {
                Divider()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)

                rootRow

                if isRootExpanded {
                    if let go = snapshot.go {
                        goSection(go)
                    }
                    if let rust = snapshot.rust {
                        rustSection(rust)
                    }
                    if let python = snapshot.python {
                        pythonSection(python)
                    }
                }
            }
            .onChange(of: model.workspaceURL) { _ in
                isRootExpanded = false
                expandedGroupIDs.removeAll()
                expandedDirectoryPaths.removeAll()
                cachedChildrenByPath.removeAll()
                loadingPaths.removeAll()
            }
            .accessibilityIdentifier("external-libraries-section")
        }
    }

    private var rootRow: some View {
        treeRow(
            depth: 0,
            isExpanded: isRootExpanded,
            showChevron: true,
            icon: "books.vertical",
            iconColor: LitheTheme.secondaryText,
            title: usesChinese ? "外部库 (External Libraries)" : "External Libraries",
            subtitle: libraryCountBadge,
            isBold: true
        ) {
            isRootExpanded.toggle()
        }
        .litheContextMenu {
            var items: [LitheContextMenuItem] = [
                .action(usesChinese ? "刷新外部库" : "Refresh External Libraries", systemImage: "arrow.clockwise") {
                    refreshLibrariesAndReloadExpanded()
                }
            ]
            if snapshot.go != nil {
                items.append(.action(usesChinese ? "配置 Go 环境…" : "Configure Go…", systemImage: "gearshape") {
                    model.showSettings(category: .go)
                })
            }
            if snapshot.rust != nil {
                items.append(.action(usesChinese ? "配置 Rust 环境…" : "Configure Rust…", systemImage: "gearshape") {
                    model.showSettings(category: .rust)
                })
            }
            if snapshot.python != nil {
                items.append(.action(usesChinese ? "配置 Python 环境…" : "Configure Python…", systemImage: "gearshape") {
                    model.showSettings(category: .python)
                })
            }
            return items
        }
    }

    private var libraryCountBadge: String? {
        var parts: [String] = []
        if let go = snapshot.go {
            parts.append(go.version ?? "Go")
        }
        if let rust = snapshot.rust {
            parts.append(rust.activeToolchain ?? "Rust")
        }
        if let py = snapshot.python {
            parts.append(py.version.map { "Python \($0)" } ?? "Python")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Go Libraries (Go SDK + Go Modules)

    @ViewBuilder
    private func goSection(_ go: GoProjectEnvironmentSnapshot) -> some View {
        if let stdLibURL = go.stdLibURL {
            let label = go.version.map { "Go SDK \($0)" } ?? "Go SDK"
            externalDirectoryNode(
                url: stdLibURL,
                title: label,
                subtitle: go.goRoot,
                icon: "chevron.left.forwardslash.chevron.right",
                depth: 1,
                displayPrefix: label
            )
        }

        let modulesGroupID = "go:modules"
        let isModulesExpanded = expandedGroupIDs.contains(modulesGroupID)
        let moduleTitle = go.moduleName.map { "Go Modules (\($0))" } ?? "Go Modules"
        treeRow(
            depth: 1,
            isExpanded: isModulesExpanded,
            showChevron: !go.dependencies.isEmpty,
            icon: "shippingbox",
            iconColor: LitheTheme.accent,
            title: moduleTitle,
            subtitle: go.dependencies.isEmpty
                ? (usesChinese ? "无外部依赖" : "No dependencies")
                : "\(go.directDependencies.count) direct / \(go.dependencies.count) total"
        ) {
            toggleGroup(modulesGroupID)
        }
        .litheContextMenu {
            var items: [LitheContextMenuItem] = []
            if let manifestURL = go.manifestURL {
                items.append(.action(usesChinese ? "打开 go.mod" : "Open go.mod", systemImage: "doc.text") {
                    model.openFile(manifestURL)
                })
            }
            if let modCache = go.goModCache {
                items.append(.action(usesChinese ? "在 Finder 中显示 GOMODCACHE" : "Reveal GOMODCACHE in Finder", systemImage: "folder") {
                    model.revealProjectItemInFinder(URL(fileURLWithPath: modCache))
                })
                items.append(.action(usesChinese ? "复制 GOMODCACHE 路径" : "Copy GOMODCACHE Path", systemImage: "doc.on.doc") {
                    copyToPasteboard(modCache)
                })
            }
            if !items.isEmpty { items.append(.separator) }
            items.append(.action(usesChinese ? "配置 Go 环境…" : "Configure Go…", systemImage: "gearshape") {
                model.showSettings(category: .go)
            })
            items.append(.action(usesChinese ? "刷新外部库" : "Refresh External Libraries", systemImage: "arrow.clockwise") {
                refreshLibrariesAndReloadExpanded()
            })
            return items
        }

        if isModulesExpanded {
            ForEach(go.directDependencies) { dep in
                dependencyRow(dep, depth: 2)
            }
            if !go.indirectDependencies.isEmpty {
                let indirectGroupID = "go:modules:indirect"
                let isIndirectExpanded = expandedGroupIDs.contains(indirectGroupID)
                treeRow(
                    depth: 2,
                    isExpanded: isIndirectExpanded,
                    showChevron: true,
                    icon: "tray.2",
                    iconColor: LitheTheme.tertiaryText,
                    title: usesChinese
                        ? "间接依赖 (\(go.indirectDependencies.count))"
                        : "Indirect Dependencies (\(go.indirectDependencies.count))",
                    subtitle: nil
                ) {
                    toggleGroup(indirectGroupID)
                }
                if isIndirectExpanded {
                    ForEach(go.indirectDependencies) { dep in
                        dependencyRow(dep, depth: 3)
                    }
                }
            }
        }
    }

    // MARK: - Rust Libraries (Rust stdlib + Cargo Dependencies)

    @ViewBuilder
    private func rustSection(_ rust: RustProjectEnvironmentSnapshot) -> some View {
        if let stdLibURL = rust.stdLibURL {
            let label = rust.activeToolchain.map { "Rust stdlib (\($0))" } ?? "Rust stdlib"
            externalDirectoryNode(
                url: stdLibURL,
                title: label,
                subtitle: rust.sysrootPath,
                icon: "books.vertical",
                depth: 1,
                displayPrefix: label
            )
        }

        let cargoGroupID = "rust:cargo"
        let isCargoExpanded = expandedGroupIDs.contains(cargoGroupID)
        let title = rust.crateName.map { "Cargo (\($0))" } ?? "Cargo Dependencies"
        treeRow(
            depth: 1,
            isExpanded: isCargoExpanded,
            showChevron: !rust.dependencies.isEmpty,
            icon: "shippingbox",
            iconColor: LitheTheme.accent,
            title: title,
            subtitle: rust.dependencies.isEmpty
                ? (usesChinese ? "无外部依赖" : "No dependencies")
                : "\(rust.dependencies.count) crates"
        ) {
            toggleGroup(cargoGroupID)
        }
        .litheContextMenu {
            var items: [LitheContextMenuItem] = []
            if let manifestURL = rust.manifestURL {
                items.append(.action(usesChinese ? "打开 Cargo.toml" : "Open Cargo.toml", systemImage: "doc.text") {
                    model.openFile(manifestURL)
                })
            }
            if let cargoHome = rust.cargoHome {
                items.append(.action(usesChinese ? "在 Finder 中显示 CARGO_HOME" : "Reveal CARGO_HOME in Finder", systemImage: "folder") {
                    model.revealProjectItemInFinder(URL(fileURLWithPath: cargoHome))
                })
            }
            if !items.isEmpty { items.append(.separator) }
            items.append(.action(usesChinese ? "配置 Rust 环境…" : "Configure Rust…", systemImage: "gearshape") {
                model.showSettings(category: .rust)
            })
            return items
        }

        if isCargoExpanded {
            ForEach(rust.dependencies) { dep in
                dependencyRow(dep, depth: 2)
            }
        }
    }

    // MARK: - Python Libraries (stdlib + site-packages)

    @ViewBuilder
    private func pythonSection(_ python: PythonProjectEnvironmentSnapshot) -> some View {
        let pyGroupID = "python:env"
        let isPyExpanded = expandedGroupIDs.contains(pyGroupID)
        let pyTitle: String = {
            let base = python.version.map { "Python \($0)" } ?? "Python"
            if let venv = python.virtualEnvName { return "\(base) (\(venv))" }
            return base
        }()
        treeRow(
            depth: 1,
            isExpanded: isPyExpanded,
            showChevron: python.stdLibURL != nil || !python.sitePackagesURLs.isEmpty || !python.dependencies.isEmpty,
            icon: "terminal",
            iconColor: LitheTheme.accent,
            title: pyTitle,
            subtitle: python.isVirtualEnvironment ? "venv" : nil
        ) {
            toggleGroup(pyGroupID)
        }
        .litheContextMenu {
            var items: [LitheContextMenuItem] = []
            if let manifestURL = python.manifestURL {
                items.append(.action(usesChinese ? "打开依赖清单" : "Open Manifest", systemImage: "doc.text") {
                    model.openFile(manifestURL)
                })
            }
            if let prefix = python.prefixPath {
                items.append(.action(usesChinese ? "在 Finder 中显示环境目录" : "Reveal Environment in Finder", systemImage: "folder") {
                    model.revealProjectItemInFinder(URL(fileURLWithPath: prefix))
                })
            }
            if !items.isEmpty { items.append(.separator) }
            items.append(.action(usesChinese ? "配置 Python 环境…" : "Configure Python…", systemImage: "gearshape") {
                model.showSettings(category: .python)
            })
            return items
        }

        if isPyExpanded {
            if !python.dependencies.isEmpty {
                let depsID = "python:declared"
                let isDepsExpanded = expandedGroupIDs.contains(depsID)
                treeRow(
                    depth: 2,
                    isExpanded: isDepsExpanded,
                    showChevron: true,
                    icon: "shippingbox",
                    iconColor: LitheTheme.secondaryText,
                    title: usesChinese
                        ? "声明依赖 (\(python.dependencies.count))"
                        : "Declared Dependencies (\(python.dependencies.count))",
                    subtitle: nil
                ) {
                    toggleGroup(depsID)
                }
                if isDepsExpanded {
                    ForEach(python.dependencies) { dep in
                        dependencyRow(dep, depth: 3)
                    }
                }
            }
            if let stdLibURL = python.stdLibURL {
                externalDirectoryNode(
                    url: stdLibURL,
                    title: "stdlib",
                    subtitle: stdLibURL.path,
                    icon: "books.vertical",
                    depth: 2,
                    displayPrefix: "Python stdlib"
                )
            }
            ForEach(python.sitePackagesURLs, id: \.self) { spURL in
                externalDirectoryNode(
                    url: spURL,
                    title: "site-packages",
                    subtitle: spURL.path,
                    icon: "shippingbox",
                    depth: 2,
                    displayPrefix: "site-packages"
                )
            }
        }
    }

    // MARK: - Dependency & Lazy Directory Rows

    @ViewBuilder
    private func dependencyRow(_ dep: ProjectDependencyItem, depth: Int) -> some View {
        if let dirURL = dep.sourceDirectoryURL {
            externalDirectoryNode(
                url: dirURL,
                title: dep.name,
                subtitle: dep.displaySubtitle,
                icon: dep.isDirect ? "shippingbox" : "shippingbox.fill",
                depth: depth,
                displayPrefix: "\(dep.name)@\(dep.version)",
                manifestURL: dep.manifestURL
            )
        } else {
            treeRow(
                depth: depth,
                isExpanded: false,
                showChevron: false,
                icon: "shippingbox",
                iconColor: LitheTheme.tertiaryText,
                title: dep.name,
                subtitle: dep.displaySubtitle.isEmpty
                    ? (usesChinese ? "未缓存" : "Not cached")
                    : "\(dep.displaySubtitle) · \(usesChinese ? "未缓存" : "not cached")"
            ) {
                if let manifestURL = dep.manifestURL {
                    model.openFile(manifestURL)
                }
            }
            .litheContextMenu {
                var items: [LitheContextMenuItem] = []
                if let manifestURL = dep.manifestURL {
                    items.append(.action(usesChinese ? "打开清单文件" : "Open Manifest", systemImage: "doc.text") {
                        model.openFile(manifestURL)
                    })
                }
                items.append(.action(usesChinese ? "复制模块名称" : "Copy Module Name", systemImage: "doc.on.doc") {
                    copyToPasteboard("\(dep.name) \(dep.version)".trimmingCharacters(in: .whitespaces))
                })
                return items
            }
        }
    }

    private func externalDirectoryNode(
        url: URL,
        title: String,
        subtitle: String?,
        icon: String,
        depth: Int,
        displayPrefix: String,
        manifestURL: URL? = nil
    ) -> AnyView {
        let path = url.standardizedFileURL.path
        let isExpanded = expandedDirectoryPaths.contains(path)
        let isLoading = loadingPaths.contains(path)
        let children = cachedChildrenByPath[path] ?? []

        return AnyView(
            VStack(alignment: .leading, spacing: LitheTheme.Metrics.projectTreeRowSpacing) {
                treeRow(
                    depth: depth,
                    isExpanded: isExpanded,
                    showChevron: true,
                    icon: icon,
                    iconColor: LitheTheme.secondaryText,
                    title: title,
                    subtitle: isLoading ? (usesChinese ? "加载中…" : "Loading…") : subtitle
                ) {
                    toggleDirectory(url)
                }
                .help(path)
                .litheContextMenu {
                    var items: [LitheContextMenuItem] = []
                    if let manifestURL {
                        items.append(.action(usesChinese ? "打开清单文件" : "Open Manifest", systemImage: "doc.text") {
                            model.openFile(manifestURL)
                        })
                    }
                    items.append(.action(usesChinese ? "在 Finder 中显示" : "Reveal in Finder", systemImage: "folder") {
                        model.revealProjectItemInFinder(url)
                    })
                    items.append(.action(usesChinese ? "复制路径" : "Copy Path", systemImage: "doc.on.doc") {
                        copyToPasteboard(path)
                    })
                    return items
                }

                if isExpanded {
                    ForEach(children) { entry in
                        if entry.isDirectory {
                            externalDirectoryNode(
                                url: entry.url,
                                title: entry.name,
                                subtitle: nil,
                                icon: "folder",
                                depth: depth + 1,
                                displayPrefix: "\(displayPrefix)/\(entry.name)"
                            )
                        } else {
                            let isActive = model.activeDocument?.url.standardizedFileURL == entry.url.standardizedFileURL
                            treeRow(
                                depth: depth + 1,
                                isExpanded: false,
                                showChevron: false,
                                icon: "doc.text",
                                iconColor: isActive ? LitheTheme.accent : LitheTheme.secondaryText,
                                title: entry.name,
                                subtitle: nil,
                                isSelected: isActive
                            ) {
                                model.openExternalLibraryFile(entry.url, displayPrefix: displayPrefix)
                            }
                            .help("\(entry.url.path) (\(usesChinese ? "只读" : "Read-only"))")
                            .litheContextMenu {
                                [
                                    .action(usesChinese ? "以只读方式打开" : "Open Read-Only", systemImage: "doc.text") {
                                        model.openExternalLibraryFile(entry.url, displayPrefix: displayPrefix)
                                    },
                                    .action(usesChinese ? "在 Finder 中显示" : "Reveal in Finder", systemImage: "folder") {
                                        model.revealProjectItemInFinder(entry.url)
                                    },
                                    .action(usesChinese ? "复制路径" : "Copy Path", systemImage: "doc.on.doc") {
                                        copyToPasteboard(entry.url.path)
                                    }
                                ]
                            }
                        }
                    }
                }
            }
        )
    }

    private func treeRow(
        depth: Int,
        isExpanded: Bool,
        showChevron: Bool,
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String?,
        isBold: Bool = false,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let indent = CGFloat(depth * 14 + 8)
        let minWidth = max(availableWidth - (LitheTheme.Metrics.projectTreeContentHorizontalInset * 2), indent + 180)
        return Button(action: action) {
            HStack(spacing: 5) {
                if showChevron {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .frame(width: 11)
                } else {
                    Spacer().frame(width: 11)
                }
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .foregroundStyle(iconColor)
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 12, weight: isBold ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : LitheTheme.primaryText)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : LitheTheme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
            }
            .padding(.leading, indent)
            .padding(.trailing, 8)
            .frame(minWidth: minWidth, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
            .background(isSelected ? LitheTheme.settingsSelection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(LitheTreeRowButtonStyle())
        .padding(.horizontal, LitheTheme.Metrics.projectTreeContentHorizontalInset)
    }

    private func toggleGroup(_ id: String) {
        if expandedGroupIDs.contains(id) {
            expandedGroupIDs.remove(id)
        } else {
            expandedGroupIDs.insert(id)
        }
    }

    private func toggleDirectory(_ url: URL) {
        let path = url.standardizedFileURL.path
        if expandedDirectoryPaths.contains(path) {
            expandedDirectoryPaths.remove(path)
            return
        }
        expandedDirectoryPaths.insert(path)
        guard cachedChildrenByPath[path] == nil, !loadingPaths.contains(path) else { return }
        loadingPaths.insert(path)
        Task { @MainActor in
            let entries = await model.externalLibraryEntries(at: url)
            cachedChildrenByPath[path] = entries
            loadingPaths.remove(path)
        }
    }

    private func refreshLibrariesAndReloadExpanded() {
        let pathsToReload = Array(expandedDirectoryPaths)
        cachedChildrenByPath.removeAll()
        loadingPaths.formUnion(pathsToReload)
        _ = model.refreshProjectEnvironmentSnapshot()
        for path in pathsToReload {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            Task { @MainActor in
                let entries = await model.externalLibraryEntries(at: url)
                if expandedDirectoryPaths.contains(path) {
                    cachedChildrenByPath[path] = entries
                }
                loadingPaths.remove(path)
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
