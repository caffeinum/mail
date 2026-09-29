import Foundation

/// Where mail goes when nobody has said. People go to the Inbox (once let
/// in). Machines go by what they send: receipts and payments to the Paper
/// Trail; newsletters, announcements, come-back mail and event invitations
/// to the Feed; everything else they send — trials, sign-ins, deploys,
/// things to act on — to Notifications. An explicit gmail label or a sender
/// decision always wins.
public enum Sorter {
    /// Bump when the rules change: the cache re-sorts every thread on open.
    public static let version = 11

    /// Money moved or something was bought: the record you may need later.
    static let receiptWords = [
        "receipt", "invoice", "your order", "order confirm", "order #", "order no", "order number", "has shipped",
        "shipped", "out for delivery", "was delivered", "has been delivered", "payment received", "payment confirmation",
        "payment successful", "you paid", "you sent", "you've paid", "thanks for your payment", "thank you for your payment",
        "refund", "booking confirm", "reservation confirm", "your reservation", "your booking", "itinerary", "e-ticket",
        "your trip", "statement is ready", "bill is ready", "your bill", "subscription renewed", "renewal confirmation",
        "purchase", "transaction", "tax document", "payout", "deposit", "withdrew", "transfer", "charged", "flight is booked",
        "return request", "return confirmed",
    ]

    /// Reading, not doing: launches, digests, come-back pitches, events.
    static let feedWords = [
        "introducing", "announcing", "now available", "is now live", "new feature", "what's new", "whats new", "we've launched",
        "just launched", "launch", "is here", "product update", "changelog", "release notes", "newsletter", "digest",
        "this week", "weekly", "monthly", "roundup", "edition", "issue #", "spotlight",
        "we miss you", "miss you", "come back", "still interested", "haven't seen you", "it's been a while", "welcome back",
        "invited", "invitation", "you're invited", "join us", "webinar", "rsvp", "meetup", "event", "summit", "conference",
        "livestream", "happy hour", "hackathon", "hacks", "register now", "save your seat", "demo day",
    ]

    static let robotLocals = ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications", "notification",
                              "notify", "alerts", "alert", "receipts", "receipt", "billing", "orders", "order", "support",
                              "info", "service", "mailer", "bounce", "auto-confirm", "account", "accounts", "team",
                              "hello", "news", "newsletter", "updates", "digest", "security", "reservations"]

    /// A machine asking you to do something, now.
    static let actionWords = [
        "update your payment", "update payment", "payment method", "payment failed", "payment declined",
        "couldn't be completed", "couldn&apos;t be completed", "could not be processed", "card declined", "card expir",
        "past due", "overdue", "action required", "action needed", "suspended", "will be deleted", "will be suspended",
        "locked", "verify your email", "confirm your email", "verification code", "one time password", "one-time password",
        "login code", "sign-in code", "security code", "your code", "reset your password", "expires today", "final notice",
    ]

    /// The subject of a notification: something happened, here's the record.
    static let eventWords = [
        "deploy", "failed", "build", "merged", "commit", "pull request", "review", "mentioned", "assigned", "comment",
        "invited", "sign-in", "sign in", "new device", "login", "alert", "report", "summary", "briefing", "confirmed",
        "scheduled", "reminder", "updated", "changed", "received", "approved", "completed", "joined", "shared",
        "trial", "expir", "ending", "ends", "paused", "deleted", "deletion", "suspended", "verify", "verification", "code",
        "password", "security", "account", "action required", "payment method", "renew", "limit", "usage", "quota",
    ]

    public static func needsAction(_ m: MessageRecord) -> Bool {
        let text = m.subject.lowercased()
        return actionWords.contains { text.contains($0) }
    }

    static func isEvent(_ m: MessageRecord) -> Bool {
        let text = m.subject.lowercased()
        return eventWords.contains { text.contains($0) }
    }

    public static func isReceipt(_ m: MessageRecord) -> Bool {
        let text = (m.subject + " " + m.snippet).lowercased()
        return receiptWords.contains { text.contains($0) }
    }

    public static func isBulk(_ m: MessageRecord) -> Bool {
        m.listUnsubscribe != nil || m.listID != nil || ["bulk", "list", "junk"].contains(m.precedence?.lowercased() ?? "")
    }

    /// A machine rather than a person: it never needs screening.
    public static func isRobot(_ m: MessageRecord) -> Bool {
        let labels = Set(m.labels)
        let local = (m.shownFrom?.email ?? "").lowercased().split(separator: "@").first.map(String.init) ?? ""
        let robotName = robotLocals.contains { local == $0 || local.hasPrefix($0 + "-") || local.hasPrefix($0 + "+")
            || local.hasPrefix($0 + ".") || local.hasPrefix($0 + "_") || local.hasSuffix("-" + $0) }
        return robotName || m.autoSubmitted != nil || isBulk(m)
            || labels.contains("CATEGORY_UPDATES") || labels.contains("CATEGORY_PROMOTIONS")
            || labels.contains("CATEGORY_SOCIAL") || labels.contains("CATEGORY_FORUMS")
    }

    public static func isFeedish(_ m: MessageRecord) -> Bool {
        let text = m.subject.lowercased()
        return feedWords.contains { text.contains($0) }
    }

    public static func guess(_ m: MessageRecord) -> Category {
        let labels = Set(m.labels)
        guard isRobot(m) else { return .inbox }
        if isReceipt(m) { return .paper }
        if isFeedish(m) { return .feed }
        if labels.contains("CATEGORY_PROMOTIONS") || labels.contains("CATEGORY_SOCIAL") || labels.contains("CATEGORY_FORUMS") { return .feed }
        if isBulk(m) && !isEvent(m) && !needsAction(m) { return .feed }
        return .notify
    }

    /// Sorting follows the sender, not the single message: a sender whose
    /// mail is mostly receipts is Paper Trail, mostly newsletters is Feed.
    /// Receipts win a third — a store that also sends promotions still
    /// belongs where its receipts can be found.
    public static func category(of messages: [MessageRecord]) -> Category {
        guard !messages.isEmpty else { return .inbox }
        var n: [Category: Int] = [:]
        for m in messages { n[guess(m), default: 0] += 1 }
        if (n[.paper] ?? 0) * 3 >= messages.count { return .paper }
        return [Category.inbox, .notify, .feed].max { (n[$0] ?? 0) < (n[$1] ?? 0) } ?? .inbox
    }
}
