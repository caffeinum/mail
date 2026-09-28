import Foundation

public enum GmailError: Error, CustomStringConvertible {
    case http(Int, String, String)
    case historyExpired

    public var description: String {
        switch self {
        case .http(let code, let path, let body): return "gmail \(code) \(path): \(body.prefix(300))"
        case .historyExpired: return "gmail history id too old; full resync needed"
        }
    }
}

public struct GmailHeader: Codable { public let name: String; public let value: String }

public struct GmailBody: Codable {
    public let size: Int?
    public let data: String?
    public let attachmentId: String?
}

public struct GmailPart: Codable {
    public let partId: String?
    public let mimeType: String?
    public let filename: String?
    public let headers: [GmailHeader]?
    public let body: GmailBody?
    public let parts: [GmailPart]?
}

public struct GmailMessage: Codable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]?
    public let snippet: String?
    public let historyId: String?
    public let internalDate: String?
    public let payload: GmailPart?
}

public struct GmailThread: Codable {
    public let id: String
    public let historyId: String?
    public let messages: [GmailMessage]?
}

public struct GmailLabel: Codable, Equatable {
    public let id: String
    public let name: String
    public let type: String?
}

public struct HistoryRecord: Codable {
    public struct Item: Codable { public let message: GmailMessage; public let labelIds: [String]? }
    public let id: String
    public let messagesAdded: [Item]?
    public let messagesDeleted: [Item]?
    public let labelsAdded: [Item]?
    public let labelsRemoved: [Item]?
}

/// Bounds how many requests run at once — gmail allows ~250 quota units a
/// second per user and a metadata get costs 5 (threads.get 10).
actor Gate {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { free = n }
    func enter() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func leave() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}

public final class Gmail: @unchecked Sendable {
    public let account: String
    private let tokens: TokenProvider
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()
    private let gate = Gate(12)
    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me/"

    public init(account: String, tokens: TokenProvider = .shared) {
        self.account = account
        self.tokens = tokens
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        await gate.enter()
        defer { Task { await gate.leave() } }
        var comps = URLComponents(string: Self.base + path)!
        if !query.isEmpty { comps.queryItems = query }
        var attempt = 0
        while true {
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue("Bearer \(try await tokens.accessToken(account))", forHTTPHeaderField: "Authorization")
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { return data }
            if code == 401, attempt == 0 { await tokens.forget(account); attempt += 1; continue }
            if (code == 429 || code >= 500 || (code == 403 && String(decoding: data, as: UTF8.self).contains("rateLimitExceeded"))), attempt < 5 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 250_000_000))
                continue
            }
            throw GmailError.http(code, path, String(decoding: data, as: UTF8.self))
        }
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request("GET", path, query: query))
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        let d = try await request("POST", path, body: try JSONSerialization.data(withJSONObject: body))
        return try JSONDecoder().decode(T.self, from: d.isEmpty ? Data("{}".utf8) : d)
    }

    // MARK: reads

    public struct Profile: Codable { public let emailAddress: String; public let historyId: String; public let messagesTotal: Int? }
    public func profile() async throws -> Profile { try await get("profile") }

    public struct ThreadRef: Codable { public let id: String; public let snippet: String?; public let historyId: String? }
    public func threads(query: String? = nil, labels: [String] = [], max: Int = 100, pageToken: String? = nil) async throws -> (refs: [ThreadRef], next: String?) {
        var q: [URLQueryItem] = [.init(name: "maxResults", value: String(max))]
        if let query { q.append(.init(name: "q", value: query)) }
        for l in labels { q.append(.init(name: "labelIds", value: l)) }
        if let pageToken { q.append(.init(name: "pageToken", value: pageToken)) }
        struct R: Decodable { let threads: [ThreadRef]?; let nextPageToken: String? }
        let r: R = try await get("threads", q)
        return (r.threads ?? [], r.nextPageToken)
    }

    public static let metadataHeaders = ["From", "To", "Cc", "Reply-To", "Subject", "Date", "Message-ID", "In-Reply-To",
                                         "References", "List-Unsubscribe", "List-Id", "Precedence", "Auto-Submitted",
                                         "Duck-Original-From", "Duck-Original-To", "Duck-Original-Reply-To"]

    public enum Format: String { case metadata, full, minimal }

    public func thread(_ id: String, format: Format) async throws -> GmailThread {
        var q = [URLQueryItem(name: "format", value: format.rawValue)]
        if format == .metadata { q += Self.metadataHeaders.map { .init(name: "metadataHeaders", value: $0) } }
        return try await get("threads/\(id)", q)
    }

    public func message(_ id: String, format: Format) async throws -> GmailMessage {
        var q = [URLQueryItem(name: "format", value: format.rawValue)]
        if format == .metadata { q += Self.metadataHeaders.map { .init(name: "metadataHeaders", value: $0) } }
        return try await get("messages/\(id)", q)
    }

    public func history(since start: String) async throws -> (records: [HistoryRecord], historyId: String) {
        var all: [HistoryRecord] = []
        var page: String?
        var latest = start
        repeat {
            var q: [URLQueryItem] = [.init(name: "startHistoryId", value: start), .init(name: "maxResults", value: "500")]
            if let page { q.append(.init(name: "pageToken", value: page)) }
            struct R: Decodable { let history: [HistoryRecord]?; let nextPageToken: String?; let historyId: String }
            let r: R
            do { r = try await get("history", q) } catch GmailError.http(404, _, _) { throw GmailError.historyExpired }
            all += r.history ?? []
            page = r.nextPageToken
            latest = r.historyId
        } while page != nil
        return (all, latest)
    }

    public func labels() async throws -> [GmailLabel] {
        struct R: Decodable { let labels: [GmailLabel]? }
        let r: R = try await get("labels")
        return r.labels ?? []
    }

    // MARK: writes

    public func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        let _: GmailThread = try await post("threads/\(id)/modify", ["addLabelIds": add, "removeLabelIds": remove])
    }

    public func trashThread(_ id: String) async throws { let _: GmailThread = try await post("threads/\(id)/trash", [:]) }
    public func untrashThread(_ id: String) async throws { let _: GmailThread = try await post("threads/\(id)/untrash", [:]) }

    public func send(raw: String, threadID: String?) async throws -> GmailMessage {
        var b: [String: Any] = ["raw": MIME.base64URLEncode(Data(raw.utf8))]
        if let threadID { b["threadId"] = threadID }
        return try await post("messages/send", b)
    }

    public struct Draft: Codable { public let id: String; public let message: GmailMessage? }
    public func createDraft(raw: String, threadID: String?) async throws -> Draft {
        var m: [String: Any] = ["raw": MIME.base64URLEncode(Data(raw.utf8))]
        if let threadID { m["threadId"] = threadID }
        return try await post("drafts", ["message": m])
    }

    public func deleteDraft(_ id: String) async throws { _ = try await request("DELETE", "drafts/\(id)") }

    public func createLabel(_ name: String) async throws -> GmailLabel {
        try await post("labels", ["name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"])
    }

    public struct Filter: Codable { public let id: String }
    public func createFilter(from: String, add: [String], remove: [String]) async throws -> Filter {
        try await post("settings/filters", ["criteria": ["from": from], "action": ["addLabelIds": add, "removeLabelIds": remove]])
    }

    public func deleteFilter(_ id: String) async throws { _ = try await request("DELETE", "settings/filters/\(id)") }
}
