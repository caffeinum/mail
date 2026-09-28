import AppKit
import WebKit
import MailCore

/// The Feed as a stream: the emails themselves, one after another, in the
/// one web view. Each email's html lives in its own shadow root so one
/// newsletter's css can't restyle the next. Page script stays off; the app
/// builds the page with its own script.
final class FeedStream: NSView {
    private(set) var ids: [String] = []
    private var cached = Set<String>()

    /// The web view went elsewhere (a thread was opened): draw afresh next time.
    func invalidate() { ids = []; cached = [] }
    var onPick: ((Int) -> Void)?

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    private var web: WKWebView { WebRenderer.shared.view }

    private func attach() {
        guard web.superview !== self else { return }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: topAnchor), web.bottomAnchor.constraint(equalTo: bottomAnchor),
            web.leadingAnchor.constraint(equalTo: leadingAnchor), web.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    struct Item: Encodable {
        let id: String
        let sender: String
        let subject: String
        let when: String
        let html: String
        let cached: Bool
        var unread = false
    }

    /// One email as a card, for the thread view: same isolation and
    /// readable column as the stream, headers left to the native view.
    static func card(html: String) {
        let html = Conversation.defuse(WebRenderer.stripPixels(html))
        let item = Item(id: "one", sender: "", subject: "", when: "", html: html, cached: true)
        let data = String(decoding: (try? JSONEncoder().encode([item])) ?? Data("[]".utf8), as: UTF8.self)
        WebRenderer.shared.blank(background: Palette.css.bg) {
            WebRenderer.shared.view.evaluateJavaScript(script + "render(\(data))") { _, e in if let e { log("card js: \(e)") } }
        }
    }

    static func item(_ t: ThreadSummary, _ m: MessageRecord?, images: Bool) -> Item {
        let html: String
        if let raw = m?.bodyHTML, !raw.isEmpty {
            let h = WebRenderer.stripPixels(raw)
            html = images ? h : Conversation.defuse(h)
        }
        else if let text = m?.bodyText, !text.isEmpty { html = "<pre>\(escape(text))</pre>" }
        else { html = "<p class=snip>\(escape(t.snippet))</p>" }
        return Item(id: t.id, sender: t.sender, subject: t.subject, when: ThreadRow.when(t.date), html: html, cached: m?.hasBody ?? false, unread: t.unread)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Draws the stream, or — when only some emails left it (done, trash) —
    /// takes those out in place so the scroll position holds.
    private var images = false

    func show(_ items: [Item], at index: Int, images: Bool) {
        attach()
        let newIDs = items.map(\.id)
        let newCached = Set(items.filter(\.cached).map(\.id))
        if !ids.isEmpty, Set(newIDs).isSubset(of: Set(ids)), newIDs == ids.filter(Set(newIDs).contains),
           newCached.isSubset(of: cached), images == self.images {
            let gone = ids.filter { !Set(newIDs).contains($0) }
            ids = newIDs
            if !gone.isEmpty { run("for (const id of \(json(gone))) document.getElementById('t'+id)?.remove(); mark(\(index))") }
            return
        }
        ids = newIDs
        cached = newCached
        self.images = images
        WebRenderer.shared.blank(background: Palette.css.bg, images: images) { [weak self] in
            guard let self else { return }
            self.run(Self.script + "render(\(self.json(items))); go(\(index), false)")
        }
    }

    func scroll(to i: Int) { run("go(\(i), true)") }

    /// j/k from wherever the reader has scrolled to, not from where the
    /// cursor last was.
    /// Calls back with the new index and the one stepped away from.
    func step(_ d: Int, done: @escaping (Int, Int) -> Void) {
        web.evaluateJavaScript("(() => { const f = here(); return [step(\(d)), f]; })()") { r, _ in
            if let a = r as? [Int], a.count == 2 { done(a[0], a[1]) }
        }
    }

    /// The post at the top of the view right now.
    func here(_ done: @escaping (Int) -> Void) {
        guard web.superview === self, !ids.isEmpty else { return }
        web.evaluateJavaScript("typeof here === 'function' ? here() : -1") { r, _ in
            if let i = r as? Int, i >= 0 { done(i) }
        }
    }

    func markRead(_ ids: [String]) {
        run("for (const id of \(json(ids))) document.getElementById('t'+id)?.classList.add('read')")
    }

    func page(_ d: CGFloat) { run("window.scrollBy(0, \(d) * window.innerHeight * 0.9)") }

    private func run(_ js: String) {
        web.evaluateJavaScript(js) { _, e in if let e { log("feed stream js: \(e)") } }
    }

    private func json<T: Encodable>(_ v: T) -> String {
        String(decoding: (try? JSONEncoder().encode(v)) ?? Data("[]".utf8), as: UTF8.self)
    }

    static let script = """
    var cur = 0;
    function render(items) {
      document.body.innerHTML = '';
      const css = document.createElement('style');
      css.textContent = `
        body { font: 14px -apple-system, sans-serif; padding: 18px 0 40vh; }
        article { max-width: 760px; margin: 0 auto 22px; background: #fffdf8; border-radius: 10px;
                  box-shadow: 0 1px 3px rgba(0,0,0,.08); overflow: hidden; border-left: 3px solid transparent; }
        article.cur { border-left-color: #f0561f; }
        article header b::before { content: '● '; color: #f0561f; font-size: 10px; vertical-align: 2px; }
        article.read header b::before { content: ''; }
        article.read header { color: #86868b; }
        header { padding: 14px 22px 10px; border-bottom: 1px solid #eee; color: #1d1d1f; }
        header b { font-weight: 600; } header span { color: #86868b; float: right; font-size: 12px; }
        header div { font-size: 16px; font-weight: 600; margin-top: 4px; }
        .note { color: #86868b; font-size: 12px; padding: 0 22px 12px; }`;
      document.head.appendChild(css);
      for (const it of items) {
        const a = document.createElement('article');
        a.id = 't' + it.id;
        if (!it.unread) a.classList.add('read');
        if (it.sender || it.subject) {
        const h = document.createElement('header');
        h.innerHTML = '<span></span><b></b><div></div>';
        h.children[0].textContent = it.when;
        h.children[1].textContent = it.sender;
        h.children[2].textContent = it.subject;
        a.appendChild(h);
        }
        const body = document.createElement('section');
        const root = body.attachShadow({ mode: 'open' });
        root.innerHTML = '<style>:host{display:block;padding:16px 22px 22px;color:#1d1d1f;overflow-wrap:anywhere}' +
          'img{max-width:100%;height:auto}table{max-width:100%!important}pre{white-space:pre-wrap;font:13px ui-monospace,monospace}' +
          '.snip{color:#86868b}</style>' + it.html;
        a.appendChild(body);
        if (!it.cached) { const n = document.createElement('div'); n.className = 'note'; n.textContent = 'preview — the full email is still downloading'; a.appendChild(n); }
        document.body.appendChild(a);
      }
    }
    function arts() { return Array.from(document.querySelectorAll('article')); }
    function mark(i) {
      const a = arts(); if (!a.length) return 0;
      cur = Math.max(0, Math.min(i, a.length - 1));
      a.forEach((x, j) => x.classList.toggle('cur', j === cur));
      return cur;
    }
    function go(i, smooth) {
      const a = arts(); if (!a.length) return 0;
      mark(i);
      window.scrollTo({ top: a[cur].offsetTop - 12, behavior: smooth ? 'smooth' : 'instant' });
      return cur;
    }
    function here() {
      const a = arts(); const y = window.scrollY + 40;
      let i = 0; for (let j = 0; j < a.length; j++) if (a[j].offsetTop <= y) i = j;
      return i;
    }
    function step(d) { return go(here() + d, true); }
    """
}
