import Foundation
import Testing
@testable import Lithe

struct HTMLPreviewAssetResolverTests {
    @Test(arguments: ["style.css", "nested/colors.css", "nested/icon.svg?version=2"])
    func relativeResourcesResolveInsideTheDocumentDirectory(path: String) throws {
        let document = URL(fileURLWithPath: "/preview-fixture/project/index.html")
        let base = try #require(HTMLPreviewAssetResolver.baseURL(for: document))
        let request = try #require(URL(string: path, relativeTo: base)?.absoluteURL)
        let resolved = try #require(HTMLPreviewAssetResolver.resolve(request, documentURL: document))
        #expect(resolved.path == "/preview-fixture/project/" + String(path.split(separator: "?")[0]))
    }

    @Test(arguments: ["../secret.txt", "nested/../../secret.txt", "%2e%2e/secret.txt",
                      "lithe-html-asset://other/preview-fixture/project/style.css",
                      "file:///preview-fixture/project/style.css",
                      "https://example.invalid/style.css"])
    func requestsCannotLeaveTheDocumentResourceScope(path: String) throws {
        let document = URL(fileURLWithPath: "/preview-fixture/project/index.html")
        let base = try #require(HTMLPreviewAssetResolver.baseURL(for: document))
        let request = try #require(URL(string: path, relativeTo: base)?.absoluteURL)
        #expect(HTMLPreviewAssetResolver.resolve(request, documentURL: document) == nil)
    }

    @Test
    func symlinkResourcesCannotEscapeTheDocumentDirectory() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = temporary.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let outside = temporary.appendingPathComponent("outside.css")
        try Data("body{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("linked.css"), withDestinationURL: outside)
        let document = project.appendingPathComponent("index.html")
        let base = try #require(HTMLPreviewAssetResolver.baseURL(for: document))
        let request = try #require(URL(string: "linked.css", relativeTo: base)?.absoluteURL)
        #expect(HTMLPreviewAssetResolver.resolve(request, documentURL: document) == nil)
    }
}
