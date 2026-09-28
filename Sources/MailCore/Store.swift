import Foundation

/// The on-disk cache: every message we've seen, one row per thread with its
/// stream worked out ahead of time (so drawing a list is a single indexed
/// read), and an fts5 index over subjects, people and bodies.
public final class Store {
    public let db: Database
    public var config: AccountsFile
    private var labelIDs: [String: [String: String]] = [:]   // account → name → id
    private let labelLock = NSLock()

    public init(path: String, config: AccountsFile) throws {
        db = try Database(path: path)
        self.config = config
        try migrate()
        if get("sorter") != String(Sorter.version) {
            try recomputeAll()
            set("sorter", String(Sorter.version))
        }
    }

    public func recomputeAll() throws {
        try db.transaction {
            try recompute(Set(try db.query("SELECT DISTINCT account, thread_id FROM messages") { $0.text(0) + "\u{1}" + $0.text(1) }))
        }
    }

    public static let schemaVersion = 1

    private func migrate() throws {
        let v = try db.scalar("PRAGMA user_version")
        guard v < Self.schemaVersion else { return }
        try db.exec("""
        CREATE TABLE IF NOT EXISTS accounts(
            email TEXT PRIMARY KEY, history_id TEXT, seeded INTEGER NOT NULL DEFAULT 0, synced_at INTEGER);
        CREATE TABLE IF NOT EXISTS labels(
            account TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(account, id));
        CREATE TABLE IF NOT EXISTS messages(
            account TEXT NOT NULL, id TEXT NOT NULL, thread_id TEXT NOT NULL, history_id INTEGER NOT NULL DEFAULT 0,
            date INTEGER NOT NULL, labels TEXT NOT NULL, from_json TEXT, to_json TEXT, cc_json TEXT, reply_to_json TEXT,
            subject TEXT NOT NULL, snippet TEXT NOT NULL, message_id TEXT, in_reply_to TEXT, refs TEXT,
            list_unsubscribe TEXT, list_id TEXT, precedence TEXT, auto_submitted TEXT,
            duck_from_json TEXT, duck_to TEXT, body_text TEXT, body_html TEXT, has_body INTEGER NOT NULL DEFAULT 0,
            UNIQUE(account, id));
        CREATE INDEX IF NOT EXISTS messages_thread ON messages(account, thread_id, date);
        CREATE TABLE IF NOT EXISTS threads(
            account TEXT NOT NULL, id TEXT NOT NULL, alias TEXT NOT NULL DEFAULT '', view TEXT NOT NULL DEFAULT '',
            category TEXT NOT NULL, date INTEGER NOT NULL, subject TEXT NOT NULL, snippet TEXT NOT NULL,
            sender TEXT NOT NULL, sender_email TEXT NOT NULL, unread INTEGER NOT NULL, count INTEGER NOT NULL,
            labels TEXT NOT NULL, has_body INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(account, id));
        CREATE INDEX IF NOT EXISTS threads_view ON threads(account, alias, view, date DESC);
        CREATE INDEX IF NOT EXISTS threads_sender ON threads(account, sender_email);
        CREATE TABLE IF NOT EXISTS senders(
            account TEXT NOT NULL, email TEXT NOT NULL, decision TEXT NOT NULL, filter_id TEXT,
            decided_at INTEGER NOT NULL, PRIMARY KEY(account, email));
        CREATE TABLE IF NOT EXISTS outbox(
            id INTEGER PRIMARY KEY AUTOINCREMENT, account TEXT NOT NULL, kind TEXT NOT NULL, thread_id TEXT,
            payload TEXT NOT NULL, not_before INTEGER NOT NULL, state TEXT NOT NULL DEFAULT 'pending',
            attempts INTEGER NOT NULL DEFAULT 0, error TEXT, created INTEGER NOT NULL, result TEXT);
        CREATE INDEX IF NOT EXISTS outbox_pending ON outbox(state, not_before);
        CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS msg_fts USING fts5(
            subject, people, body, tokenize = 'unicode61 remove_diacritics 2');
        PRAGMA user_version = \(Self.schemaVersion);
        """)
    }

    // MARK: kv + account state

    public func get(_ key: String) -> String? { try? db.string("SELECT value FROM kv WHERE key=?", key) }
    public func set(_ key: String, _ value: String) {
        try? db.run("INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", key, value)
    }

    public func historyID(_ account: String) -> String? {
        try? db.string("SELECT history_id FROM accounts WHERE email=?", account)
    }

    public func setHistoryID(_ account: String, _ id: String) throws {
        try db.run("""
            INSERT INTO accounts(email, history_id, synced_at) VALUES(?,?,?)
            ON CONFLICT(email) DO UPDATE SET history_id=excluded.history_id, synced_at=excluded.synced_at
            """, account, id, Int64(Date().timeIntervalSince1970))
    }

    public func isSeeded(_ account: String) -> Bool {
        ((try? db.scalar("SELECT seeded FROM accounts WHERE email=?", account)) ?? 0) == 1
    }

    public func markSeeded(_ account: String) throws {
        try db.run("INSERT INTO accounts(email, seeded) VALUES(?,1) ON CONFLICT(email) DO UPDATE SET seeded=1", account)
    }

    /// Drops everything cached for an account (removed from the app, or a
    /// history id too old to resume from).
    public func forget(_ account: String) throws {
        try db.transaction {
            try db.run("DELETE FROM msg_fts WHERE rowid IN (SELECT rowid FROM messages WHERE account=?)", account)
            for t in ["messages", "threads", "labels", "outbox"] { try db.run("DELETE FROM \(t) WHERE account=?", account) }
            try db.run("DELETE FROM accounts WHERE email=?", account)
        }
    }

    // MARK: labels

    public func setLabels(_ account: String, _ labels: [GmailLabel]) throws {
        try db.transaction {
            try db.run("DELETE FROM labels WHERE account=?", account)
            for l in labels { try db.run("INSERT INTO labels(account,id,name) VALUES(?,?,?)", account, l.id, l.name) }
        }
        labelLock.lock(); labelIDs[account] = nil; labelLock.unlock()
    }

    public func labelID(_ account: String, name: String) -> String? {
        labelLock.lock()
        let cached = labelIDs[account]
        labelLock.unlock()
        if let cached { return cached[name] }
        let rows = (try? db.query("SELECT name, id FROM labels WHERE account=?", account) { ($0.text(0), $0.text(1)) }) ?? []
        let map = Dictionary(rows, uniquingKeysWith: { a, _ in a })
        labelLock.lock(); labelIDs[account] = map; labelLock.unlock()
        return map[name]
    }

    // MARK: messages

    private static let enc = JSONEncoder()
    private static let dec = JSONDecoder()
    private func json<T: Encodable>(_ v: T?) -> String? { v.flatMap { try? String(decoding: Self.enc.encode($0), as: UTF8.self) } }
    private func unjson<T: Decodable>(_ s: String?, _: T.Type) -> T? { s.flatMap { try? Self.dec.decode(T.self, from: Data($0.utf8)) } }

    static func labelText(_ l: [String]) -> String { " " + l.joined(separator: " ") + " " }
    static func labelList(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

    /// Writes messages, keeping a cached body when the new copy has none, and
    /// re-derives every thread they touch.
    @discardableResult
    public func upsert(_ msgs: [MessageRecord]) throws -> Set<String> {
        var touched = Set<String>()
        try db.transaction {
            for m in msgs {
                try db.run("""
                INSERT INTO messages(account,id,thread_id,history_id,date,labels,from_json,to_json,cc_json,reply_to_json,
                    subject,snippet,message_id,in_reply_to,refs,list_unsubscribe,list_id,precedence,auto_submitted,
                    duck_from_json,duck_to,body_text,body_html,has_body)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(account,id) DO UPDATE SET
                    thread_id=excluded.thread_id, history_id=excluded.history_id, date=excluded.date, labels=excluded.labels,
                    from_json=excluded.from_json, to_json=excluded.to_json, cc_json=excluded.cc_json,
                    reply_to_json=excluded.reply_to_json, subject=excluded.subject, snippet=excluded.snippet,
                    message_id=excluded.message_id, in_reply_to=excluded.in_reply_to, refs=excluded.refs,
                    list_unsubscribe=excluded.list_unsubscribe, list_id=excluded.list_id, precedence=excluded.precedence,
                    auto_submitted=excluded.auto_submitted, duck_from_json=excluded.duck_from_json, duck_to=excluded.duck_to,
                    body_text=CASE WHEN excluded.has_body THEN excluded.body_text ELSE messages.body_text END,
                    body_html=CASE WHEN excluded.has_body THEN excluded.body_html ELSE messages.body_html END,
                    has_body=MAX(excluded.has_body, messages.has_body)
                """, [m.account, m.id, m.threadID, m.historyID, m.date, Self.labelText(m.labels), json(m.from), json(m.to),
                      json(m.cc), json(m.replyTo), m.subject, m.snippet, m.messageID, m.inReplyTo,
                      m.references.joined(separator: " "), m.listUnsubscribe, m.listID, m.precedence, m.autoSubmitted,
                      json(m.duckFrom), m.duckTo, m.bodyText, m.bodyHTML, m.hasBody])
                try index(m)
                touched.insert(m.account + "\u{1}" + m.threadID)
            }
            try recompute(touched)
        }
        return touched
    }

    private func index(_ m: MessageRecord) throws {
        guard let rowid = try db.query("SELECT rowid, body_text, body_html FROM messages WHERE account=? AND id=?", m.account, m.id, map: {
            ($0.int64(0), $0.string(1), $0.string(2))
        }).first else { return }
        let people = ([m.shownFrom].compactMap { $0 } + m.to + m.cc).map { "\($0.name) \($0.email)" }.joined(separator: " ")
        let body = rowid.1.flatMap { $0.isEmpty ? nil : $0 } ?? rowid.2.map(HTMLText.strip) ?? m.snippet
        try db.run("DELETE FROM msg_fts WHERE rowid=?", rowid.0)
        try db.run("INSERT INTO msg_fts(rowid, subject, people, body) VALUES(?,?,?,?)",
                   rowid.0, m.subject, people, String(body.prefix(20000)))
    }

    public func setLabels(account: String, messageID: String, labels: [String]) throws -> String? {
        guard let tid = try db.string("SELECT thread_id FROM messages WHERE account=? AND id=?", account, messageID) else { return nil }
        try db.run("UPDATE messages SET labels=? WHERE account=? AND id=?", Self.labelText(labels), account, messageID)
        return tid
    }

    public func deleteMessage(account: String, id: String) throws -> String? {
        guard let (rowid, tid) = try db.query("SELECT rowid, thread_id FROM messages WHERE account=? AND id=?", account, id, map: {
            ($0.int64(0), $0.text(1))
        }).first else { return nil }
        try db.run("DELETE FROM msg_fts WHERE rowid=?", rowid)
        try db.run("DELETE FROM messages WHERE rowid=?", rowid)
        return tid
    }

    public func messages(account: String, thread: String) -> [MessageRecord] {
        (try? db.query("""
            SELECT id,thread_id,history_id,date,labels,from_json,to_json,cc_json,reply_to_json,subject,snippet,message_id,
                   in_reply_to,refs,list_unsubscribe,list_id,precedence,auto_submitted,duck_from_json,duck_to,body_text,body_html,has_body
            FROM messages WHERE account=? AND thread_id=? ORDER BY date
            """, account, thread) { r in
            MessageRecord(account: account, id: r.text(0), threadID: r.text(1), historyID: r.int64(2), date: r.int64(3),
                          labels: Self.labelList(r.text(4)), from: unjson(r.string(5), Address.self),
                          to: unjson(r.string(6), [Address].self) ?? [], cc: unjson(r.string(7), [Address].self) ?? [],
                          replyTo: unjson(r.string(8), [Address].self) ?? [], subject: r.text(9), snippet: r.text(10),
                          messageID: r.string(11), inReplyTo: r.string(12),
                          references: r.text(13).split(separator: " ").map(String.init), listUnsubscribe: r.string(14),
                          listID: r.string(15), precedence: r.string(16), autoSubmitted: r.string(17),
                          duckFrom: unjson(r.string(18), Address.self), duckTo: r.string(19), bodyText: r.string(20),
                          bodyHTML: r.string(21), hasBody: r.bool(22))
        }) ?? []
    }

    // MARK: threads

    func me(_ account: String) -> Set<String> {
        Set([account.lowercased()] + config.aliases(for: account).map { $0.address.lowercased() })
    }

    public func recompute(account: String, threads: [String]) throws {
        try db.transaction { try recompute(Set(threads.map { account + "\u{1}" + $0 })) }
    }

    private func recompute(_ keys: Set<String>) throws {
        for key in keys {
            let parts = key.split(separator: "\u{1}", maxSplits: 1).map(String.init)
            try recomputeThread(account: parts[0], id: parts[1])
        }
    }

    public func decision(account: String, email: String) -> String? {
        try? db.string("SELECT decision FROM senders WHERE account=? AND email=?", account, email.lowercased())
    }

    private func recomputeThread(account: String, id: String) throws {
        let msgs = messages(account: account, thread: id)
        guard let last = msgs.last else {
            try db.run("DELETE FROM threads WHERE account=? AND id=?", account, id)
            return
        }
        let mine = me(account)
        let aliases = Set(config.aliases(for: account).map { $0.address.lowercased() })
        let union = Set(msgs.flatMap(\.labels))
        let inInbox = union.contains("INBOX")
        let alias = msgs.compactMap { $0.duckTo?.lowercased() }.first { aliases.contains($0) } ?? ""
        let inbound = msgs.last { !mine.contains($0.shownFrom?.normalized ?? "") && !Composer.isSelfRelay($0.from, mine: mine) }
        let senderAddr = inbound?.shownFrom
        let senderEmail = senderAddr?.email.lowercased() ?? ""
        let firstTo = last.to.first
        let sender = senderAddr?.display ?? (firstTo.map { mine.contains($0.normalized) ? "me" : "me → \($0.display)" } ?? "me")

        let feedID = labelID(account, name: Streams.feed)
        let paperID = labelID(account, name: Streams.paper)
        let decided = senderEmail.isEmpty ? nil : decision(account: account, email: senderEmail)
        var category: Category
        if let feedID, union.contains(feedID) { category = .feed }
        else if let paperID, union.contains(paperID) { category = .paper }
        else if let d = decided, let c = Category(rawValue: d) { category = c }
        else { category = Sorter.guess(inbound ?? last) }

        let pending = decided == nil && inbound != nil && category == .inbox
        let gone = (union.contains("TRASH") || union.contains("SPAM")) && !inInbox
        let labelled = (category == .feed && feedID.map(union.contains) == true)
            || (category == .paper && paperID.map(union.contains) == true)
        var view = ""
        if gone || decided == "blocked" { view = "" }
        else if pending && inInbox { view = "new" }
        else if category == .inbox && inInbox { view = "inbox" }
        else if category != .inbox && (inInbox || labelled) { view = category.rawValue }

        try db.run("""
            INSERT INTO threads(account,id,alias,view,category,date,subject,snippet,sender,sender_email,unread,count,labels,has_body)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(account,id) DO UPDATE SET alias=excluded.alias, view=excluded.view, category=excluded.category,
                date=excluded.date, subject=excluded.subject, snippet=excluded.snippet, sender=excluded.sender,
                sender_email=excluded.sender_email, unread=excluded.unread, count=excluded.count, labels=excluded.labels,
                has_body=excluded.has_body
            """, [account, id, alias, view, category.rawValue, last.date, msgs.first?.subject ?? "", last.snippet, sender,
                  senderEmail, union.contains("UNREAD"), msgs.count, Self.labelText(Array(union).sorted()),
                  msgs.allSatisfy(\.hasBody)])
    }

    private func summary(_ r: Row) -> ThreadSummary {
        ThreadSummary(account: r.text(0), id: r.text(1), date: r.int64(2), subject: r.text(3), snippet: r.text(4),
                      sender: r.text(5), senderEmail: r.text(6), unread: r.bool(7), count: r.int(8),
                      category: Category(rawValue: r.text(9)) ?? .inbox)
    }

    private static let cols = "account,id,date,subject,snippet,sender,sender_email,unread,count,category"

    public func threads(_ box: Mailbox, _ view: View, limit: Int = 200, offset: Int = 0) -> [ThreadSummary] {
        let alias = box.alias?.address.lowercased() ?? ""
        if case .search(let q) = view { return search(box, q, limit: limit) }
        return (try? db.query("""
            SELECT \(Self.cols) FROM threads WHERE account=? AND alias=? AND view=? ORDER BY date DESC LIMIT ? OFFSET ?
            """, box.account, alias, view.key, limit, offset, map: summary)) ?? []
    }

    public func count(_ box: Mailbox, _ view: View) -> Int {
        let alias = box.alias?.address.lowercased() ?? ""
        return (try? db.scalar("SELECT count(*) FROM threads WHERE account=? AND alias=? AND view=?", box.account, alias, view.key)) ?? 0
    }

    public func thread(account: String, id: String) -> ThreadSummary? {
        try? db.query("SELECT \(Self.cols) FROM threads WHERE account=? AND id=?", account, id, map: summary).first
    }

    public func threadsNeedingBodies(_ box: Mailbox, _ view: View, limit: Int) -> [String] {
        let alias = box.alias?.address.lowercased() ?? ""
        return (try? db.query("""
            SELECT id FROM (SELECT id, has_body FROM threads WHERE account=? AND alias=? AND view=? ORDER BY date DESC LIMIT ?)
            WHERE has_body=0
            """, box.account, alias, view.key, limit) { $0.text(0) }) ?? []
    }

    public func hasBodies(account: String, thread: String) -> Bool {
        ((try? db.scalar("SELECT has_body FROM threads WHERE account=? AND id=?", account, thread)) ?? 0) == 1
    }

    // MARK: search

    /// Every word must match, each as a prefix: "inv acme" finds "Invoice
    /// from ACME Corp".
    public static func ftsQuery(_ q: String) -> String {
        q.split(whereSeparator: { $0.isWhitespace })
            .map { $0.filter { $0.isLetter || $0.isNumber || $0 == "@" || $0 == "." || $0 == "-" || $0 == "_" } }
            .filter { !$0.isEmpty }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            .joined(separator: " ")
    }

    public func search(_ box: Mailbox, _ q: String, limit: Int = 200) -> [ThreadSummary] {
        let fts = Self.ftsQuery(q)
        guard !fts.isEmpty else { return [] }
        let alias = box.alias?.address.lowercased() ?? ""
        return (try? db.query("""
            SELECT \(Self.cols.split(separator: ",").map { "t.\($0)" }.joined(separator: ",")) FROM threads t
            WHERE t.account=? AND t.alias=? AND t.id IN (
                SELECT m.thread_id FROM msg_fts JOIN messages m ON m.rowid = msg_fts.rowid
                WHERE msg_fts MATCH ? AND m.account=?)
            ORDER BY t.date DESC LIMIT ?
            """, box.account, alias, fts, box.account, limit, map: summary)) ?? []
    }

    // MARK: senders

    public func knownSenders(_ account: String) -> Int {
        (try? db.scalar("SELECT count(*) FROM senders WHERE account=?", account)) ?? 0
    }

    /// First sync: everyone already in the mailbox (or someone we've written
    /// to) counts as known, so the new-sender queue starts empty and only
    /// fills with people who write for the first time from here on.
    public func seedSenders(_ account: String) throws {
        let now = Int64(Date().timeIntervalSince1970)
        try db.transaction {
            let mine = me(account)
            var emails = Set(try db.query("SELECT DISTINCT sender_email FROM threads WHERE account=? AND sender_email<>''", account) { $0.text(0) })
            for row in try db.query("SELECT to_json, cc_json FROM messages WHERE account=? AND labels LIKE '% SENT %'", account, map: {
                ($0.string(0), $0.string(1))
            }) {
                for a in (unjson(row.0, [Address].self) ?? []) + (unjson(row.1, [Address].self) ?? []) { emails.insert(a.normalized) }
            }
            for e in emails where !mine.contains(e) {
                try db.run("INSERT OR IGNORE INTO senders(account,email,decision,decided_at) VALUES(?,?,'known',?)", account, e, now)
            }
            try db.run("INSERT INTO accounts(email, seeded) VALUES(?,1) ON CONFLICT(email) DO UPDATE SET seeded=1", account)
            try recompute(Set(try db.query("SELECT id FROM threads WHERE account=?", account) { account + "\u{1}" + $0.text(0) }))
        }
    }

    /// decision: "inbox", "feed", "paper", "blocked" or "known".
    public func decide(account: String, email: String, decision: String, filterID: String? = nil) throws {
        try db.transaction {
            try db.run("""
                INSERT INTO senders(account,email,decision,filter_id,decided_at) VALUES(?,?,?,?,?)
                ON CONFLICT(account,email) DO UPDATE SET decision=excluded.decision,
                    filter_id=COALESCE(excluded.filter_id, senders.filter_id), decided_at=excluded.decided_at
                """, account, email.lowercased(), decision, filterID, Int64(Date().timeIntervalSince1970))
            let ids = try db.query("SELECT id FROM threads WHERE account=? AND sender_email=?", account, email.lowercased()) { $0.text(0) }
            try recompute(Set(ids.map { account + "\u{1}" + $0 }))
        }
    }

    public func undecide(account: String, email: String) throws {
        try db.transaction {
            try db.run("DELETE FROM senders WHERE account=? AND email=?", account, email.lowercased())
            let ids = try db.query("SELECT id FROM threads WHERE account=? AND sender_email=?", account, email.lowercased()) { $0.text(0) }
            try recompute(Set(ids.map { account + "\u{1}" + $0 }))
        }
    }

    public func senderRow(account: String, email: String) -> (decision: String, filterID: String?)? {
        try? db.query("SELECT decision, filter_id FROM senders WHERE account=? AND email=?", account, email.lowercased()) {
            ($0.text(0), $0.string(1))
        }.first
    }

    // MARK: local label edits

    /// Applies a label change to every message of a thread, returning each
    /// message's labels from before so the change can be undone exactly.
    public func modifyLocal(account: String, thread: String, add: [String], remove: [String]) throws -> [String: [String]] {
        try db.transaction {
            var before: [String: [String]] = [:]
            for (id, labels) in try db.query("SELECT id, labels FROM messages WHERE account=? AND thread_id=?", account, thread, map: {
                ($0.text(0), Self.labelList($0.text(1)))
            }) {
                before[id] = labels
                var next = labels.filter { !remove.contains($0) }
                for a in add where !next.contains(a) { next.append(a) }
                try db.run("UPDATE messages SET labels=? WHERE account=? AND id=?", Self.labelText(next), account, id)
            }
            try recomputeThread(account: account, id: thread)
            return before
        }
    }

    public func restoreLocal(account: String, thread: String, labels: [String: [String]]) throws {
        try db.transaction {
            for (id, l) in labels {
                try db.run("UPDATE messages SET labels=? WHERE account=? AND id=?", Self.labelText(l), account, id)
            }
            try recomputeThread(account: account, id: thread)
        }
    }
}

public enum HTMLText {
    public static func strip(_ html: String) -> String {
        var s = html
        for tag in ["style", "script", "head"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = MessageRecord.unescape(s)
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}
