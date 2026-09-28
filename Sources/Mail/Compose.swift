import AppKit
import MailCore

/// A new message, written in the main window in the same 720pt column as
/// the reader. The From line isn't editable: it's the account, or — for an
/// alias account — the alias, with the relay doing the rewriting.
final class ComposeView: NSView {
    typealias Send = (OutgoingMessage, AliasRule?) -> Void

    private let to = NSTextField()
    private let cc = NSTextField()
    private let subject = NSTextField()
    private let body = ReplyText()
    private let hint = NSTextField(labelWithString: "⌘↩ send   ·   esc discard")
    private let box: Mailbox
    private let alias: AliasRule?
    var onSend: Send?
    var onCancel: (() -> Void)?

    init(box: Mailbox) {
        self.box = box
        alias = box.alias
        super.init(frame: .zero)

        let title = NSTextField(labelWithString: "New message")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let from = NSTextField(labelWithString: alias.map { "from \($0.address) — your gmail address stays hidden" } ?? "from \(box.account)")
        from.textColor = .secondaryLabelColor
        from.font = .systemFont(ofSize: 12)
        for (f, p) in [(to, "To"), (cc, "Cc"), (subject, "Subject")] {
            f.placeholderString = p
            f.isBordered = false
            f.drawsBackground = false
            f.focusRingType = .none
            f.font = .systemFont(ofSize: 14)
        }
        body.font = .systemFont(ofSize: 14)
        body.isRichText = false
        body.drawsBackground = false
        body.isAutomaticQuoteSubstitutionEnabled = false
        body.allowsUndo = true
        body.textContainerInset = NSSize(width: 0, height: 8)
        body.onSend = { [weak self] in self?.submit() }
        body.onCancel = { [weak self] in self?.onCancel?() }
        let scroll = NSScrollView()
        scroll.documentView = body
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        body.autoresizingMask = [.width]
        body.isVerticallyResizable = true
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        func rule() -> NSView {
            let v = NSBox(); v.boxType = .separator; return v
        }
        let stack = NSStackView(views: [title, from, to, rule(), cc, rule(), subject, rule(), scroll, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let width = stack.widthAnchor.constraint(equalToConstant: 720)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            width,
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
        for v in stack.arrangedSubviews where v !== title && v !== from && v !== hint {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() { window?.makeFirstResponder(to) }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command), e.keyCode == 36 || e.keyCode == 76 { submit(); return true }
        return super.performKeyEquivalent(with: e)
    }

    private func submit() {
        var m = OutgoingMessage(from: Address(email: box.account), to: Address.parseList(to.stringValue),
                                cc: Address.parseList(cc.stringValue), subject: subject.stringValue, body: body.string)
        guard !m.to.isEmpty else { NSSound.beep(); window?.makeFirstResponder(to); return }
        if let alias {
            m = Composer.fromAlias(alias, account: box.account, to: m.to, cc: m.cc, subject: m.subject, body: m.body)
            do { try AliasRelay(alias).verify(m, account: box.account) }
            catch { hint.stringValue = "Not sent — \(error)"; hint.textColor = .systemRed; return }
        }
        onSend?(m, alias)
    }
}
