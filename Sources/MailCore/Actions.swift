import Foundation

/// Every user action lands in the cache at once and is queued for gmail.
/// z walks back through them: a queued change is simply cancelled, one that
/// already went out gets its inverse queued.
public final class Actions {
    public struct Entry {
        public let title: String
        var outbox: [(id: Int64, account: String, inverse: [Op])]
        var restore: [() throws -> Void]
    }

    let store: Store
    let outbox: Outbox
    public private(set) var undo: [Entry] = []
    /// How long a change waits before it goes out: long enough that z usually
    /// catches it before gmail ever hears of it.
    public var grace: TimeInterval = 5
    public var sendGrace: TimeInterval = 10

    public init(store: Store, outbox: Outbox) {
        self.store = store
        self.outbox = outbox
    }

    private func labels(_ t: ThreadSummary, add: [String], remove: [String], entry: inout Entry) throws {
        let before = try store.modifyLocal(account: t.account, thread: t.id, add: add, remove: remove)
        let id = try outbox.enqueue(t.account, .modify(thread: t.id, add: add, remove: remove), delay: grace)
        let reAdd = remove.filter { l in before.values.contains { $0.contains(l) } }
        let reRemove = add.filter { l in !before.values.allSatisfy { $0.contains(l) } }
        entry.outbox.append((id, t.account, [.modify(thread: t.id, add: reAdd, remove: reRemove)]))
        entry.restore.append { [store] in try store.restoreLocal(account: t.account, thread: t.id, labels: before) }
    }

    /// e: out of the inbox.
    public func done(_ threads: [ThreadSummary]) throws {
        var e = Entry(title: threads.count == 1 ? "Done" : "Done ×\(threads.count)", outbox: [], restore: [])
        for t in threads { try labels(t, add: [], remove: ["INBOX"], entry: &e) }
        undo.append(e)
    }

    /// #: to the trash.
    public func trash(_ threads: [ThreadSummary]) throws {
        var e = Entry(title: "Trashed", outbox: [], restore: [])
        for t in threads {
            let before = try store.modifyLocal(account: t.account, thread: t.id, add: ["TRASH"], remove: ["INBOX"])
            let id = try outbox.enqueue(t.account, .trash(thread: t.id), delay: grace)
            let hadInbox = before.values.contains { $0.contains("INBOX") }
            e.outbox.append((id, t.account, [.untrash(thread: t.id)] + (hadInbox ? [.modify(thread: t.id, add: ["INBOX"], remove: [])] : [])))
            e.restore.append { [store] in try store.restoreLocal(account: t.account, thread: t.id, labels: before) }
        }
        undo.append(e)
    }

    /// Opening a thread reads it. Not worth an undo step.
    public func markRead(_ t: ThreadSummary) {
        guard t.unread else { return }
        _ = try? store.modifyLocal(account: t.account, thread: t.id, add: [], remove: ["UNREAD"])
        _ = try? outbox.enqueue(t.account, .modify(thread: t.id, add: [], remove: ["UNREAD"]))
    }

    public func toggleUnread(_ t: ThreadSummary) throws {
        var e = Entry(title: t.unread ? "Marked read" : "Marked unread", outbox: [], restore: [])
        try labels(t, add: t.unread ? [] : ["UNREAD"], remove: t.unread ? ["UNREAD"] : [], entry: &e)
        undo.append(e)
    }

    /// A new sender, let in: to the inbox, the feed or the paper trail — or
    /// kept out. Gmail gets a filter so the phone sorts them the same way.
    public func decide(account: String, email: String, category: String) throws {
        let prior = store.senderRow(account: account, email: email)
        try store.decide(account: account, email: email, decision: category)
        var e = Entry(title: title(for: category), outbox: [], restore: [])
        let id = try outbox.enqueue(account, .sort(email: email, category: category), delay: grace)
        e.outbox.append((id, account, []))
        e.restore.append { [store] in
            if let prior { try store.decide(account: account, email: email, decision: prior.decision, filterID: prior.filterID) }
            else { try store.undecide(account: account, email: email) }
        }
        undo.append(e)
    }

    public func title(for category: String) -> String {
        switch category {
        case "feed": return "Moved to Feed"
        case "paper": return "Moved to Paper Trail"
        case "blocked": return "Blocked"
        default: return "Let in"
        }
    }

    /// Queues a send; z within `sendGrace` takes it back before it leaves.
    public func send(account: String, _ m: OutgoingMessage, alias: AliasRule?) throws {
        if let alias { try AliasRelay(alias).verify(m, account: account) }
        let id = try outbox.enqueue(account, .send(m, alias: alias), delay: sendGrace)
        undo.append(Entry(title: "Sent", outbox: [(id, account, [])], restore: []))
    }

    /// z. Returns what was undone, or nil when there's nothing left.
    @discardableResult
    public func undoLast() throws -> String? {
        guard let e = undo.popLast() else { return nil }
        for o in e.outbox.reversed() {
            if try outbox.cancel(o.id) { continue }
            if let s = outbox.state(o.id), s == "local" || s == "failed" || s == "cancelled" { continue }
            if case .sort(let email, _) = try decodedOp(o.id) {
                try outbox.enqueue(o.account, .unsort(email: email, filterID: outbox.result(o.id)))
                continue
            }
            for inv in o.inverse { try outbox.enqueue(o.account, inv) }
        }
        for r in e.restore.reversed() { try r() }
        return e.title
    }

    private func decodedOp(_ id: Int64) throws -> Op? {
        guard let p = try store.db.string("SELECT payload FROM outbox WHERE id=?", id) else { return nil }
        return try JSONDecoder().decode(Op.self, from: Data(p.utf8))
    }
}
