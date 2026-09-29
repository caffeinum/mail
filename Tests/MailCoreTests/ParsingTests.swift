import Testing
import Foundation
@testable import MailCore

@Suite struct Parsing {
    @Test func addressLists() {
        let a = Address.parseList(#""Doe, Jane" <jane@x.com>, bob@y.com, Ann <ann@z.org>"#)
        #expect(a == [Address(name: "Doe, Jane", email: "jane@x.com"), Address(email: "bob@y.com"), Address(name: "Ann", email: "ann@z.org")])
    }

    @Test func encodedWords() {
        #expect(MIME.decodeHeader("=?UTF-8?B?0J/RgNC40LLQtdGC?=") == "Привет")
        #expect(MIME.decodeHeader("=?iso-8859-1?Q?caf=E9_au_lait?=") == "café au lait")
        #expect(MIME.decodeHeader("=?UTF-8?Q?a?= =?UTF-8?Q?b?=") == "ab")
    }

    @Test func gmailPayload() throws {
        let html = MIME.base64URLEncode(Data("<p>Hi <b>there</b></p>".utf8))
        let text = MIME.base64URLEncode(Data("Hi there".utf8))
        let json = """
        {"id":"m","threadId":"t","labelIds":["INBOX","UNREAD"],"snippet":"Hi &amp; there","historyId":"42","internalDate":"1700000000000",
         "payload":{"mimeType":"multipart/alternative","headers":[
            {"name":"From","value":"=?UTF-8?Q?J=C3=BCrgen?= <j@x.de>"},{"name":"Subject","value":"Hello"},
            {"name":"List-Unsubscribe","value":"<mailto:u@x.de>"}],
          "parts":[{"mimeType":"text/plain","body":{"data":"\(text)"}},{"mimeType":"text/html","body":{"data":"\(html)"}}]}}
        """
        let m = MessageRecord(account: "a@gmail.com", gmail: try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8)))
        #expect(m.from == Address(name: "Jürgen", email: "j@x.de"))
        #expect(m.bodyText == "Hi there")
        #expect(m.bodyHTML == "<p>Hi <b>there</b></p>")
        #expect(m.snippet == "Hi & there")
        #expect(m.isUnread && m.hasBody && m.historyID == 42)
    }

    @Test func outgoingMime() {
        let raw = MIME.build(OutgoingMessage(from: Address(name: "Ålex", email: "a@x.com"), to: [Address(email: "b@y.com")],
                                             subject: "héllo", body: "line1\nline2", inReplyTo: "<p@x>", references: ["<o@x>", "<p@x>"]))
        #expect(raw.contains("From: =?UTF-8?B?"))
        #expect(raw.contains("Subject: =?UTF-8?B?"))
        #expect(raw.contains("In-Reply-To: <p@x>\r\nReferences: <o@x> <p@x>"))
        let body = raw.components(separatedBy: "\r\n\r\n")[1].replacingOccurrences(of: "\r\n", with: "")
        #expect(String(decoding: Data(base64Encoded: body)!, as: UTF8.self) == "line1\r\nline2")
    }

    @Test func ftsQuery() {
        #expect(Store.ftsQuery("inv acme") == "\"inv\"* \"acme\"*")
        #expect(Store.ftsQuery("  \"drop\" (tables) ") == "\"drop\"* \"tables\"*")
        #expect(Store.ftsQuery("") == "")
    }
}

@Suite struct ForwardedTo {
    @Test func aliasIsPickedOutOfTheHeader() {
        #expect(MessageRecord.forwardedTo("Oleksii Bykhun <ALEKSB@duck.com>") == "aleksb@duck.com")
        #expect(MessageRecord.forwardedTo("Herman <h@x.com>, aleksb@duck.com") == "aleksb@duck.com")
        #expect(MessageRecord.forwardedTo("aleksb@duck.com") == "aleksb@duck.com")
    }
}

@Suite struct RelayIsNotAnAlias {
    @Test func echoOfOurReplyPointsAtTheAlias() {
        #expect(MessageRecord.forwardedTo("Anna <anna_at_h1b.biz_aleksb@duck.com>") == "aleksb@duck.com")
        #expect(MessageRecord.isRelayForm("support_at_ghost.org_aleksb@duck.com"))
        #expect(!MessageRecord.isRelayForm("aleksb@duck.com"))
    }

    @Test func relayAddressesAreNeverAdopted() {
        var f = AccountsFile(accounts: [AccountConfig(email: "a@gmail.com")])
        #expect(f.adopt(["a@gmail.com": ["anna_at_h1b.biz_aleksb@duck.com"]]).isEmpty)
        #expect(f.adopt(["a@gmail.com": ["aleksb@duck.com"]]) == ["aleksb@duck.com"])
    }
}

@Suite struct JevRequests {
    @Test func bodyAsksOneChoicePerSenderWithZeroRetention() throws {
        let b = Jev.body([Jev.Sample(email: "a@x.com", name: "Ann", lines: ["\"hi\""]), Jev.Sample(email: "r@stripe.com", name: "", lines: ["\"receipt\""])])
        let q = b["questions"] as! [String: Any]
        #expect(Set(q.keys) == ["s0", "s1"])
        #expect(((q["s0"] as! [String: Any])["criteria"] as! [String: String]).keys.sorted() == ["feed", "inbox", "notify", "paper"])
        #expect((b["state"] as! String).contains("[s1] r@stripe.com"))
        #expect(((b["providerOptions"] as! [String: Any])["gateway"] as! [String: Any])["zeroDataRetention"] as! Bool)
    }

    @Test func answersMapBackToSenders() throws {
        let data = Data(#"{"answers":{"s0":{"type":"choice","choice":"inbox","confidence":0.9},"s1":{"type":"choice","choice":"paper","confidence":1}}}"#.utf8)
        let v = try Jev.parse(data, [Jev.Sample(email: "a@x.com", name: "", lines: []), Jev.Sample(email: "r@stripe.com", name: "", lines: [])])
        #expect(v["a@x.com"] == Jev.Verdict(category: .inbox, confidence: 0.9))
        #expect(v["r@stripe.com"]?.category == .paper)
    }

    @Test func onlyJevSuggests() throws {
        let s = try tempStore()
        try s.upsert([msg("1", thread: "a", from: "news@x.com", subject: "weekly digest", list: true)])
        #expect(s.thread(account: gmail, id: "a")?.category == nil)
        try s.saveVerdicts(gmail, ["news@x.com": Jev.Verdict(category: .notify, confidence: 1)])
        #expect(s.thread(account: gmail, id: "a")?.category == .notify)
        #expect(s.sendersToJudge(gmail).isEmpty)
    }
}

@Suite struct ListNames {
    @Test func listsAreNamedSensibly() {
        func l(_ raw: String) -> String? { MessageRecord(account: "a", id: "1", threadID: "t", listID: raw).list?.name }
        #expect(l("<worldwide.ctolunches.groups.io>") == "ctolunches")
        #expect(l("<bayarealesswrong.googlegroups.com>") == "bayarealesswrong")
        #expect(l("team2027/sanity-cli <sanity-cli.team2027.github.com>") == "team2027/sanity-cli")
        #expect(l("1025435519 <Huel>") == "huel")
        #expect(l("<98b5@google.com>") == nil)
    }
}
