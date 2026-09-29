import AppKit
import MailCore

final class KeyWindow: NSWindow {
    var router: ((NSEvent) -> Bool)?

    /// ⌘ keys reach the router before the menus (⌘A in New Senders selects a section).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only ⌘/⌃ chords: plain keys already went through sendEvent, and
        // routing them twice ran every key twice (g g, j j, a move twice).
        let chord = !event.modifierFlags.intersection([.command, .control]).isEmpty
        if chord, !isEditingText, let router, router(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !isEditingText, let router, router(event) { return }
        super.sendEvent(event)
    }

    var isEditingText: Bool {
        guard let r = firstResponder else { return false }
        if let tv = r as? NSTextView { return tv.isEditable }
        return r is NSTextField
    }
}

final class MainController: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    let engine: Engine
    var store: Store { engine.store }
    lazy var actions = Actions(store: store, outbox: engine.outbox)

    let window: KeyWindow
    let header = HeaderBar()
    let sidebar = Sidebar()
    private var sidebarWidth: NSLayoutConstraint!
    let list = ListView()
    lazy var reader = ThreadView()
    lazy var stream = FeedStream()
    /// Feed reads as a stream of the emails themselves; v flips to the list.
    private var streamMode = true
    private var streaming: Bool { view == .feed && streamMode && !reading }
    /// Remote images load, except in spam — there i lets them in for one
    /// thread and ⇧I for a sender. Tracking pixels are gone either way.
    private var imageThreads = Set<String>()
    private var streamImages = false

    func trusts(_ account: String, _ email: String) -> Bool { store.get("img:\(account):\(email.lowercased())") == "1" }

    func imagesAllowed(_ m: MessageRecord) -> Bool {
        !m.labels.contains("SPAM") || imageThreads.contains(m.threadID) || trusts(m.account, m.shownFrom?.email ?? "")
    }
    let toast = Toast()
    private let content = NSView()

    private(set) var boxes: [Mailbox] = []
    private(set) var box: Mailbox?
    private(set) var view: View = .inbox
    private var lastTab: View = .inbox
    private var reading = false
    /// Everything happens in this one window: a pane in place of the list
    /// (a new message, accounts) or a card over it (help, ⌘K).
    private var pane: NSView?
    private var overlay: Overlay?
    private var pendingG = false
    private var errors: [String: String] = [:]

    init(engine: Engine) {
        Launch.mark("props")
        self.engine = engine
        window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        super.init()
        Launch.mark("window")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Reply"
        window.minSize = NSSize(width: 640, height: 400)
        window.setFrameAutosaveName("ReplyMain")
        if !window.setFrameUsingName("ReplyMain") { window.center() }
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.router = { [weak self] e in self?.key(e) ?? false }
        window.backgroundColor = Palette.background
        // An empty unified toolbar makes the title bar 52pt tall, so the
        // traffic lights sit centred on the top bar, as in the mocks.
        let toolbar = NSToolbar(identifier: "main")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        let root = NSView()
        window.contentView = root
        for v in [sidebar, header, content, toast] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
        let shown = engine.store.get("ui.sidebar") != "hidden"
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: shown ? Sidebar.width : 0)
        sidebarWidth.isActive = true
        sidebar.isHidden = !shown
        header.sidebarShown = shown
        sidebar.onAccount = { [weak self] i in if i < 0 { self?.showAll() } else { self?.switchBox(i) } }
        sidebar.onStream = { [weak self] v in self?.go(v) }
        sidebar.onRename = { [weak self] i, name in self?.rename(box: i, to: name) }
        Launch.mark("layout")
        fill(content, with: list)
        header.searchDelegate = self
        header.onTab = { [weak self] v in self?.go(v) }
        header.onAccount = { [weak self] i in self?.switchBox(i) }
        list.onOpen = { [weak self] i in self?.list.select(i); self?.openSelected() }
        list.onSelect = { [weak self] _ in self?.prefetchAroundCursor() }
        list.onNearEnd = { [weak self] in self?.loadOlder() }
        list.onFold = { [weak self] open in self?.store.set("ui.ns.open", open.sorted().joined(separator: "\n")) }
    }

    private func fill(_ host: NSView, with v: NSView) {
        host.subviews.filter { $0 !== v }.forEach { $0.removeFromSuperview() }
        guard v.superview !== host else { return }
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: host.topAnchor), v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: host.leadingAnchor), v.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }

    // MARK: first frame

    /// Straight from disk: the last mailbox and stream, its first rows, one
    /// indexed read. No network is touched before this is on screen.
    func setAppearance(_ mode: String) {
        store.set("ui.appearance", mode)
        applyAppearance()
        stream.invalidate()
        if reading, let t = reader.thread { reader.show(t, messages: reader.messages, force: true) }
        else { reloadList(keep: list.selected?.id) }
    }

    private func applyAppearance() {
        switch store.get("ui.appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    func showFirstFrame() {
        applyAppearance()
        boxes = store.config.mailboxes
        let savedBox = store.get("ui.box")
        box = boxes.first { $0.id == savedBox } ?? boxes.first
        view = store.get("ui.view").flatMap(View.init(key:)) ?? .inbox
        lastTab = view
        reloadList(keep: store.get("ui.thread"))
        Launch.mark("rows")
        window.makeKeyAndOrderFront(nil)
        Launch.mark("ordered")
        window.makeFirstResponder(list.table)
        window.displayIfNeeded()
        CATransaction.flush()
        Launch.mark("committed")
        Launch.firstFrame = Launch.sinceStart
    }

    func saveState() {
        if let box { store.set("ui.box", box.id) }
        store.set("ui.view", lastTab.key)
        if let t = list.selected { store.set("ui.thread", t.id) }
    }

    func reloadList(keep id: String? = nil, keepSender: String? = nil) {
        guard let box else {
            list.set([], keep: nil)
            header.update(boxes: [], current: nil, view: view, counts: [:], note: "No accounts yet — ⌘, to add one")
            return
        }
        list.suggest = false
        list.forceRead = view == .muted
        list.accountTags = box.isAll ? Dictionary(boxes.map { ($0.account + "\u{1}" + ($0.alias?.address.lowercased() ?? ""), $0.title) }, uniquingKeysWith: { a, _ in a }) : [:]
        list.footer = olderFooter()
        var rows = store.threads(box, view, limit: 20000)
        if view == .newSenders {
            list.expanded = Set((store.get("ui.ns.open") ?? "").split(separator: "\n").map(String.init))
            list.senderLatest = store.senderLatest(box)
            list.setGrouped(rows, keep: id, keepSender: keepSender)
        } else {
            list.set(rows, keep: id)
        }
        if pane == nil { if streaming { showStream() } else if !reading { fill(content, with: list) } }
        var counts: [View: Int] = [:]
        for v in View.tabs { counts[v] = store.count(box, v) }
        header.update(boxes: boxes, current: box, view: view, counts: counts, note: errors[box.account])
        sidebar.update(boxes: boxes, current: box, view: view, counts: counts)
    }

    /// The feed opens unread-first, and keeps that order while you read —
    /// posts turning read don't jump around under you. New mail goes on top.
    private var feedOrder: [String]?
    private var streamRows: [ThreadSummary] = []
    private var viewedTimer: Timer?

    private func orderedFeed() -> [ThreadSummary] {
        let rows = Array(list.rows.prefix(60))
        if feedOrder == nil { feedOrder = (rows.filter(\.unread) + rows.filter { !$0.unread }).map(\.id) }
        let pos = Dictionary((feedOrder ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let fresh = rows.filter { pos[$0.id] == nil }
        let known = rows.filter { pos[$0.id] != nil }.sorted { pos[$0.id]! < pos[$1.id]! }
        return Array((fresh + known).prefix(40))
    }

    /// Posts you've scrolled or stepped past count as read.
    private func markViewed(_ ids: [String]) {
        var done: [String] = []
        for id in ids {
            guard let i = streamRows.firstIndex(where: { $0.id == id }), streamRows[i].unread else { continue }
            actions.markRead(streamRows[i])
            done.append(id)
        }
        guard !done.isEmpty else { return }
        streamRows = streamRows.map { t in done.contains(t.id) ? store.thread(account: t.account, id: t.id) ?? t : t }
        stream.markRead(done)
        engine.pokeOutbox()
    }

    /// Follows the scroll: whatever email is at the top of the view is the
    /// current one (highlighted, and what keys act on); everything above it
    /// has been read.
    private func watchViewed() {
        viewedTimer?.invalidate()
        viewedTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self, self.streaming, self.pane == nil, self.overlay == nil else { return }
            self.stream.here { i in
                self.selectStream(i)
                self.markViewed(self.streamRows.prefix(i).map(\.id))
                if i >= self.streamRows.count - 4 { self.topUpStream(force: true) }
            }
        }
    }

    private func selectStream(_ i: Int) {
        guard streamRows.indices.contains(i), let row = list.rows.firstIndex(where: { $0.id == streamRows[i].id }) else { return }
        list.select(row)
    }

    private func showStream() {
        fill(content, with: stream)
        if viewedTimer == nil { watchViewed() }
        if stream.isDrawn {
            // Already on screen: only take out what left; nothing moves.
            let present = Set(list.rows.map(\.id))
            streamRows.removeAll { !present.contains($0.id) }
            if streamRows.isEmpty, !list.rows.isEmpty {
                // Finished the page: start over with whatever's there now,
                // new mail included.
                feedOrder = nil
                stream.invalidate()
                showStream()
                return
            }
            let items = streamRows.map { FeedStream.Item(id: $0.id, sender: "", subject: "", when: "", html: "", cached: true) }
            stream.show(items, at: 0, images: streamImagesOn)
            let arrived = streamRows.filter { stream.previews.contains($0.id) && store.hasBodies(account: $0.account, thread: $0.id) }
            stream.fill(arrived.map(feedItem))
            topUpStream()
            return
        }
        streamRows = orderedFeed()
        let rows = streamRows
        let at = streamRows.firstIndex { $0.id == list.selected?.id } ?? 0
        let tags = box?.isAll == true
        let items = rows.map { t -> FeedStream.Item in
            let last = store.messages(account: t.account, thread: t.id).last
            return FeedStream.item(t, last, images: streamImages || last.map(imagesAllowed) == true,
                                   account: tags ? (boxFor(t)?.title ?? "") : "")
        }
        streamImagesOn = streamImages || items.contains { !$0.html.contains("blocked-http") && WebRenderer.hasRemoteImages($0.html) }
        stream.footer(olderFooter(), loading: !pagingNow.isEmpty)
        stream.show(Array(items), at: at, images: streamImagesOn)
    }

    private var streamImagesOn = false

    private func feedItem(_ t: ThreadSummary) -> FeedStream.Item {
        let last = store.messages(account: t.account, thread: t.id).last
        return FeedStream.item(t, last, images: streamImages || last.map(imagesAllowed) == true,
                               account: box?.isAll == true ? (boxFor(t)?.title ?? "") : "")
    }

    /// Keeps the stream fed from the bottom: the next emails of the Feed
    /// that aren't on the page yet, and older mail from gmail past them.
    private func topUpStream(force: Bool = false) {
        guard stream.isDrawn else { return }
        let shown = Set(streamRows.map(\.id))
        let more = list.rows.filter { !shown.contains($0.id) }.prefix(20)
        if !more.isEmpty, force || streamRows.count < 15 {
            streamRows += more
            stream.append(more.map(feedItem))
            prefetch(Array(more))
        }
        if more.count < 20 { loadOlder() }
        stream.footer(olderFooter(), loading: !pagingNow.isEmpty)
    }

    // MARK: engine callbacks

    func cacheChanged(account: String) {
        errors[account] = nil
        guard box?.account == account || box?.isAll == true else { return }
        reloadList(keep: list.grouped ? nil : list.selected?.id)
        if reading, let t = reader.thread {
            let fresh = store.thread(account: t.account, id: t.id) ?? t
            reader.show(fresh, messages: store.messages(account: t.account, thread: t.id))
        }
    }

    func syncFailed(account: String, error: Error) {
        errors[account] = "offline — showing what's cached"
        if box?.account == account || box?.isAll == true { reloadList(keep: list.selected?.id) }
    }

    func accountsChanged() {
        if let c = try? AccountsStore.load() { engine.reload(config: c) }
        boxes = store.config.mailboxes
        if box == nil || !boxes.contains(where: { $0.id == box?.id }) { box = boxes.first }
        reloadList()
        engine.syncAll()
    }

    // MARK: prefetch

    func prefetchVisible() {
        for b in boxes where b.kind == .gmail || true {
            for v in View.tabs {
                let ids = store.threadsNeedingBodies(b, v, limit: 50)
                engine.prefetch(b.account, ids)
            }
        }
    }

    private func prefetchAroundCursor() {
        guard let box else { return }
        let i = list.selectedIndex
        guard i >= 0 else { return }
        let lo = max(0, i - 5), hi = min(list.rows.count, i + 6)
        _ = box
        prefetch(Array(list.rows[lo..<hi]))
    }

    // MARK: navigation

    func go(_ v: View) {
        if reading { closeThread() }
        if v == .feed && view != .feed { feedOrder = nil; stream.invalidate() }
        view = v
        if case .search = v {} else { lastTab = v; header.search.stringValue = "" }
        reloadList()
        list.scrollToCursor()
        if let box { prefetch(store.threads(box, v, limit: 50)) }
    }

    /// Tab walks Inbox → Feed → Paper Trail (→ New Senders when someone's
    /// waiting) and round again.
    func cycleStream(_ d: Int) {
        guard let box else { return }
        let tabs = View.tabs.filter { $0 != .newSenders || store.count(box, .newSenders) > 0 }
        let i = tabs.firstIndex(of: lastTab) ?? 0
        go(tabs[(i + d + tabs.count) % tabs.count])
    }

    /// ⌃0: every account together. Each thread still acts as its own account.
    func showAll() {
        guard boxes.count > 1 else { return }
        if reading { closeThread() }
        box = .all
        feedOrder = nil
        stream.invalidate()
        if case .search = view { view = lastTab }
        reloadList()
        list.scrollToCursor()
    }

    private var lastOlder = Date.distantPast
    private var pagingNow = Set<String>()

    private var olderAccounts: [String] {
        guard let box else { return [] }
        if case .search = view { return [] }
        return box.isAll ? store.config.accounts.map(\.email) : [box.account]
    }

    private func olderFooter() -> String? {
        let accounts = olderAccounts
        guard !accounts.isEmpty else { return nil }
        if accounts.contains(where: pagingNow.contains) { return "Loading older mail…" }
        if accounts.contains(where: { engine.olderFailed.contains($0) }) { return "Couldn't load older mail — ⌘R to try again" }
        return accounts.contains(where: engine.hasOlder) ? "Scroll for older mail" : "That's everything"
    }

    private var rowsBeforePage = 0

    func pagingChanged(account: String, active: Bool) {
        if active { pagingNow.insert(account); rowsBeforePage = list.rows.count } else { pagingNow.remove(account) }
        list.loading = !pagingNow.isEmpty
        list.footer = olderFooter()
        if streaming { stream.footer(olderFooter(), loading: !pagingNow.isEmpty) }
        // Still at the bottom after a page brought something: keep going.
        // A page that brought nothing (or failed) stops here — no endless loader.
        if !active, pagingNow.isEmpty, list.nearEnd, !reading, list.rows.count > rowsBeforePage {
            lastOlder = .distantPast
            loadOlder()
        }
    }

    /// Near the bottom of a list: ask gmail for the next page of older mail.
    func loadOlder() {
        guard Date().timeIntervalSince(lastOlder) > 0.5 else { return }
        lastOlder = Date()
        for a in olderAccounts where engine.hasOlder(a) { Task { await engine.older(a) } }
    }

    func boxFor(_ t: ThreadSummary) -> Mailbox? {
        guard let box else { return nil }
        return box.isAll ? store.config.mailbox(account: t.account, alias: t.alias) : box
    }

    private func prefetch(_ threads: [ThreadSummary]) {
        for (account, ts) in Dictionary(grouping: threads, by: \.account) {
            engine.prefetch(account, ts.filter { !store.hasBodies(account: account, thread: $0.id) }.map(\.id))
        }
    }

    func switchBox(_ i: Int) {
        guard boxes.indices.contains(i) else { return }
        if reading { closeThread() }
        box = boxes[i]
        feedOrder = nil
        stream.invalidate()
        if case .search = view { view = lastTab }
        reloadList()
        list.scrollToCursor()
    }

    func openSelected() {
        guard let t = list.selected else { return }
        stream.invalidate()
        reading = true
        reader.images = { [weak self] m in self?.imagesAllowed(m) ?? false }
        fill(content, with: reader)
        reader.show(t, messages: store.messages(account: t.account, thread: t.id))
        if t.unread {
            actions.markRead(t)
            engine.pokeOutbox()
        }
        prefetchAroundCursor()
    }

    func closeThread() {
        reading = false
        fill(content, with: list)
        window.makeFirstResponder(list.table)
        reloadList(keep: reader.thread?.id)
    }

    private func step(_ d: Int) {
        if streaming {
            stream.step(d) { [weak self] i, from in
                guard let self else { return }
                if d > 0, self.streamRows.indices.contains(from) { self.markViewed([self.streamRows[from].id]) }
                self.selectStream(i)
            }
            return
        }
        if reading {
            reader.nudge(d) { [weak self] atEnd in
                guard let self else { return }
                guard atEnd else { self.edgeArmed = nil; return }
                if self.edgeArmed == d, Date().timeIntervalSince(self.edgeArmedAt) < 2 {
                    self.edgeArmed = nil
                    self.list.select(self.list.selectedIndex + d)
                    self.openSelected()
                } else {
                    self.edgeArmed = d
                    self.edgeArmedAt = Date()
                    self.toast.show(d > 0 ? "End of thread  ·  j again for the next" : "Top of thread  ·  k again for the previous")
                }
            }
            return
        }
        list.step(d)
    }

    /// Home / End / Page Up / Page Down move the cursor, not just the view.
    private func navigate(_ code: UInt16) -> Bool {
        if streaming {
            switch code {
            case 115: stream.scroll(to: 0)
            case 119: stream.scroll(to: streamRows.count - 1)
            default: stream.page(code == 116 ? -1 : 1)
            }
            return true
        }
        if reading {
            switch code {
            case 115: WebRenderer.shared.view.evaluateJavaScript("window.scrollTo(0,0)")
            case 119: WebRenderer.shared.view.evaluateJavaScript("window.scrollTo(0,document.body.scrollHeight)")
            default: reader.scrollBody(by: code == 116 ? -1 : 1)
            }
            return true
        }
        let perPage = max(1, Int(list.contentView.bounds.height / Style.rowHeight) - 2)
        switch code {
        case 115: list.select(0)
        case 119: list.select(list.rows.count - 1)
        default: for _ in 0..<perPage { list.step(code == 116 ? -1 : 1) }
        }
        return true
    }

    /// The first j at the bottom of a thread only arms the move to the next.
    private var edgeArmed: Int?
    private var edgeArmedAt = Date.distantPast

    // MARK: actions

    /// Where each undoable action happened, so z puts you back there — the
    /// thread selected again, and open again if it was open.
    private var undoPlaces: [(depth: Int, account: String, id: String, wasReading: Bool)] = []

    private func remember(_ t: ThreadSummary, reading was: Bool) {
        undoPlaces.append((actions.undo.count, t.account, t.id, was))
    }

    private func act(_ title: String, _ f: ([ThreadSummary]) throws -> Void) {
        guard let t = list.selected else { return }
        let wasReading = reading
        let depth = actions.undo.count
        defer { if actions.undo.count > depth { remember(t, reading: wasReading) } }
        if streaming {
            // Stay where you are: the email leaves the page and the next one
            // slides up into its place.
            do { try f([t]) } catch { toast.show("\(title) failed: \(error)"); return }
            reloadList()
            toast.show("\(title)  ·  z to undo")
            return
        }
        let i = list.selectedIndex
        do { try f([t]) } catch { toast.show("\(title) failed: \(error)"); return }
        reloadList()
        list.select(min(i, list.rows.count - 1))
        if reading {
            if list.rows.isEmpty { closeThread() } else { openSelected() }
        }
        toast.show("\(title)  ·  z to undo")
    }

    private func undo() {
        let place = undoPlaces.last.flatMap { $0.depth == actions.undo.count - 1 ? $0 : nil }
        do {
            if let t = try actions.undoLast() { toast.show("Undid \(t.lowercased())") } else { toast.show("Nothing to undo"); return }
        } catch { toast.show("Undo failed: \(error)"); return }
        undoPlaces.removeAll { $0.depth >= actions.undo.count }
        // Whatever came back belongs where it was: redraw the feed around it.
        if streaming { stream.invalidate() }
        guard let place else {
            reloadList(keep: list.selected?.id)
            if reading, let t = reader.thread { reader.show(t, messages: store.messages(account: t.account, thread: t.id)) }
            return
        }
        // Back to the email the action was taken on — and open, if it was.
        reloadList(keep: place.id)
        if list.selected?.id == place.id {
            if place.wasReading { openSelected() }
            else if reading { closeThread(); reloadList(keep: place.id) }
        }
    }

    /// Places every selected sender (⌘A selects a whole section). With no
    /// category given, each goes where it was proposed.
    private func decide(_ category: String?) {
        guard view == .newSenders else { return }
        let picked = list.selectedGroups
        guard !picked.isEmpty else { return }
        let placements = picked.compactMap { g -> (account: String, email: String, category: String)? in
            guard let c = category ?? g.category?.rawValue else { return nil }
            return (g.account, g.email, c)
        }
        guard !placements.isEmpty else { toast.show("No proposed label yet — pick one: a · s · p · n"); return }
        let next = list.groups.indices.first { i in i > (list.selectedGroup ?? 0) && !picked.contains { $0.key == list.groups[i].key } }
        let keepKey = next.map { list.groups[$0].key }
        do {
            if placements.count == 1, let p = placements.first {
                try actions.decide(account: p.account, email: p.email, category: p.category)
            } else {
                for (account, ps) in Dictionary(grouping: placements, by: \.account) {
                    try actions.decideMany(account: account, ps.map { ($0.email, $0.category) })
                }
            }
        } catch { toast.show("\(error)"); return }
        reloadList(keepSender: keepKey)
        let title = placements.count == 1 ? actions.title(for: placements[0].category) : "Placed \(placements.count) senders"
        toast.show("\(title)  ·  z to undo")
    }

    func compose(_ mode: ReplyMode) {
        guard let current = box else { return }
        let thread = list.selected
        if mode != .new, thread == nil { return }
        if mode != .new, let t = thread, let box = boxFor(t) {
            if !reading { openSelected() }
            do {
                let r = try InlineReply(box: box, mode: mode, thread: store.messages(account: t.account, thread: t.id), config: store.config)
                r.onCancel = { [weak self] in self?.reader.closeReply(); self?.window.makeFirstResponder(self?.reader) }
                r.onSend = { [weak self] m, alias in
                    guard let self else { return }
                    do {
                        try self.actions.send(account: box.account, m, alias: alias)
                        self.reader.closeReply()
                        let writes = self.store.config.writes(box.account)
                        self.toast.show(writes ? "Sending in 10s  ·  z to undo" : "Saved as a draft in 10s (sending is off)  ·  z to undo")
                    } catch { self.toast.show("Not sent: \(error)") }
                }
                reader.openReply(r)
            } catch { toast.show("\(error)") }
            return
        }
        guard let box = current.isAll ? boxes.first : current else { return }
        let c = ComposeView(box: box)
        c.onCancel = { [weak self] in self?.closePane() }
        c.onSend = { [weak self] m, alias in
            guard let self else { return }
            do {
                try self.actions.send(account: box.account, m, alias: alias)
                self.closePane()
                let writes = self.store.config.writes(box.account)
                self.toast.show(writes ? "Sending in 10s  ·  z to undo" : "Saved as a draft in 10s (sending is off)  ·  z to undo")
            } catch {
                self.toast.show("Not sent: \(error)")
            }
        }
        openPane(c)
        c.focus()
    }

    private func openPane(_ v: NSView) {
        if reading { reader.closeReply() }
        pane = v
        fill(content, with: v)
    }

    func closePane() {
        guard pane != nil else { return }
        pane = nil
        if reading, let t = reader.thread {
            fill(content, with: reader)
            reader.show(t, messages: store.messages(account: t.account, thread: t.id), force: true)
        } else {
            stream.invalidate()
            reloadList(keep: list.selected?.id)
            if !streaming { fill(content, with: list) }
        }
        window.makeFirstResponder(reading ? reader : list.table)
    }

    private lazy var settingsPane = SettingsPane(engine: engine) { [weak self] in self?.accountsChanged() }

    func showSettings() {
        closeOverlay()
        settingsPane.refresh()
        openPane(settingsPane)
    }

    private func showOverlay(_ o: Overlay) {
        closeOverlay()
        overlay = o
        o.onClose = { [weak self] in self?.closeOverlay() }
        o.show(in: window.contentView!)
    }

    func closeOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
        if window.firstResponder == nil || window.firstResponder === window { window.makeFirstResponder(reading ? reader : list.table) }
    }

    func showMove() {
        guard let t = reading ? reader.thread : list.selected, !t.senderEmail.isEmpty else {
            toast.show("Nothing to move — this thread has no sender but you"); return
        }
        showOverlay(MoveOverlay(sender: t.sender, email: t.senderEmail, account: t.account, current: t.category?.rawValue ?? ""))
    }

    /// Teaches the sorting: the sender's mail, old and new, follows.
    func moveSender(_ email: String, account: String, to decision: String, title: String) {
        let backToList = reading
        act("Moved \(email) to \(title)") { _ in try actions.decide(account: account, email: email, category: decision) }
        if backToList && reading { closeThread() }
    }

    /// ⌘S, as in Arc: the sidebar slides away and the top bar takes over.
    func toggleSidebar() {
        let show = sidebarWidth.constant == 0
        store.set("ui.sidebar", show ? "shown" : "hidden")
        header.sidebarShown = show
        if show { sidebar.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            sidebarWidth.animator().constant = show ? Sidebar.width : 0
            window.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in if !show { self?.sidebar.isHidden = true } })
        reloadList(keep: list.selected?.id)
    }

    /// A new name for an account or alias, kept in accounts.json.
    func rename(box i: Int, to name: String) {
        guard boxes.indices.contains(i), var f = try? AccountsStore.load() else { return }
        let b = boxes[i]
        guard let a = f.accounts.firstIndex(where: { $0.email == b.account }) else { return }
        if let alias = b.alias, let r = f.accounts[a].aliases.firstIndex(where: { $0.address == alias.address }) {
            f.accounts[a].aliases[r].label = name
        } else {
            f.accounts[a].label = name
        }
        do { try AccountsStore.save(f) } catch { toast.show("Couldn't rename: \(error)"); return }
        accountsChanged()
        window.makeFirstResponder(reading ? reader : list.table)
        toast.show("Renamed to \(name)")
    }

    /// Everyone waiting in New Senders goes where the sorter would put them.
    func placeAllAsSuggested() {
        guard let box else { return }
        var seen = Set<String>()
        let waiting = store.threads(box, .newSenders, limit: 5000).filter {
            !$0.senderEmail.isEmpty && $0.category != nil && seen.insert($0.account + $0.senderEmail).inserted
        }
        guard !waiting.isEmpty else { toast.show("No suggestions yet — Jev hasn't answered for anyone waiting"); return }
        do {
            for (account, ts) in Dictionary(grouping: waiting, by: \.account) {
                try actions.decideMany(account: account, ts.map { ($0.senderEmail, $0.category!.rawValue) })
            }
        } catch { toast.show("\(error)"); return }
        let picks = waiting
        reloadList()
        toast.show("Placed \(picks.count) senders as suggested  ·  z to undo")
    }

    func toggleHelp() {
        if overlay is HelpOverlay { closeOverlay() } else { showOverlay(HelpOverlay()) }
    }

    func showPalette() {
        let p = PaletteOverlay(for: self)
        showOverlay(p)
        p.focus()
    }

    private func loadImages(always: Bool) {
        if streaming {
            if always, let t = list.selected, !t.senderEmail.isEmpty { store.set("img:\(t.account):\(t.senderEmail)", "1") }
            else { streamImages = true }
            stream.invalidate()
            showStream()
            toast.show(always ? "Images on for this sender" : "Images on in the feed")
            return
        }
        guard reading, let t = reader.thread else { return }
        if always {
            for e in Set(reader.messages.compactMap { $0.shownFrom?.email.lowercased() }) { store.set("img:\(t.account):\(e)", "1") }
            toast.show("Images always on from \(t.sender)")
        } else {
            imageThreads.insert(t.id)
        }
        reader.show(t, messages: reader.messages, force: true)
    }

    // MARK: search

    func startSearch() {
        header.search.isHidden = false
        window.makeFirstResponder(header.search)
    }

    func controlTextDidChange(_ n: Notification) {
        let q = header.search.stringValue.trimmingCharacters(in: .whitespaces)
        view = q.isEmpty ? lastTab : .search(q)
        reloadList()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) || sel == #selector(NSResponder.moveDown(_:)) {
            window.makeFirstResponder(list.table)
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            header.search.stringValue = ""
            go(lastTab)
            window.makeFirstResponder(list.table)
            return true
        }
        return false
    }

    // MARK: keys

    /// In the feed the email on screen is the one keys act on — ask the page
    /// which that is before acting, rather than trusting a cursor that
    /// scrolling may have left behind.
    private var resolvedVisible = false
    private static let actsOnEmail: Set<String> = ["e", "#", "!", "U", "m", "M", "r", "R", "F", "o", "i", "I"]

    func key(_ e: NSEvent) -> Bool {
        let bare = e.modifierFlags.intersection([.command, .control, .option]).isEmpty
        // (Only with emails on the page and no g-chord pending — otherwise
        // the page never answers and the key would be swallowed.)
        if streaming, bare, overlay == nil, pane == nil, !resolvedVisible, !pendingG, !stream.ids.isEmpty, stream.isDrawn,
           Self.actsOnEmail.contains(e.charactersIgnoringModifiers ?? "") || e.keyCode == 36 || e.keyCode == 76 {
            stream.here { [weak self] i in
                guard let self else { return }
                self.selectStream(i)
                self.resolvedVisible = true
                _ = self.key(e)
                self.resolvedVisible = false
            }
            return true
        }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        let ch = e.charactersIgnoringModifiers ?? ""
        if mods == .control, let n = Int(ch) {
            if n == 0 { showAll() } else { switchBox(n - 1) }
            return true
        }
        if mods == .command {
            switch ch {
            case "k": showPalette(); return true
            case "r": engine.syncAll(); toast.show("Checking for new mail…"); return true
            case "s": toggleSidebar(); return true
            case "a" where list.grouped: list.selectAllInSection(); return true
            default: return false
            }
        }
        if let move = overlay as? MoveOverlay {
            if e.keyCode == 53 { closeOverlay(); return true }
            if let c = MoveOverlay.choices.first(where: { $0.key == ch }) {
                closeOverlay()
                moveSender(move.email, account: move.account, to: c.decision, title: c.title)
            }
            return true
        }
        if overlay != nil {
            if e.keyCode == 53 || ch == "?" { closeOverlay(); return true }
            return overlay is HelpOverlay
        }
        if pane != nil {
            if e.keyCode == 53 { closePane(); return true }
            return false
        }
        if e.keyCode == 48, mods.isEmpty { // tab: the next stream
            cycleStream(e.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        }
        guard mods.isEmpty else { return false }

        if pendingG {
            pendingG = false
            switch ch {
            case "g": list.select(0); if reading { openSelected() }; if streaming { stream.scroll(to: 0) }
            case "i": go(.inbox)
            case "o": go(.notifications)
            case "c": go(.calendar)
            case "t": go(.sent)
            case "f": go(.feed)
            case "p": go(.paper)
            case "n", "s": go(.newSenders)
            case "x": go(.spam)
            case "m": go(.muted)
            default: break
            }
            return true
        }

        switch e.keyCode {
        case 53: // esc
            if reading { closeThread(); return true }
            if case .search = view { header.search.stringValue = ""; go(lastTab); return true }
            return false
        case 36, 76: // return
            if list.grouped && !reading && !list.selectedRowIsThread { list.fold(open: nil); return true }
            if !reading { openSelected(); return true }
            compose(.reply)
            return true
        case 124 where list.grouped && !reading: list.fold(open: true); return true   // right
        case 123 where list.grouped && !reading: list.fold(open: false); return true  // left
        case 115, 119, 116, 121: // home, end, page up, page down
            return navigate(e.keyCode)
        case 125: step(1); return true   // down
        case 126: step(-1); return true  // up
        case 49: // space
            if streaming { stream.page(e.modifierFlags.contains(.shift) ? -1 : 1); return true }
            if reading { reader.scrollBody(by: e.modifierFlags.contains(.shift) ? -1 : 1); return true }
            return false
        default: break
        }

        switch ch {
        case "j": step(1)
        case "k": step(-1)
        case "g": pendingG = true
        case "G": list.select(list.rows.count - 1); if reading { openSelected() }; if streaming { stream.scroll(to: min(39, list.rows.count - 1)) }
        case "v": if view == .feed && !reading { streamMode.toggle(); reloadList(keep: list.selected?.id) }
        case "o":
            if list.grouped && !list.selectedRowIsThread { list.fold(open: nil) } else if !reading { openSelected() }
        case "u": if reading { closeThread() }
        case "e": act("Done") { try actions.done($0) }
        case "#": act("Trashed") { try actions.trash($0) }
        case "!":
            let undoSpam = view == .spam
            act(undoSpam ? "Not spam" : "Marked as spam") { try actions.spam($0, notSpam: undoSpam) }
        case "U": act("Toggled unread") { try actions.toggleUnread($0[0]) }
        case "z": undo()
        case "m": showMove()
        case "M":
            if let t = reading ? reader.thread : list.selected, !t.senderEmail.isEmpty { moveSender(t.senderEmail, account: t.account, to: "muted", title: "Muted") }
        case "i": loadImages(always: false)
        case "I": loadImages(always: true)
        case "/": startSearch()
        case "?": toggleHelp()
        case "c": compose(.new)
        case "r": compose(.reply)
        case "R": compose(.replyAll)
        case "F": compose(.forward)
        case "a": decide("inbox")
        case "f", "s": decide("feed")   // s: subscribe
        case "n": decide("notify")
        case "p": decide("paper")
        case "x": decide("blocked")
        case "y": decide(nil)
        case "h": if list.grouped { list.fold(open: false) }
        case "l": if list.grouped { list.fold(open: true) }
        case "1", "2", "3", "4", "5", "6", "7", "8", "9": switchBox(Int(ch)! - 1)
        default: return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) { saveState() }
}
