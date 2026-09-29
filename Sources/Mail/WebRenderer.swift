import AppKit
import WebKit
import MailCore

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
        // Emails with a dark-mode stylesheet would turn their text white
        // inside our white cards; the page always answers "light" and the
        // app picks its own theme.
        v.appearance = NSAppearance(named: .aqua)
        return v
    }()

    private var ruled = false
    /// Runs once when the next load finishes.
    private var loaded: (() -> Void)?

    /// Loads a bare page under the same policy, then hands it to `then` to
    /// fill with app-side script (page script stays off).
    private var last: (String, Bool, () -> Void)?

    func blank(background: String, images: Bool = false, then: @escaping () -> Void) {
        last = (background, images, then)
        loaded = then
        allowImages(images)
        let doc = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(Self.csp(images: images))">
        </head><body style="margin:0;background:\(background)"></body></html>
        """
        view.loadHTMLString(doc, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let f = loaded
        loaded = nil
        f?()
    }

    private var blockAll: WKContentRuleList?
    private var imagesOnly: WKContentRuleList?

    /// Open-tracking endpoints only — never a whole domain, or a sender's
    /// real images go with it (HubSpot hosts both on hubspot hosts). 1×1
    /// images are also stripped from the html before it's drawn.
    static let trackers = ["doubleclick\\.net", "google-analytics\\.com/collect", "list-manage\\.com/track/open",
                           "sendgrid\\.net/wf/open", "/wf/open", "mandrillapp\\.com/track/open", "hubspotlinks\\.com/Cto/",
                           "/e/o/", "emltrk", "mailtrack\\.io", "/open\\.gif", "/open\\.php", "/track/open", "/pixel\\.gif",
                           "sparkpostmail\\.com/q/", "mixpanel\\.com/track"]

    func prewarm() {
        view.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        let block = #"{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}}"#
        let letImages = #"{"trigger":{"url-filter":"^https?:","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}}"#
        let tracks = Self.trackers.map { t in
            #"{"trigger":{"url-filter":"\#(t.replacingOccurrences(of: "\\", with: "\\\\"))"},"action":{"type":"block"}}"#
        }
        let store = WKContentRuleListStore.default()
        store?.compileContentRuleList(forIdentifier: "post.block-remote", encodedContentRuleList: "[\(block)]") { [weak self] list, _ in
            guard let self, let list else { return }
            self.blockAll = list
            self.ruled = true
            self.allowImages(self.wantImages)
        }
        store?.compileContentRuleList(forIdentifier: "post.images-only", encodedContentRuleList: "[" + ([block, letImages] + tracks).joined(separator: ",") + "]") { [weak self] list, e in
            if let e { log("image rules: \(e)") }
            guard let self else { return }
            self.imagesOnly = list
            // A page drawn before the rules were ready had its images held
            // back; draw it again now that they can load.
            if self.wantImages, let (bg, img, then) = self.last { self.blank(background: bg, images: img, then: then) }
        }
    }

    static func csp(images: Bool) -> String {
        "default-src 'none'; img-src data: cid:\(images ? " https: http:" : ""); style-src 'unsafe-inline'; font-src data:; media-src 'none'; frame-src 'none'; form-action 'none'"
    }
    static let csp = csp(images: false)

    /// What the page on screen asked for; rule lists compiled after it
    /// loaded are applied to match, not over it.
    private var wantImages = false

    private func allowImages(_ on: Bool) {
        wantImages = on
        let ucc = view.configuration.userContentController
        ucc.removeAllContentRuleLists()
        if on, let imagesOnly { ucc.add(imagesOnly) } else if let blockAll { ucc.add(blockAll) }
    }

    /// Tracking pixels go before anything is drawn: any image sized 1×1 or 0.
    static func stripPixels(_ html: String) -> String {
        html.replacingOccurrences(of: #"<img[^>]*(width\s*=\s*["']?[01]["'\s>/]|height\s*=\s*["']?[01]["'\s>/])[^>]*>"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
    }

    static func hasRemoteImages(_ html: String) -> Bool {
        html.range(of: #"(src|background)\s*=\s*["']?https?:"#, options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: #"url\(\s*["']?https?:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func render(html: String) {
        loaded = nil
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
