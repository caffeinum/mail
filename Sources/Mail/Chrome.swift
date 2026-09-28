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
        bar = NSStackView(views: [account, tabs, NSView(), note])
        bar.spacing = 20
        bar.edgeInsets = NSEdgeInsets(top: 0, left: Style.gutter - 6, bottom: 0, right: Style.gutter)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor), bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(boxes: [Mailbox], current: Mailbox?, view: View, counts: [View: Int], note text: String?) {
        self.boxes = boxes
        account.title = current.map { "\($0.title) ▾" } ?? ""
        account.isHidden = boxes.isEmpty
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

/// ? — every key on one sheet.
final class Help {
    static let shared = Help()
    private var panel: NSPanel?

    static let keys: [(String, String)] = [
        ("j / k", "next / previous"), ("g g / G", "top / bottom"), ("o / ↩", "open"), ("u / esc", "back"),
        ("e", "done (out of the inbox)"), ("#", "trash"), ("U", "read / unread"), ("z", "undo"),
        ("/", "search"), ("⌘K", "command palette"), ("c", "compose"), ("r / R / F", "reply / reply all / forward"),
        ("⌘↩", "send"), ("g i / g f / g p / g n", "inbox / feed / paper trail / new senders"),
        ("1 2 3 …", "switch account"), ("a · f · p · x", "new sender: let in · feed · paper trail · block"),
        ("space", "page down in a message"), ("⌘,", "accounts"), ("?", "this sheet"),
    ]

    func toggle(over window: NSWindow) {
        if let p = panel, p.isVisible { p.orderOut(nil); return }
        let p = panel ?? make()
        panel = p
        let f = window.frame
        p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.midY - p.frame.height / 2))
        p.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSPanel {
        let grid = NSGridView(views: Self.keys.map { k, v in
            let a = NSTextField(labelWithString: k); a.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            let b = NSTextField(labelWithString: v); b.font = .systemFont(ofSize: 13); b.textColor = .secondaryLabelColor
            return [a, b]
        })
        grid.rowSpacing = 7
        grid.columnSpacing = 24
        grid.translatesAutoresizingMaskIntoConstraints = false
        let p = HelpPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.title = "Keys"
        p.isReleasedWhenClosed = false
        let host = NSView()
        host.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: host.topAnchor, constant: 40), grid.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 32),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -32), grid.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -28),
        ])
        p.contentView = host
        p.setContentSize(host.fittingSize)
        return p
    }
}

final class HelpPanel: NSPanel {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.charactersIgnoringModifiers == "?" { orderOut(nil) } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
