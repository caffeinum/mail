import Testing
import Foundation
@testable import MailCore

/// Places senders the way a person would, so views can be tested past the
/// New Senders queue.
func place(_ s: Store, _ pairs: [(String, String)]) throws {
    for (email, decision) in pairs { try s.decide(account: gmail, email: email, decision: decision) }
}

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
        #expect(Set(s.threads(box, .newSenders).map(\.id)) == ["a", "b", "c"])
        #expect(s.threads(duckBox, .newSenders).map(\.id) == ["d"])
        #expect(s.threads(box, .inbox).isEmpty)
        #expect(s.thread(account: gmail, id: "b")?.category == nil)   // no verdict, no guess
        try place(s, [("ann@x.com", "inbox"), ("news@substack.com", "feed"), ("shop@y.com", "paper"), ("bob@z.com", "inbox")])
        #expect(s.threads(box, .inbox).map(\.id) == ["a"])
        #expect(s.threads(box, .feed).map(\.id) == ["b"])
        #expect(s.threads(box, .paper).map(\.id) == ["c"])
        #expect(s.threads(duckBox, .inbox).map(\.id) == ["d"])
        #expect(s.threads(duckBox, .inbox).first?.sender == "bob@z.com")
    }

    @Test func everyoneWaitsThenFollowsTheirPlacement() throws {
        let s = try tempStore()
        var alert = msg("1", thread: "a", from: "notifications@vercel.com", subject: "Preview deployment failed", labels: ["INBOX", "CATEGORY_UPDATES"])
        alert.autoSubmitted = "auto-generated"
        try s.upsert([alert, msg("2", thread: "b", from: "jane@startup.io", subject: "coffee next week?")])
        #expect(Set(s.threads(box, .newSenders).map(\.id)) == ["a", "b"])
        try place(s, [("notifications@vercel.com", "paper")])
        #expect(s.threads(box, .paper).map(\.id) == ["a"])
        #expect(s.threads(box, .newSenders).map(\.id) == ["b"])
        try s.upsert([msg("3", thread: "c", from: "notifications@vercel.com", subject: "Action required: update your payment method",
                          labels: ["INBOX", "CATEGORY_UPDATES"], date: 9)])
        #expect(Set(s.threads(box, .paper).map(\.id)) == ["a", "c"])
    }

    @Test func newSenderWaitsUntilDecided() throws {
        let s = try tempStore()
        try s.upsert([msg("1", thread: "a", from: "ann@x.com")])
        try place(s, [("ann@x.com", "inbox")])
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
        try place(s, [("ann@x.com", "inbox")])
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
        try place(s, [("ann@x.com", "inbox")])
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
        try place(s, [("ann@x.com", "inbox")])
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

@Suite struct SpamAndMuted {
    let box = Mailbox(account: gmail, kind: .gmail, title: "g")

    @Test func spamGoesToSpamAndBack() throws {
        let s = try tempStore()
        try s.upsert([msg("1", thread: "a", from: "ann@x.com")])
        try place(s, [("ann@x.com", "inbox")])
        let actions = Actions(store: s, outbox: Outbox(store: s))
        try actions.spam([s.threads(box, .inbox)[0]])
        #expect(s.threads(box, .inbox).isEmpty)
        #expect(s.threads(box, .spam).map(\.id) == ["a"])
        #expect(s.decision(account: gmail, email: "ann@x.com") == "blocked")
        try actions.undoLast()
        #expect(s.threads(box, .inbox).map(\.id) == ["a"])
        #expect(s.decision(account: gmail, email: "ann@x.com") == "inbox")
    }

    @Test func mutedSendersLeaveInboxAndFeed() throws {
        let s = try tempStore()
        try s.upsert([msg("1", thread: "a", from: "news@x.com", list: true), msg("2", thread: "b", from: "ann@x.com")])
        try place(s, [("news@x.com", "muted"), ("ann@x.com", "inbox")])
        #expect(s.threads(box, .muted).map(\.id) == ["a"])
        #expect(s.threads(box, .feed).isEmpty && s.threads(box, .newSenders).isEmpty)
        #expect(s.threads(box, .inbox).map(\.id) == ["b"])
    }
}

@Suite struct Participants {
    @Test func threadNamesEveryoneWhoWrote() throws {
        let s = try tempStore()
        var mine = msg("2", thread: "a", from: gmail, subject: "Re: plan", date: 2)
        mine.labels = ["SENT"]
        try s.upsert([msg("1", thread: "a", from: "ann@x.com", subject: "plan", date: 1),
                      mine,
                      MessageRecord(account: gmail, id: "3", threadID: "a", date: 3, labels: ["INBOX"],
                                    from: Address(name: "Bo Diddley", email: "bo@y.com"), subject: "Re: plan")])
        let t = s.thread(account: gmail, id: "a")!
        #expect(t.people == "ann@x.com, me, Bo")
        #expect(t.from == "ann@x.com, me, Bo")
        try s.upsert([msg("9", thread: "b", from: "solo@x.com")])
        #expect(s.thread(account: gmail, id: "b")!.from == "solo@x.com")
    }
}
