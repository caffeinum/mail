import Testing
import Foundation
@testable import MailCore

let gmail = "person@gmail.com"
let duck = AliasRule(address: "someone@duck.com", label: "duck.com")

func duckMessage(cc: [Address] = [], replyTo: [Address] = [], body: String = "hello") -> MessageRecord {
    MessageRecord(account: gmail, id: "m1", threadID: "t1", date: 1_790_000_000_000, labels: ["INBOX", "UNREAD"],
                  from: Address(name: "The HEY Team", email: "support_at_hey.com_someone@duck.com"),
                  to: [Address(email: "someone@duck.com")], cc: cc, replyTo: replyTo,
                  subject: "Verify your backup email", snippet: body, messageID: "<abc@smtp-inbound1.duck.com>",
                  references: ["<orig@hey.com>"],
                  duckFrom: Address(name: "The HEY Team", email: "support@hey.com"), duckTo: "someone@duck.com",
                  bodyText: body, hasBody: true)
}

@Suite struct AliasReplies {
    @Test func replyGoesToTheRelayNotTheOriginalSender() throws {
        let d = try Composer.draft(.reply, thread: [duckMessage()], account: gmail, aliases: [duck])
        #expect(d.to.map(\.email) == ["support_at_hey.com_someone@duck.com"])
        #expect(d.cc.isEmpty && d.bcc.isEmpty)
        #expect(d.from == Address(email: gmail))
        #expect(d.subject == "Re: Verify your backup email")
        #expect(d.inReplyTo == "<abc@smtp-inbound1.duck.com>")
        try AliasRelay(duck).verify(d, account: gmail)
    }

    @Test func rewrittenReplyToWins() throws {
        let m = duckMessage(replyTo: [Address(email: "help_at_hey.com_someone@duck.com")])
        let d = try Composer.draft(.reply, thread: [m], account: gmail, aliases: [duck])
        #expect(d.to.map(\.email) == ["help_at_hey.com_someone@duck.com"])
    }

    @Test func replyAllDropsEveryoneNotBehindTheRelay() throws {
        let m = duckMessage(cc: [Address(email: "friend@example.com"), Address(email: "friend_at_example.com_someone@duck.com"),
                                 Address(email: gmail), Address(email: "someone@duck.com")])
        let d = try Composer.draft(.replyAll, thread: [m], account: gmail, aliases: [duck])
        let all = d.allRecipients.map(\.email)
        #expect(all == ["support_at_hey.com_someone@duck.com", "friend_at_example.com_someone@duck.com"])
        try AliasRelay(duck).verify(d, account: gmail)
    }

    @Test func realGmailAddressNeverAppearsOutsideFrom() throws {
        let m = duckMessage(body: "forwarded by duck to \(gmail) — hi")
        let d = try Composer.draft(.reply, thread: [m], account: gmail, aliases: [duck])
        let raw = MIME.build(d)
        let fromLine = raw.components(separatedBy: "\r\n").first { $0.hasPrefix("From:") }
        #expect(fromLine == "From: \(gmail)")
        let rest = raw.components(separatedBy: "\r\n").filter { !$0.hasPrefix("From:") }.joined(separator: "\n")
        let decodedBody = String(decoding: Data(base64Encoded: rest.components(separatedBy: "\n\n").last!
            .replacingOccurrences(of: "\n", with: ""))!, as: UTF8.self)
        #expect(!rest.lowercased().contains(gmail))
        #expect(!decodedBody.lowercased().contains(gmail))
        #expect(!raw.contains("support@hey.com>") || !d.allRecipients.contains { $0.email == "support@hey.com" })
        try AliasRelay(duck).verify(d, account: gmail)
    }

    @Test func verifyRefusesADirectRecipient() {
        var d = OutgoingMessage(from: Address(email: gmail), to: [Address(email: "support@hey.com")], subject: "x", body: "y")
        #expect(throws: ReplyError.self) { try AliasRelay(duck).verify(d, account: gmail) }
        d.to = [Address(email: "support_at_hey.com_someone@duck.com")]
        d.from = Address(name: "Real Name", email: gmail)
        #expect(throws: ReplyError.self) { try AliasRelay(duck).verify(d, account: gmail) }
        d.from = Address(email: gmail)
        d.body = "reach me at \(gmail)"
        #expect(throws: ReplyError.self) { try AliasRelay(duck).verify(d, account: gmail) }
    }

    @Test func newMailFromAliasIsRelayed() throws {
        let d = Composer.fromAlias(duck, account: gmail, to: [Address(name: "Bob", email: "bob@example.com")], cc: [],
                                   subject: "hi", body: "yo")
        #expect(d.to == [Address(name: "Bob", email: "bob_at_example.com_someone@duck.com")])
        try AliasRelay(duck).verify(d, account: gmail)
    }

    @Test func aliasMatchIsCaseInsensitive() {
        var m = duckMessage()
        m.duckTo = "SOMEONE@duck.com"
        #expect(Composer.relay(for: m, aliases: [duck]) != nil)
    }

    @Test func plainGmailReplyIsUntouched() throws {
        let m = MessageRecord(account: gmail, id: "x", threadID: "t", from: Address(name: "Ann", email: "ann@example.com"),
                              to: [Address(email: gmail)], cc: [Address(email: "bo@example.com")], subject: "Re: plan",
                              messageID: "<x@example.com>")
        let d = try Composer.draft(.replyAll, thread: [m], account: gmail, aliases: [duck],
                                   me: Address(name: "Me", email: gmail))
        #expect(d.to.map(\.email) == ["ann@example.com"])
        #expect(d.cc.map(\.email) == ["bo@example.com"])
        #expect(d.subject == "Re: plan")
        #expect(d.from.name == "Me")
    }
}
