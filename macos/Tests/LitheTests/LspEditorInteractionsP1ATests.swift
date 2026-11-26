import AppKit
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import Testing
@testable import Lithe

@Suite("P1-A LSP editor direct interactions")
struct LspEditorInteractionsP1ATests {
    @Test
    func documentSymbolEnclosingPathFindsNestedHierarchyAndOfflineFallback() {
        let method = LanguageServerDocumentSymbol(
            name: "ServeHTTP",
            detail: "(w ResponseWriter, r *Request)",
            kind: 6,
            range: LanguageServerRange(
                start: LanguageServerPosition(line: 5, utf16Column: 0),
                end: LanguageServerPosition(line: 12, utf16Column: 1)
            ),
            selectionRange: LanguageServerPosition(line: 5, utf16Column: 16).singleRange
        )
        let server = LanguageServerDocumentSymbol(
            name: "Server",
            detail: "struct",
            kind: 23,
            range: LanguageServerRange(
                start: LanguageServerPosition(line: 2, utf16Column: 0),
                end: LanguageServerPosition(line: 15, utf16Column: 1)
            ),
            selectionRange: LanguageServerPosition(line: 2, utf16Column: 5).singleRange,
            children: [method]
        )

        let nested = LanguageServerDocumentSymbol.enclosingPath(
            in: [server],
            line: 8,
            utf16Column: 4
        )
        #expect(nested.map(\.name) == ["Server", "ServeHTTP"])

        let outer = LanguageServerDocumentSymbol.enclosingPath(
            in: [server],
            line: 3,
            utf16Column: 2
        )
        #expect(outer.map(\.name) == ["Server"])

        let flat = [
            LanguageServerDocumentSymbol(
                name: "Config",
                kind: 23,
                range: LanguageServerPosition(line: 1, utf16Column: 0).singleRange,
                selectionRange: LanguageServerPosition(line: 1, utf16Column: 0).singleRange
            ),
            LanguageServerDocumentSymbol(
                name: "run",
                kind: 12,
                range: LanguageServerPosition(line: 10, utf16Column: 0).singleRange,
                selectionRange: LanguageServerPosition(line: 10, utf16Column: 0).singleRange
            ),
        ]
        let flatMatch = LanguageServerDocumentSymbol.enclosingPath(
            in: flat,
            line: 14,
            utf16Column: 0
        )
        #expect(flatMatch.map(\.name) == ["run"])
    }

    @Test
    @MainActor
    func semanticTokensMapToSyntaxRolesAndPaintStorageSafely() {
        #expect(SyntaxHighlighter.semanticTokenRole(for: "function", modifiers: ["declaration"]) == .functionDeclaration)
        #expect(SyntaxHighlighter.semanticTokenRole(for: "function", modifiers: []) == .functionCall)
        #expect(SyntaxHighlighter.semanticTokenRole(for: "variable", modifiers: ["readonly"]) == .constant)
        #expect(SyntaxHighlighter.semanticTokenRole(for: "variable", modifiers: []) == .variable)
        #expect(SyntaxHighlighter.semanticTokenRole(for: "struct", modifiers: []) == .type)
        #expect(SyntaxHighlighter.semanticTokenRole(for: "parameter", modifiers: []) == .parameter)
        #expect(SyntaxHighlighter.semanticTokenRole(for: "macro", modifiers: []) == .annotation)
        #expect(SyntaxHighlighter.semanticTokenRole(for: "comment", modifiers: ["documentation"]) == .documentationComment)

        let source = "func greet(name string) {}\n"
        let storage = NSTextStorage(string: source)
        let tokens = [
            LanguageServerSemanticToken(line: 0, utf16Column: 5, length: 5, tokenType: "function", tokenModifiers: ["declaration"]),
            LanguageServerSemanticToken(line: 0, utf16Column: 11, length: 4, tokenType: "parameter"),
            LanguageServerSemanticToken(line: 0, utf16Column: 16, length: 6, tokenType: "type"),
            // Out-of-bounds token must be ignored safely without throwing.
            LanguageServerSemanticToken(line: 99, utf16Column: 0, length: 10, tokenType: "type"),
        ]
        SyntaxHighlighter.applyLspSemanticTokens(
            tokens,
            to: storage,
            lineOffset: { $0 == 0 ? 0 : storage.length },
            fileName: "main.go",
            fileExtension: "go",
            isDark: true
        )
        #expect(storage.string == source)
        #expect(storage.attribute(.foregroundColor, at: 5, effectiveRange: nil) != nil)
        #expect(storage.attribute(.foregroundColor, at: 11, effectiveRange: nil) != nil)

        // Scoped lineRange re-applies semantic colors only inside the requested viewport lines.
        let multiLine = "let a = 1\nlet b = 2\n"
        let multiStorage = NSTextStorage(string: multiLine)
        let line0Color = NSColor.systemRed
        multiStorage.addAttribute(.foregroundColor, value: line0Color, range: NSRange(location: 0, length: multiStorage.length))
        let multiTokens = [
            LanguageServerSemanticToken(line: 0, utf16Column: 4, length: 1, tokenType: "variable"),
            LanguageServerSemanticToken(line: 1, utf16Column: 4, length: 1, tokenType: "variable", tokenModifiers: ["readonly"]),
        ]
        SyntaxHighlighter.applyLspSemanticTokens(
            multiTokens,
            to: multiStorage,
            lineOffset: { $0 == 0 ? 0 : 10 },
            fileName: "main.rs",
            fileExtension: "rs",
            isDark: true,
            lineRange: 1...1
        )
        #expect(multiStorage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor == line0Color)
        #expect(multiStorage.attribute(.foregroundColor, at: 14, effectiveRange: nil) as? NSColor != line0Color)
    }

    @Test
    @MainActor
    func signatureHelpHighlightsActiveParameterByOffsetsAndLabel() {
        let signature = LanguageServerSignatureInformation(
            label: "add(a int, b string) error",
            documentation: "Adds values",
            parameters: [
                LanguageServerParameterInformation(label: "a int", labelStart: 4, labelEnd: 9),
                LanguageServerParameterInformation(label: "b string"),
            ]
        )
        let help0 = LanguageServerSignatureHelp(signatures: [signature], activeSignature: 0, activeParameter: 0)
        #expect(help0.effectiveActiveParameter == 0)
        let rendered0 = SignatureHelpPanelController.attributedSignature(
            signature,
            activeParameterIndex: help0.effectiveActiveParameter,
            isDark: true
        )
        let font0 = rendered0.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        #expect(font0?.fontDescriptor.symbolicTraits.contains(.bold) == true)

        let help1 = LanguageServerSignatureHelp(signatures: [signature], activeSignature: 0, activeParameter: 1)
        let rendered1 = SignatureHelpPanelController.attributedSignature(
            signature,
            activeParameterIndex: help1.effectiveActiveParameter,
            isDark: false
        )
        let bIndex = (signature.label as NSString).range(of: "b string").location
        let font1 = rendered1.attribute(.font, at: bIndex + 1, effectiveRange: nil) as? NSFont
        #expect(font1?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test
    @MainActor
    func inlayHintOverlayRendersWithoutMutatingTextStorageAndSkipsFoldedLines() {
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        let original = "let x = compute(1)\nlet y = compute(2)\n"
        textView.string = original
        textView.rebuildLineIndex()

        let controller = InlayHintOverlayController(textView: textView)
        let hints = [
            LanguageServerInlayHint(position: .init(line: 0, utf16Column: 5), label: ": i32", kind: .type),
            LanguageServerInlayHint(position: .init(line: 0, utf16Column: 16), label: "count:", kind: .parameter),
            LanguageServerInlayHint(position: .init(line: 1, utf16Column: 5), label: ": i32", kind: .type),
        ]
        controller.update(hints: hints, collapsedLineSet: [1], isDark: true)

        #expect(textView.string == original)
        #expect(controller.renderedLineCount == 1)

        controller.clear()
        #expect(controller.renderedLineCount == 0)
    }

    @Test
    @MainActor
    func p1aCommandsAndSettingsAreRegisteredAndPersisted() throws {
        #expect(LitheCommandCatalog.command(id: "parameter-info") != nil)
        #expect(LitheCommandCatalog.command(id: "toggle-structure") != nil)
        #expect(LitheCommandCatalog.command(id: "refactor-this") != nil)
        #expect(SidebarDestination.structure.commandID == "toggle-structure")
        #expect(SidebarDestination.structure.isAvailable)

        let store = InMemoryKeyValueStore()
        let logs = StaticLogDirectoryProvider()
        let settings = AppSettings(store: store, logDirectoryProvider: logs)
        #expect(settings.showInlayHints == true)
        #expect(settings.formatOnSave == false)
        settings.showInlayHints = false
        settings.formatOnSave = true

        let reloaded = AppSettings(store: store, logDirectoryProvider: logs)
        #expect(reloaded.showInlayHints == false)
        #expect(reloaded.formatOnSave == true)
    }

    @Test
    func rustCoreOfflineWorkspaceDocumentSymbolsExtractsGoRustAndPython() {
        let core = RustCoreBridge()
        guard core.isAvailable else { return }

        let goSymbols = core.workspaceDocumentSymbols(
            path: "main.go",
            source: "package main\ntype Service struct {}\nfunc (s *Service) Start() {}\n"
        )
        #expect(goSymbols.map(\.name) == ["Service", "Start"])

        let rustSymbols = core.workspaceDocumentSymbols(
            path: "lib.rs",
            source: "pub struct Engine {}\npub fn execute() {}\n"
        )
        #expect(rustSymbols.map(\.name) == ["Engine", "execute"])

        let pySymbols = core.workspaceDocumentSymbols(
            path: "app.py",
            source: "class Runner:\n    def run(self):\n        pass\n"
        )
        #expect(pySymbols.map(\.name).contains("Runner"))
        #expect(pySymbols.map(\.name).contains("run"))
    }
}

private extension LanguageServerPosition {
    var singleRange: LanguageServerRange {
        LanguageServerRange(start: self, end: self)
    }
}

private final class InMemoryKeyValueStore: KeyValueStore {
    private var storage: [String: Any] = [:]
    func string(forKey key: String) -> String? { storage[key] as? String }
    func stringArray(forKey key: String) -> [String]? { storage[key] as? [String] }
    func data(forKey key: String) -> Data? { storage[key] as? Data }
    func object(forKey key: String) -> Any? { storage[key] }
    func set(_ value: Any?, forKey key: String) { storage[key] = value }
}

private struct StaticLogDirectoryProvider: LogDirectoryProviding {
    var defaultLogDirectory: URL { FileManager.default.temporaryDirectory }
}
