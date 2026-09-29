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
        if get("sorter") != String(Self.sortingVersion) {
            try recomputeAll()
            set("sorter", String(Self.sortingVersion))
        }
    }

    public func recomputeAll() throws {
        try db.transaction {
            try recompute(Set(try db.query("SELECT DISTINCT account, thread_id FROM messages") { $0.text(0) + "\u{1}" + $0.text(1) }))
        }
    }

    public static let schemaVersion = 6
    /// Bump when how threads are placed changes: the cache re-sorts on open.
    public static let sortingVersion = 12

    private func migrate() throws {
        let v = try db.scalar("PRAGMA user_version")
        guard v < Self.schemaVersion else { return }
        if v >= 1 && v < 5 {
            // v5: nobody is "known" by default any more; they wait to be placed.
            try db.exec("DELETE FROM senders WHERE decision='known'")
        }
        if v >= 1 && v < 4 {
            // v3: Duck-Original-To kept as the bare alias address, not the raw header.
            try db.transaction {
                for (rowid, raw) in try db.query("SELECT rowid, duck_to FROM messages WHERE duck_to IS NOT NULL", map: { ($0.int64(0), $0.text(1)) }) {
                    try db.run("UPDATE messages SET duck_to=? WHERE rowid=?", MessageRecord.forwardedTo(raw), rowid)
                }
            }
        }
        if v == 1 {
            // v2: who each message is really from, indexed, so sorting can
            // follow the sender.
            try db.exec("ALTER TABLE messages ADD COLUMN sender TEXT NOT NULL DEFAULT ''")
            try db.transaction {
                for (rowid, from, duck) in try db.query("SELECT rowid, from_json, duck_from_json FROM messages", map: { ($0.int64(0), $0.string(1), $0.string(2)) }) {
                    let a = unjson(duck, Address.self) ?? unjson(from, Address.self)
                    try db.run("UPDATE messages SET sender=? WHERE rowid=?", a?.normalized ?? "", rowid)
                }
            }
        }
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
            sender TEXT NOT NULL DEFAULT '', UNIQUE(account, id));
        CREATE INDEX IF NOT EXISTS messages_thread ON messages(account, thread_id, date);
        CREATE INDEX IF NOT EXISTS messages_sender ON messages(account, sender);
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
        CREATE TABLE IF NOT EXISTS suggestions(
            account TEXT NOT NULL, email TEXT NOT NULL, category TEXT NOT NULL, confidence REAL NOT NULL,
            source TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY(account, email));
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
                    duck_from_json,duck_to,body_text,body_html,has_body,sender)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(account,id) DO UPDATE SET
                    thread_id=excluded.thread_id, history_id=excluded.history_id, date=excluded.date, labels=excluded.labels,
                    from_json=excluded.from_json, to_json=excluded.to_json, cc_json=excluded.cc_json,
                    reply_to_json=excluded.reply_to_json, subject=excluded.subject, snippet=excluded.snippet,
                    message_id=excluded.message_id, in_reply_to=excluded.in_reply_to, refs=excluded.refs,
                    list_unsubscribe=excluded.list_unsubscribe, list_id=excluded.list_id, precedence=excluded.precedence,
                    auto_submitted=excluded.auto_submitted, duck_from_json=excluded.duck_from_json, duck_to=excluded.duck_to,
                    body_text=CASE WHEN excluded.has_body THEN excluded.body_text ELSE messages.body_text END,
                    body_html=CASE WHEN excluded.has_body THEN excluded.body_html ELSE messages.body_html END,
                    has_body=MAX(excluded.has_body, messages.has_body), sender=excluded.sender
                """, [m.account, m.id, m.threadID, m.historyID, m.date, Self.labelText(m.labels), json(m.from), json(m.to),
                      json(m.cc), json(m.replyTo), m.subject, m.snippet, m.messageID, m.inReplyTo,
                      m.references.joined(separator: " "), m.listUnsubscribe, m.listID, m.precedence, m.autoSubmitted,
                      json(m.duckFrom), m.duckTo, m.bodyText, m.bodyHTML, m.hasBody, m.shownFrom?.normalized ?? ""])
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

    /// Jev's verdict for a sender, if it has answered. No verdict, no guess.
    func verdict(account: String, email: String) -> Category? {
        (try? db.string("SELECT category FROM suggestions WHERE account=? AND email=?", account, email)).flatMap { $0.flatMap(Category.init(rawValue:)) }
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
        var category: Category?
        let notifyID = labelID(account, name: Streams.notifications)
        let labelledStream = (feedID.map(union.contains) ?? false) || (paperID.map(union.contains) ?? false)
            || (notifyID.map(union.contains) ?? false)
        if let feedID, union.contains(feedID) { category = .feed }
        else if let notifyID, union.contains(notifyID) { category = .notify }
        else if let paperID, union.contains(paperID) { category = .paper }
        else if let d = decided, let c = Category(rawValue: d) { category = c }
        else if inbound != nil, !senderEmail.isEmpty { category = verdict(account: account, email: senderEmail) }
        else { category = .inbox }   // only our own mail in the thread

        // Every sender waits in New Senders until placed — unless gmail
        // already files them (mail/feed, mail/paper-trail labels).
        let placed = decided != nil && decided != "known"
        let mutedLabel = labelID(account, name: Streams.muted).map(union.contains) ?? false
        let pending = !placed && !labelledStream && !mutedLabel && inbound != nil
        let gone = (union.contains("TRASH") || union.contains("SPAM")) && !inInbox
        let labelled = (category == .feed && feedID.map(union.contains) == true)
            || (category == .paper && paperID.map(union.contains) == true)
            || (category == .notify && notifyID.map(union.contains) == true)
        var view = ""
        let mutedID = labelID(account, name: Streams.muted)
        if union.contains("SPAM") { view = "spam" }
        else if gone || decided == "blocked" { view = "" }
        else if decided == "muted" || (mutedID.map(union.contains) ?? false) { view = "muted" }
        else if pending && inInbox { view = "new" }
        else if category == .inbox && inInbox { view = "inbox" }
        else if let category, category != .inbox, inInbox || labelled { view = category.rawValue }

        try db.run("""
            INSERT INTO threads(account,id,alias,view,category,date,subject,snippet,sender,sender_email,unread,count,labels,has_body)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(account,id) DO UPDATE SET alias=excluded.alias, view=excluded.view, category=excluded.category,
                date=excluded.date, subject=excluded.subject, snippet=excluded.snippet, sender=excluded.sender,
                sender_email=excluded.sender_email, unread=excluded.unread, count=excluded.count, labels=excluded.labels,
                has_body=excluded.has_body
            """, [account, id, alias, view, category?.rawValue ?? "", last.date, msgs.first?.subject ?? "", last.snippet, sender,
                  senderEmail, union.contains("UNREAD"), msgs.count, Self.labelText(Array(union).sorted()),
                  msgs.allSatisfy(\.hasBody)])
    }

    private func summary(_ r: Row) -> ThreadSummary {
        ThreadSummary(account: r.text(0), id: r.text(1), date: r.int64(2), subject: r.text(3), snippet: r.text(4),
                      sender: r.text(5), senderEmail: r.text(6), unread: r.bool(7), count: r.int(8),
                      category: Category(rawValue: r.text(9)), alias: r.text(10))
    }

    private static let cols = "account,id,date,subject,snippet,sender,sender_email,unread,count,category,alias"

    /// `WHERE` for a mailbox: one account (and alias), or everything.
    private func scope(_ box: Mailbox, prefix: String = "") -> (String, [SQLBindable]) {
        if box.isAll { return ("1=1", []) }
        return ("\(prefix)account=? AND \(prefix)alias=?", [box.account, box.alias?.address.lowercased() ?? ""])
    }

    public func threads(_ box: Mailbox, _ view: View, limit: Int = 200, offset: Int = 0) -> [ThreadSummary] {
        if case .search(let q) = view { return search(box, q, limit: limit) }
        let (w, args) = scope(box)
        return (try? db.query("""
            SELECT \(Self.cols) FROM threads WHERE \(w) AND view=? ORDER BY date DESC LIMIT ? OFFSET ?
            """, args + [view.key, limit, offset], map: summary)) ?? []
    }

    public func count(_ box: Mailbox, _ view: View) -> Int {
        // New Senders counts people, not threads: you decide once per sender.
        let what = view == .newSenders ? "count(DISTINCT account || sender_email)" : "count(*)"
        let (w, args) = scope(box)
        return (try? db.query("SELECT \(what) FROM threads WHERE \(w) AND view=?", args + [view.key]) { $0.int(0) }.first) ?? 0
    }

    public func thread(account: String, id: String) -> ThreadSummary? {
        try? db.query("SELECT \(Self.cols) FROM threads WHERE account=? AND id=?", account, id, map: summary).first
    }

    public func threadsNeedingBodies(_ box: Mailbox, _ view: View, limit: Int) -> [String] {
        let (w, args) = scope(box)
        return (try? db.query("""
            SELECT id FROM (SELECT id, has_body FROM threads WHERE \(w) AND view=? ORDER BY date DESC LIMIT ?)
            WHERE has_body=0
            """, args + [view.key, limit]) { $0.text(0) }) ?? []
    }

    public func hasBodies(account: String, thread: String) -> Bool {
        ((try? db.scalar("SELECT has_body FROM threads WHERE account=? AND id=?", account, thread)) ?? 0) == 1
    }

    /// Forwarding aliases that mail in this account was sent to — DuckDuckGo
    /// names the alias in Duck-Original-To. A few messages are needed, so one
    /// stray header doesn't make an account.
    public func foundAliases(_ account: String, minimum: Int = 3) -> [String] {
        (try? db.query("""
            SELECT lower(duck_to) a, count(*) n FROM messages
            WHERE account=? AND duck_to LIKE '%_@duck.com' AND instr(duck_to, '_at_') = 0
            GROUP BY a HAVING n >= ? ORDER BY n DESC
            """, account, minimum) { $0.text(0) }) ?? []
    }

    // MARK: jev

    /// Senders nobody has placed and Jev hasn't judged, newest first, each
    /// with a few recent subjects and previews — never bodies.
    public func sendersToJudge(_ account: String, limit: Int = 100) -> [Jev.Sample] {
        let emails = (try? db.query("""
            SELECT t.sender_email, t.sender FROM threads t
            WHERE t.account=? AND t.sender_email<>'' AND t.view='new'
              AND NOT EXISTS (SELECT 1 FROM suggestions s WHERE s.account=t.account AND s.email=t.sender_email)
            GROUP BY t.sender_email ORDER BY max(t.date) DESC LIMIT ?
            """, account, limit) { ($0.text(0), $0.text(1)) }) ?? []
        return emails.map { email, name in
            let lines = (try? db.query("""
                SELECT subject, snippet FROM messages WHERE account=? AND sender=? ORDER BY date DESC LIMIT 3
                """, account, email) { r -> String in
                let snip = r.text(1).prefix(90)
                return "\"\(r.text(0))\"" + (snip.isEmpty ? "" : " — \(snip)")
            }) ?? []
            return Jev.Sample(email: email, name: name, lines: lines)
        }
    }

    public func saveVerdicts(_ account: String, _ verdicts: [String: Jev.Verdict]) throws {
        guard !verdicts.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        try db.transaction {
            for (email, v) in verdicts {
                try db.run("""
                    INSERT INTO suggestions(account,email,category,confidence,source,at) VALUES(?,?,?,?,'jev',?)
                    ON CONFLICT(account,email) DO UPDATE SET category=excluded.category, confidence=excluded.confidence,
                        source=excluded.source, at=excluded.at
                    """, account, email, v.category.rawValue, v.confidence, now)
            }
            let ids = try db.query("SELECT id FROM threads WHERE account=? AND sender_email IN (\(verdicts.keys.map { _ in "?" }.joined(separator: ",")))",
                                   [account] + verdicts.keys.map { $0 as SQLBindable }) { $0.text(0) }
            try recompute(Set(ids.map { account + "\u{1}" + $0 }))
        }
    }

    public func judgedCount(_ account: String) -> Int {
        (try? db.scalar("SELECT count(*) FROM suggestions WHERE account=? AND source='jev'", account)) ?? 0
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
        let (w, args) = scope(box, prefix: "t.")
        return (try? db.query("""
            SELECT \(Self.cols.split(separator: ",").map { "t.\($0)" }.joined(separator: ",")) FROM threads t
            WHERE \(w) AND (t.account || char(1) || t.id) IN (
                SELECT m.account || char(1) || m.thread_id FROM msg_fts JOIN messages m ON m.rowid = msg_fts.rowid
                WHERE msg_fts MATCH ?)
            ORDER BY t.date DESC LIMIT ?
            """, args + [fts, limit], map: summary)) ?? []
    }

    // MARK: senders

    public func knownSenders(_ account: String) -> Int {
        (try? db.scalar("SELECT count(*) FROM senders WHERE account=?", account)) ?? 0
    }

    /// decision: "inbox", "feed", "paper" or "blocked".
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
