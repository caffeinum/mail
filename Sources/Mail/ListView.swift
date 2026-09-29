import AppKit
import MailCore

/// Cream, charcoal and ember orange — the icon's palette — in a light and a
/// dark version that follow the app's appearance.
enum Palette {
    static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { a in
            let hex = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
        }
    }
    static let background = dynamic(0xf5f1e8, 0x1f1d1a)
    static let sidebar = dynamic(0xece5d6, 0x191715)
    static let text = dynamic(0x2b2b30, 0xf2ede3)
    static let secondary = dynamic(0x8a8173, 0x9a9284)
    static let tertiary = dynamic(0xa89f8f, 0x7a7366)
    static let line = dynamic(0xe0d8c7, 0x34302a)
    static let cursor = dynamic(0xfffaf0, 0x2d2a25)
    static let accent = dynamic(0xf0561f, 0xff6a33)

    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    /// For the web pages: the same palette as css.
    static var css: (bg: String, fg: String, dim: String, line: String, link: String, card: String) {
        isDark ? ("#1f1d1a", "#f2ede3", "#9a9284", "#34302a", "#ff8a5c", "#2a2723")
               : ("#f5f1e8", "#2b2b30", "#8a8173", "#e0d8c7", "#d9471a", "#fffdf8")
    }
}

enum Style {
    static let rowHeight: CGFloat = 34
    static let body = NSFont.systemFont(ofSize: 13)
    static let bold = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let small = NSFont.systemFont(ofSize: 12)
    static var accent: NSColor { Palette.accent }
    static let gutter: CGFloat = 22
    /// The list reads like the reader: a centred column, not edge to edge.
    static let listWidth: CGFloat = 860

    static func column(_ bounds: NSRect) -> NSRect {
        let w = min(listWidth, bounds.width - 32)
        return NSRect(x: (bounds.width - w) / 2, y: bounds.minY, width: w, height: bounds.height)
    }
}

/// Threads grouped by day — Today, Yesterday, This week, Earlier — one line
/// each. `rows` holds only threads; the headers live between them in the
/// table and are never selectable.
final class ListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    enum Item { case header(String), thread(Int) }

    let table = NSTableView()
    private(set) var rows: [ThreadSummary] = []
    private var items: [Item] = []
    private var tableRowOf: [Int] = []
    var onSelect: ((Int) -> Void)?
    var onOpen: ((Int) -> Void)?
    /// In New Senders each row shows where it would go.
    var suggest = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let col = NSTableColumn(identifier: .init("t"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.allowsTypeSelect = false
        table.backgroundColor = .clear
        table.style = .plain
        table.floatsGroupRows = false
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
        contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 24, right: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func group(_ ms: Int64, now: Date = Date()) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day, days < 7 { return "This week" }
        return "Earlier"
    }

    func set(_ rows: [ThreadSummary], keep id: String?) {
        let prev = selected
        self.rows = rows
        items = []
        tableRowOf = []
        var last: String?
        for (i, t) in rows.enumerated() {
            let g = Self.group(t.date)
            if g != last { items.append(.header(g)); last = g }
            tableRowOf.append(items.count)
            items.append(.thread(i))
        }
        table.reloadData()
        let target = id ?? prev?.id
        let idx = target.flatMap { t in rows.firstIndex { $0.id == t } } ?? min(max(0, selectedIndex), rows.count - 1)
        if !rows.isEmpty { select(max(0, idx)) }
    }

    var selectedIndex: Int {
        let r = table.selectedRow
        guard items.indices.contains(r), case .thread(let i) = items[r] else { return -1 }
        return i
    }

    var selected: ThreadSummary? { rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil }

    func select(_ i: Int) {
        guard !rows.isEmpty else { return }
        let i = min(max(0, i), rows.count - 1)
        let r = tableRowOf[i]
        table.selectRowIndexes([r], byExtendingSelection: false)
        // Keep the day heading in view when the first thread under it is selected.
        table.scrollRowToVisible(r > 0 && { if case .header = items[r - 1] { return true }; return false }() ? r - 1 : r)
    }

    @objc private func doubleClicked() {
        let r = table.clickedRow
        guard items.indices.contains(r), case .thread(let i) = items[r] else { return }
        onOpen?(i)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !self.tableView(tableView, isGroupRow: row) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[row] { return row == 0 ? 30 : 40 }
        return Style.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let title):
            let v = (tableView.makeView(withIdentifier: DayHeader.id, owner: nil) as? DayHeader) ?? DayHeader()
            v.title = title
            return v
        case .thread(let i):
            let v = (tableView.makeView(withIdentifier: ThreadRow.id, owner: nil) as? ThreadRow) ?? ThreadRow()
            v.suggest = suggest
            v.thread = rows[i]
            return v
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CursorRow() }

    func tableViewSelectionDidChange(_ n: Notification) { onSelect?(selectedIndex) }
}

final class DayHeader: NSView {
    static let id = NSUserInterfaceItemIdentifier("day")
    var title = "" { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); identifier = Self.id }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let col = Style.column(bounds)
        (title.uppercased() as NSString).draw(at: NSPoint(x: col.minX + 10, y: bounds.height - 20), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Palette.secondary, .kern: 0.6,
        ])
    }
}

final class CursorRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let r = Style.column(bounds).insetBy(dx: 0, dy: 1)
        Palette.cursor.setFill()
        NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
        Palette.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY + 6, width: 3, height: r.height - 12), xRadius: 1.5, yRadius: 1.5).fill()
    }
    override var isSelected: Bool { didSet { needsDisplay = true } }
}

final class ThreadRow: NSView {
    static let id = NSUserInterfaceItemIdentifier("row")
    var thread: ThreadSummary? { didSet { needsDisplay = true } }
    var suggest = false

    override init(frame: NSRect) { super.init(frame: frame); identifier = Self.id }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    static let suggestion = ["inbox": "→ inbox", "feed": "→ feed", "paper": "→ paper trail"]

    static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
    static let timeFormat: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()

    static func when(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(d) || cal.isDateInYesterday(d) { return timeFormat.string(from: d) }
        return dayFormat.string(from: d)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let t = thread else { return }
        let h = bounds.height
        let col = Style.column(bounds)
        let unread = t.unread
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail

        // A small ring, as in U3; filled ember when unread.
        let ring = NSRect(x: col.minX + 12, y: h / 2 - 6, width: 12, height: 12)
        let path = NSBezierPath(ovalIn: ring.insetBy(dx: 0.75, dy: 0.75))
        path.lineWidth = 1.5
        if unread { Palette.accent.setFill(); NSBezierPath(ovalIn: ring.insetBy(dx: 3, dy: 3)).fill(); Palette.accent.setStroke() }
        else { Palette.line.setStroke() }
        path.stroke()

        let senderW: CGFloat = 170
        var dateW: CGFloat = 70
        let y = (h - 17) / 2
        var sender = t.sender
        if t.count > 1 { sender += "  \(t.count)" }
        let x0 = col.minX + 38
        (sender as NSString).draw(with: NSRect(x: x0, y: y, width: senderW - 12, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
            .font: unread ? Style.bold : Style.body, .foregroundColor: Palette.text, .paragraphStyle: para,
        ])
        let line = NSMutableAttributedString(string: t.subject.isEmpty ? "(no subject)" : t.subject, attributes: [
            .font: unread ? Style.bold : Style.body, .foregroundColor: Palette.text,
        ])
        line.append(NSAttributedString(string: "   " + t.snippet, attributes: [
            .font: Style.body, .foregroundColor: Palette.secondary,
        ]))
        line.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: line.length))
        if suggest, let tag = Self.suggestion[t.category.rawValue] {
            dateW += 110
            (tag as NSString).draw(with: NSRect(x: col.maxX - dateW + 4, y: y + 1, width: 104, height: 18), options: .usesLineFragmentOrigin, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium), .foregroundColor: Palette.accent,
            ])
        }
        let x = x0 + senderW
        line.draw(with: NSRect(x: x, y: y, width: col.maxX - x - dateW - 14, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        (Self.when(t.date) as NSString).draw(with: NSRect(x: col.maxX - dateW - 12, y: y + 1, width: dateW, height: 18), options: .usesLineFragmentOrigin, attributes: [
            .font: Style.small, .foregroundColor: Palette.tertiary, .paragraphStyle: right,
        ])
    }
}
