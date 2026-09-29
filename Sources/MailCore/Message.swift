import Foundation

public struct MessageRecord: Equatable {
    public var account: String
    public var id: String
    public var threadID: String
    public var historyID: Int64
    public var date: Int64
    public var labels: [String]
    public var from: Address?
    public var to: [Address]
    public var cc: [Address]
    public var replyTo: [Address]
    public var subject: String
    public var snippet: String
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var listUnsubscribe: String?
    public var listID: String?
    public var precedence: String?
    public var autoSubmitted: String?
    public var duckFrom: Address?
    public var duckTo: String?
    public var bodyText: String?
    public var bodyHTML: String?
    public var hasBody: Bool
    /// Carries a calendar invite (text/calendar part or an .ics attachment).
    public var invite = false

    public init(account: String, id: String, threadID: String, historyID: Int64 = 0, date: Int64 = 0, labels: [String] = [],
                from: Address? = nil, to: [Address] = [], cc: [Address] = [], replyTo: [Address] = [], subject: String = "",
                snippet: String = "", messageID: String? = nil, inReplyTo: String? = nil, references: [String] = [],
                listUnsubscribe: String? = nil, listID: String? = nil, precedence: String? = nil, autoSubmitted: String? = nil,
                duckFrom: Address? = nil, duckTo: String? = nil, bodyText: String? = nil, bodyHTML: String? = nil, hasBody: Bool = false) {
        self.account = account; self.id = id; self.threadID = threadID; self.historyID = historyID; self.date = date
        self.labels = labels; self.from = from; self.to = to; self.cc = cc; self.replyTo = replyTo; self.subject = subject
        self.snippet = snippet; self.messageID = messageID; self.inReplyTo = inReplyTo; self.references = references
        self.listUnsubscribe = listUnsubscribe; self.listID = listID; self.precedence = precedence; self.autoSubmitted = autoSubmitted
        self.duckFrom = duckFrom; self.duckTo = duckTo; self.bodyText = bodyText; self.bodyHTML = bodyHTML; self.hasBody = hasBody
    }

    /// A mailing list is one sender, whoever posted: its List-Id address
    /// ("ctolunches.groups.io") and name ("ctolunches").
    public var list: (key: String, name: String)? {
        guard let raw = listID?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        var key = raw, phrase = ""
        if let lt = raw.lastIndex(of: "<"), let gt = raw.lastIndex(of: ">"), lt < gt {
            key = String(raw[raw.index(after: lt)..<gt])
            phrase = String(raw[..<lt]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
        key = key.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains("@") else { return nil }
        let usable = !phrase.isEmpty && phrase.count <= 60 && !phrase.allSatisfy(\.isNumber)
        return (key, usable ? phrase : Self.listName(key))
    }

    /// "worldwide.ctolunches.groups.io" → "ctolunches": the label next to a
    /// list host's own domain, else the first label.
    static func listName(_ key: String) -> String {
        for host in [".groups.io", ".googlegroups.com", ".substack.com", ".github.com", ".list-manage.com"] where key.hasSuffix(host) {
            let rest = key.dropLast(host.count)
            if let last = rest.split(separator: ".").last { return String(last) }
        }
        return String(key.split(separator: ".").first ?? Substring(key))
    }

    /// Who the ui says it's from: the real sender behind a forwarding alias.
    public var shownFrom: Address? { duckFrom ?? from }

    public var isUnread: Bool { labels.contains("UNREAD") }

    public init(account: String, gmail m: GmailMessage) {
        let headers = m.payload?.headers ?? []
        func h(_ n: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }.map { MIME.decodeHeader($0.value) }
        }
        self.init(account: account, id: m.id, threadID: m.threadId)
        historyID = Int64(m.historyId ?? "") ?? 0
        date = Int64(m.internalDate ?? "") ?? 0
        labels = m.labelIds ?? []
        from = h("From").flatMap(Address.parse)
        to = h("To").map(Address.parseList) ?? []
        cc = h("Cc").map(Address.parseList) ?? []
        replyTo = h("Reply-To").map(Address.parseList) ?? []
        subject = h("Subject") ?? ""
        snippet = Self.unescape(m.snippet ?? "")
        messageID = h("Message-ID") ?? h("Message-Id")
        inReplyTo = h("In-Reply-To")
        references = (h("References") ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).map(String.init)
        listUnsubscribe = h("List-Unsubscribe")
        listID = h("List-Id")
        precedence = h("Precedence")
        autoSubmitted = h("Auto-Submitted")
        duckFrom = h("Duck-Original-From").flatMap(Address.parse)
        duckTo = h("Duck-Original-To").flatMap(Self.forwardedTo)
        if let p = m.payload, p.parts != nil || p.body?.data != nil {
            var text: String?, html: String?
            Self.walk(p, text: &text, html: &html)
            invite = Self.hasInvite(p)
            if text != nil || html != nil {
                bodyText = text; bodyHTML = html; hasBody = true
            } else if p.mimeType?.hasPrefix("multipart/") == true || p.body?.data != nil {
                bodyText = ""; hasBody = true
            }
        }
    }

    /// The alias a forwarded message was addressed to. The header can name
    /// several people ("Ann <ann@x.com>, me@duck.com"); the relay's own
    /// address is the one that counts.
    public static func forwardedTo(_ raw: String) -> String? {
        let emails = Address.parseList(raw).map(\.normalized)
        if let alias = emails.first(where: { $0.hasSuffix("@duck.com") && !isRelayForm($0) }) { return alias }
        // Our own reply, echoed back: only relay addresses
        // (someone_at_example.com_alias@duck.com) — the alias is their tail.
        if let relay = emails.first(where: isRelayForm), let tail = relay.split(separator: "_").last { return String(tail) }
        return emails.first
    }

    /// someone_at_example.com_alias@duck.com — a relay address, never an alias.
    public static func isRelayForm(_ email: String) -> Bool {
        email.hasSuffix("@duck.com") && email.contains("_at_")
    }

    static func charset(_ part: GmailPart) -> String {
        let ct = part.headers?.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? ""
        guard let r = ct.range(of: "charset=", options: .caseInsensitive) else { return "utf-8" }
        return ct[r.upperBound...].split(separator: ";").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) } ?? "utf-8"
    }

    static func hasInvite(_ p: GmailPart) -> Bool {
        if p.mimeType?.lowercased() == "text/calendar" || (p.filename ?? "").lowercased().hasSuffix(".ics") { return true }
        return p.parts?.contains(where: hasInvite) ?? false
    }

    static func walk(_ p: GmailPart, text: inout String?, html: inout String?) {
        if let parts = p.parts {
            for c in parts { walk(c, text: &text, html: &html) }
            return
        }
        guard (p.filename ?? "").isEmpty, let data = p.body?.data, let bytes = MIME.base64URLDecode(data) else { return }
        let decoded = String(data: bytes, encoding: MIME.encoding(charset(p))) ?? String(decoding: bytes, as: UTF8.self)
        switch p.mimeType?.lowercased() {
        case "text/plain": if text == nil { text = decoded }
        case "text/html": if html == nil { html = decoded }
        default: break
        }
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }
}

public enum Category: String, CaseIterable {
    case inbox, notify, feed, paper
}

public enum View: Equatable, Hashable {
    case inbox, notifications, feed, paper, newSenders, spam, muted, calendar, sent
    case search(String)

    public var key: String {
        switch self {
        case .inbox: return "inbox"
        case .notifications: return "notify"
        case .feed: return "feed"
        case .paper: return "paper"
        case .newSenders: return "new"
        case .spam: return "spam"
        case .muted: return "muted"
        case .calendar: return "calendar"
        case .sent: return "sent"
        case .search: return "search"
        }
    }

    public var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .notifications: return "Notifications"
        case .feed: return "Feed"
        case .paper: return "Paper Trail"
        case .newSenders: return "New Senders"
        case .spam: return "Spam"
        case .muted: return "Muted"
        case .calendar: return "Calendar"
        case .sent: return "Sent"
        case .search(let q): return "“\(q)”"
        }
    }

    public static let tabs: [View] = [.inbox, .feed, .calendar, .paper, .notifications, .muted, .newSenders]

    public init?(key: String) {
        switch key {
        case "inbox": self = .inbox
        case "notify": self = .notifications
        case "feed": self = .feed
        case "paper": self = .paper
        case "new": self = .newSenders
        case "spam": self = .spam
        case "muted": self = .muted
        case "calendar": self = .calendar
        case "sent": self = .sent
        default: return nil
        }
    }
}

public struct ThreadSummary: Equatable, Hashable {
    public let account: String
    public let id: String
    public let date: Int64
    public let subject: String
    public let snippet: String
    public let sender: String
    public let senderEmail: String
    public let unread: Bool
    public let count: Int
    /// The stream it goes to — nil while a new sender has no verdict yet.
    public let category: Category?
    /// The alias the thread came in through, or "" for the gmail account itself.
    public let alias: String
    /// Everyone who wrote in the thread, in order ("Ann, Bo, me"); the sender alone when it's one person.
    public var people: String = ""

    /// What the row names: all participants when there are several.
    public var from: String { people.isEmpty ? sender : people }
}

/// The gmail label names the three streams map onto, so a phone shows the
/// same sorting.
public enum Streams {
    public static let feed = "mail/feed"
    public static let paper = "mail/paper-trail"
    public static let notifications = "mail/notifications"
    /// Not spam, just not wanted in sight: muted senders land here, read.
    public static let muted = "mail/muted"
    public static func label(_ c: Category) -> String? {
        switch c { case .feed: return feed; case .paper: return paper; case .notify: return notifications; case .inbox: return nil }
    }
}
public typealias MailCategory = Category
