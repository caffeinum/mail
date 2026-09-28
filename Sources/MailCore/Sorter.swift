import Foundation

/// Where mail goes when nobody has said: receipts to the Paper Trail,
/// newsletters and promotions to the Feed, everything else — people and the
/// notifications that matter — to the Inbox. People wait in New Senders
/// until let in; machines don't. An explicit gmail label (mail/feed,
/// mail/paper-trail) or a sender decision always wins.
public enum Sorter {
    /// Bump when the rules change: the cache re-sorts every thread on open.
    public static let version = 5

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

    /// Mail a machine sends because something happened to you — these
    /// belong in the Inbox even when they come with an unsubscribe link.
    static let alertWords = [
        "failed", "failure", "error", "alert", "sign-in", "sign in", "signin", "login", "log in", "verification",
        "verify", "code", "password", "one-time", "otp", "2fa", "security", "action required", "requested",
        "mentioned", "assigned", "review", "invited", "invitation", "approve", "approval", "reminder", "expir",
        "due", "overdue", "declined", "suspended", "locked", "new device", "access", "deploy", "incident", "down",
    ]

    public static func isAlert(_ m: MessageRecord) -> Bool {
        let text = m.subject.lowercased()
        return alertWords.contains { text.contains($0) }
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
        if isRobot(m) && isReceipt(m) { return .paper }
        if labels.contains("CATEGORY_PROMOTIONS") || labels.contains("CATEGORY_SOCIAL") || labels.contains("CATEGORY_FORUMS") { return .feed }
        if isBulk(m) && !isAlert(m) { return .feed }
        return .inbox
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
