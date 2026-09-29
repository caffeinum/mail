import AppKit
import MailCore

/// Account on the left, the four streams, a search field that appears on /.
final class HeaderBar: NSView {
    let account = NSButton(title: "", target: nil, action: nil)
    let tabs = NSStackView()
    /// Made on first use: nothing on the first frame needs it.
    private(set) lazy var search: NSSearchField = {
        let f = NSSearchField()
        f.placeholderString = "Search"
        f.sendsSearchStringImmediately = true
        f.focusRingType = .none
        f.delegate = searchDelegate
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: 240).isActive = true
        bar.addArrangedSubview(f)
        return f
    }()
    weak var searchDelegate: NSSearchFieldDelegate?
    var searching: Bool { searchIfMade?.isHidden == false }
    private var searchIfMade: NSSearchField? { bar.arrangedSubviews.last as? NSSearchField }
    private var bar = NSStackView()
    private var boxes: [Mailbox] = []
    let note = NSTextField(labelWithString: "")
    /// With the sidebar showing, the bar only names where you are; hidden,
    /// it carries the account and the streams itself.
    let title = NSTextField(labelWithString: "")
    var sidebarShown = true
    private var leadInset: NSLayoutConstraint?
    var onTab: ((View) -> Void)?
    var onAccount: ((Int) -> Void)?
    private var tabViews: [View] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        account.isBordered = false
        account.font = .systemFont(ofSize: 13, weight: .semibold)
        account.target = self
        account.action = #selector(pickAccount)
        tabs.spacing = 18
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        bar = NSStackView(views: [title, account, tabs, NSView(), note])
        bar.spacing = 20
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: Style.gutter)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor), bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        leadInset = bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28)
        leadInset?.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(boxes: [Mailbox], current: Mailbox?, view: View, counts: [View: Int], note text: String?) {
        self.boxes = boxes
        account.title = current.map { "\($0.title) ▾" } ?? ""
        account.isHidden = boxes.isEmpty || sidebarShown
        tabs.isHidden = sidebarShown
        title.isHidden = !sidebarShown
        title.stringValue = view.title
        leadInset?.constant = sidebarShown ? 28 : 84
        tabs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabViews = View.tabs
        for (i, v) in View.tabs.enumerated() {
            let n = counts[v] ?? 0
            var title = v.title
            if v == .newSenders { if n == 0 { continue }; title += " \(n)" }
            let b = NSButton(title: title, target: self, action: #selector(tab(_:)))
            b.tag = i
            b.isBordered = false
            let on = v == view
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: on ? .semibold : .regular),
                .foregroundColor: on ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
            tabs.addArrangedSubview(b)
        }
        if case .search = view { search.isHidden = false }
        else if let f = searchIfMade, f.currentEditor() == nil { f.isHidden = true }
        note.stringValue = text ?? ""
    }

    @objc private func tab(_ b: NSButton) { onTab?(tabViews[b.tag]) }
    @objc private func pickAccount() {
        let m = NSMenu()
        for (i, b) in boxes.enumerated() {
            let item = NSMenuItem(title: b.title, action: #selector(picked(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            m.addItem(item)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: account.bounds.height + 4), in: account)
    }

    @objc private func picked(_ item: NSMenuItem) { onAccount?(item.tag) }
}

final class Toast: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hide: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.85).cgColor
        label.textColor = .textBackgroundColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ s: String) {
        label.stringValue = s
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.85).cgColor
        isHidden = false
        alphaValue = 1
        hide?.cancel()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self?.animator().alphaValue = 0 }) { self?.isHidden = true }
        }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: w)
    }
}

/// Something laid over the main window — never a window of its own: a dim
/// backdrop and a card in the middle. Clicking the backdrop closes it.
class Overlay: NSView {
    let card = NSView()
    var onClose: (() -> Void)?

    init(width: CGFloat, top: CGFloat? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        card.wantsLayer = true
        card.layer?.backgroundColor = Palette.background.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        var c = [card.centerXAnchor.constraint(equalTo: centerXAnchor), card.widthAnchor.constraint(equalToConstant: width)]
        if let top { c.append(card.topAnchor.constraint(equalTo: topAnchor, constant: top)) }
        else { c.append(card.centerYAnchor.constraint(equalTo: centerYAnchor)) }
        NSLayoutConstraint.activate(c)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    func show(in host: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor), bottomAnchor.constraint(equalTo: host.bottomAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor), trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }
}

/// ? — every key on one card.
final class HelpOverlay: Overlay {
    static let keys: [(String, String)] = [
        ("j / k", "next / previous"), ("g g / G", "top / bottom"), ("o / ↩", "open"), ("u / esc", "back"),
        ("e", "done (out of the inbox)"), ("#", "trash"), ("!", "spam (again in Spam: not spam)"), ("g x", "spam folder"), ("M", "mute sender (g m: Muted)"), ("U", "read / unread"), ("z", "undo"),
        ("/", "search"), ("⌘K", "command palette"), ("c", "new message"), ("r / R / F", "reply / reply all / forward"),
        ("⌘↩", "send"), ("tab / ⇧tab", "next / previous stream"), ("g i · g f · g p · g o · g n", "inbox · feed · paper trail · notifications · new senders"),
        ("⌃1 ⌃2 ⌃3", "switch account"), ("a · s · p · n · x · y", "new sender: inbox · feed (subscribe) · paper trail · notifications · block · as suggested"),
        ("i / ⇧I", "images for this email / always from sender"), ("m", "move sender to inbox · feed · paper trail"), ("v", "feed as stream / list"),
        ("space", "scroll"), ("⌘R", "check for mail"), ("⌘,", "accounts"), ("?", "this card"),
    ]

    init() {
        super.init(width: 540)
        let grid = NSGridView(views: Self.keys.map { k, v in
            let a = NSTextField(labelWithString: k); a.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            let b = NSTextField(labelWithString: v); b.font = .systemFont(ofSize: 13); b.textColor = .secondaryLabelColor
            return [a, b]
        })
        grid.rowSpacing = 7
        grid.columnSpacing = 24
        grid.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: card.topAnchor, constant: 24), grid.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -28), grid.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// m — move a thread's sender to a stream. It teaches the sorting: every
/// thread from them, now and later, goes there too.
final class MoveOverlay: Overlay {
    static let choices: [(key: String, title: String, decision: String)] = [
        ("i", "Inbox", "inbox"), ("s", "Feed (subscribe)", "feed"), ("p", "Paper Trail", "paper"), ("n", "Notifications", "notify"), ("m", "Muted", "muted"), ("x", "Block", "blocked"),
    ]
    let email: String
    let account: String

    init(sender: String, email: String, account: String, current: String) {
        self.email = email
        self.account = account
        super.init(width: 420, top: 140)
        let title = NSTextField(labelWithString: "Move \(sender) to…")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let sub = NSTextField(wrappingLabelWithString: "Everything from \(email) goes there from now on.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        var rows: [NSView] = [title, sub]
        for c in Self.choices {
            let k = NSTextField(labelWithString: c.key)
            k.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            k.textColor = .secondaryLabelColor
            let t = NSTextField(labelWithString: c.title + (c.decision == current ? "  (now)" : ""))
            t.font = .systemFont(ofSize: 14)
            rows.append(NSStackView(views: [k, t]))
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20), stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -24), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            sub.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
