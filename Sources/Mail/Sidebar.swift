import AppKit
import MailCore

/// Accounts and streams down the left, the traffic lights sitting on top of
/// it. ⌘S hides it; the top bar then carries the account and streams.
final class Sidebar: NSView {
    static let width: CGFloat = 220
    var onAccount: ((Int) -> Void)?
    var onStream: ((View) -> Void)?
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let edge = NSBox()
        edge.boxType = .separator
        edge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edge)
        NSLayoutConstraint.activate([
            edge.topAnchor.constraint(equalTo: topAnchor), edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.trailingAnchor.constraint(equalTo: trailingAnchor), edge.widthAnchor.constraint(equalToConstant: 1),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 52),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Palette.sidebar.cgColor
    }

    func update(boxes: [Mailbox], current: Mailbox?, view: View, counts: [View: Int]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !boxes.isEmpty else { return }
        stack.addArrangedSubview(heading("ACCOUNTS"))
        for (i, b) in boxes.enumerated() {
            add(SidebarItem(title: b.title, trailing: .key("⌃\(i + 1)"), on: b == current) { [weak self] in self?.onAccount?(i) })
        }
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(heading("STREAMS"))
        for v in View.tabs {
            let n = counts[v] ?? 0
            if v == .newSenders && n == 0 { continue }
            let trailing: SidebarItem.Trailing = v == .newSenders ? .badge("\(n)") : .count(n > 0 ? "\(n)" : "")
            let on: Bool = { if case .search = view { return false }; return v == view }()
            add(SidebarItem(title: v.title, trailing: trailing, on: on) { [weak self] in self?.onStream?(v) })
        }
    }

    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func heading(_ s: String) -> NSView {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 10.5, weight: .medium)
        t.textColor = Palette.secondary
        let wrap = NSView()
        t.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(t)
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 8), t.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 6),
            t.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4),
        ])
        return wrap
    }
}

final class SidebarItem: NSView {
    enum Trailing { case key(String), count(String), badge(String) }
    private let action: () -> Void
    private let on: Bool

    init(title: String, trailing: Trailing, on: Bool, action: @escaping () -> Void) {
        self.action = action
        self.on = on
        super.init(frame: .zero)
        wantsLayer = true
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: on ? .semibold : .regular)
        t.lineBreakMode = .byTruncatingTail
        let right: NSView
        switch trailing {
        case .key(let k):
            let l = NSTextField(labelWithString: k)
            l.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            l.textColor = .tertiaryLabelColor
            right = l
        case .count(let n):
            let l = NSTextField(labelWithString: n)
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            right = l
        case .badge(let n):
            let l = NSTextField(labelWithString: " \(n) ")
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = .white
            l.wantsLayer = true
            l.drawsBackground = true
            l.backgroundColor = Palette.accent
            l.layer?.cornerRadius = 8
            l.layer?.masksToBounds = true
            right = l
        }
        let s = NSStackView(views: [t, NSView(), right])
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            s.topAnchor.constraint(equalTo: topAnchor, constant: 5), s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 7
        layer?.backgroundColor = on ? Palette.line.cgColor : NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) { action() }
}
