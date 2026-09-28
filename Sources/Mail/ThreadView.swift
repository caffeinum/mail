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

    func show(_ t: ThreadSummary, messages: [MessageRecord]) {
        let same = thread?.id == t.id && thread?.account == t.account
        thread = t
        self.messages = messages
        if !same { openIndex = max(0, messages.count - 1) }
        let key = t.id + messages.map { "\($0.id):\($0.hasBody)" }.joined()
        guard key != shownKey || WebRenderer.shared.view.superview !== self else { return }
        shownKey = key
        attach()
        Conversation.render(subject: t.subject, messages: messages, openIndex: openIndex)
    }

    var openMessage: MessageRecord? { messages.indices.contains(openIndex) ? messages[openIndex] : nil }

    private func attach() {
        let web = WebRenderer.shared.view
        guard web.superview !== self else { return }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: topAnchor), web.bottomAnchor.constraint(equalTo: bottomAnchor),
            web.leadingAnchor.constraint(equalTo: leadingAnchor), web.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func scrollBody(by pages: CGFloat) {
        WebRenderer.shared.view.evaluateJavaScript("window.scrollBy(0, \(pages) * window.innerHeight * 0.9)")
    }
}
