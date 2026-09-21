import Foundation
import Testing
@testable import Lithe

@MainActor
struct LanguageTestLocalizationTests {
    private func localization(_ language: AppLanguage) throws -> LanguageTestLocalization {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        return LanguageTestLocalization(language: language, resourceBundle: try #require(Bundle(url: resources)))
    }

    @Test
    func testStatusFollowsTheSelectedAppLanguage() throws {
        let chinese = try localization(.simplifiedChinese)
        let english = try localization(.english)
        for (key, value) in ["Passed": "通过", "Failed": "失败", "Cancelled": "已取消"] {
            #expect(chinese.text(key) == value)
            #expect(english.text(key) == key)
        }
    }

    @Test
    func unknownDiagnosticsRemainVerbatim() throws {
        let diagnostic = "Go: fixture/main.go 100% complete"
        for language in [AppLanguage.simplifiedChinese, .english] {
            #expect(try localization(language).error(diagnostic) == diagnostic)
        }
    }
}
