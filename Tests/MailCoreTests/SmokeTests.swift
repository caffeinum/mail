import Testing
@testable import MailCore

@Test func version() { #expect(MailCore.version == "0.1.0") }
