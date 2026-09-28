import AppKit
import MailCore

/// Reply, reply all and forward open under the conversation, not in a
/// window. What you type goes above the quoted history, which is added on
/// send and never shown in the box.
final class InlineReply: NSView {
    private let to = NSTextField()
    private let text = ReplyText()
    private let hint = NSTextField(labelWithString: "⌘↩ send   ·   esc discard")
    private let box: Mailbox
    private let mode: ReplyMode
    private var base: OutgoingMessage
    private let alias: AliasRule?
    var onSend: ((OutgoingMessage, AliasRule?) -> Void)?
    var onCancel: (() -> Void)?

    init(box: Mailbox, mode: ReplyMode, thread: [MessageRecord], config: AccountsFile) throws {
        self.box = box
        self.mode = mode
        let aliases = config.aliases(for: box.account)
        base = try Composer.draft(mode, thread: thread, account: box.account, aliases: aliases)
        alias = thread.lazy.compactMap { Composer.relay(for: $0, aliases: aliases)?.rule }.first
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10

        let verb = mode == .forward ? "Forward to" : mode == .replyAll ? "Reply all to" : "Reply to"
        let lead = NSTextField(labelWithString: verb)
        lead.font = .systemFont(ofSize: 12)
        lead.textColor = .secondaryLabelColor
        to.stringValue = (base.to + base.cc).header
        to.placeholderString = "name@example.com"
        to.font = .systemFont(ofSize: 12)
        to.isBordered = false
        to.drawsBackground = false
        to.focusRingType = .none
        let via = NSTextField(labelWithString: alias.map { "via \($0.address)" } ?? "from \(box.account)")
        via.font = .systemFont(ofSize: 11)
        via.textColor = .tertiaryLabelColor
        let top = NSStackView(views: [lead, to, via])
        top.spacing = 6
        to.setContentHuggingPriority(.defaultLow, for: .horizontal)

        text.font = .systemFont(ofSize: 14)
        text.isRichText = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.textContainerInset = NSSize(width: 0, height: 6)
        text.onSend = { [weak self] in self?.submit() }
        text.onCancel = { [weak self] in self?.onCancel?() }
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        for v in [top, scroll, hint] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() { window?.makeFirstResponder(mode == .forward ? to : text) }

    var isEmpty: Bool { text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func submit() {
        var m = base
        let recipients = Address.parseList(to.stringValue)
        m.to = recipients
        m.cc = []
        m.body = text.string + base.body
        if let alias, base.inReplyTo == nil {
            m = Composer.fromAlias(alias, account: box.account, to: m.to, cc: [], subject: m.subject, body: m.body)
        }
        guard !m.to.isEmpty else { NSSound.beep(); window?.makeFirstResponder(to); return }
        if let alias {
            do { try AliasRelay(alias).verify(m, account: box.account) }
            catch { hint.stringValue = "Not sent — \(error)"; hint.textColor = .systemRed; return }
        }
        onSend?(m, alias)
    }
}

final class ReplyText: NSTextView {
    var onSend: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command), e.keyCode == 36 || e.keyCode == 76 { onSend?(); return }
        if e.keyCode == 53 { onCancel?(); return }
        super.keyDown(with: e)
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command), e.keyCode == 36 || e.keyCode == 76 { onSend?(); return true }
        return super.performKeyEquivalent(with: e)
    }
}
