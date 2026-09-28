import Foundation

/// Which stream a thread belongs in when nobody has said. An explicit gmail
/// label (mail/feed, mail/paper-trail) or a sender decision always wins over
/// this guess.
public enum Sorter {
    static let paperWords = [
        "receipt", "invoice", "your order", "order confirm", "order #", "order no", "has shipped", "shipped",
        "out for delivery", "delivered", "payment", "paid", "statement", "billing", "bill is ready", "booking",
        "reservation", "itinerary", "e-ticket", "ticket", "confirmation", "confirmed", "subscription", "renewal",
        "trial", "refund", "transaction", "deposit", "transfer", "your account", "security alert", "sign-in",
        "verification code", "verify your", "password", "one-time", "login code", "tracking",
    ]

    static let robotLocals = ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications", "notification",
                              "alerts", "alert", "receipts", "billing", "orders", "order", "support", "info", "service"]

    public static func guess(_ m: MessageRecord) -> Category {
        let labels = Set(m.labels)
        let text = (m.subject + " " + m.snippet).lowercased()
        let sender = (m.shownFrom?.email ?? "").lowercased()
        let local = sender.split(separator: "@").first.map(String.init) ?? ""
        let robot = robotLocals.contains { local == $0 || local.hasPrefix($0 + "-") || local.hasPrefix($0 + "+") || local.hasPrefix($0 + ".") }
        let transactional = paperWords.contains { text.contains($0) }
        let bulk = m.listUnsubscribe != nil || m.listID != nil
            || ["bulk", "list", "junk"].contains(m.precedence?.lowercased() ?? "")

        if transactional && (robot || labels.contains("CATEGORY_UPDATES") || m.autoSubmitted != nil) { return .paper }
        if labels.contains("CATEGORY_PROMOTIONS") || labels.contains("CATEGORY_SOCIAL") || labels.contains("CATEGORY_FORUMS") { return .feed }
        if bulk { return .feed }
        if labels.contains("CATEGORY_UPDATES") && robot { return .paper }
        return .inbox
    }
}
