import AppKit
import MailCore

final class KeyWindow: NSWindow {
    var router: ((NSEvent) -> Bool)?

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

    func reloadList(keep id: String? = nil) {
        guard let box else {
            list.set([], keep: nil)
            header.update(boxes: [], current: nil, view: view, counts: [:], note: "No accounts yet — ⌘, to add one")
            return
        }
        list.suggest = view == .newSenders
        list.accountTags = box.isAll ? Dictionary(boxes.map { ($0.account + "\u{1}" + ($0.alias?.address.lowercased() ?? ""), $0.title) }, uniquingKeysWith: { a, _ in a }) : [:]
        var rows = store.threads(box, view, limit: 500)
        if view == .newSenders {
            // One row per sender — their latest thread stands for them.
            var seen = Set<String>()
            rows = rows.filter { seen.insert($0.account + $0.senderEmail).inserted }
        }
        list.set(rows, keep: id)
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

    private func watchViewed() {
        viewedTimer?.invalidate()
        viewedTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, self.streaming, self.pane == nil else { return }
            self.stream.here { i in
                self.markViewed(self.streamRows.prefix(i).map(\.id))
            }
        }
    }

    private func selectStream(_ i: Int) {
        guard streamRows.indices.contains(i), let row = list.rows.firstIndex(where: { $0.id == streamRows[i].id }) else { return }
        list.select(row)
    }

    private func showStream() {
        fill(content, with: stream)
        streamRows = orderedFeed()
        if viewedTimer == nil { watchViewed() }
        let rows = streamRows
        let at = streamRows.firstIndex { $0.id == list.selected?.id } ?? 0
        let items = rows.map { t -> FeedStream.Item in
            let last = store.messages(account: t.account, thread: t.id).last
            return FeedStream.item(t, last, images: streamImages || last.map(imagesAllowed) == true)
        }
        stream.show(Array(items), at: at, images: streamImages || items.contains { !$0.html.contains("blocked-http") && WebRenderer.hasRemoteImages($0.html) })
    }

    // MARK: engine callbacks

    func cacheChanged(account: String) {
        errors[account] = nil
        guard box?.account == account || box?.isAll == true else { return }
        reloadList(keep: list.selected?.id)
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
    }

    private var lastOlder = Date.distantPast

    /// Near the bottom of a list: ask gmail for the next page of older mail.
    func loadOlder() {
        guard let box, Date().timeIntervalSince(lastOlder) > 2 else { return }
        lastOlder = Date()
        let accounts = box.isAll ? store.config.accounts.map(\.email) : [box.account]
        for a in accounts { Task { await engine.older(a) } }
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
        list.select(list.selectedIndex + d)
    }

    /// The first j at the bottom of a thread only arms the move to the next.
    private var edgeArmed: Int?
    private var edgeArmedAt = Date.distantPast

    // MARK: actions

    private func act(_ title: String, _ f: ([ThreadSummary]) throws -> Void) {
        guard let t = list.selected else { return }
        if streaming {
            // Stay where you are: the next post slides up into place.
            let si = streamRows.firstIndex { $0.id == t.id } ?? 0
            let next = streamRows.indices.contains(si + 1) ? streamRows[si + 1].id : (si > 0 ? streamRows[si - 1].id : nil)
            do { try f([t]) } catch { toast.show("\(title) failed: \(error)"); return }
            reloadList(keep: next)
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
        do {
            if let t = try actions.undoLast() { toast.show("Undid \(t.lowercased())") } else { toast.show("Nothing to undo") }
        } catch { toast.show("Undo failed: \(error)") }
        reloadList(keep: list.selected?.id)
        if reading, let t = reader.thread {
            reader.show(t, messages: store.messages(account: t.account, thread: t.id))
        }
    }

    private func decide(_ category: String) {
        guard view == .newSenders, let t = list.selected, !t.senderEmail.isEmpty else { return }
        act(actions.title(for: category)) { _ in try actions.decide(account: t.account, email: t.senderEmail, category: category) }
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

    func key(_ e: NSEvent) -> Bool {
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
            if !reading { openSelected(); return true }
            compose(.reply)
            return true
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
        case "o": if !reading { openSelected() }
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
        case "y":
            if view == .newSenders, let t = list.selected {
                if let c = t.category { decide(c.rawValue) } else { toast.show("No suggestion yet for \(t.sender)") }
            }
        case "1", "2", "3", "4", "5", "6", "7", "8", "9": switchBox(Int(ch)! - 1)
        default: return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) { saveState() }
}
