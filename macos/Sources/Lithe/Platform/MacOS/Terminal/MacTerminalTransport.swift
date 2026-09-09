import AppKit
import Darwin
import Foundation
import SwiftTerm
import LitheTerminalModule

/// Persistent renderer; each process launch is owned by a separate connection.
final class LitheTerminalView: SwiftTerm.TerminalView {
    private var showsWorkbenchBackground = false
    private weak var metalActivationFailedWindow: NSWindow?
    var copyOnSelect = false {
        didSet { if !copyOnSelect { selectionGesture = nil } }
    }
    var keepSelectionOnCopy = true
    private struct SelectionGesture {
        let range: TerminalSelectionRange?
        let buffer: Buffer
        let trimmedLines: Int
    }
    private var selectionGesture: SelectionGesture?
    private let linkActivation: MacTerminalLinkActivation
    private var mouseUpModifiers: NSEvent.ModifierFlags?

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, linkActivation: MacTerminalLinkActivation())
    }

    init(frame frameRect: NSRect, linkActivation: MacTerminalLinkActivation) {
        self.linkActivation = linkActivation
        super.init(frame: frameRect)
        configureRendererPolicy()
    }

    required init?(coder: NSCoder) {
        linkActivation = MacTerminalLinkActivation()
        super.init(coder: coder)
        configureRendererPolicy()
    }

    override func viewDidMoveToWindow() {
        cancelMouseInteraction()
        super.viewDidMoveToWindow()
        guard let currentWindow = window,
              !isUsingMetalRenderer,
              currentWindow !== metalActivationFailedWindow else { return }

        do {
            try setUseMetal(true)
            metalActivationFailedWindow = nil
        } catch {
            // A different window gets one fresh attempt because SwiftTerm's
            // CAMetalLayer must be rebound when the persistent terminal moves.
            metalActivationFailedWindow = currentWindow
            NSLog(
                "Lithe terminal Metal renderer could not be enabled; using Core Graphics: %@",
                String(describing: error)
            )
        }
    }

    func cancelMouseInteraction() {
        selectionGesture = nil
        linkActivation.cancel()
        cancelMouseGesture()
    }

    func activateLink(_ action: @escaping @MainActor @Sendable () -> Void) {
        selectionGesture = nil
        if let mouseUpModifiers, !mouseUpModifiers.contains(.command) {
            linkActivation.submit(action)
        } else {
            action()
        }
    }

    override func bufferActivated(source: Terminal) {
        cancelMouseInteraction()
        super.bufferActivated(source: source)
    }

    private func reportsMouse(_ event: NSEvent) -> Bool {
        let bypass = event.modifierFlags.contains(.shift) && !terminal.mouseShiftCapture
        return allowMouseReporting && terminal.mouseMode != .off && !bypass
    }

    override func mouseDown(with event: NSEvent) {
        // Metal's drawing subview forwards clicks without transferring the
        // keyboard responder from an editor that previously had focus.
        if let window, window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        cancelMouseInteraction()
        if copyOnSelect && !reportsMouse(event) {
            selectionGesture = SelectionGesture(range: selectionRange, buffer: terminal.buffer,
                                                trimmedLines: terminal.buffer.totalLinesTrimmed)
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        linkActivation.cancel()
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseUpModifiers = event.modifierFlags
        defer { selectionGesture = nil; mouseUpModifiers = nil }
        super.mouseUp(with: event)
        // Link handling, buffer changes, and settings changes may synchronously
        // cancel this gesture while the native mouseUp is running.
        guard copyOnSelect, !reportsMouse(event), let gesture = selectionGesture,
              gesture.buffer === terminal.buffer,
              gesture.trimmedLines == terminal.buffer.totalLinesTrimmed,
              let range = selectionRange, range != gesture.range,
              let text = getSelection(), !text.isEmpty else { return }
        super.copy(self)
    }

    override func copy(_ sender: Any) {
        super.copy(sender)
        if !keepSelectionOnCopy {
            cancelMouseInteraction()
            selectNone()
        }
    }

    private func configureRendererPolicy() {
        // Ghostty's renderer keeps unchanged terminal content on the GPU and
        // redraws only invalidated cells. SwiftTerm's persistent row mode gives
        // Lithe the same workload shape while its paused MTKView remains
        // event-driven instead of running a continuous display loop.
        metalBufferingMode = .perRowPersistent
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let window else { return nil }
        LitheContextMenuPresenter.shared.show(
            items: [
                .action("Paste") { [weak self] in if let self { self.paste(self) } },
                .action("Copy") { [weak self] in if let self { self.copy(self) } },
                .action("Select All") { [weak self] in if let self { self.selectAll(self) } }
            ],
            at: window.convertPoint(toScreen: event.locationInWindow),
            appearance: effectiveAppearance,
            locale: .current
        )
        return nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColors()
    }

    func applyThemeColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        nativeBackgroundColor = LitheTheme.nsColor(.editor, isDark: isDark)
            .withAlphaComponent(showsWorkbenchBackground ? 0 : 1)
        nativeForegroundColor = isDark
            ? NSColor(srgbRed: 0.86, green: 0.87, blue: 0.89, alpha: 1)
            : NSColor(srgbRed: 0.15, green: 0.16, blue: 0.18, alpha: 1)
        caretColor = isDark
            ? NSColor(srgbRed: 0.35, green: 0.67, blue: 0.98, alpha: 1)
            : NSColor(srgbRed: 0.18, green: 0.43, blue: 0.79, alpha: 1)
        selectedTextBackgroundColor = isDark
            ? NSColor(srgbRed: 0.16, green: 0.31, blue: 0.48, alpha: 1)
            : NSColor(srgbRed: 0.69, green: 0.82, blue: 0.98, alpha: 1)
        needsDisplay = true
    }

    func setWorkbenchBackgroundVisible(_ isVisible: Bool) {
        guard showsWorkbenchBackground != isVisible else { return }
        showsWorkbenchBackground = isVisible
        applyThemeColors()
    }

    func terminalWindowSize() -> winsize {
        let cell = cellSizeInPixels(source: terminal)
        return winsize(
            ws_row: UInt16(clamping: terminal.rows), ws_col: UInt16(clamping: terminal.cols),
            ws_xpixel: UInt16(clamping: (cell?.width ?? 0) * terminal.cols),
            ws_ypixel: UInt16(clamping: (cell?.height ?? 0) * terminal.rows)
        )
    }
}

extension LitheTerminalView: WorkbenchBackgroundRendering {}

/// Owns one persistent SwiftTerm surface and the local PTY process connected to it.
/// The surface intentionally lives with the session instead of the SwiftUI view so
/// switching terminal tabs or hiding the tool window does not reset a TUI screen.
@MainActor
final class MacTerminalTransport: NSObject, TerminalTransport, @preconcurrency TerminalViewDelegate {
    static func availableShells(fileManager: FileManager = .default) -> [String] {
        MacTerminalShellDiscovery.availableShells(fileManager: fileManager)
    }
    let view: LitheTerminalView

    var onTermination: ((Int32?) -> Void)?
    var onOutput: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectoryUpdate: ((String?) -> Void)?
    var onLink: ((String, [String: String]) -> Void)?
    var onVirtualEnvironmentState: ((TerminalVirtualEnvironmentState) -> Void)?

    private var selectedShellPath: String?
    private let stoppedChildProcessReaper = MacStoppedChildProcessReaper()
    private var processSession: MacTerminalProcessSession?
    private var connection: MacTerminalProcessConnection?
    private var preparationID: UUID?
    private var cancelPreparation: (() -> Void)?
    private var activation: VirtualEnvironmentActivation?
    private var cancelActivationTimeout: (() -> Void)?
    private let virtualEnvironmentProbe: MacTerminalVirtualEnvironmentProbe
    private let inheritedEnvironment: () -> [String: String]
    private let scheduleActivationTimeout: (@escaping @MainActor @Sendable () -> Void) -> () -> Void
    private struct VirtualEnvironmentActivation {
        let nonce: String
        let path: String
        var processID: Int32?
        var ready = false
        var earlyPayload: String?
        var activated = false
    }
    private struct Typography: Equatable {
        let name: String?
        let size: Double
        let fallbacks: [String]
        let spacing: Double

        init(_ configuration: TerminalDisplayConfiguration) {
            name = configuration.fontName
            size = configuration.fontSize
            fallbacks = configuration.fallbackFontNames
            spacing = configuration.lineSpacing
        }
    }
    private var appliedTypography: Typography?
    private var preferredCursor: CursorStyle?

    var isRunning: Bool {
        connection?.process.running ?? false
    }

    var processID: Int32? {
        let processID = connection?.process.shellPid ?? 0
        return processID > 0 ? processID : nil
    }

    var shellName: String {
        guard let selectedShellPath else { return "Shell" }
        return URL(fileURLWithPath: selectedShellPath).lastPathComponent
    }

    var nativeView: AnyObject { view }

    override convenience init() {
        self.init(linkActivation: MacTerminalLinkActivation())
    }

    init(linkActivation: MacTerminalLinkActivation,
         virtualEnvironmentProbe: MacTerminalVirtualEnvironmentProbe? = nil,
         inheritedEnvironment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
         scheduleActivationTimeout: ((@escaping @MainActor @Sendable () -> Void) -> () -> Void)? = nil) {
        self.virtualEnvironmentProbe = virtualEnvironmentProbe ?? .shared
        self.inheritedEnvironment = inheritedEnvironment
        self.scheduleActivationTimeout = scheduleActivationTimeout ?? { action in
            let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + MacTerminalShellIntegration.acknowledgmentTimeout, execute: item)
            return { item.cancel() }
        }
        view = LitheTerminalView(frame: .zero, linkActivation: linkActivation)
        super.init()

        view.terminalDelegate = self
        view.font = Self.preferredTerminalFont()
        view.applyThemeColors()
        view.allowMouseReporting = true
        view.linkReporting = .implicit
        view.linkHighlightMode = .hoverWithModifier

        var options = view.terminal.options
        options.termName = "xterm-256color"
        options.scrollback = 2_000
        view.terminal.options = options
        view.terminal.setup(isReset: false)
        view.terminal.registerOscHandler(code: MacTerminalShellIntegration.oscCode) { [weak self] payload in
            guard payload.count <= MacTerminalShellIntegration.maximumPayloadBytes,
                  let value = String(bytes: payload, encoding: .ascii) else { return }
            self?.receiveVirtualEnvironmentAcknowledgment(value)
        }
    }

    private static func preferredTerminalFont(size: CGFloat = 13) -> NSFont {
        let fontNames = [
            "MesloLGS NF",
            "MesloLGS Nerd Font Mono",
            "JetBrainsMono Nerd Font Mono",
            "Hack Nerd Font Mono",
            "FiraCode Nerd Font Mono",
            "IosevkaTerm Nerd Font Mono",
            "Menlo"
        ]

        for name in fontNames {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func applyDisplayConfiguration(_ configuration: TerminalDisplayConfiguration) -> [String] {
        var diagnostics = applyTypography(configuration)
        if let error = configuration.scrollbackValidationMessage {
            diagnostics.append(error)
        } else if view.terminal.options.scrollback != configuration.scrollback {
            if configuration.scrollback < view.terminal.options.scrollback {
                view.cancelMouseInteraction()
                view.selectNone()
            }
            view.changeScrollback(configuration.scrollback == 0 ? nil : configuration.scrollback)
        }
        if let error = configuration.scrollSensitivityValidationMessage {
            diagnostics.append(error)
        } else {
            view.scrollSensitivity = CGFloat(configuration.scrollSensitivity)
        }
        let cursor = cursorStyle(configuration)
        if preferredCursor != cursor {
            preferredCursor = cursor
            view.terminal.setCursorStyle(cursor)
        }
        view.optionAsMetaKey = configuration.optionAsMeta
        view.copyOnSelect = configuration.copyOnSelect
        view.keepSelectionOnCopy = configuration.keepSelectionOnCopy
        let reporting: LinkReporting
        switch configuration.linkDetection {
        case .automatic: reporting = .implicit
        case .explicit: reporting = .explicit
        case .disabled: reporting = .none
        }
        let highlighting: LinkHighlightMode = configuration.linkModifier == .command ? .hoverWithModifier : .hover
        if reporting != view.linkReporting || highlighting != view.linkHighlightMode {
            view.cancelMouseInteraction()
            view.linkReporting = reporting
            view.linkHighlightMode = highlighting
        }
        return diagnostics
    }

    private func cursorStyle(_ configuration: TerminalDisplayConfiguration) -> CursorStyle {
        switch (configuration.cursorShape, configuration.cursorBlink) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        }
    }

    private func applyTypography(_ configuration: TerminalDisplayConfiguration) -> [String] {
        if let error = configuration.typographyValidationMessage { return [error] }
        let typography = Typography(configuration)
        guard appliedTypography != typography else { return [] }
        let size = CGFloat(configuration.fontSize)
        let base: NSFont
        if let name = configuration.fontName {
            guard let resolved = NSFont(name: name, size: size), resolved.fontName == name else {
                return ["Terminal font settings were not applied because a font is unavailable. Choose installed fonts and retry."]
            }
            base = resolved
        } else {
            base = Self.preferredTerminalFont(size: size)
        }
        var fallbackDescriptors: [NSFontDescriptor] = []
        for name in configuration.fallbackFontNames {
            guard let font = NSFont(name: name, size: size), font.fontName == name else {
                return ["Terminal font settings were not applied because a font is unavailable. Choose installed fonts and retry."]
            }
            fallbackDescriptors.append(font.fontDescriptor)
        }
        let descriptor = fallbackDescriptors.isEmpty ? base.fontDescriptor
            : base.fontDescriptor.addingAttributes([.cascadeList: fallbackDescriptors])
        guard let font = NSFont(descriptor: descriptor, size: size) else {
            return ["Terminal font settings could not be applied. Choose installed fonts and retry."]
        }
        view.cancelMouseInteraction()
        view.updateTypography(font: font, lineSpacing: CGFloat(configuration.lineSpacing))
        // Failed resolution never advances this cache, so Retry can apply an
        // unchanged request after the font becomes available.
        appliedTypography = typography
        return []
    }

    func defaultShellPath() -> String {
        inheritedEnvironment()["SHELL"] ?? "/bin/zsh"
    }

    func defaultEnvironment() -> [String: String] {
        inheritedEnvironment()
    }

    func prepareShellLaunch(
        _ configuration: TerminalShellConfiguration,
        context: TerminalLaunchContext
    ) throws -> TerminalShellLaunch {
        let plan = try configuration.launchPlan(
            context: context, systemShell: defaultShellPath(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            inheritedEnvironment: defaultEnvironment()
        )
        try validateWorkingDirectory(plan.process.workingDirectory)
        let executable = try resolveExecutablePath(
            plan.process.executablePath,
            workingDirectory: plan.process.workingDirectory,
            environment: plan.environment
        )
        return TerminalShellLaunch(
            process: TerminalProcessLaunch(
                title: nil, executablePath: executable, arguments: plan.process.arguments,
                workingDirectory: plan.process.workingDirectory
            ),
            environment: plan.environment, virtualEnvironment: plan.virtualEnvironment
        )
    }

    func startShell(_ launch: TerminalShellLaunch,
                    completion: @escaping @MainActor (TerminalShellLaunch, Result<Int32, any Error>) -> Void) {
        stop()
        let id = UUID()
        preparationID = id
        func finish(_ resolved: TerminalShellLaunch, path: String? = nil,
                    state: TerminalVirtualEnvironmentState = .inactive) {
            guard preparationID == id else { return }
            preparationID = nil; cancelPreparation = nil
            var process = resolved.process, environment = resolved.environment
            var pending: VirtualEnvironmentActivation?
            var state = state
            if let path {
                let nonce = UUID().uuidString
                if let integrated = MacTerminalShellIntegration.prepare(resolved, path: path, nonce: nonce,
                                                                        resources: MacTerminalShellIntegration.directory) {
                    process = integrated.process; environment = integrated.environment
                    pending = .init(nonce: nonce, path: path)
                    state = .activating(path)
                } else { state = .skipped(.integrationUnavailable) }
            }
            let result = Result {
                try launchProcess(process, environment: environment,
                                  displayShellPath: resolved.process.executablePath, activation: pending)
            }
            let source = connection
            if case .failure = result { onVirtualEnvironmentState?(.inactive) }
            // Publish the frozen decision before an ACK can advance the UI.
            completion(resolved, result)
            guard let source, connection === source else { return }
            onVirtualEnvironmentState?(state)
            guard connection === source else { return }
            if activation != nil {
                activation?.ready = true
                cancelActivationTimeout = scheduleActivationTimeout { [weak self, weak source] in
                    guard let self, let source, self.connection === source,
                          let activation = self.activation, !activation.activated else { return }
                    self.cancelActivationTimeout = nil
                    self.onVirtualEnvironmentState?(.unconfirmed(activation.path))
                }
                if let early = activation?.earlyPayload { receiveVirtualEnvironmentAcknowledgment(early) }
            }
        }
        switch launch.virtualEnvironment {
        case .disabled, .notFound: finish(launch); return
        case .preserveExisting: finish(launch, state: .skipped(.existingEnvironment)); return
        case .unknown: finish(launch, state: .skipped(.discoveryUnavailable)); return
        case .discover, .selected: break
        }
        guard MacTerminalShellIntegration.shell(for: launch.process) != nil else {
            let frozen: TerminalShellLaunch
            if case .discover = launch.virtualEnvironment { frozen = launch.selectingVirtualEnvironment(.unknown) }
            else { frozen = launch }
            finish(frozen, state: .skipped(.unsupportedShell)); return
        }
        let paths: [String]
        if case .selected(let path) = launch.virtualEnvironment { paths = [path] }
        else if case .discover(let candidates) = launch.virtualEnvironment {
            paths = candidates.map { URL(fileURLWithPath: launch.process.workingDirectory).appendingPathComponent($0).path }
        } else { paths = [] }
        onVirtualEnvironmentState?(.detecting)
        guard preparationID == id else { return }
        let cancel = virtualEnvironmentProbe.check(paths) { [weak self] result in
            guard let self, self.preparationID == id else { return }
            let selected: Bool
            if case .selected = launch.virtualEnvironment { selected = true } else { selected = false }
            switch result {
            case .found(let path): finish(launch.selectingVirtualEnvironment(.selected(path)), path: path)
            case .missing:
                finish(selected ? launch : launch.selectingVirtualEnvironment(.notFound),
                       state: selected ? .skipped(.unavailable) : .inactive)
            case .unknown, .unsupportedPath:
                finish(selected ? launch : launch.selectingVirtualEnvironment(.unknown),
                       state: .skipped(result == .unsupportedPath ? .unsupportedPath : .discoveryUnavailable))
            }
        }
        if preparationID == id { cancelPreparation = cancel } else { cancel() }
    }

    private func receiveVirtualEnvironmentAcknowledgment(_ value: String) {
        guard var current = activation else { return }
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "1", fields[1] == current.nonce,
              let pid = Int32(fields[2]), pid == processID else { return }
        guard current.ready else {
            current.earlyPayload = value; activation = current; return
        }
        guard isRunning, pid == current.processID else { return }
        let state: TerminalVirtualEnvironmentState
        switch fields[3] {
        case "activated" where !current.activated:
            current.activated = true; state = .activated(current.path)
        case "deactivated" where current.activated:
            state = .deactivated
        case "existing" where !current.activated: state = .skipped(.existingEnvironment)
        case "missing" where !current.activated: state = .skipped(.unavailable)
        case "configuration" where !current.activated: state = .skipped(.shellConfiguration)
        default: return
        }
        cancelActivationTimeout?(); cancelActivationTimeout = nil
        current.earlyPayload = nil
        activation = state == .activated(current.path) ? current : nil
        onVirtualEnvironmentState?(state)
    }

    func start(
        workingDirectory: String,
        shellPath: String,
        environment: [String: String]
    ) throws {
        _ = try startProcess(
            TerminalProcessLaunch(
                title: nil,
                executablePath: shellPath,
                arguments: MacTerminalShellDiscovery.startupArguments(for: shellPath),
                workingDirectory: workingDirectory
            ),
            environment: environment
        )
    }

    func startProcess(
        _ launch: TerminalProcessLaunch,
        environment: [String: String]
    ) throws -> Int32 {
        try launchProcess(launch, environment: environment)
    }

    private func launchProcess(_ launch: TerminalProcessLaunch, environment: [String: String],
                               displayShellPath: String? = nil,
                               activation: VirtualEnvironmentActivation? = nil) throws -> Int32 {
        let executablePath = try resolveExecutablePath(
            launch.executablePath,
            workingDirectory: launch.workingDirectory,
            environment: environment
        )
        try validateWorkingDirectory(launch.workingDirectory)
        stop()
        selectedShellPath = displayShellPath ?? executablePath
        self.activation = activation

        view.cancelMouseInteraction()
        view.terminal.resetToInitialState()
        var options = view.terminal.options
        options.termName = environment["TERM"] ?? "xterm-256color"
        view.terminal.options = options
        view.terminal.setup(isReset: false)
        if let preferredCursor { view.terminal.setCursorStyle(preferredCursor) }

        let environmentArray = environment.keys.sorted().map { key in
            "\(key)=\(environment[key] ?? "")"
        }

        let connection = MacTerminalProcessConnection(view: view)
        self.connection = connection
        connection.onOutput = { [weak self] source, data in
            guard let self, self.connection === source else { return }
            self.onOutput?(Data(data))
            // Client callbacks may synchronously restart the terminal.
            guard self.connection === source else { return }
            self.view.feed(byteArray: data)
        }
        connection.onTermination = { [weak self] source, exitCode in
            guard let self, self.connection === source else { return }
            self.activation = nil
            self.cancelActivationTimeout?(); self.cancelActivationTimeout = nil
            self.onVirtualEnvironmentState?(.inactive)
            guard self.connection === source else { return }
            self.onTermination?(exitCode)
        }
        connection.process.startProcess(
            executable: executablePath,
            args: launch.arguments,
            environment: environmentArray,
            currentDirectory: launch.workingDirectory
        )

        guard connection.process.running, let processID else {
            stop()
            throw terminalError("Unable to start \(executablePath)")
        }
        processSession = MacTerminalProcessSession(processID: processID)
        self.activation?.processID = processID
        return processID
    }

    func send(_ input: Data) throws {
        guard isRunning else { return }
        connection?.process.send(data: Array(input)[...])
    }

    func interrupt() throws {
        guard isRunning else { return }
        connection?.process.send(data: [UInt8(0x03)][...])
    }

    func focus() {
        guard let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    func clear() {
        view.cancelMouseInteraction()
        view.terminal.resetToInitialState()
    }

    func stop() {
        preparationID = nil
        let cancel = cancelPreparation; cancelPreparation = nil
        cancel?()
        activation = nil
        cancelActivationTimeout?(); cancelActivationTimeout = nil
        view.cancelMouseInteraction()
        guard let connection else { return }
        let processID = connection.process.shellPid
        let ownedSession = processSession
        self.connection = nil
        processSession = nil
        connection.invalidate()
        if let ownedSession {
            ownedSession.terminate { connection.process.terminate() }
        } else if connection.process.running {
            connection.process.terminate()
        }
        if processID > 0 { stoppedChildProcessReaper.reapWhenExited(processID) }
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        guard isRunning, let process = connection?.process, process.childfd >= 0 else { return }
        var size = view.terminalWindowSize()
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        onDirectoryUpdate?(directory)
    }

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        guard isRunning else { return }
        connection?.process.send(data: data)
    }

    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        view.activateLink { [weak self] in self?.onLink?(link, params) }
    }

    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        guard let string = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([string as NSString])
    }

    func clipboardRead(source: SwiftTerm.TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }

    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

    func resolveExecutablePath(
        _ executablePath: String,
        workingDirectory: String,
        environment: [String: String]
    ) throws -> String {
        let fileManager = FileManager.default
        let candidate: String?
        if executablePath.contains("/") {
            let url = executablePath.hasPrefix("/")
                ? URL(fileURLWithPath: executablePath)
                : URL(fileURLWithPath: workingDirectory, isDirectory: true)
                    .appendingPathComponent(executablePath)
            candidate = url.standardizedFileURL.path
        } else {
            candidate = environment["PATH"]?
                .split(separator: ":", omittingEmptySubsequences: false)
                .map(String.init)
                .map { directory in
                    (directory.hasPrefix("/")
                        ? URL(fileURLWithPath: directory, isDirectory: true)
                        : URL(fileURLWithPath: workingDirectory, isDirectory: true).appendingPathComponent(directory, isDirectory: true))
                        .appendingPathComponent(executablePath)
                        .standardizedFileURL.path
                }
                .first { isExecutableFile($0, fileManager: fileManager) }
        }
        guard let candidate, isExecutableFile(candidate, fileManager: fileManager) else {
            throw terminalError("The terminal executable is unavailable: \(executablePath)")
        }
        return candidate
    }

    private func isExecutableFile(_ path: String, fileManager: FileManager) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolved),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return fileManager.isExecutableFile(atPath: resolved)
    }

    private func validateWorkingDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw terminalError("The terminal working directory does not exist: \(path)")
        }
        // SwiftTerm does not report child-side chdir failures. Reject known
        // inaccessible directories before forkpty instead of executing in the
        // app's directory. A concurrent permission/path change remains a
        // limitation until the transport has a child startup error channel.
        guard Darwin.access(path, X_OK) == 0 else {
            throw terminalError("The terminal working directory is inaccessible: \(path)")
        }
    }

    private func terminalError(_ message: String) -> NSError {
        NSError(
            domain: "Lithe.Terminal",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
