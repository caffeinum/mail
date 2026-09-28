import AppKit
import MailCore

/// One thread, drawn as a single page in the shared web view (see
/// Conversation). Nothing here waits on the network: a body not cached yet
/// shows its snippet until the prefetch lands.
final class ThreadView: NSView {
    private(set) var thread: ThreadSummary?
    private(set) var messages: [MessageRecord] = []
    private var openIndex = 0
    private var shownKey = ""

    var images: (MessageRecord) -> Bool = { _ in false }
    private(set) var reply: InlineReply?
    private var webBottom: NSLayoutConstraint?

    func show(_ t: ThreadSummary, messages: [MessageRecord], force: Bool = false) {
        let same = thread?.id == t.id && thread?.account == t.account
        if !same { closeReply() }
        thread = t
        self.messages = messages
        if !same { openIndex = max(0, messages.count - 1) }
        let key = t.id + messages.map { "\($0.id):\($0.hasBody)" }.joined()
        guard force || key != shownKey || WebRenderer.shared.view.superview !== self else { return }
        shownKey = key
        attach()
        Conversation.render(subject: t.subject, messages: messages, openIndex: openIndex, images: images)
    }

    var openMessage: MessageRecord? { messages.indices.contains(openIndex) ? messages[openIndex] : nil }

    private func attach() {
        let web = WebRenderer.shared.view
        guard web.superview !== self else { return }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        addSubview(web)
        let bottom = web.bottomAnchor.constraint(equalTo: reply?.topAnchor ?? bottomAnchor, constant: reply == nil ? 0 : -12)
        webBottom = bottom
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: topAnchor), bottom,
            web.leadingAnchor.constraint(equalTo: leadingAnchor), web.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// The reply box docks under the conversation, in the same 720pt column.
    func openReply(_ r: InlineReply) {
        closeReply()
        reply = r
        r.translatesAutoresizingMaskIntoConstraints = false
        addSubview(r)
        let web = WebRenderer.shared.view
        webBottom?.isActive = false
        let bottom = web.bottomAnchor.constraint(equalTo: r.topAnchor, constant: -12)
        webBottom = bottom
        let width = r.widthAnchor.constraint(equalToConstant: 720)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            bottom, width,
            r.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            r.centerXAnchor.constraint(equalTo: centerXAnchor),
            r.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            r.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
        ])
        r.focus()
    }

    func closeReply() {
        guard let r = reply else { return }
        r.removeFromSuperview()
        reply = nil
        let web = WebRenderer.shared.view
        guard web.superview === self else { return }
        webBottom?.isActive = false
        webBottom = web.bottomAnchor.constraint(equalTo: bottomAnchor)
        webBottom?.isActive = true
    }

    /// Scrolls by a step and says whether the page was already at that end
    /// before this press — the second press at the end moves to the next thread.
    func nudge(_ d: Int, done: @escaping (Bool) -> Void) {
        let js = """
        (() => { const el = document.scrollingElement; const max = el.scrollHeight - window.innerHeight;
          const atEnd = \(d) > 0 ? el.scrollTop >= max - 2 : el.scrollTop <= 2;
          if (!atEnd) window.scrollBy({ top: \(d) * Math.max(120, window.innerHeight * 0.33), behavior: 'instant' });
          return atEnd; })()
        """
        WebRenderer.shared.view.evaluateJavaScript(js) { r, _ in done((r as? Bool) ?? true) }
    }

    func scrollBody(by pages: CGFloat) {
        WebRenderer.shared.view.evaluateJavaScript("window.scrollBy(0, \(pages) * window.innerHeight * 0.9)")
    }
}
