import AppKit
import MailCore

/// A thread as one page, superhuman-style: a centered column in the app's
/// own colors, earlier messages folded to a line, quoted history folded
/// behind •••, the newest message open. Everyday mail takes on the theme;
/// a designed email (tables, its own backgrounds) keeps its look on a white
/// card. Folding uses <details>, so no page script is needed; the app's own
/// script only builds the page.
enum Conversation {
    struct Msg: Encodable {
        let from: String
        let email: String
        let to: String
        let when: String
        let snippet: String
        let html: String
        let designed: Bool
        let open: Bool
        let pending: Bool
        let blocked: Bool
    }

    /// A message whose images stay off has every remote reference defused
    /// in the markup, so the page may let images in for the others.
    static func defuse(_ h: String) -> String {
        h.replacingOccurrences(of: #"((?:src|background)\s*=\s*["']?|url\(\s*["']?)(https?:)"#, with: "$1blocked-$2",
                               options: [.regularExpression, .caseInsensitive])
    }

    static var dark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    static func render(subject: String, messages: [MessageRecord], openIndex: Int, images: (MessageRecord) -> Bool) {
        let msgs = messages.enumerated().map { i, m in msg(m, open: i == openIndex || i == messages.count - 1, images: images(m)) }
        let anyImages = msgs.contains { !$0.blocked } && messages.contains(where: images)
        let payload = String(decoding: (try? JSONEncoder().encode(msgs)) ?? Data("[]".utf8), as: UTF8.self)
        let title = String(decoding: (try? JSONEncoder().encode([subject.isEmpty ? "(no subject)" : subject])) ?? Data("[\"\"]".utf8), as: UTF8.self)
        let bg = dark ? "#1e1e1e" : "#ffffff"
        WebRenderer.shared.blank(background: bg, images: anyImages) {
            WebRenderer.shared.view.evaluateJavaScript(script(dark: dark) + "render(\(title)[0], \(payload))") { _, e in
                if let e { log("conversation js: \(e)") }
            }
        }
    }

    static func msg(_ m: MessageRecord, open: Bool, images: Bool) -> Msg {
        var html: String
        var designed = false
        var blocked = false
        if let raw = m.bodyHTML, !raw.isEmpty {
            let h = WebRenderer.stripPixels(raw)
            designed = isDesigned(h)
            blocked = !images && WebRenderer.hasRemoteImages(h)
            html = images ? h : defuse(h)
        } else if let t = m.bodyText, !t.isEmpty {
            html = plain(t)
        } else {
            html = "<p class=pending>\(escape(m.snippet))</p>"
        }
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return Msg(from: m.shownFrom?.display ?? "?", email: m.shownFrom?.email ?? "",
                   to: m.to.map(\.display).joined(separator: ", "),
                   when: f.string(from: Date(timeIntervalSince1970: TimeInterval(m.date) / 1000)),
                   snippet: m.snippet, html: html, designed: designed, open: open, pending: !m.hasBody, blocked: blocked)
    }

    /// Newsletters and receipts paint their own page; personal mail doesn't.
    static func isDesigned(_ h: String) -> Bool {
        let l = h.lowercased()
        let paints = l.components(separatedBy: "background").count - 1 + l.components(separatedBy: "bgcolor").count - 1
        return paints >= 3 || (l.contains("<table") && l.components(separatedBy: "<table").count > 3)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Plain text: links made clickable, and everything from the first
    /// "On … wrote:" or run of "> " lines folded away.
    static func plain(_ t: String) -> String {
        var lines = t.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var quoted: [String] = []
        if let cut = lines.firstIndex(where: { l in
            let s = l.trimmingCharacters(in: .whitespaces)
            return (s.hasPrefix("On ") && s.hasSuffix("wrote:")) || s.hasPrefix(">") || s.hasPrefix("-----Original Message")
        }) {
            quoted = Array(lines[cut...])
            lines = Array(lines[..<cut])
        }
        func html(_ ls: [String]) -> String {
            let e = escape(ls.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
            return e.replacingOccurrences(of: #"(https?://[^\s<>"]+)"#, with: "<a href=\"$1\">$1</a>", options: .regularExpression)
        }
        var out = "<div class=plain>\(html(lines))</div>"
        if !quoted.isEmpty { out += "<details class=q><summary>•••</summary><div class=plain>\(html(quoted))</div></details>" }
        return out
    }

    static func script(dark: Bool) -> String {
        let fg = dark ? "#e8e8e8" : "#1d1d1f"
        let dim = dark ? "#8e8e93" : "#86868b"
        let line = dark ? "#333" : "#e5e5e5"
        let link = dark ? "#6cb4ff" : "#0a66d8"
        return """
        function render(subject, msgs) {
          const css = document.createElement('style');
          css.textContent = `
            body { font: 15px/1.55 -apple-system, sans-serif; color: \(fg); padding: 28px 24px 30vh; }
            main { max-width: 720px; margin: 0 auto; }
            h1 { font-size: 22px; font-weight: 600; margin: 0 0 22px; line-height: 1.3; }
            details.m { border-top: 1px solid \(line); padding: 12px 0; }
            details.m > summary { list-style: none; cursor: pointer; display: flex; gap: 12px; align-items: baseline; }
            details.m > summary::-webkit-details-marker { display: none; }
            .who { font-weight: 600; white-space: nowrap; }
            .snip { color: \(dim); flex: 1; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
            details.m[open] .snip { visibility: hidden; }
            .when { color: \(dim); font-size: 12px; white-space: nowrap; margin-left: auto; }
            .to { color: \(dim); font-size: 13px; margin: 2px 0 12px; }
            .body { margin-top: 6px; }
            .imgs { color: \(dim); font-size: 12px; margin: -6px 0 10px; }`;
          document.head.appendChild(css);
          const main = document.createElement('main');
          const h = document.createElement('h1'); h.textContent = subject; main.appendChild(h);
          let last;
          for (const m of msgs) {
            const d = document.createElement('details'); d.className = 'm'; d.open = m.open;
            const s = document.createElement('summary');
            s.innerHTML = '<span class=who></span><span class=snip></span><span class=when></span>';
            s.children[0].textContent = m.from; s.children[1].textContent = m.snippet; s.children[2].textContent = m.when;
            d.appendChild(s);
            const to = document.createElement('div'); to.className = 'to';
            to.textContent = m.email + (m.to ? '  →  ' + m.to : ''); d.appendChild(to);
            if (m.blocked) { const n = document.createElement('div'); n.className = 'imgs';
              n.textContent = 'Images blocked  ·  i to load  ·  ⇧I always from ' + m.from; d.appendChild(n); }
            const b = document.createElement('div'); b.className = 'body';
            const root = b.attachShadow({ mode: 'open' });
            const own = m.designed
              ? ':host{display:block;background:#fff;color:#1d1d1f;border-radius:10px;padding:18px;overflow:hidden}'
              : ':host{display:block;color:\(fg);overflow-wrap:anywhere} *{color:inherit!important;background:transparent!important;font-family:inherit!important} a{color:\(link)!important}';
            root.innerHTML = '<style>' + own +
              'img{max-width:100%;height:auto}table{max-width:100%!important}' +
              '.plain{white-space:pre-wrap} .pending{color:\(dim)} details.q>summary{list-style:none;cursor:pointer;color:\(dim);' +
              'display:inline-block;padding:0 8px;border-radius:6px;background:rgba(127,127,127,.18)!important;font-size:12px;letter-spacing:2px}' +
              'details.q>summary::-webkit-details-marker{display:none} blockquote{margin:0 0 0 2px;padding-left:12px;border-left:2px solid \(line)}</style>' + m.html;
            fold(root);
            d.appendChild(b);
            main.appendChild(d);
            last = d;
          }
          document.body.appendChild(main);
          if (msgs.length > 1 && last) window.scrollTo(0, last.offsetTop - 20);
        }
        // Quoted history in html mail goes behind •••, as in plain text.
        function fold(root) {
          const sel = '.gmail_quote, blockquote[type=cite], .gmail_extra, #appendonsend, .yahoo_quoted, div[id^=divRplyFwdMsg]';
          for (const q of Array.from(root.querySelectorAll(sel))) {
            if (q.closest('details.q')) continue;
            const d = document.createElement('details'); d.className = 'q';
            const s = document.createElement('summary'); s.textContent = '•••';
            q.parentNode.insertBefore(d, q); d.appendChild(s); d.appendChild(q);
          }
        }
        """
    }
}
