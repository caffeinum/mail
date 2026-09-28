import AppKit
import MailCore

/// ⌘K: type a few letters of any command, ↩ runs it.
final class Palette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let shared = Palette()

    struct Command { let title: String; let key: String; let run: () -> Void }

    private var panel: PalettePanel?
    private let field = NSTextField()
    private let table = NSTableView()
    private var all: [Command] = []
    private var shown: [Command] = []

    func show(for main: MainController) {
        all = commands(main)
        let p = panel ?? make()
        panel = p
        field.stringValue = ""
        filter()
        let f = main.window.frame
        p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - p.frame.height - 120))
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(field)
    }

    private func commands(_ m: MainController) -> [Command] {
        var c: [Command] = [
            .init(title: "Go to Inbox", key: "g i") { m.go(.inbox) },
            .init(title: "Go to Feed", key: "g f") { m.go(.feed) },
            .init(title: "Go to Paper Trail", key: "g p") { m.go(.paper) },
            .init(title: "Go to New Senders", key: "g n") { m.go(.newSenders) },
            .init(title: "Compose", key: "c") { m.compose(.new) },
            .init(title: "Reply", key: "r") { m.compose(.reply) },
            .init(title: "Reply All", key: "R") { m.compose(.replyAll) },
            .init(title: "Forward", key: "F") { m.compose(.forward) },
            .init(title: "Search", key: "/") { m.startSearch() },
            .init(title: "Sync Now", key: "") { m.engine.syncAll() },
            .init(title: "Accounts…", key: "⌘,") { (NSApp.delegate as? AppDelegate)?.openSettings(nil) },
            .init(title: "Keyboard Shortcuts", key: "?") { Help.shared.toggle(over: m.window) },
        ]
        for (i, b) in m.boxes.enumerated() {
            c.append(.init(title: "Switch to \(b.title)", key: "\(i + 1)") { m.switchBox(i) })
        }
        return c
    }

    private func make() -> PalettePanel {
        let p = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isReleasedWhenClosed = false
        p.onEscape = { [weak p] in p?.orderOut(nil) }
        field.placeholderString = "Type a command"
        field.font = .systemFont(ofSize: 16)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.delegate = self
        let col = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 28
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.backgroundColor = .clear
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        let host = NSView()
        for v in [field, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(v) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: host.topAnchor, constant: 18), field.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8), scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8),
        ])
        p.contentView = host
        return p
    }

    private func filter() {
        let q = field.stringValue.lowercased().split(separator: " ")
        shown = q.isEmpty ? all : all.filter { c in q.allSatisfy { c.title.lowercased().contains($0) } }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func run() {
        let i = table.selectedRow
        guard shown.indices.contains(i) else { return }
        panel?.orderOut(nil)
        shown[i].run()
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): run(); return true
        case #selector(NSResponder.moveDown(_:)): table.selectRowIndexes([min(table.selectedRow + 1, shown.count - 1)], byExtendingSelection: false); return true
        case #selector(NSResponder.moveUp(_:)): table.selectRowIndexes([max(table.selectedRow - 1, 0)], byExtendingSelection: false); return true
        case #selector(NSResponder.cancelOperation(_:)): panel?.orderOut(nil); return true
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
        s.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        return s
    }
}

final class PalettePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func resignKey() { super.resignKey(); orderOut(nil) }
}
