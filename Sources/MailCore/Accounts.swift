import Foundation

/// An address that forwards into a gmail account and should be shown as an
/// account of its own. Mail is recognised by the forwarder's header naming
/// the alias (DuckDuckGo: `Duck-Original-To`).
public struct AliasRule: Codable, Equatable, Hashable {
    public enum Kind: String, Codable { case duck }
    public var address: String
    public var label: String
    public var kind: Kind

    public init(address: String, label: String, kind: Kind = .duck) {
        self.address = address; self.label = label; self.kind = kind
    }
}

public struct AccountConfig: Codable, Equatable, Hashable {
    public var email: String
    public var label: String?
    public var aliases: [AliasRule]

    public init(email: String, label: String? = nil, aliases: [AliasRule] = []) {
        self.email = email; self.label = label; self.aliases = aliases
    }

    enum CodingKeys: String, CodingKey { case email, label, aliases }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decode(String.self, forKey: .email)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        aliases = try c.decodeIfPresent([AliasRule].self, forKey: .aliases) ?? []
    }
}

/// What the ui calls an account: a gmail account, or an alias shown apart.
public struct Mailbox: Equatable, Hashable, Identifiable {
    public enum Kind: Equatable, Hashable { case gmail, alias(AliasRule) }
    public let account: String
    public let kind: Kind
    public let title: String

    public var id: String {
        switch kind {
        case .gmail: return "gmail:\(account)"
        case .alias(let r): return "alias:\(account):\(r.address.lowercased())"
        }
    }

    public var alias: AliasRule? { if case .alias(let r) = kind { return r }; return nil }
}

public struct AccountsFile: Codable, Equatable {
    public var accounts: [AccountConfig]
    /// Remote writes (labels, filters, sends) stay off per account until the
    /// owner turns them on. Until then sends become drafts and label changes
    /// stay local.
    public var writesEnabled: [String]

    public init(accounts: [AccountConfig] = [], writesEnabled: [String] = []) {
        self.accounts = accounts; self.writesEnabled = writesEnabled
    }

    enum CodingKeys: String, CodingKey { case accounts, writesEnabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([AccountConfig].self, forKey: .accounts) ?? []
        writesEnabled = try c.decodeIfPresent([String].self, forKey: .writesEnabled) ?? []
    }

    /// Gmail accounts first, in file order, then every alias — so 1/2/3 are
    /// the real accounts before the virtual ones.
    public var mailboxes: [Mailbox] {
        let real = accounts.map { Mailbox(account: $0.email, kind: .gmail, title: $0.label ?? $0.email) }
        let virtual = accounts.flatMap { a in a.aliases.map { Mailbox(account: a.email, kind: .alias($0), title: $0.label) } }
        return real + virtual
    }

    public func writes(_ email: String) -> Bool { writesEnabled.contains(email.lowercased()) }

    public func aliases(for email: String) -> [AliasRule] {
        accounts.first { $0.email.lowercased() == email.lowercased() }?.aliases ?? []
    }
}

public enum Paths {
    public static let bundleID = "com.caffeinum.mail"

    public static var support: URL {
        if let o = ProcessInfo.processInfo.environment["POST_HOME"] { return URL(fileURLWithPath: o) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(bundleID)
    }

    public static var accounts: URL { support.appendingPathComponent("accounts.json") }
    public static var database: URL { support.appendingPathComponent("cache.sqlite") }
    public static var log: URL { support.appendingPathComponent("post.log") }

    public static func ensure() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
}

public enum AccountsStore {
    public static func load(from url: URL = Paths.accounts) throws -> AccountsFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return AccountsFile() }
        return try JSONDecoder().decode(AccountsFile.self, from: Data(contentsOf: url))
    }

    public static func save(_ f: AccountsFile, to url: URL = Paths.accounts) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(f).write(to: url, options: .atomic)
    }
}
