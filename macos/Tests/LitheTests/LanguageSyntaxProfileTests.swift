import AppKit
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import Testing
@testable import Lithe

@Suite("Declarative language syntax profiles")
@MainActor
struct LanguageSyntaxProfileTests {
    @Test
    func highlightOnlyLanguagesSupportExactFilenamesAndDashComments() {
        let dockerfileProfile = LanguageSyntaxProfileRegistry.shared.profile(
            forFileName: "Dockerfile",
            fileExtension: ""
        )
        #expect(dockerfileProfile.languageID == "shell")
        #expect(dockerfileProfile.keywords.contains("FROM"))
        #expect(dockerfileProfile.supportsHashComments)

        let sqlProfile = LanguageSyntaxProfileRegistry.shared.profile(
            forFileName: "query.sql",
            fileExtension: "sql"
        )
        #expect(sqlProfile.languageID == "sql")
        #expect(sqlProfile.supportsDashComments)

        let source = "SELECT '-- not a comment' -- real comment\n"
        let storage = NSTextStorage(string: source)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        SyntaxHighlighter.apply(to: storage, font: font, fileName: "query.sql", fileExtension: "sql", isDark: true)

        let basePalette = CodeEditorPalette(isDark: true, theme: LitheTheme.activeTheme)
        let palette = SyntaxHighlightingColorConfiguration.bundled.palette(formatID: nil, base: basePalette)

        let nsSource = source as NSString
        let insideStringDash = nsSource.range(of: "-- not a comment").location
        let realCommentDash = nsSource.range(of: "-- real comment").location
        let insideColor = storage.attribute(.foregroundColor, at: insideStringDash, effectiveRange: nil) as? NSColor
        let commentColor = storage.attribute(.foregroundColor, at: realCommentDash, effectiveRange: nil) as? NSColor
        #expect(insideColor == palette.string)
        #expect(commentColor == palette.comment)
    }

    @Test
    func pluginSyntaxProfileOverridesAndRestoresRegistryAndBuiltinCompletions() throws {
        let registry = LanguageSyntaxProfileRegistry.shared
        let customProfile = LanguageSyntaxProfile(
            languageID: "lua",
            displayName: "Lua Custom",
            fileExtensions: ["lua"],
            supportsSlashComments: false,
            supportsBlockComments: false,
            supportsDashComments: true,
            keywords: ["local", "function", "customkw"]
        )
        registry.register(customProfile)
        defer { registry.unregister(languageID: "lua") }

        let resolved = registry.profile(forFileName: "init.lua", fileExtension: "lua")
        #expect(resolved.displayName == "Lua Custom")
        #expect(resolved.keywords.contains("customkw"))

        let provider = BuiltinLanguageFeatureProvider()
        var items: [LanguageServerCompletionItem] = []
        try provider.completions(
            in: LanguageFeatureRequestContext(
                fileURL: URL(fileURLWithPath: "/fixture/init.lua"),
                text: "cus",
                position: LanguageServerPosition(line: 0, utf16Column: 3),
                languageID: "lua"
            ),
            completion: { result in
                if case .success(let received) = result {
                    items = received
                }
            }
        )
        #expect(items.contains { $0.label == "customkw" })

        registry.unregister(languageID: "lua")
        let restored = registry.profile(forFileName: "init.lua", fileExtension: "lua")
        #expect(restored.displayName == "Lua")
        #expect(!restored.keywords.contains("customkw"))
    }
}
