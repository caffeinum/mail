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
    let list = ListView()
    lazy var reader = ThreadView()
    lazy var stream = FeedStream()
    /// Feed reads as a stream of the emails themselves; v flips to the list.
    private var streamMode = true
    private var streaming: Bool { view == .feed && streamMode && !reading }
    let toast = Toast()
    private let content = NSView()

    private(set) var boxes: [Mailbox] = []
    private(set) var box: Mailbox?
    private(set) var view: View = .inbox
    private var lastTab: View = .inbox
    private var reading = false
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
        window.title = "Post"
        window.minSize = NSSize(width: 640, height: 400)
        window.setFrameAutosaveName("PostMain")
        if !window.setFrameUsingName("PostMain") { window.center() }
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.router = { [weak self] e in self?.key(e) ?? false }
        window.backgroundColor = .textBackgroundColor

        let root = NSView()
        window.contentView = root
        for v in [header, content, toast] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
        Launch.mark("layout")
        fill(content, with: list)
        header.searchDelegate = self
        header.onTab = { [weak self] v in self?.go(v) }
        header.onAccount = { [weak self] i in self?.switchBox(i) }
        list.onOpen = { [weak self] i in self?.list.select(i); self?.openSelected() }
        list.onSelect = { [weak self] _ in self?.prefetchAroundCursor() }
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
    func showFirstFrame() {
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
        list.set(store.threads(box, view, limit: 500), keep: id)
        if streaming { showStream() } else if !reading { fill(content, with: list) }
        var counts: [View: Int] = [:]
        for v in View.tabs { counts[v] = store.count(box, v) }
        header.update(boxes: boxes, current: box, view: view, counts: counts, note: errors[box.account])
    }

    private func showStream() {
        fill(content, with: stream)
        let rows = list.rows.prefix(40)
        let items = rows.map { t in FeedStream.item(t, store.messages(account: t.account, thread: t.id).last) }
        stream.show(Array(items), at: max(0, list.selectedIndex))
    }

    // MARK: engine callbacks

    func cacheChanged(account: String) {
        errors[account] = nil
        guard box?.account == account else { return }
        reloadList(keep: list.selected?.id)
        if reading, let t = reader.thread {
            let fresh = store.thread(account: t.account, id: t.id) ?? t
            reader.show(fresh, messages: store.messages(account: t.account, thread: t.id))
        }
    }

    func syncFailed(account: String, error: Error) {
        errors[account] = "offline — showing what's cached"
        if box?.account == account { reloadList(keep: list.selected?.id) }
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
        let ids = list.rows[lo..<hi].filter { !store.hasBodies(account: $0.account, thread: $0.id) }.map(\.id)
        engine.prefetch(box.account, ids)
    }

    // MARK: navigation

    func go(_ v: View) {
        if reading { closeThread() }
        view = v
        if case .search = v {} else { lastTab = v; header.search.stringValue = "" }
        reloadList()
        if let box { engine.prefetch(box.account, store.threadsNeedingBodies(box, v, limit: 50)) }
    }

    func switchBox(_ i: Int) {
        guard boxes.indices.contains(i) else { return }
        if reading { closeThread() }
        box = boxes[i]
        if case .search = view { view = lastTab }
        reloadList()
    }

    func openSelected() {
        guard let t = list.selected else { return }
        stream.invalidate()
        reading = true
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
            stream.step(d) { [weak self] i in self?.list.select(i) }
            return
        }
        list.select(list.selectedIndex + d)
        if reading { openSelected() }
    }

    // MARK: actions

    private func act(_ title: String, _ f: ([ThreadSummary]) throws -> Void) {
        guard let t = list.selected else { return }
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
        guard let box else { return }
        let thread = list.selected
        if mode != .new, thread == nil { return }
        let msgs = thread.map { store.messages(account: $0.account, thread: $0.id) } ?? []
        do {
            let c = try ComposeWindow(box: box, mode: mode, thread: msgs, config: store.config) { [weak self] m, alias in
                guard let self else { return }
                do {
                    try self.actions.send(account: box.account, m, alias: alias)
                    let writes = self.store.config.writes(box.account)
                    self.toast.show(writes ? "Sending in 10s  ·  z to undo" : "Saved as a draft in 10s (sending is off)  ·  z to undo")
                } catch {
                    self.toast.show("Not sent: \(error)")
                }
            }
            c.show()
        } catch {
            toast.show("\(error)")
        }
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
        if mods == .command {
            switch ch {
            case "k": Palette.shared.show(for: self); return true
            default: return false
            }
        }
        guard mods.isEmpty else { return false }

        if pendingG {
            pendingG = false
            switch ch {
            case "g": list.select(0); if reading { openSelected() }; if streaming { stream.scroll(to: 0) }
            case "i": go(.inbox)
            case "f": go(.feed)
            case "p": go(.paper)
            case "n", "s": go(.newSenders)
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
            return false
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
        case "U": act("Toggled unread") { try actions.toggleUnread($0[0]) }
        case "z": undo()
        case "/": startSearch()
        case "?": Help.shared.toggle(over: window)
        case "c": compose(.new)
        case "r": compose(.reply)
        case "R": compose(.replyAll)
        case "F": compose(.forward)
        case "a", "y": decide("inbox")
        case "f": decide("feed")
        case "p": decide("paper")
        case "x": decide("blocked")
        case "1", "2", "3", "4", "5", "6", "7", "8", "9": switchBox(Int(ch)! - 1)
        default: return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) { saveState() }
}
