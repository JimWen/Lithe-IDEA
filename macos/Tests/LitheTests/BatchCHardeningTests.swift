import AppKit
import Foundation
import LitheCoreContracts
import LitheSearchModule
import Testing
@testable import Lithe

@MainActor
@Suite("Batch C focus, syntax, relevance, and platform hardening")
struct BatchCHardeningTests {
    @Test
    func focusHandoffBuffersTypingCancelsOnEscapeAndReplaysInOrder() throws {
        var currentTime = Date(timeIntervalSince1970: 1_000)
        let coordinator = MacFocusHandoffCoordinator(
            timeout: 0.25,
            now: { currentTime },
            installsEventMonitor: false
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let targetField = NSTextField(frame: NSRect(x: 0, y: 100, width: 100, height: 24))
        window.contentView?.addSubview(editor)
        window.contentView?.addSubview(targetField)
        window.makeFirstResponder(editor)
        #expect(window.firstResponder === editor)

        coordinator.begin(to: .searchEverywhere, in: window)
        // Synchronously detaches the editor so no keystroke can leak into it.
        #expect(window.firstResponder !== editor)

        let keyM = try makeKeyEvent(characters: "m", keyCode: 46, modifiers: [], windowNumber: window.windowNumber)
        let keyA = try makeKeyEvent(characters: "A", keyCode: 0, modifiers: [.shift], windowNumber: window.windowNumber)
        #expect(coordinator.intercept(keyM) == nil)
        #expect(coordinator.intercept(keyA) == nil)
        #expect(coordinator.bufferedEvents.count == 2)

        var replayed: [String] = []
        let delivered = coordinator.complete(for: .searchEverywhere, responder: targetField, in: window) { events in
            replayed = events.compactMap(\.characters)
        }
        #expect(delivered.count == 2)
        #expect(replayed == ["m", "A"])
        #expect(coordinator.pendingTarget == nil)

        // Escape cancels pending handoff and passes through.
        coordinator.begin(to: .terminal, in: window)
        let escape = try makeKeyEvent(characters: "\u{1B}", keyCode: 53, modifiers: [], windowNumber: window.windowNumber)
        #expect(coordinator.intercept(escape) != nil)
        #expect(coordinator.pendingTarget == nil)

        // Expired handoff cancels and passes through.
        coordinator.begin(to: .terminal, in: window)
        currentTime = currentTime.addingTimeInterval(0.30)
        #expect(coordinator.intercept(keyM) != nil)
        #expect(coordinator.pendingTarget == nil)
    }

    @Test
    func goRustPythonStringsKeepCommentMarkersAndLanguageConstructsAccurate() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let basePalette = CodeEditorPalette(isDark: true, theme: LitheTheme.activeTheme)
        let palette = SyntaxHighlightingColorConfiguration.bundled.palette(formatID: nil, base: basePalette)

        // Go: comment marker inside double string & multiline backtick raw string
        let goSource = #"""
        package main
        func greet() string {
            a := "return // marker # hash"
            b := `line1
        return // raw`
            return a + b // real comment
        }
        """#
        let goStorage = NSTextStorage(string: goSource)
        SyntaxHighlighter.apply(to: goStorage, font: font, fileExtension: "go", isDark: true)
        let goNS = goSource as NSString
        #expect(try fg(goStorage, at: goNS.range(of: "// marker").location) == palette.string)
        #expect(try fg(goStorage, at: goNS.range(of: "# hash").location) == palette.string)
        #expect(try fg(goStorage, at: goNS.range(of: "// raw").location) == palette.string)
        #expect(try fg(goStorage, at: goNS.range(of: "// real comment").location) == palette.comment)
        #expect(try fg(goStorage, at: goNS.range(of: "func").location) == palette.keyword)

        // Rust: attributes, raw strings, lifetimes, nested block comments
        let rustSource = #"""
        #[derive(Debug)]
        fn keep<'a>(s: &'a str) -> &'a str {
            let raw = r#"return // raw "quote""#;
            let ch = 'x';
            /* outer /* inner */ still comment */
            let ok = true;
            s
        }
        """#
        let rustStorage = NSTextStorage(string: rustSource)
        SyntaxHighlighter.apply(to: rustStorage, font: font, fileExtension: "rs", isDark: true)
        let rustNS = rustSource as NSString
        #expect(try fg(rustStorage, at: rustNS.range(of: "#[derive(Debug)]").location) == palette.annotation)
        #expect(try fg(rustStorage, at: rustNS.range(of: "->").location) == palette.text)
        #expect(try fg(rustStorage, at: rustNS.range(of: "// raw").location) == palette.string)
        #expect(try fg(rustStorage, at: rustNS.range(of: "'x'").location) == palette.string)
        #expect(try fg(rustStorage, at: rustNS.range(of: "still comment").location) == palette.comment)
        #expect(try fg(rustStorage, at: rustNS.range(of: "true").location) == palette.keyword)

        // Python: triple quotes, # inside string, // is not comment, # outside string is comment
        let pySource = #"""
        @dataclass
        def load():
            msg = "return # marker // slash"
            doc = """
            def not_a_keyword # still string
            """
            # real python comment
            return msg
        """#
        let pyStorage = NSTextStorage(string: pySource)
        SyntaxHighlighter.apply(to: pyStorage, font: font, fileExtension: "py", isDark: true)
        let pyNS = pySource as NSString
        #expect(try fg(pyStorage, at: pyNS.range(of: "@dataclass").location) == palette.annotation)
        #expect(try fg(pyStorage, at: pyNS.range(of: "# marker").location) == palette.string)
        #expect(try fg(pyStorage, at: pyNS.range(of: "// slash").location) == palette.string)
        #expect(try fg(pyStorage, at: pyNS.range(of: "def not_a_keyword").location) == palette.string)
        #expect(try fg(pyStorage, at: pyNS.range(of: "# real python comment").location) == palette.comment)
        #expect(try fg(pyStorage, at: pyNS.range(of: "return msg").location) == palette.keyword)
    }

    @Test
    func sqlHighlighterKeepsCommentMarkersInsideStringsColoredAsStrings() throws {
        let sql = "SELECT 'foo -- not comment', '/* also string */' FROM users -- real SELECT"
        let storage = NSTextStorage(string: sql)
        SQLSyntaxHighlighter.apply(to: storage, isDark: true)
        let ns = sql as NSString

        let stringColor = try fg(storage, at: ns.range(of: "'foo").location)
        let dashInsideString = try fg(storage, at: ns.range(of: "-- not comment").location)
        let blockInsideString = try fg(storage, at: ns.range(of: "/* also string */").location)
        let realComment = try fg(storage, at: ns.range(of: "-- real SELECT").location)
        let keywordInComment = try fg(storage, at: ns.range(of: "real SELECT").location + 5)
        let selectKeyword = try fg(storage, at: ns.range(of: "SELECT").location)

        #expect(dashInsideString == stringColor)
        #expect(blockInsideString == stringColor)
        #expect(realComment != stringColor)
        #expect(keywordInComment == realComment)
        #expect(selectKeyword != stringColor)
        #expect(selectKeyword != realComment)
    }

    @Test
    func searchRelevanceMatchesCamelCaseInitialsLinearlyAndScoresRelativeDepth() {
        let root = URL(fileURLWithPath: "/Users/dev/very/deep/prefix/workspace", isDirectory: true)
        let shallow = FileSearchResult(
            url: root.appendingPathComponent("DeviceHandler.go"),
            line: nil,
            preview: "",
            kind: .file
        )
        let deep = FileSearchResult(
            url: root.appendingPathComponent("a/b/c/d/e/DeviceHandler.go"),
            line: nil,
            preview: "",
            kind: .file
        )
        let urlLoader = FileSearchResult(
            url: root.appendingPathComponent("URLLoader.go"),
            line: nil,
            preview: "",
            kind: .file
        )

        #expect(SearchRelevance.score(shallow, query: "dh", workspaceRoot: root) > 200)
        #expect(SearchRelevance.score(shallow, query: "dh", workspaceRoot: root)
            > SearchRelevance.score(deep, query: "dh", workspaceRoot: root))
        // Consecutive capitals in `URLLoader` treat `U` and `L` as initials, not `RL`.
        #expect(SearchRelevance.score(urlLoader, query: "ul", workspaceRoot: root) > 200)
    }

    @Test
    func processRunnerPreservesOutputContainingInvalidUTF8Bytes() {
        let result = MacProcessRunner().run(ProcessRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'ok\\377tail'"],
            timeoutMilliseconds: 2_000
        ))
        #expect(result.exitCode == 0)
        #expect(result.output.contains("ok"))
        #expect(result.output.contains("tail"))
    }

    @Test
    func localSecretStoreCreatesFileWithOwnerOnlyPermissions() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-secret-perms-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("ai-secrets.json")
        let store = MacLocalSecretStore(fileURL: fileURL)
        try store.write("super-secret-token", key: "provider.key")

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)
        #expect(store.read(key: "provider.key") == "super-secret-token")

        try store.delete(key: "provider.key")
        #expect(store.read(key: "provider.key") == nil)
    }

    private func fg(_ storage: NSTextStorage, at location: Int) throws -> NSColor {
        try #require(storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor)
    }

    private func makeKeyEvent(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        windowNumber: Int
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
