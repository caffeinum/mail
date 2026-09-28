import Foundation

public enum MIME {
    // MARK: headers

    /// Decodes RFC 2047 encoded words (=?utf-8?B?...?= / =?utf-8?Q?...?=).
    public static func decodeHeader(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        var prevWasWord = false
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            // whitespace between two adjacent encoded words is dropped
            if !(prevWasWord && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { out += gap }
            let charset = ns.substring(with: m.range(at: 1))
            let enc = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))
            let data: Data?
            if enc == "B" {
                data = Data(base64Encoded: padBase64(text))
            } else {
                data = decodeQuotedPrintable(text.replacingOccurrences(of: "_", with: " "), header: true)
            }
            if let data, let decoded = String(data: data, encoding: encoding(charset)) ?? String(data: data, encoding: .isoLatin1) {
                out += decoded
            } else {
                out += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
            prevWasWord = true
        }
        out += ns.substring(from: last)
        return out
    }

    public static func encodeHeaderWord(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { !$0.isASCII }) else { return s }
        return "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    static func encoding(_ charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8", "us-ascii", "ascii": return .utf8
        case "iso-8859-1", "latin1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        case "iso-8859-2": return .isoLatin2
        case "windows-1251": return .windowsCP1251
        case "koi8-r": return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))
        case "shift_jis": return .shiftJIS
        case "iso-2022-jp": return .iso2022JP
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf == kCFStringEncodingInvalidId { return .utf8 }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    // MARK: transfer encodings

    public static func padBase64(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t = t.filter { !$0.isWhitespace }
        let r = t.count % 4
        if r > 0 { t += String(repeating: "=", count: 4 - r) }
        return t
    }

    public static func base64URLDecode(_ s: String) -> Data? { Data(base64Encoded: padBase64(s)) }

    public static func base64URLEncode(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeQuotedPrintable(_ s: String, header: Bool = false) -> Data {
        var out = Data()
        let bytes = Array(s.utf8)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: return b - 48
            case 65...70: return b - 55
            case 97...102: return b - 87
            default: return nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == 61 /* = */ {
                if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                    out.append(h << 4 | l); i += 3; continue
                }
                // soft line break
                if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                if i + 1 == bytes.count { i += 1; continue }
            }
            out.append(b); i += 1
        }
        return out
    }

    // MARK: outgoing

    /// A plain-text UTF-8 message, base64 bodied, ready for users.messages.send.
    public static func build(_ d: OutgoingMessage, date: Date = Date(), messageID: String? = nil) -> String {
        var h: [(String, String)] = []
        h.append(("From", d.from.header))
        if !d.to.isEmpty { h.append(("To", d.to.header)) }
        if !d.cc.isEmpty { h.append(("Cc", d.cc.header)) }
        if !d.bcc.isEmpty { h.append(("Bcc", d.bcc.header)) }
        h.append(("Subject", encodeHeaderWord(d.subject)))
        h.append(("Date", rfc2822(date)))
        if let messageID { h.append(("Message-ID", messageID)) }
        if let r = d.inReplyTo { h.append(("In-Reply-To", r)) }
        if !d.references.isEmpty { h.append(("References", d.references.joined(separator: " "))) }
        h.append(("MIME-Version", "1.0"))
        h.append(("Content-Type", "text/plain; charset=UTF-8"))
        h.append(("Content-Transfer-Encoding", "base64"))
        let body = Data(d.body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
            .base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return h.map { "\($0.0): \($0.1)" }.joined(separator: "\r\n") + "\r\n\r\n" + body + "\r\n"
    }

    static func rfc2822(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: d)
    }
}

public struct OutgoingMessage: Codable, Equatable {
    public var from: Address
    public var to: [Address]
    public var cc: [Address]
    public var bcc: [Address]
    public var subject: String
    public var body: String
    public var inReplyTo: String?
    public var references: [String]
    public var threadID: String?

    public init(from: Address, to: [Address], cc: [Address] = [], bcc: [Address] = [], subject: String, body: String,
                inReplyTo: String? = nil, references: [String] = [], threadID: String? = nil) {
        self.from = from; self.to = to; self.cc = cc; self.bcc = bcc
        self.subject = subject; self.body = body
        self.inReplyTo = inReplyTo; self.references = references; self.threadID = threadID
    }

    public var allRecipients: [Address] { to + cc + bcc }
}
