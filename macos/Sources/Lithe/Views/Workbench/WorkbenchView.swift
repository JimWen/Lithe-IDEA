import AppKit
import SwiftUI
import LitheGitModule

enum WorkbenchLayoutMetrics {
    static let rightActivityBarWidth: CGFloat = 40
    static let minimumDockedToolWidth: CGFloat = 240
    static let minimumWorkspaceContentWidth: CGFloat = 640

    static func dockedToolWidth(availableWidth: CGFloat, preferredWidth: CGFloat) -> CGFloat {
        let budget = max(0, availableWidth - ActivityBarMetrics.width
            - rightActivityBarWidth - minimumWorkspaceContentWidth)
        return min(budget, max(minimumDockedToolWidth, preferredWidth))
    }
}

private enum ActivityBarMetrics {
    static let width: CGFloat = 40
    static let rightWidth = WorkbenchLayoutMetrics.rightActivityBarWidth
    static let buttonWidth: CGFloat = 30
    static let buttonHeight: CGFloat = 30
    static let spacing: CGFloat = 10
    static let edgeInset: CGFloat = 5
    static let toolViewportHeight: CGFloat = 320
}

private enum WorkbenchWorkspaceMetrics {
    static let paneInset: CGFloat = 0
    static let paneSpacing: CGFloat = 1
    static let paneCornerRadius: CGFloat = 10
}

struct WorkbenchView: View {
    private let moduleUIRegistry = WorkbenchModuleUIComposition.builtIn
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updateChecker: UpdateChecker
    @EnvironmentObject private var projectSessions: ProjectSessionManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarWidth: CGFloat = 320
    @State private var rightSidebarWidth: CGFloat = 380
    @State private var topPaneHeight: CGFloat?
    @State private var isBranchSwitcherPresented = false
    @State private var isCheckoutRevisionPresented = false
    @State private var pendingTopBarDeleteReference: GitReference?
    @State private var isProjectSwitcherPresented = false
    @State private var isPluginPanelPresented = false
    @State private var isNotificationCenterPresented = false
    @State private var didRestoreLayout = false
    @State private var hoveredProjectTabID: UUID?
    @State private var workbenchBackgroundImage: NSImage?
    @State private var isBackgroundPickerPresented = false
    @State private var isRunConfigurationPickerPresented = false

    var body: some View {
        let _ = LitheSignpost.bodyEvaluated("WorkbenchView")
        VStack(spacing: 0) {
            if projectSessions.openProjects.count > 1 {
                projectTabBar
            }

            GeometryReader { geometry in
                // Keep the project tree and editor usable at the minimum window
                // width, while preserving the preferred tool width on larger windows.
                let panelWidth = WorkbenchLayoutMetrics.dockedToolWidth(
                    availableWidth: geometry.size.width, preferredWidth: rightSidebarWidth)
                HStack(spacing: 0) {
                    activityBar
                    workspaceArea
                    rightHoverRegion(panelWidth: panelWidth)
                }
                .frame(maxHeight: .infinity)
            }

            statusBar
        }
        .background {
            WorkbenchTitlebar(content: topBar
                .environmentObject(model)
                .environmentObject(updateChecker)
                .environmentObject(projectSessions)
                .environmentObject(settings)
                .environment(\.locale, locale)
                .environment(\.colorScheme, colorScheme))
        }
        .background {
            WorkbenchBackgroundImageView(
                image: workbenchBackgroundImage,
                opacity: settings.workbenchBackgroundOpacity
            )
        }
        .sheet(item: $model.editingRunConfiguration) { configuration in
            if let feature = model.runFeatureIfActive {
                RunConfigurationEditorView(feature: feature, configuration: configuration)
                    .environmentObject(model)
            }
        }
        .onChange(of: model.branchSwitcherRequest) { _ in
            updateSwitcherPresentation(project: false, branch: true)
        }
        .sheet(item: $model.pendingNewBranchReference) { reference in
            TopBarNewBranchDialog(reference: reference) { name, checkout in
                Task {
                    await model.createBranch(named: name, from: reference, checkout: checkout)
                }
            }
        }
        .sheet(item: $model.debugBreakpointPresentation.pendingEditor) { breakpoint in
            BreakpointEditorView(breakpoint: breakpoint) { value in
                model.updateDebugBreakpoint(
                    breakpoint,
                    enabled: value.enabled,
                    condition: value.condition,
                    hitCondition: value.hitCondition,
                    logMessage: value.logMessage
                )
            }
        }
        .sheet(isPresented: $model.debugBreakpointPresentation.isManagerPresented) {
            if let feature = model.genericDebugFeatureIfActive {
                DebugBreakpointManagerDialog(feature: feature)
            } else {
                ProgressView("Loading breakpoints…")
                    .frame(minWidth: 640, minHeight: 420)
            }
        }
        .onAppear {
            updateWorkbenchBackgroundImage(model.workbenchBackgroundFeature.imageData)
        }
        .onReceive(model.workbenchBackgroundFeature.$imageData) { data in
            updateWorkbenchBackgroundImage(data)
        }
        .sheet(isPresented: $isCheckoutRevisionPresented) {
            CheckoutRevisionDialog { revision in
                Task { await model.checkoutRevision(revision) }
            }
        }
        .confirmationDialog(
            runConfigurationSetupTitle,
            isPresented: Binding(
                get: { model.runFeatureIfActive?.isGenerationConfirmationPresented ?? false },
                set: { model.runFeatureIfActive?.isGenerationConfirmationPresented = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button(model.runFeatureIfActive?.configurationStatus == .ready ? "Rescan" : "Identify and Generate") {
                continueAfterRunConfigurationGeneration()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(runConfigurationSetupMessage)
        }
        .sheet(item: $model.pendingCheckoutConflict) { request in
            GitCheckoutConflictDialog(
                request: request,
                savePolicy: model.gitSaveChangesPolicy,
                onResolve: { strategy in
                    Task { await model.resolveCheckoutConflict(request, strategy: strategy) }
                },
                onRollback: { path in
                    model.requestConflictRollback(path: path, resume: .checkout(request.reference))
                }
            )
        }
        .sheet(item: $model.pendingPullStrategy) { request in
            GitPullStrategyDialog(request: request) { strategy in
                Task { await model.resolvePullStrategy(strategy) }
            }
            .onDisappear { model.cancelPullStrategy() }
        }
        .sheet(item: $model.pendingIntegrationConflict) { request in
            GitIntegrationConflictDialog(
                request: request,
                savePolicy: model.gitSaveChangesPolicy,
                onStash: { Task { await model.resolveIntegrationConflict(request) } },
                onRollback: { path in
                    model.requestConflictRollback(
                        path: path,
                        resume: .integration(target: request.target, operation: request.operation)
                    )
                }
            )
            .onDisappear { model.cancelIntegrationConflict() }
        }
        .confirmationDialog(
            "Save changes before closing?",
            isPresented: Binding(
                get: { model.pendingCloseDocument != nil },
                set: { if !$0 { model.cancelPendingClose() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Save") { model.closePendingDocument(discardingChanges: false) }
                .lithePointer()
            Button("Discard Changes", role: .destructive) { model.closePendingDocument(discardingChanges: true) }
                .lithePointer()
            Button("Cancel", role: .cancel) { model.cancelPendingClose() }
                .lithePointer()
        } message: {
            Text(model.pendingCloseDocument?.url.lastPathComponent ?? "")
        }
        .confirmationDialog(
            model.pendingDiscardChange?.isUntracked == true ? "Delete this untracked file?" : "Discard changes to this file?",
            isPresented: Binding(
                get: { model.pendingDiscardChange != nil },
                set: { if !$0 { model.cancelDiscardChange() } }
            ),
            titleVisibility: .visible
        ) {
            Button(model.pendingDiscardChange?.isUntracked == true ? "Delete File" : "Discard Changes", role: .destructive) {
                guard let change = model.pendingDiscardChange else { return }
                Task { await model.confirmDiscardChange(change) }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) { model.cancelDiscardChange() }
                .lithePointer()
        } message: {
            Text("This action cannot be undone by Lithe.")
        }
        .confirmationDialog(
            "Discard changes to '\(model.pendingConflictRollback?.path ?? "this file")'?",
            isPresented: Binding(
                get: { model.pendingConflictRollback != nil },
                set: { if !$0 { model.cancelConflictRollback() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard and Retry", role: .destructive) {
                guard let request = model.pendingConflictRollback else { return }
                Task { await model.confirmConflictRollback(request) }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) { model.cancelConflictRollback() }
                .lithePointer()
        } message: {
            Text("This discards the file's staged and working-tree changes, then retries the blocked Git operation.")
        }
        .confirmationDialog(
            "Discard this change block?",
            isPresented: Binding(
                get: { model.pendingDiscardHunk != nil },
                set: { if !$0 { model.cancelDiscardHunk() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard Block", role: .destructive) {
                guard let request = model.pendingDiscardHunk else { return }
                Task { await model.confirmDiscardHunk(request) }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) { model.cancelDiscardHunk() }
                .lithePointer()
        } message: {
            Text(model.pendingDiscardHunk?.change.path ?? "This action cannot be undone by Lithe.")
        }
        .sheet(item: $model.pendingGitPushReference) { reference in
            GitPushDialog(
                projectName: model.projectName,
                reference: reference,
                onPush: {
                    Task { await model.pushBranch(reference) }
                }
            )
        }
        .confirmationDialog(
            "Delete branch?",
            isPresented: Binding(
                get: { pendingTopBarDeleteReference != nil },
                set: { if !$0 { pendingTopBarDeleteReference = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let reference = pendingTopBarDeleteReference else { return }
                pendingTopBarDeleteReference = nil
                Task { await model.deleteBranch(reference) }
            }
            .disabled(model.isPerformingBranchOperation)
            .lithePointer()
            Button("Cancel", role: .cancel) {
                pendingTopBarDeleteReference = nil
            }
            .lithePointer()
        } message: {
            Text(
                "Delete the local branch \(pendingTopBarDeleteReference?.shortName ?? "")? "
                    + "Git will refuse if it contains unmerged work."
            )
        }
        .overlay {
            if model.isSearchEverywhereVisible {
                SearchEverywhereView()
                    .environmentObject(model)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.isSearchEverywhereVisible)
        // Replace in Files 挂在工作台层：搜索侧栏未打开时快捷键也能直接弹出。
        .sheet(isPresented: $model.isProjectSearchPresented) {
            ProjectSearchView().environmentObject(model)
        }
        .sheet(isPresented: $model.isProjectReplaceVisible) {
            ProjectReplaceView()
                .environmentObject(model)
        }
        .onAppear {
            restoreLayout()
        }
        .onChange(of: model.workspaceURL?.standardizedFileURL.path) { _ in
            didRestoreLayout = false
            restoreLayout()
        }
    }

    private var projectTabBar: some View {
        GeometryReader { geometry in
            let horizontalPadding: CGFloat = 6
            let tabSpacing: CGFloat = 6
            let minimumTabWidth: CGFloat = 180
            let projectCount = CGFloat(max(projectSessions.openProjects.count, 1))
            let availableWidth = geometry.size.width
                - horizontalPadding * 2
                - tabSpacing * (projectCount - 1)
            let tabWidth = max(minimumTabWidth, floor(availableWidth / projectCount))

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: tabSpacing) {
                        ForEach(projectSessions.openProjects) { projectModel in
                            projectTab(projectModel, width: tabWidth)
                                .id(projectModel.id)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                }
                .onAppear {
                    proxy.scrollTo(projectSessions.activeSessionID, anchor: .center)
                }
                .onChange(of: projectSessions.activeSessionID) { id in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .frame(height: LitheTheme.Metrics.projectTabHeight)
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.toolHeader)
    }

    private func projectTab(_ projectModel: AppModel, width: CGFloat) -> some View {
        let isActive = projectModel.id == projectSessions.activeSessionID
        let isHovered = projectModel.id == hoveredProjectTabID

        return ZStack(alignment: .trailing) {
            Button {
                projectSessions.activateSession(projectModel.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isActive ? LitheTheme.accent : LitheTheme.secondaryText)

                    Text(projectModel.projectName)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? LitheTheme.primaryText : LitheTheme.secondaryText)

                    if let documentName = projectModel.activeDocument?.displayName {
                        Text("· \(documentName)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 38)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()
            .accessibilityIdentifier("project-tab-\(projectModel.id.uuidString)")

            Button {
                projectSessions.closeProject(projectModel.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .buttonStyle(LitheIconButtonStyle())
            .lithePointer()
            .help("Close Project")
            .opacity(isActive || isHovered ? 1 : 0)
            .allowsHitTesting(isActive || isHovered)
            .padding(.trailing, 3)
        }
        .frame(width: width, height: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isActive
                        ? LitheTheme.activeTabBackground
                        : (isHovered ? LitheTheme.hoverBackground : LitheTheme.inactiveTabBackground)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    isActive
                        ? LitheTheme.inputFocusBorder.opacity(0.7)
                        : (isHovered ? LitheTheme.panelBorder : .clear),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(isActive ? LitheTheme.tabUnderline : .clear)
                .frame(width: min(56, max(28, width * 0.12)), height: 2)
                .padding(.bottom, 1)
        }
        .onHover { hovering in
            hoveredProjectTabID = hovering ? projectModel.id : nil
        }
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private var topBar: some View {
        HStack(spacing: 9) {
            Button {
                updateSwitcherPresentation(
                    project: !isProjectSwitcherPresented,
                    branch: false
                )
            } label: {
                HStack(spacing: 8) {
                    ProjectBadge(name: model.projectName)

                    Text(model.projectName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .litheRowHover(
                    isActive: isProjectSwitcherPresented,
                    cornerRadius: 6,
                    activeBackground: LitheTheme.subtleSelection
                )
            }
            .buttonStyle(.plain)
            .lithePointer()
            .accessibilityIdentifier("project-switcher-\(model.id.uuidString)")
            .popover(isPresented: instantProjectSwitcherPresentation, arrowEdge: .bottom) {
                projectSwitcherContent
            }

            Button {
                updateSwitcherPresentation(
                    project: false,
                    branch: !isBranchSwitcherPresented
                )
                if isBranchSwitcherPresented {
                    Task { await model.refreshGitHistory() }
                }
            } label: {
                HStack(spacing: 7) {
                    LitheIDEAIcon(
                        resourcePath: "toolwindows/toolWindowVcs.svg",
                        size: 16,
                        fallbackSystemImage: "point.3.connected.trianglepath.dotted"
                    )
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text(model.currentBranch)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .padding(.horizontal, 9)
                .frame(height: 32)
                .litheRowHover(
                    isActive: isBranchSwitcherPresented,
                    cornerRadius: 6,
                    activeBackground: LitheTheme.subtleSelection
                )
            }
            .buttonStyle(.plain)
            .lithePointer()
            .popover(isPresented: instantBranchSwitcherPresentation, arrowEdge: .bottom) {
                branchSwitcherContent
            }

            Spacer(minLength: 22)

            HStack(spacing: 8) {
                runConfigurationPicker
                runLaunchButton
                debugLaunchButton
                if hasActiveExecution {
                    stopExecutionButton
                }
            }

            UpdateControl(compact: true)
            backgroundPickerButton

        }
        .padding(.trailing, 10)
        .frame(height: LitheTheme.Metrics.toolbarHeight)
        .background {
            (model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.titlebar)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    (NSApplication.shared.keyWindow?.delegate as? LitheWindowCoordinator)?
                        .toggleWorkspaceZoom()
                }
        }
    }

    private var projectSwitcherContent: some View {
        ProjectSwitcherPopover(
            isPresented: instantProjectSwitcherPresentation,
            onNewProject: {
                updateSwitcherPresentation(project: false)
                model.chooseProject(title: "New Project", prompt: "Choose Folder")
            },
            onOpenProject: {
                updateSwitcherPresentation(project: false)
                model.chooseProject()
            },
            onCloneRepository: {
                updateSwitcherPresentation(project: false)
                model.showCloneRepository()
            },
            onOpenRecentProject: { project in
                updateSwitcherPresentation(project: false)
                model.openProject(project.url)
            }
        )
        .environmentObject(model)
    }

    private var branchSwitcherContent: some View {
        BranchSwitcherPopover(
            isPresented: instantBranchSwitcherPresentation,
            onCommit: {
                updateSwitcherPresentation(branch: false)
                model.selectedSidebar = .changes
            },
            onPush: { reference in
                updateSwitcherPresentation(branch: false)
                model.pendingGitPushReference = reference
            },
            onDelete: { reference in
                updateSwitcherPresentation(branch: false)
                pendingTopBarDeleteReference = reference
            },
            onNewBranch: { reference in
                updateSwitcherPresentation(branch: false)
                model.pendingNewBranchReference = reference
            },
            onCheckoutRevision: {
                updateSwitcherPresentation(branch: false)
                isCheckoutRevisionPresented = true
            },
            onManageBranches: {
                updateSwitcherPresentation(branch: false)
                if !model.isGitLogVisible {
                    model.selectedSidebar = .changes
                    Task { await model.toggleGitLog() }
                }
            }
        )
        .environmentObject(model)
    }

    private var instantProjectSwitcherPresentation: Binding<Bool> {
        Binding(
            get: { isProjectSwitcherPresented },
            set: { updateSwitcherPresentation(project: $0) }
        )
    }

    private var instantBranchSwitcherPresentation: Binding<Bool> {
        Binding(
            get: { isBranchSwitcherPresented },
            set: { updateSwitcherPresentation(branch: $0) }
        )
    }

    private func updateSwitcherPresentation(
        project: Bool? = nil,
        branch: Bool? = nil
    ) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let project {
                isProjectSwitcherPresented = project
            }
            if let branch {
                isBranchSwitcherPresented = branch
            }
        }
    }

    private var runLaunchButton: some View {
        Button {
            if model.runFeatureIfActive?.isSelectedConfigurationRunning == true {
                model.restartSelectedRun()
            } else {
                model.runSelectedConfiguration()
            }
        } label: {
            LitheIDEAIcon(
                resourcePath: model.runFeatureIfActive?.isSelectedConfigurationRunning == true
                    ? "debugger/rerun.svg"
                    : "debugger/run.svg",
                size: 16,
                fallbackSystemImage: model.runFeatureIfActive?.isSelectedConfigurationRunning == true
                    ? "arrow.clockwise"
                    : "play.fill",
                preservesOriginalColors: true
            )
                .frame(width: 28, height: 28)
                .litheRowHover(isActive: false, cornerRadius: 6, activeBackground: LitheTheme.subtleSelection)
        }
        .buttonStyle(.plain)
        .lithePointer()
        .help(model.runFeatureIfActive?.isSelectedConfigurationRunning == true ? "Rerun selected configuration" : "Run selected configuration")
        .accessibilityLabel(model.runFeatureIfActive?.isSelectedConfigurationRunning == true ? "Rerun selected configuration" : "Run selected configuration")
        .accessibilityIdentifier("run-selected-run-configuration")
    }

    private var debugLaunchButton: some View {
        Button {
            model.startOrRestartDebugging()
        } label: {
            LitheIDEAIcon(
                resourcePath: isDebugSessionActive
                    ? "debugger/restartDebug.svg"
                    : "debugger/debug.svg",
                size: 16,
                fallbackSystemImage: "ladybug.fill",
                preservesOriginalColors: true
            )
            .frame(width: 28, height: 28)
            .litheRowHover(isActive: false, cornerRadius: 6, activeBackground: LitheTheme.subtleSelection)
        }
        .buttonStyle(.plain)
        .lithePointer()
        .help(isDebugSessionActive ? "Rerun or show Debug session" : "Debug selected run configuration")
        .accessibilityLabel(isDebugSessionActive ? "Rerun or show Debug session" : "Debug selected run configuration")
        .accessibilityIdentifier("debug-selected-run-configuration")
    }

    private var stopExecutionButton: some View {
        Button {
            if isDebugSessionActive {
                model.stopDebugging()
            } else {
                model.stopSelectedRun()
            }
        } label: {
            LitheIDEAIcon(
                resourcePath: "debugger/stop.svg",
                size: 16,
                fallbackSystemImage: "stop.fill",
                preservesOriginalColors: true
            )
                .frame(width: 28, height: 28)
                .litheRowHover(isActive: false, cornerRadius: 6, activeBackground: LitheTheme.subtleSelection)
        }
        .buttonStyle(.plain)
        .lithePointer()
        .help("Stop active execution")
        .accessibilityLabel("Stop active execution")
        .accessibilityIdentifier("stop-active-execution")
    }

    private var isDebugSessionActive: Bool {
        model.genericDebugFeatureIfActive?.isSessionActive == true
    }

    private var hasActiveExecution: Bool {
        isDebugSessionActive || model.runFeatureIfActive?.isSelectedConfigurationRunning == true
    }

    private var runConfigurationPicker: some View {
        Button {
            isRunConfigurationPickerPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                RunConfigurationIcon(
                    kind: model.runFeatureIfActive?.selectedConfiguration?.kind ?? .currentFile,
                    size: 14
                )
                Text(model.runFeatureIfActive?.selectedConfiguration?.name ?? "Current File")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 4)
            .frame(minWidth: 180, maxWidth: 300, alignment: .leading)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 180, maxWidth: 300, alignment: .leading)
        .frame(height: 30)
        .litheRowHover(isActive: false, cornerRadius: 6, activeBackground: LitheTheme.subtleSelection)
        .help("Select run configuration for Run or Debug")
        .accessibilityLabel("Select run configuration for Run or Debug")
        .accessibilityIdentifier("run-configuration-picker")
        .popover(isPresented: $isRunConfigurationPickerPresented, arrowEdge: .bottom) {
            runConfigurationSelectionPanel
        }
    }

    private var runConfigurationSelectionPanel: some View {
        let configurations = model.runFeatureIfActive?.configurations ?? [.currentFile]
        let services = configurations.filter { $0.execution == .service }
        let otherConfigurations = configurations.filter { $0.kind != .currentFile && $0.execution != .service }
        let visibleConfigurations = [RunConfiguration.currentFile] + services + otherConfigurations
        return VStack(alignment: .leading, spacing: 6) {
            Text("Run configurations")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(visibleConfigurations) { configuration in
                        if configuration.id == services.first?.id {
                            Divider().padding(.vertical, 3)
                            Text("Services")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                        }
                        if configuration.id == otherConfigurations.first?.id {
                            Divider().padding(.vertical, 3)
                            Text("Other run configurations")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                        }
                        let isSelected = configuration.id == model.runFeatureIfActive?.selectedConfiguration?.id
                        Button {
                            model.selectRunConfiguration(configuration)
                            isRunConfigurationPickerPresented = false
                        } label: {
                            HStack(spacing: 10) {
                                RunConfigurationIcon(kind: configuration.kind, size: 16)
                                Text(configuration.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 12)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .opacity(isSelected ? 1 : 0)
                            }
                            .foregroundStyle(LitheTheme.primaryText)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                            .litheRowHover(isActive: isSelected, cornerRadius: 6, activeBackground: LitheTheme.subtleSelection)
                        }
                        .buttonStyle(.plain)
                        .help(configuration.name)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .frame(height: min(CGFloat(visibleConfigurations.count) * 37
                + (services.isEmpty ? 0 : 28) + (otherConfigurations.isEmpty ? 0 : 28), 296))
            Divider()
            Button("Edit Configurations…") {
                isRunConfigurationPickerPresented = false
                model.showRunConfigurationEditor()
            }
            Button("Identify / Rescan Project…") {
                isRunConfigurationPickerPresented = false
                model.requestRunConfigurationRescan()
            }
        }
        .padding(8)
        .frame(width: 280)
        .background(LitheTheme.editor)
    }

    private var backgroundPickerButton: some View {
        Button {
            isBackgroundPickerPresented.toggle()
        } label: {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .litheRowHover(
                    isActive: isBackgroundPickerPresented,
                    cornerRadius: 6,
                    activeBackground: LitheTheme.subtleSelection
                )
        }
        .buttonStyle(.plain)
        .lithePointer()
        .foregroundStyle(LitheTheme.secondaryText)
        .help("Change workbench background")
        .accessibilityLabel("Change workbench background")
        .accessibilityIdentifier("workbench-background-picker")
        .popover(isPresented: $isBackgroundPickerPresented, arrowEdge: .bottom) {
            WorkbenchBackgroundPicker {
                isBackgroundPickerPresented = false
            }
            .environmentObject(model)
            .environmentObject(settings)
        }
    }

    private var activityBar: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VStack(spacing: ActivityBarMetrics.spacing) {
                    ForEach(model.availableSidebarDestinations) { destination in
                        Button {
                            if let id = destination.commandID { model.performShortcutCommand(id: id) }
                            else { model.toggleSidebar(destination) }
                        } label: {
                            Group {
                                if let ideaAssetPath = destination.ideaAssetPath {
                                    LitheIDEAIcon(
                                        resourcePath: ideaAssetPath,
                                        size: 20,
                                        fallbackSystemImage: destination.systemImage
                                    )
                                } else {
                                    Image(systemName: destination.systemImage)
                                        .font(.system(size: 18, weight: .regular))
                                }
                            }
                                .frame(
                                    width: ActivityBarMetrics.buttonWidth,
                                    height: ActivityBarMetrics.buttonHeight
                                )
                                .litheRowHover(
                                    isActive: model.isSidebarVisible && model.selectedSidebar == destination,
                                    cornerRadius: 4,
                                    activeBackground: LitheTheme.subtleSelection
                                )
                        }
                        .buttonStyle(.plain)
                        .lithePointer()
                        .disabled(!destination.isAvailable || destination.commandID.map {
                            !model.canPerformShortcutCommand(id: $0)
                        } == true)
                        .foregroundStyle(model.isSidebarVisible && model.selectedSidebar == destination ? LitheTheme.primaryText : LitheTheme.secondaryText)
                        .help(
                            destination.isAvailable
                                ? commandHelp(destination.title, commandID: destination.commandID)
                                : Text("Pull Requests integration is under development")
                        )
                        .accessibilityLabel(LocalizedStringKey(destination.title))
                        .accessibilityHint(
                            destination.isAvailable
                                ? LocalizedStringKey("")
                                : LocalizedStringKey("Pull Requests integration is under development")
                        )
                    }
                }
                .padding(.top, ActivityBarMetrics.edgeInset)

                Spacer(minLength: 0)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: ActivityBarMetrics.spacing) {
                        ForEach(model.activityBarContributions) { contribution in
                            if let renderer = moduleUIRegistry.renderer(for: contribution),
                               renderer.isVisible(model) {
                                activityToolButton(
                                    systemImage: contribution.icon ?? "square.grid.2x2",
                                    ideaAssetPath: renderer.ideaAssetPath,
                                    help: contribution.title,
                                    commandID: moduleUIRegistry.commandID(for: contribution),
                                    isSelected: renderer.isSelected(model)
                                ) {
                                    moduleUIRegistry.perform(contribution, model: model)
                                }
                            }
                        }

                        activityToolButton(
                            systemImage: "gearshape",
                            ideaAssetPath: "general/gear.svg",
                            help: "Settings",
                            commandID: "settings",
                            isSelected: model.isSettingsPresented
                        ) {
                            model.performShortcutCommand(id: "settings")
                        }
                    }
                    // Keep short tool lists against the status bar while preserving
                    // vertical scrolling when modules add more activity buttons.
                    .frame(
                        minHeight: ActivityBarMetrics.toolViewportHeight,
                        alignment: .bottom
                    )
                }
                .frame(height: ActivityBarMetrics.toolViewportHeight)
                .padding(.bottom, ActivityBarMetrics.edgeInset)
            }
            .frame(width: ActivityBarMetrics.width, height: geometry.size.height, alignment: .top)
            .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.titlebar)
        }
        .frame(width: ActivityBarMetrics.width)
    }

    private var pluginActivityBar: some View {
        VStack(spacing: ActivityBarMetrics.spacing) {
            Button {
                isNotificationCenterPresented.toggle()
                if isNotificationCenterPresented {
                    model.markAllNotificationsRead()
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: unreadNotificationCount > 0 ? "bell.fill" : "bell")
                        .font(.system(size: 18))
                        .frame(width: ActivityBarMetrics.buttonWidth, height: ActivityBarMetrics.buttonHeight)
                        .litheRowHover(
                            isActive: isNotificationCenterPresented,
                            cornerRadius: 4,
                            activeBackground: LitheTheme.subtleSelection
                        )

                    if unreadNotificationCount > 0 {
                        Circle()
                            .fill(LitheTheme.error)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(LitheTheme.titlebar, lineWidth: 1))
                            .offset(x: -2, y: 3)
                    }
                }
            }
            .buttonStyle(.plain)
            .lithePointer()
            .foregroundStyle(
                unreadNotificationCount > 0 || isNotificationCenterPresented
                    ? LitheTheme.primaryText
                    : LitheTheme.secondaryText
            )
            .help(LocalizedStringKey("Notifications"))
            .accessibilityLabel("Notifications")
            .popover(isPresented: $isNotificationCenterPresented, arrowEdge: .trailing) {
                WorkbenchNotificationCenterView()
                    .environmentObject(model)
            }

            ForEach(model.rightSidebarContributions) { contribution in
                if let renderer = moduleUIRegistry.renderer(for: contribution),
                   renderer.isVisible(model) {
                    Button { moduleUIRegistry.perform(contribution, model: model) } label: {
                        Group {
                            if let asset = renderer.ideaAssetPath {
                                LitheIDEAIcon(resourcePath: asset, size: 18,
                                    fallbackSystemImage: contribution.icon ?? "rectangle.rightthird.inset.filled")
                            } else {
                                Image(systemName: contribution.icon ?? "rectangle.rightthird.inset.filled")
                                    .font(.system(size: 18))
                            }
                        }
                            .frame(width: ActivityBarMetrics.buttonWidth, height: ActivityBarMetrics.buttonHeight)
                            .litheRowHover(
                                isActive: renderer.isSelected(model),
                                cornerRadius: 4,
                                activeBackground: LitheTheme.subtleSelection
                            )
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                    .foregroundStyle(renderer.isSelected(model) ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    .disabled(moduleUIRegistry.commandID(for: contribution).map { !model.canPerformShortcutCommand(id: $0) } == true)
                    .help(commandHelp(contribution.title, commandID: moduleUIRegistry.commandID(for: contribution)))
                    .accessibilityLabel(contribution.title)

                }
            }
            Button { isPluginPanelPresented.toggle() } label: {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 18))
                    .frame(width: ActivityBarMetrics.buttonWidth, height: ActivityBarMetrics.buttonHeight)
                    .litheRowHover(isActive: isPluginPanelPresented, cornerRadius: 4, activeBackground: LitheTheme.subtleSelection)
            }
            .buttonStyle(.plain)
            .lithePointer()
            .foregroundStyle(isPluginPanelPresented ? LitheTheme.primaryText : LitheTheme.secondaryText)
            .help("Plugins")
            Spacer()
        }
        .padding(.top, ActivityBarMetrics.edgeInset)
        .frame(width: ActivityBarMetrics.rightWidth)
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.titlebar)
    }

    private var unreadNotificationCount: Int {
        model.notifications.lazy.filter { !$0.isRead }.count
    }

    private func rightHoverRegion(panelWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            if isRightSidebarVisible {
                moduleUIRegistry.selectedToolContent(
                    from: model.rightSidebarContributions,
                    model: model
                )
                .equatable()
                .frame(width: panelWidth)
                .frame(maxHeight: .infinity)
                .workbenchPaneChrome(
                    background: model.workbenchBackgroundFeature.hasImage
                        ? Color.clear
                        : LitheTheme.editor,
                    surrounding: model.workbenchBackgroundFeature.hasImage
                        ? Color.clear
                        : LitheTheme.titlebar,
                    roundsCorners: !model.workbenchBackgroundFeature.hasImage
                )
                .padding(WorkbenchWorkspaceMetrics.paneInset)
                .background(
                    model.workbenchBackgroundFeature.hasImage
                        ? Color.clear
                        : LitheTheme.titlebar
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .trailing).combined(with: .opacity)
                )

            }
            pluginActivityBar
        }
        .fixedSize(horizontal: true, vertical: false)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.14),
            value: isRightSidebarVisible
        )
    }

    private var isRightSidebarVisible: Bool {
        model.rightSidebarContributions.contains { contribution in
            moduleUIRegistry.renderer(for: contribution)?.isSelected(model) == true
        }
    }

    private var runConfigurationSetupTitle: String {
        switch model.runFeatureIfActive?.configurationStatus ?? .missing {
        case .missing:
            String(localized: "Project run configuration not found")
        case .invalid:
            String(localized: "Project run configuration is invalid")
        case .ready:
            String(localized: "Rescan the project for services")
        }
    }

    /// The dialog doubles as first-time setup and as an explicit rescan. Only
    /// the first case can claim Run is unavailable until it completes.
    private var runConfigurationSetupMessage: String {
        model.runFeatureIfActive?.configurationStatus == .ready
            ? String(localized: "Lithe will look for services again and refresh .lithe/run/generated.json. Project and local overrides will not be changed.")
            : String(localized: "Lithe needs to identify the project and generate .lithe/run/generated.json before Run and Debug are available. Project and local overrides will not be changed.")
    }

    private func continueAfterRunConfigurationGeneration() {
        Task {
            await model.continueAfterRunConfigurationGeneration()
        }
    }

    private func activityToolButton(
        systemImage: String,
        ideaAssetPath: String? = nil,
        help: String,
        commandID: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let ideaAssetPath {
                    LitheIDEAIcon(
                        resourcePath: ideaAssetPath,
                        size: 18,
                        fallbackSystemImage: systemImage
                    )
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .medium))
                }
            }
            .frame(
                width: ActivityBarMetrics.buttonWidth,
                height: ActivityBarMetrics.buttonHeight
            )
            .litheRowHover(
                isActive: isSelected,
                cornerRadius: 4,
                activeBackground: LitheTheme.subtleSelection
            )
        }
        .buttonStyle(.plain)
        .lithePointer()
        .foregroundStyle(isSelected ? LitheTheme.primaryText : LitheTheme.secondaryText)
        .disabled(commandID.map { !model.canPerformShortcutCommand(id: $0) } == true)
        .help(commandHelp(help, commandID: commandID))
        .accessibilityLabel(Text(LocalizedStringKey(help)))
    }

    private func commandHelp(_ title: String, commandID: String?) -> Text {
        let title = Text(LocalizedStringKey(title))
        guard let commandID,
              let binding = model.keyboardShortcutFeature.displayText(for: commandID) else { return title }
        return title + Text(" (\(binding))")
    }

    private var workspaceArea: some View {
        WorkbenchWorkspaceSplitView(
            sidebarWidth: sidebarWidth,
            isSidebarVisible: model.isSidebarVisible,
            topPaneHeight: topPaneHeight,
            isBottomToolVisible: isBottomToolVisible,
            actions: WorkbenchWorkspaceSplitActions(
                onSidebarWidthCommitted: { width in
                    sidebarWidth = width
                    saveLayout(sidebarWidth: width, topPaneHeight: topPaneHeight)
                },
                onTopPaneHeightCommitted: { height in
                    topPaneHeight = height
                    saveLayout(sidebarWidth: sidebarWidth, topPaneHeight: height)
                }
            ),
            hasWorkbenchBackground: model.workbenchBackgroundFeature.hasImage,
            sidebar: {
                activeSidebar(projectTreeRowHeight: settings.projectTreeRowHeight)
            },
            editor: {
                Group {
                    if isPluginPanelPresented {
                        PluginManagementView()
                            .environmentObject(model)
                    } else if model.selectedSidebar == .pullRequests {
                        if LitheFeatureAvailability.githubPullRequests {
                            GitHubPullRequestDetailView()
                        } else {
                            GitHubFeatureUnavailableView()
                        }
                    } else {
                        EditorAreaView()
                    }
                }
            },
            bottomTool: {
                Group {
                    if model.isReferencesVisible {
                        LanguageReferencesView()
                    } else {
                        moduleUIRegistry.selectedToolContent(
                            from: model.activityBarContributions,
                            model: model
                        )
                        .equatable()
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func activeSidebar(projectTreeRowHeight: CGFloat) -> some View {
        Group {
            switch model.selectedSidebar {
            case .project:
                ProjectSidebarView(rowHeight: projectTreeRowHeight)
            case .changes:
                ChangesSidebarView()
            case .pullRequests:
                if LitheFeatureAvailability.githubPullRequests {
                    GitHubPullRequestsSidebarView()
                } else {
                    GitHubFeatureUnavailableView()
                }
            case .search:
                SearchSidebarView()
            case .database:
                if model.isDatabaseModuleActive {
                    DatabaseSidebarView()
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task { await model.activateDatabaseModule() }
                }
            }
        }
    }

    private var isBottomToolVisible: Bool {
        model.isGitLogVisible || model.isTerminalVisible || model.isReferencesVisible || model.isProblemsVisible || model.isDebugVisible || model.isRunVisible || model.isTestsVisible
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            editorBreadcrumbs
                .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                detailedStatusItems
                compactStatusItems
            }
        }
        .font(LitheTheme.smallFont)
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.horizontal, 9)
        .frame(height: LitheTheme.Metrics.statusBarHeight)
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.titlebar)
    }

    private var editorBreadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let document = model.activeDocument {
                    let path = document.displayPath ?? model.relativePath(for: document.url)
                    let components = path.split(separator: "/")
                    ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                        let isFile = index == components.count - 1
                        breadcrumbItem(
                            title: String(component),
                            iconKind: isFile
                                ? LitheIcons.kind(for: document.url, isDirectory: false)
                                : nil,
                            isEmphasized: isFile
                        ) {
                            guard let itemURL = breadcrumbURL(
                                for: document,
                                componentIndex: index,
                                componentCount: components.count
                            ) else { return }
                            model.revealInProjectTree(itemURL, isDirectory: !isFile)
                        }
                        if index < components.count - 1 {
                            breadcrumbSeparator
                        }
                    }
                } else {
                    HStack(spacing: 5) {
                        LitheIcon(kind: .folder, size: 13)
                        Text(model.projectName)
                    }
                }
            }
        }
    }

    private func breadcrumbURL(
        for document: EditorDocument,
        componentIndex: Int,
        componentCount: Int
    ) -> URL? {
        guard componentIndex >= 0, componentIndex < componentCount else { return nil }
        if componentIndex == componentCount - 1 {
            return document.url
        }
        guard let workspaceURL = model.workspaceURL else { return nil }
        return (0...componentIndex).reduce(workspaceURL) { url, index in
            let path = document.displayPath ?? model.relativePath(for: document.url)
            let components = path.split(separator: "/")
            return url.appendingPathComponent(String(components[index]), isDirectory: true)
        }
    }

    private func breadcrumbItem(
        title: String,
        iconKind: LitheIconKind?,
        isEmphasized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let iconKind {
                    LitheIcon(kind: iconKind, size: 12)
                        .opacity(isEmphasized ? 1 : 0.72)
                }
                Text(LocalizedStringKey(title))
                    .lineLimit(1)
            }
            .foregroundStyle(isEmphasized ? LitheTheme.primaryText : LitheTheme.secondaryText)
        }
        .buttonStyle(.plain)
        .lithePointer()
        .help(LocalizedStringKey(title))
    }

    private var breadcrumbSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(LitheTheme.secondaryText.opacity(0.72))
    }

    private var detailedStatusItems: some View {
        HStack(spacing: 14) {
            EditorCaretPositionLabel(chrome: model.editorChrome) { model.showGoToLine() }
            Text("UTF-8")
            Text("\(settings.tabWidth) spaces")
            Button {
                model.saveActiveDocument()
            } label: {
                Image(systemName: model.activeDocument?.isReadOnly == true ? "lock.fill" : "lock.open")
            }
            .litheIconButton()
            .disabled(model.activeDocument?.isReadOnly == true)
            .help(LocalizedStringKey(
                model.activeDocument?.isReadOnly == true ? "Read-only document" : "Save"
            ))
            MemoryUsageStatusView()
            FrameRateStatusView()
            gitStatus
        }
    }

    private var compactStatusItems: some View {
        HStack(spacing: 10) {
            EditorCaretPositionLabel(chrome: model.editorChrome) { model.showGoToLine() }
            MemoryUsageStatusView()
            FrameRateStatusView()
            gitStatus
        }
    }

    private var gitStatus: some View {
        HStack(spacing: 7) {
            if model.isReferencesVisible {
                Label("\(model.languageNavigationResults.count) usages", systemImage: "scope")
            }
            Text(model.gitChanges.isEmpty ? "No changes" : "\(model.gitChanges.count) changes")
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LitheTheme.success)
        }
    }

    private func restoreLayout() {
        guard !didRestoreLayout, let workspaceURL = model.workspaceURL else { return }
        let layout = model.loadWorkbenchLayout(for: workspaceURL)
        sidebarWidth = CGFloat(layout.sidebarWidth)
        topPaneHeight = layout.topPaneHeight.map { CGFloat($0) }
        didRestoreLayout = true
    }

    private func saveLayout(sidebarWidth: CGFloat, topPaneHeight: CGFloat?) {
        guard didRestoreLayout, let workspaceURL = model.workspaceURL else { return }
        model.saveWorkbenchLayout(
            WorkbenchLayout(
                sidebarWidth: Double(sidebarWidth),
                topPaneHeight: topPaneHeight.map(Double.init)
            ),
            for: workspaceURL
        )
    }

    private func updateWorkbenchBackgroundImage(_ data: Data?) {
        workbenchBackgroundImage = data.flatMap(NSImage.init(data:))
    }

}

private struct WorkbenchNotificationCenterView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)

                Spacer()

                Button("Clear All") {
                    model.clearNotifications()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(
                    model.notifications.isEmpty
                        ? LitheTheme.tertiaryText
                        : LitheTheme.accent
                )
                .disabled(model.notifications.isEmpty)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            if model.notifications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(LitheTheme.tertiaryText)
                    Text("No notifications")
                        .font(.system(size: 12))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.notifications) { notification in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    WorkbenchNotificationContent(notification: notification)

                                    Text(notification.createdAt.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(LitheTheme.tertiaryText)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)

                            Rectangle()
                                .fill(LitheTheme.divider.opacity(0.7))
                                .frame(height: 1)
                                .padding(.leading, 37)
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 420)
        .background(LitheTheme.raised)
        .onAppear {
            model.markAllNotificationsRead()
        }
        .onChange(of: model.notifications.count) { _ in
            model.markAllNotificationsRead()
        }
    }
}

/// The callbacks the workspace split view hands back to the workbench.
///
/// Grouped into one value, following `GitGraphRowActions`, so the split view
/// carries a single stored property instead of three freshly allocated escaping
/// closures per parent body pass.
private struct WorkbenchWorkspaceSplitActions {
    let onSidebarWidthCommitted: (CGFloat) -> Void
    let onTopPaneHeightCommitted: (CGFloat) -> Void
}

private struct WorkbenchWorkspaceSplitView<Sidebar: View, Editor: View, BottomTool: View>: View {
    let sidebarWidth: CGFloat
    let isSidebarVisible: Bool
    let topPaneHeight: CGFloat?
    let isBottomToolVisible: Bool
    let actions: WorkbenchWorkspaceSplitActions
    let hasWorkbenchBackground: Bool
    let sidebar: Sidebar
    let editor: Editor
    let bottomTool: BottomTool

    init(
        sidebarWidth: CGFloat,
        isSidebarVisible: Bool,
        topPaneHeight: CGFloat?,
        isBottomToolVisible: Bool,
        actions: WorkbenchWorkspaceSplitActions,
        hasWorkbenchBackground: Bool,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder editor: () -> Editor,
        @ViewBuilder bottomTool: () -> BottomTool
    ) {
        self.sidebarWidth = sidebarWidth
        self.isSidebarVisible = isSidebarVisible
        self.topPaneHeight = topPaneHeight
        self.isBottomToolVisible = isBottomToolVisible
        self.actions = actions
        self.hasWorkbenchBackground = hasWorkbenchBackground
        self.sidebar = sidebar()
        self.editor = editor()
        self.bottomTool = bottomTool()
    }

    var body: some View {
        let _ = LitheSignpost.bodyEvaluated("WorkbenchWorkspaceSplitView")
        GeometryReader { geometry in
            let inset = WorkbenchWorkspaceMetrics.paneInset
            let width = max(0, geometry.size.width - 2 * inset)
            let height = max(0, geometry.size.height - 2 * inset)
            let divider = SplitHandleView.thickness
            let maximumSidebar = max(0, min(520, width - 400 - divider))
            let minimumSidebar = min(220, maximumSidebar)
            let minimumBottom = min(260, max(0, height - divider))
            let maximumBottom = max(minimumBottom, height - min(220, height) - divider)
            let defaultTop = topPaneHeight ?? max(255, height * 0.40)
            let topContent = LitheSplitPaneView(
                axis: .horizontal,
                placement: .leading,
                defaultSize: sidebarWidth,
                minimum: minimumSidebar,
                maximum: maximumSidebar,
                showsIdleDivider: false,
                isSizedPaneVisible: isSidebarVisible,
                onCommit: actions.onSidebarWidthCommitted,
                sized: {
                    sidebar
                        .frame(maxHeight: .infinity)
                        .workbenchPaneChrome(
                            background: hasWorkbenchBackground ? Color.clear : LitheTheme.sidebar,
                            surrounding: hasWorkbenchBackground ? Color.clear : LitheTheme.titlebar,
                            roundsCorners: false
                        )
                },
                flexible: {
                    editor
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .workbenchPaneChrome(
                            background: hasWorkbenchBackground ? Color.clear : LitheTheme.editor,
                            surrounding: hasWorkbenchBackground ? Color.clear : LitheTheme.titlebar,
                            roundsCorners: false
                        )
                }
            )

            // Both split containers stay mounted. Hiding a tool only collapses
            // its pane, so editor buffers and project expansion survive.
            LitheSplitPaneView(
                axis: .vertical,
                placement: .trailing,
                defaultSize: height - defaultTop - divider,
                minimum: minimumBottom,
                maximum: maximumBottom,
                showsIdleDivider: false,
                isSizedPaneVisible: isBottomToolVisible,
                onCommit: { actions.onTopPaneHeightCommitted(max(0, height - $0 - divider)) },
                sized: {
                    bottomTool
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .workbenchPaneChrome(
                            background: hasWorkbenchBackground ? Color.clear : LitheTheme.editor,
                            surrounding: hasWorkbenchBackground ? Color.clear : LitheTheme.titlebar,
                            roundsCorners: false
                        )
                },
                flexible: { topContent }
            )
            .padding(inset)
            .background(hasWorkbenchBackground ? Color.clear : LitheTheme.titlebar)
        }
    }
}

private extension View {
    /// Draws pane rounding without masking AppKit-backed editor and tool views.
    func workbenchPaneChrome(
        background: Color,
        surrounding: Color,
        roundsCorners: Bool = true
    ) -> some View {
        modifier(
            WorkbenchPaneChromeModifier(
                background: background,
                surrounding: surrounding,
                roundsCorners: roundsCorners
            )
        )
    }
}

private struct WorkbenchPaneChromeModifier: ViewModifier {
    let background: Color
    let surrounding: Color
    let roundsCorners: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if roundsCorners {
            // Four fixed-size corner notches instead of one pane-sized even-odd
            // fill. The notch geometry only depends on the corner radius, so it
            // is built once and merely repositioned while a pane resizes, rather
            // than re-tessellating a full-pane vector path every frame. Absolute
            // positioning (not leading/trailing alignment) keeps the notches on
            // the same physical corners the previous fill used.
            content
                .background(background)
                .overlay {
                    GeometryReader { proxy in
                        let radius = WorkbenchWorkspaceMetrics.paneCornerRadius
                        let half = radius / 2
                        ZStack {
                            notch(.topLeading).position(x: half, y: half)
                            notch(.topTrailing).position(x: proxy.size.width - half, y: half)
                            notch(.bottomLeading).position(x: half, y: proxy.size.height - half)
                            notch(.bottomTrailing)
                                .position(x: proxy.size.width - half, y: proxy.size.height - half)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            content.background(background)
        }
    }

    private func notch(_ corner: WorkbenchPaneCornerGeometry.Corner) -> some View {
        WorkbenchPaneCornerNotch(corner: corner)
            .fill(surrounding)
            .frame(
                width: WorkbenchWorkspaceMetrics.paneCornerRadius,
                height: WorkbenchWorkspaceMetrics.paneCornerRadius
            )
    }
}

/// One corner of the gap between a pane's square bounds and its rounded
/// silhouette, painted in the surrounding color so the pane reads as rounded
/// without clipping the AppKit-backed content inside it.
///
/// The path is a compile-time constant: the radius is fixed, so every instance
/// reuses the same geometry and resizing a pane only moves it.
private struct WorkbenchPaneCornerNotch: Shape {
    let corner: WorkbenchPaneCornerGeometry.Corner

    /// Ignores `rect` because the caller always frames this at exactly
    /// `paneCornerRadius` square; honoring an arbitrary rect would mean
    /// rebuilding the path on every layout, which is the cost being removed.
    func path(in rect: CGRect) -> Path {
        WorkbenchPaneCornerGeometry.path(for: corner)
    }
}

/// Pure geometry for the four pane corner notches, separated from the `Shape`
/// so the arc direction can be verified without rendering.
enum WorkbenchPaneCornerGeometry {
    enum Corner: CaseIterable {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing
    }

    /// The notch path in a `radius`-square box, cached per corner.
    static func path(for corner: Corner) -> Path {
        paths[corner] ?? Path()
    }

    private static let radius = WorkbenchWorkspaceMetrics.paneCornerRadius

    private static let paths: [Corner: Path] = Dictionary(
        uniqueKeysWithValues: Corner.allCases.map { ($0, makePath(for: $0, radius: radius)) }
    )

    static func makePath(for corner: Corner, radius: CGFloat) -> Path {
        // The arc is centered on the box corner diagonally opposite the pane
        // corner being rounded, so it stays tangent to both pane edges.
        let center: CGPoint
        let start: CGPoint
        let end: CGPoint
        switch corner {
        case .topLeading:
            center = CGPoint(x: radius, y: radius)
            start = CGPoint(x: radius, y: 0)
            end = CGPoint(x: 0, y: radius)
        case .topTrailing:
            center = CGPoint(x: 0, y: radius)
            start = CGPoint(x: 0, y: 0)
            end = CGPoint(x: radius, y: radius)
        case .bottomLeading:
            center = CGPoint(x: radius, y: 0)
            start = CGPoint(x: radius, y: radius)
            end = CGPoint(x: 0, y: 0)
        case .bottomTrailing:
            center = CGPoint(x: 0, y: 0)
            start = CGPoint(x: 0, y: radius)
            end = CGPoint(x: radius, y: 0)
        }

        // Quarter arc as a cubic Bézier. Building it from the two tangent points
        // rather than sweep angles keeps the direction unambiguous in SwiftUI's
        // y-down space, where `clockwise:` reads inverted.
        let handle = radius * 0.5522847498307936
        let startTangent = unitTangent(from: center, through: start, toward: end)
        let endTangent = unitTangent(from: center, through: end, toward: start)

        var path = Path()
        path.move(to: paneCorner(for: corner, radius: radius))
        path.addLine(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(
                x: start.x + startTangent.dx * handle,
                y: start.y + startTangent.dy * handle
            ),
            control2: CGPoint(
                x: end.x + endTangent.dx * handle,
                y: end.y + endTangent.dy * handle
            )
        )
        path.closeSubpath()
        return path
    }

    /// The square corner the notch fills in, in box-local coordinates.
    private static func paneCorner(for corner: Corner, radius: CGFloat) -> CGPoint {
        switch corner {
        case .topLeading: CGPoint(x: 0, y: 0)
        case .topTrailing: CGPoint(x: radius, y: 0)
        case .bottomLeading: CGPoint(x: 0, y: radius)
        case .bottomTrailing: CGPoint(x: radius, y: radius)
        }
    }

    /// Unit tangent to the circle at `point`, oriented so the arc sweeps toward
    /// `destination` along the 90-degree side.
    private static func unitTangent(
        from center: CGPoint,
        through point: CGPoint,
        toward destination: CGPoint
    ) -> CGVector {
        let radial = CGVector(dx: point.x - center.x, dy: point.y - center.y)
        // Rotating the radius by 90 degrees gives the tangent; the sign that
        // points at the other endpoint is the one that sweeps the minor arc.
        let candidate = CGVector(dx: -radial.dy, dy: radial.dx)
        let towardDestination = CGVector(
            dx: destination.x - point.x,
            dy: destination.y - point.y
        )
        let alignment = candidate.dx * towardDestination.dx + candidate.dy * towardDestination.dy
        let length = max(hypot(radial.dx, radial.dy), 0.0001)
        let sign: CGFloat = alignment >= 0 ? 1 : -1
        return CGVector(dx: sign * candidate.dx / length, dy: sign * candidate.dy / length)
    }
}

private struct WorkbenchBackgroundImageView: View {
    let image: NSImage?
    let opacity: Double
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LitheTheme.window

            if let image {
                // Fill and clip at the container instead of measuring with a
                // GeometryReader, so a window resize no longer re-evaluates a
                // geometry closure just to restate the size the layout offers.
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .opacity(opacity)
            }

            // Preserve the source image's colour while keeping text legible.
            // Soft-light compositing against the dark theme muted bright images
            // twice, so a single contrast veil produces the intended wallpaper
            // effect at the full 100% setting.
            (colorScheme == .dark ? Color.black.opacity(0.46) : Color.white.opacity(0.25))
        }
        .clipped()
        // Deliberately not a compositing group: no group-wide opacity or blend
        // mode is applied here, so flattening these layers offscreen changed
        // nothing visually while forcing the whole window to recomposite on
        // every resize.
        .allowsHitTesting(false)
    }
}

struct WorkbenchBackgroundPicker: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    let dismiss: () -> Void

    private var availablePresets: [WorkbenchBackgroundPreset] {
        model.workbenchBackgroundFeature.availablePresets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Workbench background", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .litheIconButton()
                .help("Close")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Built-in backgrounds")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 10
                ) {
                    ForEach(availablePresets) { preset in
                        presetButton(preset)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button("Choose Image…") {
                    model.workbenchBackgroundFeature.chooseCustomImage()
                }
                .buttonStyle(LitheSecondaryButtonStyle())

                if settings.hasConfiguredWorkbenchBackground {
                    Button("Remove") {
                        model.workbenchBackgroundFeature.clear()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LitheTheme.accent)
                    .lithePointer()
                }

                Spacer(minLength: 0)

                Text(model.workbenchBackgroundFeature.displayName ?? "No background image selected")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 112, alignment: .trailing)
            }

            if settings.hasConfiguredWorkbenchBackground {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Workbench background opacity")
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer()
                        Text("\(Int((settings.workbenchBackgroundOpacity * 100).rounded()))%")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                    Slider(value: $settings.workbenchBackgroundOpacity, in: 0.05...1.0, step: 0.01)
                }
            }
        }
        .padding(14)
        .frame(width: 356)
        .background(LitheTheme.popupBackground)
    }

    private func presetButton(_ preset: WorkbenchBackgroundPreset) -> some View {
        let isSelected = settings.workbenchBackgroundPreset == preset
        return Button {
            model.workbenchBackgroundFeature.selectPreset(preset)
        } label: {
            VStack(spacing: 5) {
                WorkbenchBackgroundPresetArtwork(
                    imageData: model.workbenchBackgroundFeature.previewData(for: preset)
                )
                    .frame(height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                isSelected ? LitheTheme.accent : LitheTheme.panelBorder,
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
                Text(LocalizedStringKey(preset.title))
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? LitheTheme.primaryText : LitheTheme.secondaryText)
            }
            .frame(width: 100)
        }
        .buttonStyle(.plain)
        .lithePointer()
        .accessibilityLabel(Text(LocalizedStringKey(preset.title)))
    }
}

struct WorkbenchBackgroundPresetArtwork: View {
    let imageData: Data?

    var body: some View {
        if let imageData, let image = NSImage(data: imageData) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        }
    }
}
