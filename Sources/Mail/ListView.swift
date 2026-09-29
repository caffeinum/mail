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
    enum Item { case header(String), sender(Int), thread(Int), footer }

    /// New Senders: one row per sender, under the label Jev proposed; their
    /// threads unfold beneath with ›.
    struct SenderGroup {
        let key: String          // account \u{1} email
        let account: String
        let email: String
        let name: String
        let category: MailCategory?
        var threads: [Int]        // indices into rows
        var unread: Bool
        let latest: Int64
    }

    private(set) var groups: [SenderGroup] = []
    private var groupOfRow: [Int] = []   // row index → group index (grouped mode)
    private var senderRowOf: [Int] = []  // group index → table row
    var grouped = false
    /// Unfolded senders; kept by the controller across launches.
    var expanded = Set<String>()
    var onFold: ((Set<String>) -> Void)?
    /// Muted mail is shown as read, whatever its state.
    var forceRead = false

    let table = NSTableView()
    private(set) var rows: [ThreadSummary] = []
    private var items: [Item] = []
    private var tableRowOf: [Int] = []
    var onSelect: ((Int) -> Void)?
    var onOpen: ((Int) -> Void)?
    /// Called when the list is scrolled (or the cursor moved) near its end.
    var onNearEnd: (() -> Void)?
    /// The last row: "loading older mail…" while paging, "that's everything" once done.
    var footer: String? { didSet { if footer != oldValue { refreshFooter() } } }
    var loading = false { didSet { if loading != oldValue { refreshFooter() } } }

    var nearEnd: Bool {
        let visible = contentView.bounds
        return visible.maxY > table.bounds.height - visible.height
    }

    private func refreshFooter() {
        guard let i = items.lastIndex(where: { if case .footer = $0 { return true }; return false }) else { return }
        table.reloadData(forRowIndexes: [i], columnIndexes: [0])
    }
    /// In New Senders each row shows where it would go.
    var suggest = false
    /// In the combined view each row names its account ("account\u{1}alias" → title).
    var accountTags: [String: String] = [:]

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
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }

    @objc private func scrolled() { if nearEnd { onNearEnd?() } }

    required init?(coder: NSCoder) { fatalError() }

    static func group(_ ms: Int64, now: Date = Date()) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day, days < 7 { return "This week" }
        return "Earlier"
    }

    static let sectionOrder: [MailCategory?] = [.inbox, .feed, .paper, .notify, nil]
    static func sectionTitle(_ c: MailCategory?) -> String {
        switch c {
        case .inbox: return "Inbox"
        case .feed: return "Feed"
        case .paper: return "Paper Trail"
        case .notify: return "Notifications"
        case nil: return "Unsorted"
        }
    }

    /// Sections by proposed label, then senders (newest first), then — when
    /// unfolded — their threads.
    func setGrouped(_ threads: [ThreadSummary], keep id: String?, keepSender: String? = nil) {
        let prevKey = keepSender ?? selectedGroup.map { groups[$0].key }
        let prevID = id ?? (selectedRowIsThread ? selected?.id : nil)
        // A multi-sender selection (⌘A) survives a reload.
        let prevKeys = keepSender == nil && table.selectedRowIndexes.count > 1 ? Set(selectedGroups.map(\.key)) : []
        grouped = true
        table.allowsMultipleSelection = true
        var byKey: [String: [ThreadSummary]] = [:]
        var order: [String] = []
        for t in threads where !t.senderEmail.isEmpty {
            let k = t.account + "\u{1}" + t.senderEmail
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(t)
        }
        rows = []
        groups = []
        for section in Self.sectionOrder {
            for k in order {
                let ts = byKey[k]!
                guard ts[0].category == section else { continue }
                let start = rows.count
                rows += ts
                groups.append(SenderGroup(key: k, account: ts[0].account, email: ts[0].senderEmail, name: ts[0].sender,
                                          category: section, threads: Array(start..<rows.count),
                                          unread: ts.contains(where: \.unread), latest: ts[0].date))
            }
        }
        rebuildGrouped()
        let keep = IndexSet(groups.indices.filter { prevKeys.contains(groups[$0].key) }.map { senderRowOf[$0] })
        if keep.count > 1 { table.selectRowIndexes(keep, byExtendingSelection: false) }
        else if let prevID, let i = rows.firstIndex(where: { $0.id == prevID }), expanded.contains(groups[groupIndex(ofThread: i)].key) { select(i) }
        else if let prevKey, let g = groups.firstIndex(where: { $0.key == prevKey }) { selectGroup(g) }
        else if !groups.isEmpty { selectGroup(0) }
    }

    private func rebuildGrouped() {
        items = []
        tableRowOf = Array(repeating: -1, count: rows.count)
        senderRowOf = Array(repeating: -1, count: groups.count)
        groupOfRow = []
        var last: MailCategory?? = .none
        for (gi, g) in groups.enumerated() {
            if last == nil || last! != g.category { items.append(.header(Self.sectionTitle(g.category))); groupOfRow.append(-1); last = .some(g.category) }
            senderRowOf[gi] = items.count
            items.append(.sender(gi)); groupOfRow.append(gi)
            if expanded.contains(g.key) {
                for i in g.threads { tableRowOf[i] = items.count; items.append(.thread(i)); groupOfRow.append(gi) }
            }
        }
        if footer != nil { items.append(.footer); groupOfRow.append(-1) }
        table.reloadData()
    }

    private func groupIndex(ofThread i: Int) -> Int { groups.firstIndex { $0.threads.contains(i) } ?? 0 }

    /// The sender under the cursor (grouped mode).
    var selectedGroup: Int? {
        let r = table.selectedRowIndexes.last ?? -1
        guard grouped, groupOfRow.indices.contains(r), groupOfRow[r] >= 0 else { return nil }
        return groupOfRow[r]
    }

    var selectedRowIsThread: Bool {
        let r = table.selectedRowIndexes.last ?? -1
        guard items.indices.contains(r), case .thread = items[r] else { return false }
        return true
    }

    /// Every sender touched by the selection — a sender row or any of its threads.
    var selectedGroups: [SenderGroup] {
        guard grouped else { return [] }
        var seen = Set<Int>()
        return table.selectedRowIndexes.compactMap { r in
            guard groupOfRow.indices.contains(r), groupOfRow[r] >= 0, seen.insert(groupOfRow[r]).inserted else { return nil }
            return groups[groupOfRow[r]]
        }
    }

    func selectGroup(_ g: Int) {
        guard senderRowOf.indices.contains(g) else { return }
        let r = senderRowOf[g]
        table.selectRowIndexes([r], byExtendingSelection: false)
        if !quiet { table.scrollRowToVisible(r > 0 && { if case .header = items[r - 1] { return true }; return false }() ? r - 1 : r) }
    }

    /// → / o on a sender unfolds it, ← folds (from any of its threads too).
    func fold(open: Bool?) {
        guard let g = selectedGroup else { return }
        let key = groups[g].key
        let willOpen = open ?? !expanded.contains(key)
        if willOpen { expanded.insert(key) } else { expanded.remove(key) }
        rebuildGrouped()
        selectGroup(g)
        onFold?(expanded)
    }

    /// ⌘A: every sender in the cursor's section.
    func selectAllInSection() {
        guard let g = selectedGroup else { return }
        let c = groups[g].category
        let rowsInSection = groups.indices.filter { groups[$0].category == c }.map { senderRowOf[$0] }
        table.selectRowIndexes(IndexSet(rowsInSection), byExtendingSelection: false)
    }

    /// j / k: the next row you can stand on — a sender, or an unfolded thread.
    func step(_ d: Int) {
        guard grouped else { select(selectedIndex + d); return }
        var r = table.selectedRowIndexes.last ?? -1
        repeat {
            r += d
            guard items.indices.contains(r) else { return }
            switch items[r] {
            case .sender, .thread:
                table.selectRowIndexes([r], byExtendingSelection: false)
                table.scrollRowToVisible(r)
                return
            default: continue
            }
        } while true
    }

    private var quiet = false

    func set(_ rows: [ThreadSummary], keep id: String?) {
        grouped = false
        table.allowsMultipleSelection = false
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
        if footer != nil { items.append(.footer) }
        table.reloadData()
        let target = id ?? prev?.id
        let idx = target.flatMap { t in rows.firstIndex { $0.id == t } } ?? min(max(0, selectedIndex), rows.count - 1)
        if !rows.isEmpty { select(max(0, idx)) }
    }

    var selectedIndex: Int {
        let r = table.selectedRowIndexes.last ?? -1
        guard items.indices.contains(r) else { return -1 }
        switch items[r] {
        case .thread(let i): return i
        case .sender(let g): return groups[g].threads.first ?? -1
        default: return -1
        }
    }

    var selected: ThreadSummary? { rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil }

    func select(_ i: Int) {
        guard !rows.isEmpty else { return }
        let i = min(max(0, i), rows.count - 1)
        if grouped, tableRowOf[i] < 0 { selectGroup(groupIndex(ofThread: i)); return }
        let r = tableRowOf[i]
        table.selectRowIndexes([r], byExtendingSelection: false)
        // Keep the day heading in view when the first thread under it is selected.
        if !quiet { table.scrollRowToVisible(r > 0 && { if case .header = items[r - 1] { return true }; return false }() ? r - 1 : r) }
    }

    @objc private func doubleClicked() {
        let r = table.clickedRow
        guard items.indices.contains(r) else { return }
        switch items[r] {
        case .thread(let i): onOpen?(i)
        case .sender: fold(open: nil)
        default: break
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch items[row] {
        case .thread, .sender: return true
        default: return false
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .header: return row == 0 ? 30 : 40
        case .footer: return 56
        case .thread, .sender: return Style.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let title):
            let v = (tableView.makeView(withIdentifier: DayHeader.id, owner: nil) as? DayHeader) ?? DayHeader()
            v.title = title
            return v
        case .footer:
            let v = (tableView.makeView(withIdentifier: LoaderRow.id, owner: nil) as? LoaderRow) ?? LoaderRow()
            v.set(text: footer ?? "", spinning: loading)
            return v
        case .sender(let g):
            let v = (tableView.makeView(withIdentifier: SenderRow.id, owner: nil) as? SenderRow) ?? SenderRow()
            v.set(groups[g], open: expanded.contains(groups[g].key), when: rows[groups[g].threads[0]].date)
            return v
        case .thread(let i):
            let v = (tableView.makeView(withIdentifier: ThreadRow.id, owner: nil) as? ThreadRow) ?? ThreadRow()
            v.indent = grouped ? 26 : 0
            v.forceRead = forceRead
            v.suggest = suggest
            v.accountTag = accountTags.isEmpty ? nil : accountTags[rows[i].account + "\u{1}" + rows[i].alias]
            v.thread = rows[i]
            return v
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CursorRow() }

    func tableViewSelectionDidChange(_ n: Notification) {
        onSelect?(selectedIndex)
        if selectedIndex >= rows.count - 15 { onNearEnd?() }
    }
}

final class LoaderRow: NSView {
    static let id = NSUserInterfaceItemIdentifier("loader")
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.font = .systemFont(ofSize: 12)
        label.textColor = Palette.secondary
        let s = NSStackView(views: [spinner, label])
        s.spacing = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([s.centerXAnchor.constraint(equalTo: centerXAnchor), s.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, spinning: Bool) {
        label.stringValue = text
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}

/// A sender in New Senders: › name  count      address                date
final class SenderRow: NSView {
    static let id = NSUserInterfaceItemIdentifier("sender")
    private var group: ListView.SenderGroup?
    private var open = false
    private var when: Int64 = 0

    override init(frame: NSRect) { super.init(frame: frame); identifier = Self.id }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func set(_ g: ListView.SenderGroup, open: Bool, when: Int64) {
        group = g; self.open = open; self.when = when
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = group else { return }
        let col = Style.column(bounds)
        let y = (bounds.height - 17) / 2
        (open ? "⌄" : "›" as NSString).draw(at: NSPoint(x: col.minX + 14, y: y - (open ? 3 : 0)), withAttributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: Palette.secondary,
        ])
        let name = NSMutableAttributedString(string: g.name, attributes: [
            .font: g.unread ? Style.bold : Style.body, .foregroundColor: Palette.text,
        ])
        if g.threads.count > 1 {
            name.append(NSAttributedString(string: "  \(g.threads.count)", attributes: [.font: Style.body, .foregroundColor: Palette.secondary]))
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        name.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: name.length))
        name.draw(with: NSRect(x: col.minX + 38, y: y, width: 250, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        (g.email as NSString).draw(with: NSRect(x: col.minX + 300, y: y, width: col.width - 400, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
            .font: Style.body, .foregroundColor: Palette.secondary, .paragraphStyle: para,
        ])
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        (ThreadRow.when(when) as NSString).draw(with: NSRect(x: col.maxX - 82, y: y + 1, width: 70, height: 18), options: .usesLineFragmentOrigin, attributes: [
            .font: Style.small, .foregroundColor: Palette.tertiary, .paragraphStyle: right,
        ])
    }
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
    var accountTag: String?
    var indent: CGFloat = 0
    var forceRead = false

    override init(frame: NSRect) { super.init(frame: frame); identifier = Self.id }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    static let suggestion = ["inbox": "→ inbox", "notify": "→ notifications", "feed": "→ feed", "paper": "→ paper trail"]

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
        var col = Style.column(bounds)
        col.origin.x += indent; col.size.width -= indent
        let unread = t.unread && !forceRead
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
        if let account = accountTag {
            dateW += 96
            (account as NSString).draw(with: NSRect(x: col.maxX - dateW + 6, y: y + 1, width: 90, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular), .foregroundColor: Palette.secondary, .paragraphStyle: para,
            ])
        }
        if suggest, let c = t.category, let tag = Self.suggestion[c.rawValue] {
            dateW += 124
            (tag as NSString).draw(with: NSRect(x: col.maxX - dateW + 4, y: y + 1, width: 120, height: 18), options: .usesLineFragmentOrigin, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: Palette.accent,
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
