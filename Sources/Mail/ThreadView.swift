import AppKit
import MailCore

/// One thread: the subject, a line per earlier message, and the open
/// message's body below — plain text drawn natively, html in the shared
/// web view. Nothing here waits on the network: a body not cached yet shows
/// its snippet until the prefetch lands.
final class ThreadView: NSView {
    private let subject = NSTextField(labelWithString: "")
    private let headers = NSStackView()
    private let textScroll = NSScrollView()
    private let text = NSTextView()
    private let bodyHost = NSView()
    private(set) var thread: ThreadSummary?
    private(set) var messages: [MessageRecord] = []
    private var openIndex = 0
    private var shownKey = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        subject.font = .systemFont(ofSize: 20, weight: .semibold)
        subject.lineBreakMode = .byTruncatingTail
        subject.maximumNumberOfLines = 2
        subject.cell?.wraps = true
        headers.orientation = .vertical
        headers.alignment = .leading
        headers.spacing = 2

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: 24, height: 16)
        text.isAutomaticLinkDetectionEnabled = true
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        textScroll.documentView = text
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.drawsBackground = false

        for v in [subject, headers, bodyHost] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            subject.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            subject.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            subject.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            headers.topAnchor.constraint(equalTo: subject.bottomAnchor, constant: 12),
            headers.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            headers.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            bodyHost.topAnchor.constraint(equalTo: headers.bottomAnchor, constant: 8),
            bodyHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ t: ThreadSummary, messages: [MessageRecord]) {
        let sameThread = thread?.id == t.id && thread?.account == t.account
        thread = t
        self.messages = messages
        if !sameThread { openIndex = max(0, messages.count - 1) }
        openIndex = min(openIndex, max(0, messages.count - 1))
        subject.stringValue = t.subject.isEmpty ? "(no subject)" : t.subject
        rebuildHeaders()
        renderBody()
    }

    func open(message i: Int) {
        guard messages.indices.contains(i) else { return }
        openIndex = i
        rebuildHeaders()
        renderBody()
    }

    var openMessage: MessageRecord? { messages.indices.contains(openIndex) ? messages[openIndex] : nil }

    private func rebuildHeaders() {
        headers.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, m) in messages.enumerated() {
            let row = HeaderRow(message: m, open: i == openIndex) { [weak self] in self?.open(message: i) }
            headers.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: headers.widthAnchor).isActive = true
        }
    }

    private func renderBody() {
        guard let m = openMessage else { return }
        let key = "\(m.id):\(m.hasBody)"
        guard key != shownKey else { return }
        shownKey = key
        bodyHost.subviews.forEach { $0.removeFromSuperview() }
        if let html = m.bodyHTML, !html.isEmpty, (m.bodyText ?? "").isEmpty || prefersHTML(m) {
            let web = WebRenderer.shared.view
            attach(web)
            WebRenderer.shared.render(html: html)
        } else {
            attach(textScroll)
            let body: String
            let color: NSColor
            if m.hasBody { body = m.bodyText ?? ""; color = .labelColor }
            else { body = m.snippet; color = .secondaryLabelColor }
            text.string = body
            text.textColor = color
            text.font = .systemFont(ofSize: 14)
            text.checkTextInDocument(nil)
            text.scroll(.zero)
        }
    }

    /// Html wins when there is one: a text/plain alternative is often a
    /// bare "view this in a browser".
    private func prefersHTML(_ m: MessageRecord) -> Bool { m.bodyHTML != nil }

    private func attach(_ v: NSView) {
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        bodyHost.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: bodyHost.topAnchor),
            v.bottomAnchor.constraint(equalTo: bodyHost.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: bodyHost.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor),
        ])
    }

    func scrollBody(by pages: CGFloat) {
        if textScroll.superview != nil {
            let clip = textScroll.contentView
            var p = clip.bounds.origin
            p.y = max(0, p.y + clip.bounds.height * 0.9 * pages)
            clip.scroll(to: p)
            textScroll.reflectScrolledClipView(clip)
        } else {
            WebRenderer.shared.view.pageScroll(pages)
        }
    }
}

extension NSView {
    func pageScroll(_ pages: CGFloat) {
        if let sv = enclosingScrollView ?? subviews.compactMap({ $0 as? NSScrollView }).first {
            let clip = sv.contentView
            var p = clip.bounds.origin
            p.y += clip.bounds.height * 0.9 * pages
            clip.scroll(to: p)
            sv.reflectScrolledClipView(clip)
        }
    }
}

final class HeaderRow: NSView {
    private let action: () -> Void

    init(message m: MessageRecord, open: Bool, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        let who = NSTextField(labelWithString: m.shownFrom?.display ?? "?")
        who.font = open ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
        let detail: String
        if open {
            var parts = [m.shownFrom?.email ?? ""]
            if !m.to.isEmpty { parts.append("to " + m.to.map(\.display).joined(separator: ", ")) }
            if m.duckFrom != nil { parts.append("via \(m.duckTo ?? "alias")") }
            detail = parts.joined(separator: "  ·  ")
        } else {
            detail = m.snippet
        }
        let rest = NSTextField(labelWithString: detail)
        rest.font = .systemFont(ofSize: 12)
        rest.textColor = .secondaryLabelColor
        rest.lineBreakMode = .byTruncatingTail
        rest.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let when = NSTextField(labelWithString: ThreadRow.when(m.date))
        when.font = .systemFont(ofSize: 12)
        when.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [who, rest, when])
        stack.spacing = 10
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        rest.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { action() }
}
