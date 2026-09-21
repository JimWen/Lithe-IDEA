import Foundation
import Testing
@testable import Lithe

@MainActor
struct HTMLPreviewNavigationTests {
    @Test(arguments: ["file:///fixture/site/", "file:///fixture/site/#previous",
                      "about:blank", "about:blank#previous", nil] as [String?])
    func sameDocumentFragmentStaysInsideLivePreview(currentPage: String?) throws {
        let base = try #require(URL(string: "file:///fixture/site/"))
        for fragment in ["section", ""] {
            let destination = try #require(URL(string: "#" + fragment, relativeTo: base)?.absoluteURL)
            #expect(HTMLPreviewNavigationPolicy.decision(
                destination: destination, isActivatedLink: true,
                currentPageURL: currentPage.flatMap { URL(string: $0) }, htmlBaseURL: base
            ) == .allow)
            #expect(HTMLPreviewNavigationPolicy.decision(
                destination: destination, isActivatedLink: false,
                currentPageURL: currentPage.flatMap { URL(string: $0) }, htmlBaseURL: base
            ) == .allow, "Script changes to the current fragment should still scroll the preview")
        }
    }

    @Test(arguments: ["file:///fixture/other.html#section", "file:///fixture/index.html?other#section",
                      "file:///fixture/index.html", "javascript:alert(1)", "data:text/html,other"])
    func differentLocalPageOrUnsafeSchemeDoesNotReplaceLiveBuffer(destination: String) throws {
        #expect(HTMLPreviewNavigationPolicy.decision(
            destination: try #require(URL(string: destination)), isActivatedLink: true,
            currentPageURL: URL(string: "file:///fixture/index.html"),
            htmlBaseURL: URL(string: "file:///fixture/")
        ) == .cancel)
    }

    @Test(arguments: ["http://example.invalid/", "https://example.invalid/", "mailto:fixture@example.invalid"])
    func explicitExternalLinksOpenOutsideButScriptNavigationIsCancelled(destination: String) throws {
        let url = try #require(URL(string: destination))
        #expect(HTMLPreviewNavigationPolicy.decision(
            destination: url, isActivatedLink: true, currentPageURL: nil, htmlBaseURL: nil
        ) == .openExternally)
        #expect(HTMLPreviewNavigationPolicy.decision(
            destination: url, isActivatedLink: false, currentPageURL: nil, htmlBaseURL: nil
        ) == .cancel)
    }

    @Test
    func initialHTMLLoadIsAllowedAndMissingDestinationIsCancelled() throws {
        for url in [URL(string: "about:blank"), URL(string: "file:///fixture/site/")] {
            #expect(HTMLPreviewNavigationPolicy.decision(
                destination: try #require(url), isActivatedLink: false,
                currentPageURL: nil, htmlBaseURL: URL(string: "file:///fixture/site/"),
                allowsPayloadLoad: true
            ) == .allow)
        }
        #expect(HTMLPreviewNavigationPolicy.decision(
            destination: nil, isActivatedLink: true, currentPageURL: nil, htmlBaseURL: nil
        ) == .cancel)
    }

    @Test(arguments: ["file:///fixture/site/other.html", "file:///fixture/site/index.html",
                      "file:///fixture/site/", "file:///fixture/site/?submitted=value", "about:blank"])
    func formOrScriptNavigationCannotReplaceTheMainPreviewAfterCommit(destination: String) throws {
        // Form submission and script/meta-refresh navigation are both non-link
        // actions. They no longer inherit a blanket allowance for local files.
        #expect(HTMLPreviewNavigationPolicy.decision(
            destination: try #require(URL(string: destination)), isActivatedLink: false,
            currentPageURL: URL(string: "file:///fixture/site/"),
            htmlBaseURL: URL(string: "file:///fixture/site/")
        ) == .cancel)
    }

    @Test(arguments: ["file:///fixture/site/other.html", "file:///fixture/site/?submitted=value"])
    func pendingPayloadDoesNotAuthorizeAnotherMainFrameDestination(destination: String) throws {
        #expect(HTMLPreviewNavigationPolicy.decision(
            destination: try #require(URL(string: destination)), isActivatedLink: false,
            currentPageURL: URL(string: "about:blank"),
            htmlBaseURL: URL(string: "file:///fixture/site/"), allowsPayloadLoad: true
        ) == .cancel)
    }

    @Test
    func aNewBufferPayloadMayReplaceThePreviouslyCommittedPreview() throws {
        let base = try #require(URL(string: "file:///fixture/site/"))
        #expect(HTMLPreviewNavigationPolicy.decision(
            destination: base, isActivatedLink: false,
            currentPageURL: URL(string: "file:///fixture/site/#section"),
            htmlBaseURL: base, allowsPayloadLoad: true
        ) == .allow)
    }

    @Test(arguments: ["file:///fixture/site/embedded.html", "about:blank"])
    func embeddedLocalFramesKeepTheirExistingLoadPolicy(destination: String) throws {
        #expect(HTMLPreviewNavigationPolicy.decision(
            destination: try #require(URL(string: destination)), isActivatedLink: false,
            currentPageURL: URL(string: "file:///fixture/site/embedded.html"),
            htmlBaseURL: URL(string: "file:///fixture/site/"), isMainFrameNavigation: false
        ) == .allow)
    }

    @Test(arguments: ["https", "http", nil] as [String?])
    func browserLookupUsesNetworkSchemeHandlersInsteadOfTheHTMLFileAssociation(availableScheme: String?) throws {
        let browser = URL(fileURLWithPath: "/fixture/Browser.app")
        var requestedSchemes: [String] = []
        let result = MacPlatformUI.browserApplicationURL { url in
            #expect(url.host == nil, "Resolving a handler must not require a live site")
            #expect(!url.isFileURL)
            requestedSchemes.append(url.scheme ?? "")
            return url.scheme == availableScheme ? browser : nil
        }
        #expect(requestedSchemes == (availableScheme == "https" ? ["https"] : ["https", "http"]))
        #expect(result == (availableScheme == nil ? nil : browser))
    }
}
