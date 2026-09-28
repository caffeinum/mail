import AppKit
import MailCore

enum Style {
    static let rowHeight: CGFloat = 38
    static let body = NSFont.systemFont(ofSize: 13)
    static let bold = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let small = NSFont.systemFont(ofSize: 12)
    static let accent = NSColor.controlAccentColor
    static let gutter: CGFloat = 22
    /// The list reads like the reader: a centred column, not edge to edge.
    static let listWidth: CGFloat = 880

    static func column(_ bounds: NSRect) -> NSRect {
        let w = min(listWidth, bounds.width - 32)
        return NSRect(x: (bounds.width - w) / 2, y: bounds.minY, width: w, height: bounds.height)
    }
}

/// The thread list: a view-based NSTableView whose rows draw themselves in
/// one pass — no stack of text fields per row.
final class ListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    private(set) var rows: [ThreadSummary] = []
    var onSelect: ((Int) -> Void)?
    var onOpen: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let col = NSTableColumn(identifier: .init("t"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = Style.rowHeight + 4
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.allowsTypeSelect = false
        table.backgroundColor = .clear
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        documentView = table
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 24, right: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ rows: [ThreadSummary], keep id: String?) {
        let prev = selected
        self.rows = rows
        table.reloadData()
        let target = id ?? prev?.id
        let idx = target.flatMap { t in rows.firstIndex { $0.id == t } } ?? min(max(0, table.selectedRow), rows.count - 1)
        if !rows.isEmpty { select(max(0, idx)) }
    }

    var selectedIndex: Int { table.selectedRow }
    var selected: ThreadSummary? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }

    func select(_ i: Int) {
        guard !rows.isEmpty else { return }
        let i = min(max(0, i), rows.count - 1)
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    @objc private func doubleClicked() { if table.clickedRow >= 0 { onOpen?(table.clickedRow) } }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let v = (tableView.makeView(withIdentifier: ThreadRow.id, owner: nil) as? ThreadRow) ?? ThreadRow()
        v.thread = rows[row]
        return v
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CursorRow() }

    func tableViewSelectionDidChange(_ n: Notification) { onSelect?(table.selectedRow) }
}

final class CursorRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let r = Style.column(bounds).insetBy(dx: 0, dy: 2)
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        Style.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY + 6, width: 3, height: r.height - 12), xRadius: 1.5, yRadius: 1.5).fill()
    }
    override var isSelected: Bool { didSet { needsDisplay = true } }
}

final class ThreadRow: NSView {
    static let id = NSUserInterfaceItemIdentifier("row")
    var thread: ThreadSummary? { didSet { needsDisplay = true } }

    override init(frame: NSRect) { super.init(frame: frame); identifier = Self.id }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
    static let timeFormat: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()

    static func when(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return Calendar.current.isDateInToday(d) ? timeFormat.string(from: d) : dayFormat.string(from: d)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let t = thread else { return }
        let h = bounds.height
        let col = Style.column(bounds)
        let unread = t.unread
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail

        if unread {
            Style.accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: col.minX + 10, y: h / 2 - 3, width: 6, height: 6)).fill()
        }
        let senderW: CGFloat = 170
        let dateW: CGFloat = 64
        let y = (h - 17) / 2
        var sender = t.sender
        if t.count > 1 { sender += "  \(t.count)" }
        (sender as NSString).draw(with: NSRect(x: col.minX + Style.gutter + 4, y: y, width: senderW - 12, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
            .font: unread ? Style.bold : Style.body, .foregroundColor: NSColor.labelColor, .paragraphStyle: para,
        ])
        let line = NSMutableAttributedString(string: t.subject.isEmpty ? "(no subject)" : t.subject, attributes: [
            .font: unread ? Style.bold : Style.body, .foregroundColor: NSColor.labelColor,
        ])
        line.append(NSAttributedString(string: "   " + t.snippet, attributes: [
            .font: Style.body, .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        line.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: line.length))
        let x = col.minX + Style.gutter + 4 + senderW
        line.draw(with: NSRect(x: x, y: y, width: col.maxX - x - dateW - 16, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        (Self.when(t.date) as NSString).draw(with: NSRect(x: col.maxX - dateW - 14, y: y + 1, width: dateW, height: 18), options: .usesLineFragmentOrigin, attributes: [
            .font: Style.small, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: right,
        ])
    }
}
