import AppKit
import WebKit
import MailCore

/// The Feed as a stream: the emails themselves, one after another, grouped
/// by day, in the one web view. Each email's html lives in its own shadow
/// root so one newsletter's css can't restyle the next; who sent it, to
/// whom and when sit in a column on the right. Page script stays off; the
/// app builds and edits the page with its own script. Once drawn, the page
/// is only ever edited in place — a finished email is taken out and the
/// next slides up — so it never jumps under you.
final class FeedStream: NSView {
    private(set) var ids: [String] = []
    private var drawn = false
    private var images = false

    /// The web view went elsewhere (a thread was opened): draw afresh next time.
    func invalidate() { ids = []; drawn = false }
    var isDrawn: Bool { drawn && web.superview === self }

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
        var group = ""
        var from = ""
        var to = ""
        var account = ""
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

    static let full: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d, h:mm a"; return f
    }()

    static func item(_ t: ThreadSummary, _ m: MessageRecord?, images: Bool, account: String = "") -> Item {
        let html: String
        if let raw = m?.bodyHTML, !raw.isEmpty {
            let h = WebRenderer.stripPixels(raw)
            html = images ? h : Conversation.defuse(h)
        }
        else if let text = m?.bodyText, !text.isEmpty { html = "<pre>\(escape(text))</pre>" }
        else { html = "<p class=snip>\(escape(t.snippet))</p>" }
        let from = m?.shownFrom.map { $0.name.isEmpty ? $0.email : "\($0.name) <\($0.email)>" } ?? t.sender
        let to = m.map { ($0.to + $0.cc).map(\.display).joined(separator: ", ") } ?? ""
        return Item(id: t.id, sender: t.from, subject: t.subject,
                    when: full.string(from: Date(timeIntervalSince1970: TimeInterval(t.date) / 1000)),
                    html: html, cached: m?.hasBody ?? false, unread: t.unread, group: ListView.group(t.date),
                    from: from, to: to, account: account)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// First visit (or after `invalidate`) draws the page. After that the
    /// page is patched: emails that left are removed where they stand and
    /// nothing else moves. New mail waits for the next visit.
    func show(_ items: [Item], at index: Int, images: Bool) {
        attach()
        if drawn, images == self.images {
            let keep = Set(items.map(\.id))
            let gone = ids.filter { !keep.contains($0) }
            if !gone.isEmpty {
                ids.removeAll { !keep.contains($0) }
                run("remove(\(json(gone)))")
            }
            return
        }
        ids = items.map(\.id)
        self.images = images
        drawn = true
        WebRenderer.shared.blank(background: Palette.css.bg, images: images) { [weak self] in
            guard let self else { return }
            self.run(Self.script(dark: Palette.isDark) + "render(\(self.json(items))); go(\(index), false)")
        }
    }

    func scroll(to i: Int) { run("go(\(i), true)") }

    /// j/k from wherever the reader has scrolled to, not from where the
    /// cursor last was. Calls back with the new index and the one left.
    func step(_ d: Int, done: @escaping (Int, Int) -> Void) {
        web.evaluateJavaScript("(() => { const f = here(); return [step(\(d)), f]; })()") { r, _ in
            if let a = r as? [Int], a.count == 2 { done(a[0], a[1]) }
        }
    }

    /// The email at the top of the view right now — what any key acts on.
    func here(_ done: @escaping (Int) -> Void) {
        guard web.superview === self, !ids.isEmpty else { return }
        web.evaluateJavaScript("typeof here === 'function' ? mark(here()) : -1") { r, _ in
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

    static var script: String { script(dark: Palette.isDark) }

    static func script(dark: Bool) -> String {
        let fg = dark ? "#f2ede3" : "#2b2b30"
        let dim = dark ? "#9a9284" : "#8a8173"
        let line = dark ? "#34302a" : "#e0d8c7"
        return """
        var cur = 0;
        function card(it) {
          const a = document.createElement('article');
          a.id = 't' + it.id;
          if (!it.unread) a.classList.add('read');
          const body = document.createElement('section');
          body.className = 'body';
          const root = body.attachShadow({ mode: 'open' });
          root.innerHTML = '<style>:host{display:block;padding:18px 22px 22px;color:#1d1d1f;overflow-wrap:anywhere}' +
            'img{max-width:100%;height:auto}table{max-width:100%!important}pre{white-space:pre-wrap;font:14px -apple-system,sans-serif}' +
            '.snip{color:#86868b}</style>' + it.html;
          a.appendChild(body);
          if (it.sender || it.subject) {
            const m = document.createElement('aside');
            m.innerHTML = '<div class=s></div><div class=f></div><div class=a></div><div class=t></div><div class=w></div><div class=n></div>';
            m.children[0].textContent = it.subject;
            m.children[1].textContent = it.sender;
            m.children[2].textContent = it.from;
            m.children[3].textContent = it.to ? 'to ' + it.to : '';
            m.children[4].textContent = it.when + (it.account ? ' · ' + it.account : '');
            m.children[5].textContent = it.cached ? '' : 'preview — the full email is still downloading';
            a.appendChild(m);
          }
          return a;
        }
        function render(items) {
          document.body.innerHTML = '';
          const css = document.createElement('style');
          css.textContent = `
            body { font: 13px -apple-system, sans-serif; padding: 8px 20px 40vh; color: \(fg); }
            h6 { max-width: 980px; margin: 22px auto 10px; font: 600 11px -apple-system; letter-spacing: .08em; color: \(dim); }
            article { max-width: 980px; margin: 0 auto 18px; display: grid; grid-template-columns: minmax(0, 1fr) 220px; gap: 22px; align-items: start; }
            .body { background: #fffdf8; border-radius: 10px; box-shadow: 0 1px 3px rgba(0,0,0,.08); overflow: hidden; border-left: 3px solid transparent; }
            article.cur .body { border-left-color: #f0561f; }
            aside { position: sticky; top: 14px; padding-top: 4px; line-height: 1.45; }
            aside .s { font-size: 14px; font-weight: 600; margin-bottom: 6px; }
            aside .f { font-weight: 600; }
            aside .f::before { content: '● '; color: #f0561f; font-size: 9px; vertical-align: 2px; }
            article.read aside .f::before { content: ''; }
            article.read aside .s, article.read aside .f { font-weight: 400; }
            aside .a, aside .t, aside .w, aside .n { color: \(dim); font-size: 12px; overflow-wrap: anywhere; }
            aside .w { margin-top: 6px; }
            aside .n { margin-top: 8px; }
            @media (max-width: 760px) { article { grid-template-columns: 1fr; } aside { position: static; order: -1; } }`;
          document.head.appendChild(css);
          let group = null;
          for (const it of items) {
            if (it.group && it.group !== group) {
              const h = document.createElement('h6'); h.textContent = it.group.toUpperCase(); document.body.appendChild(h);
              group = it.group;
            }
            document.body.appendChild(card(it));
          }
        }
        // Take emails out where they stand; drop a day heading left empty.
        function remove(ids) {
          for (const id of ids) document.getElementById('t' + id)?.remove();
          for (const h of Array.from(document.querySelectorAll('h6'))) {
            const n = h.nextElementSibling;
            if (!n || n.tagName !== 'ARTICLE') h.remove();
          }
          return mark(here());
        }
        function arts() { return Array.from(document.querySelectorAll('article')); }
        function mark(i) {
          const a = arts(); if (!a.length) return -1;
          cur = Math.max(0, Math.min(i, a.length - 1));
          a.forEach((x, j) => x.classList.toggle('cur', j === cur));
          return cur;
        }
        function go(i, smooth) {
          const a = arts(); if (!a.length) return 0;
          mark(i);
          const h = a[cur].previousElementSibling;
          const top = (h && h.tagName === 'H6' ? h : a[cur]).offsetTop - 8;
          window.scrollTo({ top: top, behavior: smooth ? 'smooth' : 'instant' });
          return cur;
        }
        // The email you're looking at: the one under a line a third of the
        // way down the view — so a card whose tail is still at the top
        // doesn't keep the focus once the next one fills the screen.
        function here() {
          const a = arts(); if (!a.length) return 0;
          const line = window.scrollY + window.innerHeight / 3;
          for (let j = 0; j < a.length; j++) {
            const top = a[j].offsetTop, bottom = top + a[j].offsetHeight;
            if (line < bottom) return j;
          }
          return a.length - 1;
        }
        function step(d) { return go(here() + d, true); }
        """
    }
}
