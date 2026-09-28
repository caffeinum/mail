import AppKit
import WebKit

/// The one WKWebView in the app, made once and kept warm: WebKit is only
/// here to draw html mail. No scripts, no remote loads — images, fonts,
/// tracking pixels and css from the network are all refused, by a content
/// security policy in the page and a content rule list under it.
final class WebRenderer: NSObject, WKNavigationDelegate {
    static let shared = WebRenderer()

    private(set) lazy var view: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.suppressesIncrementalRendering = false
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
        v.navigationDelegate = self
        v.setValue(false, forKey: "drawsBackground")
        v.allowsMagnification = true
        return v
    }()

    private var ruled = false

    func prewarm() {
        view.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        let rules = #"[{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "post.block-remote", encodedContentRuleList: rules) { [weak self] list, _ in
            guard let self, let list else { return }
            self.view.configuration.userContentController.add(list)
            self.ruled = true
        }
    }

    static let csp = "default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; font-src data:; media-src 'none'; frame-src 'none'; form-action 'none'"

    func render(html: String) {
        let doc = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(Self.csp)">
        <meta name="viewport" content="width=device-width">
        <style>
          html { background: #fff; }
          body { margin: 0; padding: 20px 24px 60px; font: 14px -apple-system, sans-serif; color: #1d1d1f; word-wrap: break-word; }
          img { max-width: 100%; height: auto; }
          table { max-width: 100% !important; }
          pre { white-space: pre-wrap; }
          blockquote { border-left: 3px solid #ddd; margin-left: 0; padding-left: 12px; color: #555; }
        </style></head><body>\(html)</body></html>
        """
        view.loadHTMLString(doc, baseURL: nil)
    }

    func clear() { view.loadHTMLString("", baseURL: nil) }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            return decisionHandler(.cancel)
        }
        decisionHandler(action.request.url?.scheme == "about" || action.request.url == nil ? .allow : .cancel)
    }
}
