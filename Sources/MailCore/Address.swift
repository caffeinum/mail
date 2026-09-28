import Foundation

public struct Address: Equatable, Hashable, Codable {
    public var name: String
    public var email: String

    public init(name: String = "", email: String) {
        self.name = name
        self.email = email
    }

    public var display: String { name.isEmpty ? email : name }

    /// RFC 5322 form, with the name quoted or encoded when it needs to be.
    public var header: String {
        guard !name.isEmpty else { return email }
        return "\(MIME.encodeHeaderWord(quotedIfNeeded(name))) <\(email)>"
    }

    private func quotedIfNeeded(_ s: String) -> String {
        let special = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
        guard s.rangeOfCharacter(from: special) != nil else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public var normalized: String { email.lowercased() }

    public static func parse(_ s: String) -> Address? { parseList(s).first }

    /// Splits "A <a@x>, \"B, Jr\" <b@y>, c@z" on top-level commas.
    public static func parseList(_ raw: String) -> [Address] {
        let s = MIME.decodeHeader(raw)
        var parts: [String] = []
        var cur = ""
        var inQuote = false, depth = 0, escaped = false
        for ch in s {
            if escaped { cur.append(ch); escaped = false; continue }
            switch ch {
            case "\\" where inQuote: escaped = true; cur.append(ch)
            case "\"": inQuote.toggle(); cur.append(ch)
            case "<" where !inQuote: depth += 1; cur.append(ch)
            case ">" where !inQuote: depth = max(0, depth - 1); cur.append(ch)
            case "," where !inQuote && depth == 0: parts.append(cur); cur = ""
            default: cur.append(ch)
            }
        }
        parts.append(cur)
        return parts.compactMap(parseOne)
    }

    private static func parseOne(_ part: String) -> Address? {
        let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        if let lt = p.lastIndex(of: "<"), let gt = p.lastIndex(of: ">"), lt < gt {
            let email = String(p[p.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            var name = String(p[..<lt]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            guard email.contains("@") else { return nil }
            return Address(name: name, email: email)
        }
        guard p.contains("@") else { return nil }
        return Address(email: p)
    }
}

extension Array where Element == Address {
    public var header: String { map(\.header).joined(separator: ", ") }
}
