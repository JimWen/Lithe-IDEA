import AppKit
import SwiftUI
import WebKit

/// Hosts a static HTML document in an isolated, non-persistent WebKit page.
struct HTMLPreviewWebView: NSViewRepresentable {
    struct Payload: Equatable {
        let html: String
        let documentURL: URL
    }

    let payload: Payload

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator.assetHandler, forURLScheme: HTMLPreviewAssetResolver.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = pagePreferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.update(payload, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(payload, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        coordinator.invalidatePayloadNavigation()
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let assetHandler = HTMLPreviewAssetSchemeHandler()
        private var payloadBaseURL: URL?
        private var lastPayload: Payload?
        private var payloadNavigation: WKNavigation?

        func update(_ payload: Payload, in webView: WKWebView) {
            guard payload != lastPayload else { return }
            lastPayload = payload
            payloadBaseURL = assetHandler.update(documentURL: payload.documentURL)
            payloadNavigation = webView.loadHTMLString(
                payload.html,
                baseURL: payloadBaseURL
            )
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            let decision = HTMLPreviewNavigationPolicy.decision(
                destination: url,
                isActivatedLink: navigationAction.navigationType == .linkActivated,
                currentPageURL: isMainFrame ? webView.url : navigationAction.sourceFrame.request.url,
                htmlBaseURL: payloadBaseURL,
                isMainFrameNavigation: isMainFrame,
                allowsPayloadLoad: payloadNavigation != nil && navigationAction.navigationType == .other
            )
            switch decision {
            case .allow:
                decisionHandler(.allow)
            case .openExternally:
                if let url { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            case .cancel:
                decisionHandler(.cancel)
            }
        }

        func invalidatePayloadNavigation() {
            assetHandler.cancelPendingRequests()
            payloadNavigation = nil
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            finishPayloadNavigation(navigation)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finishPayloadNavigation(navigation)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finishPayloadNavigation(navigation)
        }

        private func finishPayloadNavigation(_ navigation: WKNavigation?) {
            // A cancelled older payload must not clear a successor load's slot.
            guard let navigation, navigation === payloadNavigation else { return }
            payloadNavigation = nil
        }
    }
}

/// Pure routing keeps document anchors inside the preview and external links in
/// their native handlers. The main frame remains owned by the current HTML payload.
enum HTMLPreviewNavigationPolicy {
    enum Decision: Equatable {
        case allow
        case openExternally
        case cancel
    }

    static func decision(
        destination: URL?, isActivatedLink: Bool,
        currentPageURL: URL?, htmlBaseURL: URL?,
        isMainFrameNavigation: Bool = true, allowsPayloadLoad: Bool = false
    ) -> Decision {
        guard let destination else { return .cancel }
        // loadHTMLString may expose about:blank before its base URL becomes
        // the current page. In that state relative anchors use the HTML base.
        let page = currentPageURL ?? htmlBaseURL
        let isBlankPage = page.map(isAboutBlankPage) == true
        let fragmentBase = isBlankPage ? htmlBaseURL : page
        if destination.fragment != nil,
           sameDocument(destination, page) || sameDocument(destination, fragmentBase) {
            return .allow
        }
        if isActivatedLink {
            if let scheme = destination.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                return .openExternally
            }
            return .cancel
        }
        if !isMainFrameNavigation {
            // Preserve embedded local frames. CSS and image requests are resource
            // loads, not main-frame navigations governed by this policy.
            return destination.isFileURL || destination.scheme == HTMLPreviewAssetResolver.scheme
                || destination.absoluteString == "about:blank" ? .allow : .cancel
        }
        // Only the native loadHTMLString request can replace the main document.
        // Forms, script redirects, refreshes and reloads must not detach the
        // preview from its live source buffer, even when they target a file URL.
        guard allowsPayloadLoad, destination.fragment == nil,
              destination.absoluteString == "about:blank" || destination.absoluteURL == htmlBaseURL?.absoluteURL else {
            return .cancel
        }
        return .allow
    }

    private static func isAboutBlankPage(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme?.lowercased() == "about", components.query == nil else { return false }
        // Older Foundation URL parsing encodes an opaque about: URL's fragment
        // into its path (blank%23section). Limit this compatibility rule to the
        // blank page; file paths must retain their ordinary URL semantics.
        return components.path.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first == "blank"
    }

    private static func sameDocument(_ destination: URL, _ current: URL?) -> Bool {
        guard let current,
              var target = URLComponents(url: destination, resolvingAgainstBaseURL: true),
              var page = URLComponents(url: current, resolvingAgainstBaseURL: true) else { return false }
        target.fragment = nil
        page.fragment = nil
        return target.url == page.url
    }
}
