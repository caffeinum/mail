import AppKit
import MailCore

/// A plain-text message. The From line isn't editable: it's the account the
/// thread lives in, or — for alias mail — the alias, with the relay doing
/// the rewriting.
final class ComposeWindow: NSObject, NSWindowDelegate {
    typealias Send = (OutgoingMessage, AliasRule?) -> Void

    private let window: ComposePanel
    private let to = NSTextField()
    private let cc = NSTextField()
    private let subject = NSTextField()
    private let body = NSTextView()
    private let box: Mailbox
    private var base: OutgoingMessage
    private let alias: AliasRule?
    private let send: Send
    private static var open: [ComposeWindow] = []

    init(box: Mailbox, mode: ReplyMode, thread: [MessageRecord], config: AccountsFile, send: @escaping Send) throws {
        self.box = box
        self.send = send
        let aliases = config.aliases(for: box.account)
        if mode == .new {
            base = OutgoingMessage(from: Address(email: box.account), to: [], subject: "", body: "")
            alias = box.alias
        } else {
            base = try Composer.draft(mode, thread: thread, account: box.account, aliases: aliases)
            alias = thread.lazy.compactMap { Composer.relay(for: $0, aliases: aliases)?.rule }.first
        }
        window = ComposePanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.title = mode == .new ? "New message" : (base.subject.isEmpty ? "Reply" : base.subject)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onSend = { [weak self] in self?.submit() }
        window.onClose = { [weak self] in self?.window.close() }
        build(mode: mode)
    }

    private func build(mode: ReplyMode) {
        let fromText: String
        if let alias { fromText = "\(alias.address)  (through \(alias.label) — your gmail address stays hidden)" }
        else { fromText = box.account }
        let from = NSTextField(labelWithString: fromText)
        from.textColor = .secondaryLabelColor
        from.font = .systemFont(ofSize: 12)
        func field(_ f: NSTextField, _ placeholder: String, _ value: String) {
            f.placeholderString = placeholder
            f.stringValue = value
            f.isBordered = false
            f.drawsBackground = false
            f.focusRingType = .none
            f.font = .systemFont(ofSize: 13)
        }
        field(to, "To", shownRecipients(base.to))
        field(cc, "Cc", shownRecipients(base.cc))
        field(subject, "Subject", base.subject)
        body.string = base.body
        body.font = .systemFont(ofSize: 14)
        body.isRichText = false
        body.isAutomaticQuoteSubstitutionEnabled = false
        body.allowsUndo = true
        body.textContainerInset = NSSize(width: 4, height: 8)
        let scroll = NSScrollView()
        scroll.documentView = body
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        body.autoresizingMask = [.width]
        body.isVerticallyResizable = true
        let hint = NSTextField(labelWithString: "⌘↩ send  ·  esc discard")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [from, to, cc, subject, scroll, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 22, bottom: 14, right: 22)
        for v in [to, cc, subject, scroll] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack
        window.initialFirstResponder = mode == .new || mode == .forward ? to : body
    }

    /// For an alias reply the relay addresses are what's really used; show
    /// the person behind them so the field reads like normal mail.
    private func shownRecipients(_ a: [Address]) -> String { a.header }

    func show() {
        Self.open.append(self)
        window.center()
        window.makeKeyAndOrderFront(nil)
        if window.initialFirstResponder === body { body.setSelectedRange(NSRange(location: 0, length: 0)) }
    }

    private func submit() {
        var m = base
        m.to = Address.parseList(to.stringValue)
        m.cc = Address.parseList(cc.stringValue)
        m.subject = subject.stringValue
        m.body = body.string
        if let alias, base.inReplyTo == nil {
            m = Composer.fromAlias(alias, account: box.account, to: m.to, cc: m.cc, subject: m.subject, body: m.body)
        }
        if let alias {
            do { try AliasRelay(alias).verify(m, account: box.account) }
            catch {
                let a = NSAlert()
                a.messageText = "Not sent"
                a.informativeText = "\(error)"
                a.beginSheetModal(for: window)
                return
            }
        }
        guard !m.to.isEmpty else { NSSound.beep(); window.makeFirstResponder(to); return }
        send(m, alias)
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

final class ComposePanel: NSWindow {
    var onSend: (() -> Void)?
    var onClose: (() -> Void)?

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command), e.keyCode == 36 || e.keyCode == 76 { onSend?(); return true }
        return super.performKeyEquivalent(with: e)
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }
}
