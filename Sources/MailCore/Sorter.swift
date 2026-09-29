import Foundation

/// Where mail goes when nobody has said. People go to the Inbox once let
/// in (they wait in New Senders until then). Machines go by what they send:
/// newsletters and promotions to the Feed, receipts and notifications —
/// deploys, sign-ins, bookings, the record of things that happened — to the
/// Paper Trail. A machine asking you to act (update a payment method, an
/// account suspended, a code you're waiting for) reaches the Inbox. An
/// explicit gmail label (mail/feed, mail/paper-trail) or a sender decision
/// decides the stream; only a request to act gets past it.
public enum Sorter {
    /// Bump when the rules change: the cache re-sorts every thread on open.
    public static let version = 8

    static let receiptWords = [
        "receipt", "invoice", "your order", "order confirm", "order #", "order no", "order number", "has shipped",
        "shipped", "out for delivery", "was delivered", "has been delivered", "payment received", "payment confirmation",
        "payment successful", "you paid", "you sent", "you've paid", "thanks for your payment", "thank you for your payment",
        "refund", "booking confirm", "reservation confirm", "your reservation", "your booking", "itinerary", "e-ticket",
        "your trip", "statement is ready", "bill is ready", "your bill", "subscription renewed", "renewal confirmation",
        "purchase", "transaction", "tax document", "payout", "deposit received", "your flight is booked",
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

    public static func guess(_ m: MessageRecord) -> Category {
        let labels = Set(m.labels)
        guard isRobot(m) else { return .inbox }
        if needsAction(m) { return .inbox }
        if isReceipt(m) { return .paper }
        if labels.contains("CATEGORY_PROMOTIONS") || labels.contains("CATEGORY_SOCIAL") || labels.contains("CATEGORY_FORUMS") { return .feed }
        if isBulk(m) && !isEvent(m) { return .feed }
        return .paper
    }

    /// Sorting follows the sender, not the single message: a sender whose
    /// mail is mostly receipts is Paper Trail, mostly newsletters is Feed.
    /// Receipts win a third — a store that also sends promotions still
    /// belongs where its receipts can be found.
    public static func category(of messages: [MessageRecord]) -> Category {
        guard !messages.isEmpty else { return .inbox }
        var n: [Category: Int] = [:]
        for m in messages { n[guess(m), default: 0] += 1 }
        let paper = n[.paper] ?? 0, feed = n[.feed] ?? 0, inbox = n[.inbox] ?? 0
        if paper * 3 >= messages.count { return .paper }
        if feed > inbox { return .feed }
        if inbox > 0 { return .inbox }
        return .feed
    }
}
