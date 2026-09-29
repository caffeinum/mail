import AppKit
import MailCore

/// Accounts and streams down the left, the traffic lights sitting on top of
/// it. ⌘S hides it; the top bar then carries the account and streams.
final class Sidebar: NSView {
    static let width: CGFloat = 220
    var onAccount: ((Int) -> Void)?
    var onStream: ((View) -> Void)?
    var onRename: ((Int, String) -> Void)?
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
        if boxes.count > 1 {
            add(SidebarItem(title: "All accounts", trailing: .key("⌃0"), on: current?.isAll == true) { [weak self] in self?.onAccount?(-1) })
        }
        for (i, b) in boxes.enumerated() {
            let email = b.alias?.address ?? b.account
            let item = SidebarItem(title: b.title, subtitle: b.title == email ? nil : email, trailing: .key("⌃\(i + 1)"), on: b == current) { [weak self] in self?.onAccount?(i) }
            item.onRename = { [weak self] name in self?.onRename?(i, name) }
            add(item)
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

final class SidebarItem: NSView, NSTextFieldDelegate {
    enum Trailing { case key(String), count(String), badge(String) }
    private let action: () -> Void
    private let on: Bool
    private let t: NSTextField
    private let original: String
    /// Double-click edits the name in place; ↩ keeps it, esc puts it back.
    var onRename: ((String) -> Void)?

    init(title: String, subtitle: String? = nil, trailing: Trailing, on: Bool, action: @escaping () -> Void) {
        self.action = action
        self.on = on
        original = title
        t = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        t.font = .systemFont(ofSize: 13, weight: on ? .semibold : .regular)
        t.lineBreakMode = .byTruncatingTail
        t.delegate = self
        let left: NSView
        if let subtitle {
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = Palette.secondary
            sub.lineBreakMode = .byTruncatingMiddle
            sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let v = NSStackView(views: [t, sub])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 0
            left = v
        } else {
            left = t
        }
        let right: NSView
        switch trailing {
        case .key(let k):
            let l = NSTextField(labelWithString: k)
            l.font = .systemFont(ofSize: 10.5, weight: .regular)
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
        let s = NSStackView(views: [left, NSView(), right])
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

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, onRename != nil { beginRename(); return }
        action()
    }

    private func beginRename() {
        t.isEditable = true
        t.isBordered = false
        t.drawsBackground = true
        t.backgroundColor = Palette.background
        t.focusRingType = .none
        window?.makeFirstResponder(t)
        t.currentEditor()?.selectAll(nil)
    }

    private func endRename(save: Bool) {
        let name = t.stringValue.trimmingCharacters(in: .whitespaces)
        t.isEditable = false
        t.drawsBackground = false
        if save, !name.isEmpty, name != original { onRename?(name) } else { t.stringValue = original }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { endRename(save: true); window?.makeFirstResponder(nil); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { endRename(save: false); window?.makeFirstResponder(nil); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { if t.isEditable { endRename(save: true) } }
}
