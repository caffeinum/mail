import Foundation

public enum ReplyMode: String, Codable { case reply, replyAll, forward, new }

public enum ReplyError: Error, CustomStringConvertible, Equatable {
    case noRecipient
    case leak(String)

    public var description: String {
        switch self {
        case .noRecipient: return "no one to reply to"
        case .leak(let why): return "refusing to send: \(why)"
        }
    }
}

/// Mail that came in through a forwarding alias (DuckDuckGo's duck.com) has
/// its sender rewritten to a relay address. Replies go to that relay, sent
/// from the gmail account the alias forwards to — the relay recognises it
/// and swaps it for the alias on the way out. Anything addressed straight to
/// the original sender, or to anyone not behind the relay, would hand over
/// the real gmail address.
public struct AliasRelay: Equatable {
    public let rule: AliasRule

    public init(_ rule: AliasRule) { self.rule = rule }

    var aliasEmail: String { rule.address.lowercased() }
    var domain: String { String(aliasEmail.split(separator: "@").last ?? "") }
    var aliasLocal: String { String(aliasEmail.split(separator: "@").first ?? "") }

    public func isRelay(_ a: Address) -> Bool {
        let e = a.normalized
        return e.hasSuffix("@" + domain) && e != aliasEmail
    }

    /// someone@example.com → someone_at_example.com_alias@duck.com, the
    /// relay's own form for writing to someone new from the alias.
    public func relay(_ a: Address) -> Address {
        if isRelay(a) { return a }
        let local = a.email.replacingOccurrences(of: "@", with: "_at_")
        return Address(name: a.name, email: "\(local)_\(aliasLocal)@\(domain)")
    }

    /// The last check before anything leaves: every recipient is behind the
    /// relay, and the gmail address appears nowhere but the From line the
    /// relay rewrites.
    public func verify(_ m: OutgoingMessage, account: String) throws {
        for r in m.allRecipients where !isRelay(r) {
            throw ReplyError.leak("\(r.email) is not a \(domain) relay address; writing to it would reveal \(account)")
        }
        guard !m.allRecipients.isEmpty else { throw ReplyError.noRecipient }
        guard m.from.normalized == account.lowercased() else {
            throw ReplyError.leak("alias mail must go out from the forwarding account so the relay can rewrite it")
        }
        let acct = account.lowercased()
        if m.body.lowercased().contains(acct) || m.subject.lowercased().contains(acct) {
            throw ReplyError.leak("the message text contains \(account)")
        }
        if !m.from.name.isEmpty { throw ReplyError.leak("From carries a display name") }
    }
}

public enum Composer {
    public static func relay(for m: MessageRecord, aliases: [AliasRule]) -> AliasRelay? {
        guard let to = m.duckTo?.lowercased() else { return nil }
        return aliases.first { $0.address.lowercased() == to }.map(AliasRelay.init)
    }

    public static func draft(_ mode: ReplyMode, thread: [MessageRecord], account: String, aliases: [AliasRule],
                             me: Address? = nil) throws -> OutgoingMessage {
        let mine = Set([account.lowercased()] + aliases.map { $0.address.lowercased() })
        guard let target = thread.last(where: { !mine.contains($0.from?.normalized ?? "") }) ?? thread.last else {
            throw ReplyError.noRecipient
        }
        let relay = thread.lazy.compactMap { relay(for: $0, aliases: aliases) }.first
        let from = relay == nil ? (me ?? Address(email: account)) : Address(email: account)

        var to: [Address] = []
        var cc: [Address] = []
        switch mode {
        case .reply, .replyAll:
            to = target.replyTo.isEmpty ? [target.from].compactMap { $0 } : target.replyTo
            if mode == .replyAll { cc = target.to + target.cc }
        case .forward, .new: break
        }
        func keep(_ a: Address) -> Bool {
            if mine.contains(a.normalized) { return false }
            if let relay { return relay.isRelay(a) }
            return true
        }
        to = unique(to.filter(keep))
        cc = unique(cc.filter(keep)).filter { c in !to.contains { $0.normalized == c.normalized } }
        if (mode == .reply || mode == .replyAll) && to.isEmpty {
            if cc.isEmpty { throw ReplyError.noRecipient }
            to = [cc.removeFirst()]
        }

        let base = target.subject
        let subject: String
        switch mode {
        case .forward: subject = base.lowercased().hasPrefix("fwd:") ? base : "Fwd: \(base)"
        case .new: subject = ""
        default: subject = base.lowercased().hasPrefix("re:") ? base : "Re: \(base)"
        }

        let quoted = quote(target, forward: mode == .forward)
        let refs = target.references + [target.messageID].compactMap { $0 }
        var m = OutgoingMessage(from: from, to: to, cc: cc, subject: subject, body: "\n\n" + quoted,
                                inReplyTo: mode == .forward ? nil : target.messageID,
                                references: mode == .forward ? [] : refs, threadID: target.threadID)
        if relay != nil { m.body = m.body.replacingOccurrences(of: account, with: "", options: .caseInsensitive) }
        return m
    }

    /// A new message from an alias: every recipient is rewritten into the
    /// relay form, so the alias is what they see.
    public static func fromAlias(_ rule: AliasRule, account: String, to: [Address], cc: [Address], subject: String, body: String) -> OutgoingMessage {
        let r = AliasRelay(rule)
        return OutgoingMessage(from: Address(email: account), to: to.map(r.relay), cc: cc.map(r.relay), subject: subject, body: body)
    }

    static func unique(_ a: [Address]) -> [Address] {
        var seen = Set<String>()
        return a.filter { seen.insert($0.normalized).inserted }
    }

    static func quote(_ m: MessageRecord, forward: Bool) -> String {
        let when = Date(timeIntervalSince1970: TimeInterval(m.date) / 1000)
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        let who = m.shownFrom.map { $0.name.isEmpty ? $0.email : "\($0.name) <\($0.email)>" } ?? "someone"
        let text = (m.bodyText?.isEmpty == false ? m.bodyText : m.bodyHTML.map(HTMLText.strip)) ?? m.snippet
        if forward {
            return "---------- Forwarded message ---------\nFrom: \(who)\nDate: \(f.string(from: when))\nSubject: \(m.subject)\n\n\(text)"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        return "On \(f.string(from: when)), \(who) wrote:\n\(lines)"
    }
}
