import Testing
import Foundation
@testable import MailCore

func tempStore(_ config: AccountsFile = AccountsFile(accounts: [AccountConfig(email: gmail, aliases: [duck])])) throws -> Store {
    let p = FileManager.default.temporaryDirectory.appendingPathComponent("post-test-\(UUID().uuidString).sqlite").path
    return try Store(path: p, config: config)
}

func msg(_ id: String, thread: String, from: String, subject: String = "hi", labels: [String] = ["INBOX", "UNREAD"],
         date: Int64 = 1, duck: Bool = false, list: Bool = false) -> MessageRecord {
    MessageRecord(account: gmail, id: id, threadID: thread, date: date, labels: labels,
                  from: Address(email: duck ? from.replacingOccurrences(of: "@", with: "_at_") + "_someone@duck.com" : from),
                  to: [Address(email: duck ? "someone@duck.com" : gmail)], subject: subject, snippet: "snippet of \(subject)",
                  listUnsubscribe: list ? "<x>" : nil,
                  duckFrom: duck ? Address(email: from) : nil, duckTo: duck ? "someone@duck.com" : nil)
}

@Suite struct StoreViews {
    let box = Mailbox(account: gmail, kind: .gmail, title: "g")
    let duckBox = Mailbox(account: gmail, kind: .alias(duck), title: "duck")

    @Test func streamsAndAliasSplit() throws {
        let s = try tempStore()
        try s.upsert([
            msg("1", thread: "a", from: "ann@x.com", date: 3),
            msg("2", thread: "b", from: "news@substack.com", subject: "weekly", date: 2, list: true),
            msg("3", thread: "c", from: "shop@y.com", subject: "your receipt", labels: ["INBOX", "CATEGORY_UPDATES"], date: 1),
            msg("4", thread: "d", from: "bob@z.com", date: 4, duck: true),
        ])
        try s.seedSenders(gmail)
        #expect(s.threads(box, .inbox).map(\.id) == ["a"])
        #expect(s.threads(box, .feed).map(\.id) == ["b"])
        #expect(s.threads(box, .paper).map(\.id) == ["c"])
        #expect(s.threads(duckBox, .inbox).map(\.id) == ["d"])
        #expect(s.threads(duckBox, .inbox).first?.sender == "bob@z.com")
    }

    @Test func machinesSkipScreeningPeopleDont() throws {
        let s = try tempStore()
        try s.seedSenders(gmail)
        var alert = msg("1", thread: "a", from: "notifications@vercel.com", subject: "Preview deployment failed", labels: ["INBOX", "CATEGORY_UPDATES"])
        alert.autoSubmitted = "auto-generated"
        try s.upsert([alert, msg("2", thread: "b", from: "jane@startup.io", subject: "coffee next week?")])
        #expect(s.threads(box, .paper).map(\.id) == ["a"])
        #expect(s.threads(box, .newSenders).map(\.id) == ["b"])
        try s.upsert([msg("3", thread: "c", from: "notifications@vercel.com", subject: "Action required: update your payment method",
                          labels: ["INBOX", "CATEGORY_UPDATES"], date: 9)])
        #expect(s.threads(box, .inbox).map(\.id) == ["c"])
    }

    @Test func sortingFollowsTheSender() throws {
        let s = try tempStore()
        try s.upsert([
            msg("1", thread: "a", from: "orders@shop.com", subject: "Your receipt", labels: ["INBOX", "CATEGORY_UPDATES"], date: 1),
            msg("2", thread: "b", from: "orders@shop.com", subject: "Fall collection is here", labels: ["INBOX", "CATEGORY_PROMOTIONS"], date: 2),
        ])
        #expect(Set(s.threads(box, .paper).map(\.id)) == ["a", "b"])
    }

    @Test func newSenderWaitsUntilDecided() throws {
        let s = try tempStore()
        try s.upsert([msg("1", thread: "a", from: "ann@x.com")])
        try s.seedSenders(gmail)
        try s.upsert([msg("2", thread: "b", from: "stranger@new.com", date: 5)])
        #expect(s.threads(box, .newSenders).map(\.id) == ["b"])
        #expect(!s.threads(box, .inbox).map(\.id).contains("b"))
        try s.decide(account: gmail, email: "stranger@new.com", decision: "feed")
        #expect(s.threads(box, .newSenders).isEmpty)
        #expect(s.threads(box, .feed).map(\.id) == ["b"])
        try s.undecide(account: gmail, email: "stranger@new.com")
        #expect(s.threads(box, .newSenders).map(\.id) == ["b"])
    }

    @Test func searchFindsByPrefix() throws {
        let s = try tempStore()
        try s.upsert([msg("1", thread: "a", from: "ann@acme.com", subject: "Invoice for September"),
                      msg("2", thread: "b", from: "bob@x.com", subject: "lunch")])
        #expect(s.search(box, "inv acme").map(\.id) == ["a"])
        #expect(s.search(box, "lun").map(\.id) == ["b"])
        #expect(s.search(box, "nothing").isEmpty)
    }

    @Test func cachedBodySurvivesMetadataRefresh() throws {
        let s = try tempStore()
        var m = msg("1", thread: "a", from: "ann@x.com")
        m.bodyText = "full body"; m.hasBody = true
        try s.upsert([m])
        try s.upsert([msg("1", thread: "a", from: "ann@x.com", labels: ["INBOX"])])
        let got = s.messages(account: gmail, thread: "a")[0]
        #expect(got.bodyText == "full body" && got.hasBody && !got.isUnread)
    }
}

@Suite struct UndoFlow {
    @Test func doneThenUndoCancelsBeforeGmailHears() throws {
        let s = try tempStore()
        try s.upsert([msg("1", thread: "a", from: "ann@x.com")])
        try s.seedSenders(gmail)
        let box = Mailbox(account: gmail, kind: .gmail, title: "g")
        let outbox = Outbox(store: s)
        let actions = Actions(store: s, outbox: outbox)
        let t = s.threads(box, .inbox)[0]
        try actions.done([t])
        #expect(s.threads(box, .inbox).isEmpty)
        #expect(outbox.pending(account: gmail).count == 1)
        #expect(try actions.undoLast() == "Done")
        #expect(s.threads(box, .inbox).map(\.id) == ["a"])
        #expect(outbox.pending(account: gmail).isEmpty)
    }

    @Test func undoAfterItWentOutQueuesTheInverse() throws {
        let s = try tempStore()
        try s.upsert([msg("1", thread: "a", from: "ann@x.com")])
        try s.seedSenders(gmail)
        let box = Mailbox(account: gmail, kind: .gmail, title: "g")
        let outbox = Outbox(store: s)
        let actions = Actions(store: s, outbox: outbox)
        try actions.done([s.threads(box, .inbox)[0]])
        let id = outbox.pending(account: gmail)[0].id
        try s.db.run("UPDATE outbox SET state='done' WHERE id=?", id)
        try actions.undoLast()
        let inv = outbox.pending(account: gmail)
        #expect(inv.count == 1)
        #expect(inv[0].op == .modify(thread: "a", add: ["INBOX"], remove: []))
    }

    @Test func pendingChangeSurvivesAStaleSync() throws {
        let s = try tempStore()
        try s.upsert([msg("1", thread: "a", from: "ann@x.com")])
        try s.seedSenders(gmail)
        let box = Mailbox(account: gmail, kind: .gmail, title: "g")
        let outbox = Outbox(store: s)
        try Actions(store: s, outbox: outbox).done([s.threads(box, .inbox)[0]])
        try s.upsert([msg("1", thread: "a", from: "ann@x.com")])   // server hasn't heard yet
        outbox.overlay(account: gmail, threads: ["a"])
        #expect(s.threads(box, .inbox).isEmpty)
    }

    @Test func aliasSendIsCheckedBeforeItQueues() throws {
        let s = try tempStore()
        let actions = Actions(store: s, outbox: Outbox(store: s))
        let bad = OutgoingMessage(from: Address(email: gmail), to: [Address(email: "support@hey.com")], subject: "x", body: "y")
        #expect(throws: ReplyError.self) { try actions.send(account: gmail, bad, alias: duck) }
        #expect(Outbox(store: s).pending(account: gmail).isEmpty)
    }
}

@Suite struct AliasDiscovery {
    @Test func aliasInTheMailBecomesAnAccount() throws {
        var file = AccountsFile(accounts: [AccountConfig(email: gmail)])
        let s = try tempStore(file)
        try s.upsert((1...3).map { msg("\($0)", thread: "t\($0)", from: "x\($0)@shop.com", duck: true) })
        try s.upsert([MessageRecord(account: gmail, id: "z", threadID: "z", duckTo: "stray@duck.com")])
        #expect(s.foundAliases(gmail) == ["someone@duck.com"])
        #expect(file.adopt([gmail: s.foundAliases(gmail)]) == ["someone@duck.com"])
        #expect(file.mailboxes.map(\.title) == [gmail, "duck.com"])
        #expect(file.adopt([gmail: s.foundAliases(gmail)]).isEmpty)
        file.accounts[0].aliases = []
        file.accounts[0].ignoredAliases = ["someone@duck.com"]
        #expect(file.adopt([gmail: ["someone@duck.com"]]).isEmpty)
    }
}
