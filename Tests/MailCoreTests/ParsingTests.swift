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
        #expect(Sorter.guess(m) == .feed)
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

    @Test func sorting() {
        func m(_ from: String, _ subject: String, _ labels: [String] = [], list: Bool = false) -> MessageRecord {
            MessageRecord(account: "a", id: "1", threadID: "t", labels: labels, from: Address(email: from), subject: subject,
                          listUnsubscribe: list ? "<x>" : nil)
        }
        #expect(Sorter.guess(m("noreply@shop.com", "Your order has shipped", ["CATEGORY_UPDATES"])) == .paper)
        #expect(Sorter.guess(m("receipts@stripe.com", "Your receipt from Acme")) == .paper)
        #expect(Sorter.guess(m("news@substack.com", "This week in AI", list: true)) == .feed)
        #expect(Sorter.guess(m("deals@shop.com", "50% off", ["CATEGORY_PROMOTIONS"])) == .feed)
        #expect(Sorter.guess(m("friend@gmail.com", "dinner? I paid last time")) == .inbox)
        #expect(Sorter.guess(m("notifications@vercel.com", "Preview deployment failed", ["CATEGORY_UPDATES"])) == .paper)
        #expect(Sorter.guess(m("security@github.com", "New sign-in to your account", ["CATEGORY_UPDATES"])) == .paper)
        #expect(Sorter.guess(m("billing@lime.com", "Update your payment method", ["CATEGORY_UPDATES"])) == .inbox)
        #expect(Sorter.guess(m("hello@thecommons.org", "Public Events Bulletin", ["CATEGORY_UPDATES"], list: true)) == .feed)
        #expect(Sorter.isRobot(m("notifications@vercel.com", "x")) && !Sorter.isRobot(m("friend@gmail.com", "x")))
        let store = [m("orders@shop.com", "Your order has shipped"), m("orders@shop.com", "Big sale", ["CATEGORY_PROMOTIONS"]),
                     m("orders@shop.com", "New arrivals", ["CATEGORY_PROMOTIONS"])]
        #expect(Sorter.category(of: store) == .paper)
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
