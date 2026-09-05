import AppKit
import SwiftUI

private let litheProcessLaunchDate = Date()

@MainActor
protocol UnsavedDocumentHandling: AnyObject {
    var hasUnsavedDocuments: Bool { get }
    var unsavedDocumentNames: [String] { get }

    @discardableResult
    func saveAllDocuments() -> Bool
}

enum UnsavedDocumentsConfirmationContext {
    case applicationTermination
    case projectWindowClose

    var messageText: String {
        switch self {
        case .applicationTermination:
            "Save changes before quitting?"
        case .projectWindowClose:
            "Save changes before closing this window?"
        }
    }
}

@MainActor
final class LitheAppDelegate: NSObject, NSApplicationDelegate {
    private enum TerminationCleanupState {
        case idle
        case cleaning
        case approved
    }

    /// Upper bound for module/session teardown during in-app update replacement.
    /// A hung language server or plugin must not leave the installer spinner forever.
    private static let updateTerminationCleanupTimeoutNanoseconds: UInt64 = 5_000_000_000
    /// Hard ceiling after requesting update termination; the helper force-kills later.
    private static let updateTerminationForceExitNanoseconds: UInt64 = 8_000_000_000

    private var pendingFileURLs: [URL] = []
    private var terminationCleanupTask: Task<Void, Never>?
    private var terminationCleanupState: TerminationCleanupState = .idle
    private var isUpdateInstallTermination = false
    private var updateForceExitTask: Task<Void, Never>?
    weak var projectWindows: ProjectWindowManager? {
        didSet {
            guard let projectWindows else { return }
            let pendingURLs = pendingFileURLs
            pendingFileURLs.removeAll()
            pendingURLs.forEach { projectWindows.openStandaloneFile($0) }
        }
    }
    var recordCleanPluginShutdown: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftUI normally forwards this event to the delegate methods below,
        // but older Finder/AppKit launch paths can bypass that forwarding.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    /// Confirms unsaved work before an update download starts so termination
    /// during replacement cannot be cancelled mid-install.
    func prepareForUpdateInstall() -> Bool {
        guard let projectWindows else { return true }
        return Self.confirmUnsavedDocuments(
            for: projectWindows,
            context: .applicationTermination
        )
    }

    /// Starts the post-helper quit path used by the in-app updater.
    /// Skips cancelable prompts and bounds cleanup so replacement can proceed.
    func requestTerminationForUpdateInstall() {
        isUpdateInstallTermination = true
        updateForceExitTask?.cancel()
        updateForceExitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.updateTerminationForceExitNanoseconds)
            guard let self, self.isUpdateInstallTermination, !Task.isCancelled else { return }
            // Soft AppKit termination can stall on module shutdown; the staged
            // helper is already waiting and will replace the bundle after exit.
            Foundation.exit(EXIT_SUCCESS)
        }
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let projectWindows else { return .terminateNow }

        // AppKit may ask more than once while a previous asynchronous reply is
        // pending. Do not show another confirmation dialog or start a second
        // module shutdown graph in that interval. Once the cleanup reply has
        // been approved, allow AppKit's follow-up request to finish normally.
        switch terminationCleanupState {
        case .cleaning:
            return .terminateLater
        case .approved:
            return .terminateNow
        case .idle:
            break
        }

        if isUpdateInstallTermination {
            return beginTerminationCleanup(
                for: projectWindows,
                sender: sender,
                timeoutNanoseconds: Self.updateTerminationCleanupTimeoutNanoseconds
            )
        }

        return Self.confirmUnsavedDocuments(
            for: projectWindows,
            context: .applicationTermination
        ) ? beginTerminationCleanup(for: projectWindows, sender: sender) : .terminateCancel
    }

    private func beginTerminationCleanup(
        for projectWindows: ProjectWindowManager,
        sender: NSApplication,
        timeoutNanoseconds: UInt64? = nil
    ) -> NSApplication.TerminateReply {
        terminationCleanupState = .cleaning
        terminationCleanupTask = Task { @MainActor [weak self, projectWindows, sender] in
            if let timeoutNanoseconds {
                await Self.stopSessions(
                    projectWindows,
                    timingOutAfterNanoseconds: timeoutNanoseconds
                )
            } else {
                await projectWindows.stopAllSessions()
            }
            guard let self, self.terminationCleanupState == .cleaning else { return }
            self.terminationCleanupTask = nil
            self.terminationCleanupState = .approved
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private static func stopSessions(
        _ projectWindows: ProjectWindowManager,
        timingOutAfterNanoseconds timeoutNanoseconds: UInt64
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await projectWindows.stopAllSessions()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            }
            await group.next()
            group.cancelAll()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isUpdateInstallTermination = false
        updateForceExitTask?.cancel()
        updateForceExitTask = nil
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
        recordCleanPluginShutdown?()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let projectWindows else { return }
        Task { await projectWindows.resumeGitObservationAfterActivation() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleOpenedURLs(urls)
    }

    // Finder can deliver document-open Apple Events through these older
    // delegate methods, depending on whether the app was already running.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleOpenedURLs([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        handleOpenedURLs(filenames.map(URL.init(fileURLWithPath:)))
        sender.reply(toOpenOrPrint: .success)
    }

    @objc private func handleOpenDocuments(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor?
    ) {
        guard let fileList = event.paramDescriptor(forKeyword: keyDirectObject) else { return }

        var urls: [URL] = []
        guard fileList.numberOfItems > 0 else { return }
        for index in 1...fileList.numberOfItems {
            guard let aliasDescriptor = fileList.atIndex(index),
                  let fileURLDescriptor = aliasDescriptor.coerce(toDescriptorType: typeFileURL),
                  let url = URL(dataRepresentation: fileURLDescriptor.data, relativeTo: nil) else {
                continue
            }
            urls.append(url)
        }

        handleOpenedURLs(urls)
    }

    private func handleOpenedURLs(_ urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                if let projectWindows {
                    projectWindows.openStandaloneFile(url)
                } else if !pendingFileURLs.contains(where: {
                    $0.standardizedFileURL == url.standardizedFileURL
                }) {
                    pendingFileURLs.append(url.standardizedFileURL)
                }
            }
        }
    }

    static func confirmUnsavedDocuments(
        for documentOwner: any UnsavedDocumentHandling,
        context: UnsavedDocumentsConfirmationContext
    ) -> Bool {
        guard documentOwner.hasUnsavedDocuments else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = context.messageText
        alert.informativeText = documentOwner.unsavedDocumentNames.joined(separator: ", ")
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return documentOwner.saveAllDocuments()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

@main
struct LitheApp: App {
    @NSApplicationDelegateAdaptor(LitheAppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var projectWindows: ProjectWindowManager
    @StateObject private var windowPresentation: ProjectWindowPresentation
    @StateObject private var memoryUsageMonitor: MemoryUsageMonitor
    @StateObject private var frameRateMonitor = FrameRateMonitor()
    @StateObject private var updateChecker: UpdateChecker
    private let applicationLogWriter: MacApplicationLogWriter

    init() {
        let store = MacUserDefaultsStore()
        let settings = AppSettings(
            store: store,
            logDirectoryProvider: MacServiceContainer.makeLogDirectoryProvider()
        )
        let applicationLogWriter = MacServiceContainer.makeApplicationLogWriter()
        if !Self.redirectApplicationLogs(applicationLogWriter, to: settings.logDirectory),
           settings.customLogDirectory != nil {
            settings.setCustomLogDirectory(nil)
            _ = Self.redirectApplicationLogs(applicationLogWriter, to: settings.defaultLogDirectory)
        }
        settings.addLogDirectoryObserver { [weak settings] directory in
            guard !Self.redirectApplicationLogs(applicationLogWriter, to: directory),
                  settings?.customLogDirectory != nil else { return }
            settings?.setCustomLogDirectory(nil)
        }
        self.applicationLogWriter = applicationLogWriter
        let gitPerformanceLogger = MacGitPerformanceLogger(writer: applicationLogWriter)
        MacBundledFontRegistry.registerFonts { message in
            Self.appendApplicationLog(applicationLogWriter, message: message)
        }
        let processRegistry = ManagedProcessRegistry()
        let moduleStore = MacModuleConfigurationStore(store: store)
        let pluginRuntimeRecovery = MacPluginRuntimeRecoveryCoordinator()
        pluginRuntimeRecovery.recoverPreviousSession(using: moduleStore)
        _settings = StateObject(wrappedValue: settings)
        let projectWindows = ProjectWindowManager(
            settings: settings,
            modelFactory: {
                AppModel(
                    settings: settings,
                    services: MacServiceContainer(
                        store: store,
                        settings: settings,
                        processRegistry: processRegistry,
                        moduleLaunchMode: CommandLine.arguments.contains("--safe-mode")
                            ? .safeMode
                            : .normal,
                        moduleStore: moduleStore,
                        pluginRuntimeRecovery: pluginRuntimeRecovery,
                        gitPerformanceLogger: gitPerformanceLogger
                    ).services
                )
            }
        )
        if let startupProjectURL = Self.startupProjectURL {
            projectWindows.activeSessions.openStartupProject(startupProjectURL)
        }
        _projectWindows = StateObject(wrappedValue: projectWindows)
        _windowPresentation = StateObject(wrappedValue: ProjectWindowPresentation(manager: projectWindows))
        NSWindow.allowsAutomaticWindowTabbing = false
        _memoryUsageMonitor = StateObject(wrappedValue: MemoryUsageMonitor(
            startedAt: litheProcessLaunchDate,
            baselineReporter: { marker in
                Self.appendApplicationLog(applicationLogWriter, message: marker + "\n")
            },
            logsPerformanceBaseline: ProcessInfo.processInfo.environment["LITHE_PERFORMANCE_BASELINE"] == "1",
            processRegistry: processRegistry,
            memorySampler: MacProcessMemorySampler()
        ))
        let updateChecker = UpdateChecker()
        _updateChecker = StateObject(wrappedValue: updateChecker)
        appDelegate.projectWindows = projectWindows
        appDelegate.recordCleanPluginShutdown = {
            pluginRuntimeRecovery.recordCleanShutdown(using: moduleStore)
        }
        let appDelegate = appDelegate
        updateChecker.prepareForInstall = { [weak appDelegate] in
            appDelegate?.prepareForUpdateInstall() ?? true
        }
        updateChecker.requestTerminationForInstall = { [weak appDelegate] in
            appDelegate?.requestTerminationForUpdateInstall()
        }
    }

    private static func redirectApplicationLogs(
        _ writer: MacApplicationLogWriter,
        to directory: URL
    ) -> Bool {
        do {
            try writer.redirect(to: directory)
            return true
        } catch {
            let message = "Could not redirect Lithe logs to \(directory.path): \(error.localizedDescription)\n"
            if let data = message.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
            return false
        }
    }

    private static func appendApplicationLog(
        _ writer: MacApplicationLogWriter,
        message: String
    ) {
        do {
            try writer.append(message)
        } catch {
            let fallback = "Could not write Lithe log: \(error.localizedDescription)\n"
            if let data = fallback.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
    }

    private var model: AppModel { projectWindows.activeSessions.activeModel }

    var body: some Scene {
        WindowGroup("Lithe", id: LitheWindowID.workspace, for: UUID.self) { windowID in
            ProjectWindowScene(
                windows: projectWindows,
                presentation: windowPresentation,
                windowID: windowID.wrappedValue
            )
                .environmentObject(settings)
                .environmentObject(memoryUsageMonitor)
                .environmentObject(frameRateMonitor)
                .environmentObject(updateChecker)
                .environment(\.locale, settings.language.locale)
                // SwiftUI does not consistently re-resolve every existing
                // LocalizedStringKey when only the locale environment value
                // changes. Re-identify the root so a language selection takes
                // effect immediately across every workspace, including sheets.
                .id(settings.language)
                .preferredColorScheme(settings.themePreference.preferredColorScheme)
                .task {
                    memoryUsageMonitor.start()
                    frameRateMonitor.start()
                }
        } defaultValue: {
            projectWindows.defaultWindowID()
        }
        .defaultSize(
            width: LitheWindowLayout.welcomeContentSize.width,
            height: LitheWindowLayout.welcomeContentSize.height
        )
        .windowStyle(.hiddenTitleBar)
        .commands {
            LitheProjectCommands(
                projectWindows: projectWindows,
                windowPresentation: windowPresentation,
                updateChecker: updateChecker
            )
        }

        Window(settingsWindowTitle(for: settings.language), id: LitheWindowID.settings) {
            ProjectSettingsWindow(windows: projectWindows, settings: settings)
            .environmentObject(settings)
            .environmentObject(updateChecker)
            .environment(\.locale, settings.language.locale)
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.contentMinSize)
    }

    private static var startupProjectURL: URL? {
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--open-project"),
              CommandLine.arguments.indices.contains(flagIndex + 1) else { return nil }
        let url = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1]).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }


}

private struct ProjectSettingsWindow: View {
    @ObservedObject var windows: ProjectWindowManager
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsWindow(model: windows.activeSessions.activeModel, settings: settings)
            .id(windows.activeSessions.activeModel.id)
    }
}

private struct SettingsWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @StateObject private var windowReference = SettingsWindowReference()
    @StateObject private var viewState: SettingsViewState

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        _viewState = StateObject(wrappedValue: SettingsViewState(
            initialCategory: model.requestedSettingsCategory
        ))
    }

    var body: some View {
        SettingsAppearanceContainer(themePreference: settings.themePreference) {
            SettingsView(
                settings: settings,
                viewState: viewState,
                initialCategory: model.requestedSettingsCategory,
                onDismiss: close
            )
            .environmentObject(model)
        }
        .background(
            SettingsWindowAccessor(
                reference: windowReference,
                title: settingsWindowTitle(for: settings.language),
                themePreference: settings.themePreference
            )
        )
        .onAppear { windowReference.requestPresentation() }
        .onDisappear {
            model.isSettingsPresented = false
        }
        .onReceive(model.$isSettingsPresented) { isPresented in
            if isPresented { windowReference.requestPresentation() }
        }
    }

    private func close() {
        model.isSettingsPresented = false
        windowReference.window?.performClose(nil)
    }
}

struct SettingsAppearanceContainer<Content: View>: View {
    let themePreference: AppThemePreference
    let content: Content

    init(
        themePreference: AppThemePreference,
        @ViewBuilder content: () -> Content
    ) {
        self.themePreference = themePreference
        self.content = content()
    }

    var body: some View {
        content.preferredColorScheme(themePreference.preferredColorScheme)
    }
}

@MainActor
private final class SettingsWindowReference: ObservableObject {
    weak var window: NSWindow?
    private var presentationRequested = false

    func requestPresentation() {
        presentationRequested = true
        presentIfRequested()
    }

    func presentIfRequested() {
        guard presentationRequested, let window else { return }
        presentationRequested = false
        // A retained Settings window may belong to another display or Space.
        // Open it beside the requesting project instead of leaving it hidden.
        let projectWindow = NSApp.orderedWindows.first {
            $0 !== window && $0.isVisible && !$0.isMiniaturized && $0.level == .normal
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        if let projectWindow, let screen = projectWindow.screen {
            var frame = window.frame
            frame.origin = NSPoint(x: projectWindow.frame.midX - frame.width / 2,
                                   y: projectWindow.frame.midY - frame.height / 2)
            window.setFrame(LitheWindowLayout.frame(frame, fitting: screen.visibleFrame), display: false)
        }
        window.makeKeyAndOrderFront(nil)
    }
}

private final class SettingsTitlebarBackgroundView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class SettingsWindowProbe: NSView {
    var onEffectiveAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    let reference: SettingsWindowReference
    let title: String
    let themePreference: AppThemePreference

    func makeNSView(context: Context) -> SettingsWindowProbe {
        let view = SettingsWindowProbe(frame: .zero)
        bindAppearanceUpdates(to: view)
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ view: SettingsWindowProbe, context: Context) {
        bindAppearanceUpdates(to: view)
        configureWindow(for: view)
    }

    private func bindAppearanceUpdates(to view: SettingsWindowProbe) {
        view.onEffectiveAppearanceChange = { [weak view] in
            guard let view else { return }
            configureWindow(for: view)
        }
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            reference.window = window
            window.title = title
            window.level = .floating
            let windowAppearance = themePreference.windowAppearance
            if window.appearance?.name != windowAppearance?.name {
                window.appearance = windowAppearance
            }
            if window.contentView?.appearance?.name != windowAppearance?.name {
                window.contentView?.appearance = windowAppearance
            }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
            window.titlebarSeparatorStyle = .none
            window.isOpaque = true
            let settingsSurface = LitheTheme.settingsSurfaceNSColor(
                for: window.effectiveAppearance
            )
            window.backgroundColor = settingsSurface
            applySettingsSurface(toTitlebarOf: window, color: settingsSurface)
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
            window.standardWindowButton(.zoomButton)?.isEnabled = true
            reference.presentIfRequested()
        }
    }

    private func applySettingsSurface(toTitlebarOf window: NSWindow, color: NSColor) {
        // AppKit places the titlebar in multiple nested views. Styling only
        // the close-button's immediate superview leaves the opaque theme
        // frame above it untouched, which is the extra strip seen in the
        // settings window. Apply the same surface to each titlebar ancestor.
        var view = window.standardWindowButton(.closeButton)?.superview
        var titlebarHost: NSView?
        while let current = view, current !== window.contentView {
            current.wantsLayer = true
            current.layer?.backgroundColor = color.cgColor
            if current.bounds.width >= window.frame.width * 0.8,
               current.bounds.height <= 100 {
                titlebarHost = current
            }
            view = current.superview
        }

        guard let titlebarHost else { return }
        let backgroundView: SettingsTitlebarBackgroundView
        if let existing = titlebarHost.subviews.first(where: {
            $0 is SettingsTitlebarBackgroundView
        }) as? SettingsTitlebarBackgroundView {
            backgroundView = existing
        } else {
            backgroundView = SettingsTitlebarBackgroundView(frame: titlebarHost.bounds)
            titlebarHost.addSubview(backgroundView, positioned: .below, relativeTo: nil)
        }
        backgroundView.frame = titlebarHost.bounds
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = color.cgColor
    }
}

private func settingsWindowTitle(for language: AppLanguage) -> String {
    String(
        localized: "Settings",
        bundle: .main,
        locale: language.locale
    )
}

extension AppThemePreference {
    /// NSAppearance applied to app windows for the selected theme; `nil`
    /// means follow the system appearance. Shared by every presenting
    /// window, including the Go to Line dialog.
    var windowAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
