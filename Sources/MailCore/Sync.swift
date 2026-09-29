import Foundation

/// Keeps one gmail account's cache current: a first fill of the streams,
/// then history deltas from the stored history id. Bodies come ahead of
/// need for the top of each list and around the cursor.
public actor AccountSync {
    public let account: String
    let gmail: Gmail
    let store: Store
    let outbox: Outbox
    private var syncing = false
    private var bodyInFlight = Set<String>()

    public init(account: String, store: Store, outbox: Outbox) {
        self.account = account
        self.gmail = Gmail(account: account)
        self.store = store
        self.outbox = outbox
    }

    public struct Report: CustomStringConvertible {
        public var full = false
        public var changed = 0
        public var fetched = 0
        public var ms = 0
        public var description: String { "\(full ? "fill" : "delta") changed=\(changed) fetched=\(fetched) \(ms)ms" }
    }

    /// Pulls whatever changed. Safe to call as often as the doorbell rings;
    /// overlapping calls collapse into the one already running.
    @discardableResult
    public func sync() async throws -> Report? {
        guard !syncing else { return nil }
        syncing = true
        defer { syncing = false }
        let t0 = Date()
        var r: Report
        if let hid = store.historyID(account) {
            do { r = try await delta(from: hid) }
            catch GmailError.historyExpired {
                log("\(account): history expired, filling again")
                r = try await fill()
            }
        } else {
            r = try await fill()
        }
        // Caches filled before spam was shown pick it up once.
        let key = "backfill.spam.\(account)"
        if store.get(key) == nil {
            let refs = try await gmail.threads(query: "in:spam", max: 50).refs
            r.fetched += try await fetchThreads(refs.map(\.id), format: .metadata)
            store.set(key, "1")
        }
        r.ms = Int(Date().timeIntervalSince(t0) * 1000)
        return r
    }

    static let fillQueries: [(String, Int)] = [
        ("in:inbox", 200),
        ("label:\(Streams.feed.replacingOccurrences(of: "/", with: "-"))", 100),
        ("label:\(Streams.paper.replacingOccurrences(of: "/", with: "-"))", 100),
        ("in:sent", 100),
        ("in:spam", 50),
    ]

    func fill() async throws -> Report {
        let labels = try await gmail.labels()
        try store.setLabels(account, labels)
        // The history id is taken before listing, so nothing that changes
        // while we list is missed by the next delta.
        let profile = try await gmail.profile()
        var ids: [String] = []
        var seen = Set<String>()
        for (q, max) in Self.fillQueries {
            let refs = try await gmail.threads(query: q, max: max).refs
            for r in refs where seen.insert(r.id).inserted { ids.append(r.id) }
        }
        let fetched = try await fetchThreads(ids, format: .metadata)
        try store.setHistoryID(account, profile.historyId)
        return Report(full: true, changed: ids.count, fetched: fetched)
    }

    /// Fetches threads concurrently and writes them in batches as they land,
    /// so a list starts filling before the last request returns.
    @discardableResult
    func fetchThreads(_ ids: [String], format: Gmail.Format) async throws -> Int {
        var count = 0
        let chunk = 25
        for start in stride(from: 0, to: ids.count, by: chunk) {
            let slice = Array(ids[start..<min(start + chunk, ids.count)])
            let msgs = try await withThrowingTaskGroup(of: [GmailMessage].self) { g in
                for id in slice {
                    g.addTask { [gmail] in
                        do { return try await gmail.thread(id, format: format).messages ?? [] }
                        catch GmailError.http(404, _, _) { return [] }
                    }
                }
                var all: [GmailMessage] = []
                for try await m in g { all += m }
                return all
            }
            let recs = msgs.map { MessageRecord(account: account, gmail: $0) }
            let touched = try store.upsert(recs)
            outbox.overlay(account: account, threads: Set(touched.map { String($0.split(separator: "\u{1}").last ?? "") }))
            count += slice.count
        }
        return count
    }

    func delta(from hid: String) async throws -> Report {
        let (records, latest) = try await gmail.history(since: hid)
        var added = Set<String>()
        var labelled: [String: [String]] = [:]
        var deleted = Set<String>()
        for rec in records {
            for i in rec.messagesAdded ?? [] { added.insert(i.message.id) }
            for i in (rec.labelsAdded ?? []) + (rec.labelsRemoved ?? []) {
                if let l = i.message.labelIds { labelled[i.message.id] = l }
            }
            for i in rec.messagesDeleted ?? [] { deleted.insert(i.message.id); added.remove(i.message.id) }
        }
        var touched = Set<String>()
        for id in deleted { if let t = try store.deleteMessage(account: account, id: id) { touched.insert(t) } }
        for (id, l) in labelled where !added.contains(id) && !deleted.contains(id) {
            if let t = try store.setLabels(account: account, messageID: id, labels: l) { touched.insert(t) }
            else { added.insert(id) }
        }
        if !added.isEmpty {
            let msgs = try await withThrowingTaskGroup(of: GmailMessage?.self) { g in
                for id in added {
                    g.addTask { [gmail] in
                        do { return try await gmail.message(id, format: .metadata) }
                        catch GmailError.http(404, _, _) { return nil }
                    }
                }
                var all: [GmailMessage] = []
                for try await m in g { if let m { all.append(m) } }
                return all
            }
            for k in try store.upsert(msgs.map { MessageRecord(account: account, gmail: $0) }) {
                touched.insert(String(k.split(separator: "\u{1}").last ?? ""))
            }
        }
        if !touched.isEmpty {
            try store.recompute(account: account, threads: Array(touched))
            outbox.overlay(account: account, threads: touched)
        }
        try store.setHistoryID(account, latest)
        return Report(full: false, changed: touched.count, fetched: added.count)
    }

    /// Full bodies for these threads, skipping ones already cached or on
    /// their way.
    public func prefetch(_ threads: [String]) async {
        let want = threads.filter { !bodyInFlight.contains($0) && !store.hasBodies(account: account, thread: $0) }
        guard !want.isEmpty else { return }
        want.forEach { bodyInFlight.insert($0) }
        defer { want.forEach { bodyInFlight.remove($0) } }
        do { try await fetchThreads(want, format: .full) }
        catch { log("\(account): body prefetch failed: \(error)") }
    }
}
