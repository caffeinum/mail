import AppKit
import MailCore

/// ⌘K: type a few letters of any command, ↩ runs it. Drawn over the main
/// window, not in one of its own.
final class PaletteOverlay: Overlay, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    struct Command { let title: String; let key: String; let run: () -> Void }

    private let field = NSTextField()
    private let table = NSTableView()
    private let all: [Command]
    private var shown: [Command] = []

    init(for m: MainController) {
        all = Self.commands(m)
        super.init(width: 520, top: 110)
        field.placeholderString = "Type a command"
        field.font = .systemFont(ofSize: 17)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.delegate = self
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.headerView = nil
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.backgroundColor = .clear
        table.target = self
        table.action = #selector(clicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        for v in [field, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(v) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: card.topAnchor, constant: 16), field.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6), scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            scroll.heightAnchor.constraint(equalToConstant: 300),
        ])
        filter()
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() { window?.makeFirstResponder(field) }

    static func commands(_ m: MainController) -> [Command] {
        var c: [Command] = [
            .init(title: "Go to Inbox", key: "g i") { m.go(.inbox) },
            .init(title: "Go to Notifications", key: "g o") { m.go(.notifications) },
            .init(title: "Go to Feed", key: "g f") { m.go(.feed) },
            .init(title: "Go to Paper Trail", key: "g p") { m.go(.paper) },
            .init(title: "Go to New Senders", key: "g n") { m.go(.newSenders) },
            .init(title: "Go to Spam", key: "g x") { m.go(.spam) },
            .init(title: "Go to Muted", key: "g m") { m.go(.muted) },
            .init(title: "New Message", key: "c") { m.compose(.new) },
            .init(title: "Reply", key: "r") { m.compose(.reply) },
            .init(title: "Reply All", key: "R") { m.compose(.replyAll) },
            .init(title: "Forward", key: "F") { m.compose(.forward) },
            .init(title: "Search", key: "/") { m.startSearch() },
            .init(title: "Move to…", key: "m") { m.showMove() },
            .init(title: "Place everyone in New Senders as suggested", key: "") { m.placeAllAsSuggested() },
            .init(title: "Check for Mail", key: "⌘R") { m.engine.syncAll() },
            .init(title: "Show / Hide Sidebar", key: "⌘S") { m.toggleSidebar() },
            .init(title: "Appearance: Light", key: "") { m.setAppearance("light") },
            .init(title: "Appearance: Dark", key: "") { m.setAppearance("dark") },
            .init(title: "Appearance: Follow System", key: "") { m.setAppearance("system") },
            .init(title: "Accounts", key: "⌘,") { m.showSettings() },
            .init(title: "Keyboard Shortcuts", key: "?") { m.toggleHelp() },
        ]
        if let t = m.list.selected, !t.senderEmail.isEmpty {
            for choice in MoveOverlay.choices {
                c.append(.init(title: "Move \(t.sender) to \(choice.title)", key: "m \(choice.key)") {
                    m.moveSender(t.senderEmail, account: t.account, to: choice.decision, title: choice.title)
                })
            }
        }
        if m.boxes.count > 1 { c.append(.init(title: "All accounts together", key: "⌃0") { m.showAll() }) }
        for (i, b) in m.boxes.enumerated() {
            c.append(.init(title: "Switch to \(b.title)", key: "⌃\(i + 1)") { m.switchBox(i) })
        }
        return c
    }

    private func filter() {
        let q = field.stringValue.lowercased().split(separator: " ")
        shown = q.isEmpty ? all : all.filter { c in q.allSatisfy { c.title.lowercased().contains($0) } }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc private func clicked() { run() }

    private func run() {
        let i = table.selectedRow
        guard shown.indices.contains(i) else { return }
        let cmd = shown[i]
        onClose?()
        cmd.run()
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): run(); return true
        case #selector(NSResponder.moveDown(_:)): table.selectRowIndexes([min(table.selectedRow + 1, shown.count - 1)], byExtendingSelection: false); return true
        case #selector(NSResponder.moveUp(_:)): table.selectRowIndexes([max(table.selectedRow - 1, 0)], byExtendingSelection: false); return true
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        default: return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = shown[row]
        let a = NSTextField(labelWithString: c.title)
        a.font = .systemFont(ofSize: 13)
        let b = NSTextField(labelWithString: c.key)
        b.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        b.textColor = .tertiaryLabelColor
        let s = NSStackView(views: [a, NSView(), b])
        s.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        return s
    }
}
