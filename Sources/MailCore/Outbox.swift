import Foundation

/// A change waiting to reach gmail. Local state already reflects it.
public enum Op: Codable, Equatable {
    case modify(thread: String, add: [String], remove: [String])
    /// Label by stream name; the runner resolves (or creates) the label id.
    case stream(thread: String, add: String?, remove: String?, archive: Bool)
    case trash(thread: String)
    case untrash(thread: String)
    case send(OutgoingMessage, alias: AliasRule?)
    /// Keep a sender sorted server-side: a filter for from:email, plus the
    /// same treatment for their threads already here.
    case sort(email: String, category: String)
    case unsort(email: String, filterID: String?)

    var kind: String {
        switch self {
        case .modify: return "modify"
        case .stream: return "stream"
        case .trash: return "trash"
        case .untrash: return "untrash"
        case .send: return "send"
        case .sort: return "sort"
        case .unsort: return "unsort"
        }
    }

    var thread: String? {
        switch self {
        case .modify(let t, _, _), .stream(let t, _, _, _), .trash(let t), .untrash(let t): return t
        case .send(let m, _): return m.threadID
        default: return nil
        }
    }
}

public struct OutboxRow {
    public let id: Int64
    public let account: String
    public let op: Op
    public let state: String
    public let attempts: Int
}

public final class Outbox {
    let store: Store
    public init(store: Store) { self.store = store }
    private var db: Database { store.db }

    @discardableResult
    public func enqueue(_ account: String, _ op: Op, delay: TimeInterval = 0) throws -> Int64 {
        let payload = String(decoding: try JSONEncoder().encode(op), as: UTF8.self)
        let now = Date().timeIntervalSince1970
        try db.run("INSERT INTO outbox(account,kind,thread_id,payload,not_before,created) VALUES(?,?,?,?,?,?)",
                   account, op.kind, op.thread, payload, Int64((now + delay) * 1000), Int64(now * 1000))
        return db.lastInsertID
    }

    /// Cancels a change that hasn't gone out yet. False if it already has.
    public func cancel(_ id: Int64) throws -> Bool {
        try db.run("UPDATE outbox SET state='cancelled' WHERE id=? AND state='pending'", id)
        return db.changes > 0
    }

    public func state(_ id: Int64) -> String? { try? db.string("SELECT state FROM outbox WHERE id=?", id) }

    public func result(_ id: Int64) -> String? { try? db.string("SELECT result FROM outbox WHERE id=?", id) }

    private func row(_ r: Row) -> OutboxRow? {
        guard let op = try? JSONDecoder().decode(Op.self, from: Data(r.text(2).utf8)) else { return nil }
        return OutboxRow(id: r.int64(0), account: r.text(1), op: op, state: r.text(3), attempts: r.int(4))
    }

    public func due(now: Date = Date()) -> [OutboxRow] {
        (try? db.query("""
            SELECT id, account, payload, state, attempts FROM outbox
            WHERE state='pending' AND not_before<=? ORDER BY id LIMIT 50
            """, Int64(now.timeIntervalSince1970 * 1000)) { self.row($0) })?.compactMap { $0 } ?? []
    }

    public func pending(account: String) -> [OutboxRow] {
        (try? db.query("SELECT id, account, payload, state, attempts FROM outbox WHERE account=? AND state='pending' ORDER BY id",
                       account) { self.row($0) })?.compactMap { $0 } ?? []
    }

    public func nextDue() -> Date? {
        guard let ms = try? db.query("SELECT min(not_before) FROM outbox WHERE state='pending'", map: { $0.isNull(0) ? nil : $0.int64(0) }).first ?? nil
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    func finish(_ id: Int64, state: String, result: String? = nil, error: String? = nil) {
        try? db.run("UPDATE outbox SET state=?, result=?, error=?, attempts=attempts+1 WHERE id=?", state, result, error, id)
    }

    func retry(_ id: Int64, error: String, after: TimeInterval) {
        try? db.run("UPDATE outbox SET attempts=attempts+1, error=?, not_before=? WHERE id=?",
                    error, Int64((Date().timeIntervalSince1970 + after) * 1000), id)
    }

    /// Server state that arrives while a change is still queued would undo
    /// it on screen; lay the queued label changes back on top.
    public func overlay(account: String, threads: Set<String>) {
        for r in pending(account: account) {
            guard let t = r.op.thread, threads.contains(t) else { continue }
            switch r.op {
            case .modify(_, let add, let remove): _ = try? store.modifyLocal(account: account, thread: t, add: add, remove: remove)
            case .trash: _ = try? store.modifyLocal(account: account, thread: t, add: ["TRASH"], remove: ["INBOX"])
            case .untrash: _ = try? store.modifyLocal(account: account, thread: t, add: [], remove: ["TRASH"])
            default: break
            }
        }
    }
}

/// Plays the outbox against gmail, in order, one change at a time. An
/// account without writes turned on keeps its changes local, and a send
/// becomes a draft instead.
public actor OutboxRunner {
    let outbox: Outbox
    let store: Store
    private var running = false
    public var onChange: (@Sendable (String) -> Void)?

    public init(outbox: Outbox, store: Store) {
        self.outbox = outbox
        self.store = store
    }

    public func setOnChange(_ f: @escaping @Sendable (String) -> Void) { onChange = f }

    public func drain() async {
        guard !running else { return }
        running = true
        defer { running = false }
        for r in outbox.due() {
            do {
                let result = try await play(r)
                outbox.finish(r.id, state: result.state, result: result.detail)
                onChange?(r.account)
            } catch let e as ReplyError {
                outbox.finish(r.id, state: "failed", error: e.description)
                log("outbox \(r.id) \(r.op.kind) refused: \(e)")
            } catch {
                if r.attempts >= 6 {
                    outbox.finish(r.id, state: "failed", error: "\(error)")
                    log("outbox \(r.id) \(r.op.kind) failed for good: \(error)")
                } else {
                    outbox.retry(r.id, error: "\(error)", after: pow(2, Double(r.attempts + 1)) * 5)
                    log("outbox \(r.id) \(r.op.kind) will retry: \(error)")
                }
            }
        }
    }

    private func play(_ r: OutboxRow) async throws -> (state: String, detail: String?) {
        let gmail = Gmail(account: r.account)
        let writes = store.config.writes(r.account)

        if case .send(let m, let alias) = r.op {
            if let alias { try AliasRelay(alias).verify(m, account: r.account) }
            let raw = MIME.build(m, messageID: "<\(UUID().uuidString)@post.local>")
            if writes {
                let sent = try await gmail.send(raw: raw, threadID: m.threadID)
                return ("done", sent.id)
            }
            let d = try await gmail.createDraft(raw: raw, threadID: m.threadID)
            log("writes off for \(r.account): send \(r.id) saved as draft \(d.id)")
            return ("drafted", d.id)
        }

        guard writes else { return ("local", nil) }

        switch r.op {
        case .modify(let t, let add, let remove):
            try await gmail.modifyThread(t, add: add, remove: remove)
        case .stream(let t, let add, let remove, let archive):
            var addIDs: [String] = []
            if let add { addIDs.append(try await labelID(add, gmail)) }
            let removeIDs = (remove.flatMap { store.labelID(r.account, name: $0) }.map { [$0] } ?? []) + (archive ? ["INBOX"] : [])
            try await gmail.modifyThread(t, add: addIDs, remove: removeIDs)
        case .trash(let t):
            try await gmail.trashThread(t)
        case .untrash(let t):
            try await gmail.untrashThread(t)
        case .sort(let email, let category):
            var add: [String] = []
            var remove: [String] = []
            switch category {
            case "feed": add = [try await labelID(Streams.feed, gmail)]; remove = ["INBOX"]
            case "paper": add = [try await labelID(Streams.paper, gmail)]; remove = ["INBOX"]
            case "blocked": add = ["TRASH"]; remove = ["INBOX"]
            case "muted": add = [try await labelID(Streams.muted, gmail)]; remove = ["INBOX", "UNREAD"]
            default: return ("done", nil)
            }
            let f = try await gmail.createFilter(from: email, add: add, remove: remove)
            try? store.decide(account: r.account, email: email, decision: category, filterID: f.id)
            let threads = (try? store.db.query("SELECT id FROM threads WHERE account=? AND sender_email=?", r.account, email.lowercased()) { $0.text(0) }) ?? []
            for t in threads { try await gmail.modifyThread(t, add: add, remove: remove) }
            return ("done", f.id)
        case .unsort(_, let filterID):
            if let filterID { try await gmail.deleteFilter(filterID) }
        case .send:
            break
        }
        return ("done", nil)
    }

    private func labelID(_ name: String, _ gmail: Gmail) async throws -> String {
        if let id = store.labelID(gmail.account, name: name) { return id }
        let all = try await gmail.labels()
        if let l = all.first(where: { $0.name == name }) {
            try store.setLabels(gmail.account, all)
            return l.id
        }
        let made = try await gmail.createLabel(name)
        try store.setLabels(gmail.account, all + [made])
        return made.id
    }
}

public func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    FileHandle.standardError.write(Data(line.utf8))
    if let h = try? FileHandle(forWritingTo: Paths.log) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? Data(line.utf8).write(to: Paths.log)
    }
}
