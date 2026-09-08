import AppKit
import Foundation
import Testing
@testable import Lithe

@Suite("Run output source links")
@MainActor
struct OutputLocationTests {
    @Test
    func goCompilerLinksUseCapturedDirectoryAndPreserveUnicode() throws {
        let root = URL(fileURLWithPath: "/fixture/module two")
        let file = root.appendingPathComponent("子目录/check.go")
        let output = "# example.test/check\n\u{1B}[31m子目录/check.go:3:28: undefined: missingValue\u{1B}[0m\n"
        let rendered = OutputTextView.renderOutput(output, searchRoots: [root],
            fileExists: { $0 == file }, isDark: true, theme: .lithe)
        let pathRange = (rendered.string as NSString).range(of: "子目录/check.go:3:28")
        var actualRange = NSRange()
        let link = try #require(rendered.attribute(.link, at: pathRange.location, effectiveRange: &actualRange) as? URL)
        let query = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(actualRange == pathRange)
        #expect(query.first(where: { $0.name == "path" })?.value == file.path)
        #expect(query.first(where: { $0.name == "line" })?.value == "3")
        #expect(query.first(where: { $0.name == "col" })?.value == "28")
    }

    @Test(arguments: ["    service_test.go:9: failed", "  --> src/main.rs:12:5"])
    func supportsTestAndRustLocations(_ output: String) {
        let rendered = OutputTextView.renderOutput(output,
            searchRoots: [URL(fileURLWithPath: "/fixture")], fileExists: { _ in true },
            isDark: false, theme: .lithe)
        var links = 0
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if value != nil { links += 1 }
        }
        #expect(links == 1)
    }

    @Test
    func identicalLogsResolveWithinEachInvocation() throws {
        let source = "check.go:1:2: failure\n"
        let roots = ["/fixture/one", "/fixture/two"].map { URL(fileURLWithPath: $0) }
        let links = try roots.map { root in
            let rendered = OutputTextView.renderOutput(source, searchRoots: [root],
                fileExists: { $0 == root.appendingPathComponent("check.go") }, isDark: true, theme: .lithe)
            return try #require(rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL)
        }
        #expect(links[0] != links[1])
    }

    @Test(arguments: ["check.go:0:1: invalid", "check.go:999999999999999999999999: invalid",
                      "check.go:1:999999999999999999999999: invalid", "missing.go:2:3: absent"])
    func missingAndInvalidLocationsStayPlainText(_ source: String) {
        let rendered = OutputTextView.renderOutput(source,
            searchRoots: [URL(fileURLWithPath: "/fixture")],
            fileExists: { $0.lastPathComponent == "check.go" }, isDark: true, theme: .lithe)
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            #expect(value == nil)
        }
    }
}
