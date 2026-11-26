import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Lithe

@Suite("Workbench tab hit-testing and Go environment resolution", .serialized)
struct WorkbenchTabCloseAndGoEnvTests {
    @Test
    func framedLoginShellEnvironmentStripsStartupNoiseAndAppliesAllowlist() {
        let output = [
            "Welcome to interactive zsh\n",
            MacLoginShellEnvironmentCache.startMarker,
            "GOPATH=/custom/gopath",
            "GOMODCACHE=/custom/gopath/pkg/mod",
            "GOROOT=/opt/go",
            "PATH=/opt/homebrew/bin:/usr/bin",
            "API_SECRET_TOKEN=must-not-leak",
            "UNRELATED_VAR=ignored",
            MacLoginShellEnvironmentCache.endMarker,
            "\ntrailing noise"
        ].joined(separator: "\0")

        let parsed = MacLoginShellEnvironmentCache.parseFramedEnvironment(output)
        #expect(parsed["GOPATH"] == "/custom/gopath")
        #expect(parsed["GOMODCACHE"] == "/custom/gopath/pkg/mod")
        #expect(parsed["GOROOT"] == "/opt/go")
        #expect(parsed["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(parsed["API_SECRET_TOKEN"] == nil)
        #expect(parsed["UNRELATED_VAR"] == nil)
    }

    @Test
    func goEnvFileParserReadsOnlySafeGoPathKeys() {
        let content = """
        # Comment line
        GOPATH="/custom/go-from-env"
        GOMODCACHE='/custom/mod-cache'
        GOCACHE=/custom/build-cache
        GOROOT=/custom/goroot
        GOPROXY=https://proxy.example.com,direct
        GONOPROXY=none
        GOFLAGS=-mod=mod
        """

        let parsed = MacLoginShellEnvironmentCache.parseGoEnvFile(content)
        #expect(parsed == [
            "GOPATH": "/custom/go-from-env",
            "GOMODCACHE": "/custom/mod-cache",
            "GOCACHE": "/custom/build-cache",
            "GOROOT": "/custom/goroot"
        ])
    }

    @Test
    func macRuntimeLocatorPrefersProcessThenLoginShellThenGoEnvThenHomeDefault() {
        let fakeHome = URL(fileURLWithPath: "/Users/fake")
        let homeGo = fakeHome.appendingPathComponent("go").path

        // 1. Finder-like launch: ~/go exists on disk, but login shell sets a custom GOPATH.
        let fromShell = MacRuntimeLocator(
            homeDirectoryURL: fakeHome,
            baseEnvironmentProvider: { ["HOME": fakeHome.path, "PATH": "/usr/bin:/bin"] },
            shellEnvironmentProvider: {
                [
                    "GOPATH": "/workspace-cache/gopath",
                    "PATH": "/opt/homebrew/bin:/usr/bin:/custom/bin"
                ]
            },
            prepareShellEnvironment: {},
            goEnvFileProvider: { _ in "GOPATH=/from-go-env\nGOMODCACHE=/from-go-env/pkg/mod\n" },
            fileExists: { $0 == homeGo },
            isExecutableCheck: { _ in false }
        ).environment()
        #expect(fromShell["GOPATH"] == "/workspace-cache/gopath")
        #expect(fromShell["GOMODCACHE"] == "/from-go-env/pkg/mod")
        #expect(fromShell["PATH"] == "/usr/bin:/bin:/opt/homebrew/bin:/custom/bin")

        // 2. Explicit process environment always wins over login shell and go/env.
        let fromProcess = MacRuntimeLocator(
            homeDirectoryURL: fakeHome,
            baseEnvironmentProvider: { ["HOME": fakeHome.path, "GOPATH": "/explicit/gopath"] },
            shellEnvironmentProvider: { ["GOPATH": "/shell/gopath"] },
            prepareShellEnvironment: {},
            goEnvFileProvider: { _ in "GOPATH=/file/gopath\n" },
            fileExists: { $0 == homeGo },
            isExecutableCheck: { _ in false }
        ).environment()
        #expect(fromProcess["GOPATH"] == "/explicit/gopath")

        // 3. When shell has no GOPATH, go/env file still wins over ~/go fallback.
        let fromGoEnv = MacRuntimeLocator(
            homeDirectoryURL: fakeHome,
            baseEnvironmentProvider: { ["HOME": fakeHome.path] },
            shellEnvironmentProvider: { [:] },
            prepareShellEnvironment: {},
            goEnvFileProvider: { _ in "GOPATH=/configured-via-go-env\n" },
            fileExists: { $0 == homeGo },
            isExecutableCheck: { _ in false }
        ).environment()
        #expect(fromGoEnv["GOPATH"] == "/configured-via-go-env")

        // 4. Only when neither process, shell, nor go/env specifies GOPATH does ~/go apply.
        let fromHomeFallback = MacRuntimeLocator(
            homeDirectoryURL: fakeHome,
            baseEnvironmentProvider: { ["HOME": fakeHome.path] },
            shellEnvironmentProvider: { [:] },
            prepareShellEnvironment: {},
            goEnvFileProvider: { _ in nil },
            fileExists: { $0 == homeGo },
            isExecutableCheck: { _ in false }
        ).environment()
        #expect(fromHomeFallback["GOPATH"] == homeGo)
    }

    @Test
    func loginShellEnvironmentCacheProbesOnceAndResumesWaiters() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }
        let counter = Counter()
        let cache = MacLoginShellEnvironmentCache(
            shouldProbe: { true },
            probe: {
                counter.increment()
                return ["GOPATH": "/resolved/gopath"]
            }
        )

        async let first: Void = cache.awaitReady()
        async let second: Void = cache.awaitReady()
        _ = await (first, second)

        #expect(counter.count == 1)
        #expect(cache.cachedEnvironment()["GOPATH"] == "/resolved/gopath")
    }

    /// Regression for macOS 26/27 top-edge horizontal ScrollView safe-area bleed:
    /// a 1pt non-interactive barrier under the .fullSizeContentView titlebar keeps
    /// DocumentView aligned with HostingScrollView so clicking the tab close button
    /// reaches SwiftUI instead of hitting NSClipView.
    @Test
    @MainActor
    func workbenchTopSafeAreaBarrierKeepsHorizontalScrollTabCloseButtonClickable() {
        final class CloseRecorder: ObservableObject {
            @Published var closedCount = 0
        }

        struct TabBarHarness: View {
            @ObservedObject var recorder: CloseRecorder

            var body: some View {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 1)
                        .allowsHitTesting(false)
                    GeometryReader { _ in
                        VStack(spacing: 0) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 0) {
                                    Text(".gitignore")
                                        .padding(.leading, 12)
                                        .frame(height: LitheTheme.Metrics.tabHeight)
                                    Button {
                                        recorder.closedCount += 1
                                    } label: {
                                        Image(systemName: "xmark")
                                            .frame(width: 20, height: 20)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(LitheTreeRowButtonStyle())
                                    .padding(.trailing, 8)
                                }
                            }
                            .frame(height: LitheTheme.Metrics.tabHeight)
                            .clipped()
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        _ = NSApplication.shared
        let recorder = CloseRecorder()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Programmatic NSWindows default to `isReleasedWhenClosed = true`, which
        // over-releases an ARC-owned instance when `close()` runs during teardown.
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.toolbar = nil
            window.close()
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        let toolbar = NSToolbar(identifier: "lithe-tab-hit-test-\(UUID().uuidString)")
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        let titlebarHost = NSHostingView(rootView: HStack { Text("Titlebar"); Spacer() }.frame(height: LitheTheme.Metrics.toolbarHeight))
        titlebarHost.sizingOptions = []
        titlebarHost.setFrameSize(NSSize(width: 524, height: LitheTheme.Metrics.toolbarHeight))
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = titlebarHost
        window.addTitlebarAccessoryViewController(accessory)

        let host = NSHostingView(rootView: TabBarHarness(recorder: recorder))
        host.frame = NSRect(origin: .zero, size: window.frame.size)
        window.contentView = host
        window.orderBack(nil)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        guard let root = window.contentView?.superview else {
            Issue.record("Missing window frame root view")
            return
        }

        func firstView(in view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
            if predicate(view) { return view }
            for subview in view.subviews {
                if let match = firstView(in: subview, matching: predicate) { return match }
            }
            return nil
        }

        let scrollView = firstView(in: root) { $0 is NSScrollView }
        let documentView = (scrollView as? NSScrollView)?.documentView
        #expect(scrollView != nil)
        #expect(documentView != nil)

        if let scrollView, let documentView {
            let scrollFrame = scrollView.convert(scrollView.bounds, to: root)
            let docFrame = documentView.convert(documentView.bounds, to: root)
            // ScrollView must NOT expand vertically into the titlebar safe area,
            // and DocumentView must share the same vertical band as the tab bar.
            #expect(abs(scrollFrame.height - LitheTheme.Metrics.tabHeight) < 1.5)
            #expect(abs(docFrame.minY - scrollFrame.minY) < 1.5)
            #expect(abs(docFrame.maxY - scrollFrame.maxY) < 1.5)

            let closeCenter = NSPoint(x: docFrame.maxX - 18, y: docFrame.midY)
            let hit = root.hitTest(closeCenter)
            #expect(hit != nil)
            if let hit {
                #expect(hit === documentView || hit.isDescendant(of: documentView))
            }

            let down = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: closeCenter,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )!
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: closeCenter,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 0
            )!
            window.sendEvent(down)
            window.sendEvent(up)
            #expect(recorder.closedCount == 1)
        }
    }
}
