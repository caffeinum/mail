import Foundation

/// Sorting by Jev (TypeSafe AI's evaluation model, through Vercel AI
/// Gateway): each sender nobody has placed yet is a typed choice question
/// over inbox / notifications / feed / paper trail. It only sees the sender's
/// name, address and a few recent subjects and snippets — never bodies — and
/// every request asks for zero data retention. The hand-written Sorter
/// stays as the fallback when there's no key or no network.
public enum Jev {
    public static let keychainAccount = "vercel-ai-gateway"
    static let endpoint = URL(string: "https://ai-gateway.vercel.sh/v1/evaluate")!
    static let batch = 25

    public struct Sample: Equatable {
        public let email: String
        public let name: String
        public let lines: [String]
    }

    public struct Verdict: Equatable {
        public let category: Category
        public let confidence: Double
    }

    public enum Failure: Error, CustomStringConvertible {
        case noKey, http(Int, String), shape(String)
        public var description: String {
            switch self {
            case .noKey: return "no AI Gateway key in the keychain (service \(Keychain.service), account \(keychainAccount))"
            case .http(let c, let b): return "ai gateway \(c): \(b.prefix(300))"
            case .shape(let s): return "unexpected jev answer: \(s.prefix(300))"
            }
        }
    }

    static let criteria: [String: String] = [
        "inbox": "a real person writing to the user personally",
        "notify": "automated notices about the user's accounts: trials, alerts, sign-ins, security, deploys, things to act on",
        "feed": "newsletters, product announcements, come-back emails, promotions, event invitations",
        "paper": "receipts, payments, invoices, orders, shipping, bookings, bank transfers",
    ]

    public static var key: String? { Keychain.read(service: Keychain.service, account: keychainAccount) }

    /// The request body for a batch — kept separate so it can be tested.
    static func body(_ samples: [Sample]) -> [String: Any] {
        var state = "Email senders the user has not sorted yet. Each: id, sender, then recent subjects and previews.\n"
        var questions: [String: Any] = [:]
        for (i, s) in samples.enumerated() {
            let id = "s\(i)"
            state += "[\(id)] \(s.name.isEmpty ? s.email : "\(s.name) <\(s.email)>"): " + s.lines.joined(separator: " | ") + "\n"
            questions[id] = ["type": "choice", "instructions": "Where should mail from sender \(id) go?", "criteria": criteria]
        }
        return ["model": "typesafe-ai/jev", "state": state, "questions": questions,
                "providerOptions": ["gateway": ["zeroDataRetention": true]]]
    }

    public static func classify(_ samples: [Sample]) async throws -> [String: Verdict] {
        guard let key else { throw Failure.noKey }
        var out: [String: Verdict] = [:]
        for start in stride(from: 0, to: samples.count, by: batch) {
            let part = Array(samples[start..<min(start + batch, samples.count)])
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body(part))
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw Failure.http(code, String(decoding: data, as: UTF8.self)) }
            for (email, v) in try parse(data, part) { out[email] = v }
        }
        return out
    }

    static func parse(_ data: Data, _ part: [Sample]) throws -> [String: Verdict] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any] else { throw Failure.shape(String(decoding: data, as: UTF8.self)) }
        var out: [String: Verdict] = [:]
        for (i, s) in part.enumerated() {
            guard let a = answers["s\(i)"] as? [String: Any], let choice = a["choice"] as? String,
                  let c = Category(rawValue: choice) else { continue }
            out[s.email] = Verdict(category: c, confidence: (a["confidence"] as? Double) ?? 0)
        }
        return out
    }
}
