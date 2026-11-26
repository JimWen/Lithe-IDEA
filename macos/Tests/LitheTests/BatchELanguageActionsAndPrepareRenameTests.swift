import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Batch E language shortcuts and B6a2 protocol")
@MainActor
struct BatchELanguageActionsAndPrepareRenameTests {
    @Test
    func commandCatalogRegistersLanguageActionShortcutsWithoutConflicts() throws {
        let expected: [(id: String, display: String, menu: ProjectMenuCommand)] = [
            ("rename-symbol", "⇧F6", .renameSymbol),
            ("format-document", "⌥⌘L", .formatDocument),
            ("source-actions", "⌥↩", .sourceActions),
            ("complete-symbol", "⌃Space", .completeSymbol),
            ("quick-documentation", "F1", .quickDocumentation)
        ]

        for entry in expected {
            let command = try #require(LitheCommandCatalog.command(id: entry.id))
            #expect(command.defaultBindings.first?.displayText == entry.display)
            #expect(entry.menu.shortcutID == entry.id)
        }
    }

    @Test
    func codeActionRangeNormalizationAndDiagnosticIntersectionFilterAccurately() {
        let reversed = LanguageServerRange(
            start: .init(line: 4, utf16Column: 10),
            end: .init(line: 2, utf16Column: 3)
        )
        let normalized = AppModel.normalizedCodeActionRange(reversed)
        #expect(normalized.start == .init(line: 2, utf16Column: 3))
        #expect(normalized.end == .init(line: 4, utf16Column: 10))

        let diagBefore = LanguageServerDiagnostic(
            range: .init(start: .init(line: 0, utf16Column: 0), end: .init(line: 1, utf16Column: 5)),
            severity: 2,
            message: "before",
            source: nil,
            code: nil
        )
        let diagTouchingStart = LanguageServerDiagnostic(
            range: .init(start: .init(line: 1, utf16Column: 0), end: .init(line: 2, utf16Column: 3)),
            severity: 1,
            message: "touching-start",
            source: nil,
            code: nil
        )
        let diagInside = LanguageServerDiagnostic(
            range: .init(start: .init(line: 3, utf16Column: 1), end: .init(line: 3, utf16Column: 8)),
            severity: 1,
            message: "inside",
            source: nil,
            code: nil
        )
        let diagAfter = LanguageServerDiagnostic(
            range: .init(start: .init(line: 5, utf16Column: 0), end: .init(line: 5, utf16Column: 4)),
            severity: 2,
            message: "after",
            source: nil,
            code: nil
        )

        let intersected = AppModel.diagnosticsIntersecting(
            [diagBefore, diagTouchingStart, diagInside, diagAfter],
            range: normalized
        )
        #expect(intersected.map(\.message) == ["touching-start", "inside"])
    }

    @Test
    func codeTextViewSelectedLanguageServerRangeTracksUtf16SelectionAccurately() {
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        // Includes an emoji (2 UTF-16 code units) on line 0 before the selected identifier.
        let source = "let 😀 = value\nlet next = value\n"
        textView.string = source
        textView.rebuildLineIndex()

        let nsSource = source as NSString
        let firstValue = nsSource.range(of: "value")
        let secondValue = nsSource.range(of: "value", options: [], range: NSRange(location: NSMaxRange(firstValue), length: nsSource.length - NSMaxRange(firstValue)))
        let multiLineSelection = NSRange(
            location: firstValue.location,
            length: NSMaxRange(secondValue) - firstValue.location
        )
        textView.setSelectedRange(multiLineSelection)

        let range = textView.selectedLanguageServerRange()
        #expect(range.start == LanguageServerPosition(line: 0, utf16Column: 9))
        #expect(range.end == LanguageServerPosition(line: 1, utf16Column: 16))
    }

    @Test
    func editorChromeModelPublishesAndConsumesLanguageActionRequests() {
        let chrome = EditorChromeModel()
        let documentID = UUID()

        chrome.requestLanguageAction(.renameSymbol, for: documentID)
        let request = chrome.languageActionRequest
        #expect(request?.documentID == documentID)
        #expect(request?.kind == .renameSymbol)

        if let id = request?.id {
            chrome.consumeLanguageActionRequest(id: UUID())
            #expect(chrome.languageActionRequest?.id == id)
            chrome.consumeLanguageActionRequest(id: id)
            #expect(chrome.languageActionRequest == nil)
        }
    }

    @Test
    func languageServerFeatureSetKeepsPrepareRenameDistinctFromRename() {
        let renameOnly: LanguageServerFeatureSet = [.rename]
        #expect(renameOnly.contains(.rename))
        #expect(!renameOnly.contains(.prepareRename))
        #expect(!LanguageServerFeatureSet.standardEditing.contains(.prepareRename))

        let both: LanguageServerFeatureSet = [.rename, .prepareRename]
        #expect(both.contains(.rename))
        #expect(both.contains(.prepareRename))
    }
}
