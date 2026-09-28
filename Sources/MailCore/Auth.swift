import Foundation
import CryptoKit
import Network

public enum AuthError: Error, CustomStringConvertible {
    case noClient(String)
    case noToken(String)
    case refresh(String, Int, String)
    case keychain(String)
    case consent(String)

    public var description: String {
        switch self {
        case .noClient(let p): return "no oauth client at \(p) (gog's credentials.json)"
        case .noToken(let e): return "no refresh token for \(e): not in Reply's keychain item nor gog's. add it in the app or run `mailctl auth \(e)`"
        case .refresh(let e, let code, let body): return "token refresh for \(e) failed: http \(code) \(body)"
        case .keychain(let m): return "keychain: \(m)"
        case .consent(let m): return "consent: \(m)"
        }
    }
}

public struct OAuthClient: Codable {
    public let clientID: String
    public let clientSecret: String

    enum CodingKeys: String, CodingKey { case clientID = "client_id", clientSecret = "client_secret" }

    public static var gogPath: URL {
        if let p = ProcessInfo.processInfo.environment["POST_OAUTH_CLIENT"] { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/gogcli/credentials.json")
    }

    public static func load(_ url: URL = gogPath) throws -> OAuthClient {
        guard let d = try? Data(contentsOf: url) else { throw AuthError.noClient(url.path) }
        return try JSONDecoder().decode(OAuthClient.self, from: d)
    }
}

public struct StoredToken: Codable {
    public var refreshToken: String
    public var scopes: [String]

    enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token", scopes }
}

public enum Scope {
    public static let full = "https://mail.google.com/"
    public static let modify = "https://www.googleapis.com/auth/gmail.modify"
    public static let settings = "https://www.googleapis.com/auth/gmail.settings.basic"
    public static let requested = [full, settings, "email"]
}

/// Refresh tokens live in the login keychain. Post's own item wins; gog's is
/// the fallback, so an account gog already authorised works with no consent.
/// Reads and writes go through /usr/bin/security with secrets on stdin, never
/// argv, and items are created readable by any app so a rebuilt, re-signed
/// binary isn't met with an access prompt.
public enum Keychain {
    public static let service = Paths.bundleID
    public static let gogService = "gogcli"

    static func security(_ args: [String], stdin: String? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        do { try p.run() } catch { return (-1, "") }
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func read(service: String, account: String) -> String? {
        let (rc, out) = security(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard rc == 0 else { return nil }
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    public static func token(for email: String) -> (StoredToken, source: String)? {
        if let raw = read(service: service, account: "refresh:\(email.lowercased())") ?? read(service: Paths.legacyID, account: "refresh:\(email.lowercased())"),
           let d = Data(base64Encoded: raw), let t = try? JSONDecoder().decode(StoredToken.self, from: d) {
            return (t, "reply")
        }
        for acct in ["token:default:\(email)", "token:\(email)"] {
            if let raw = read(service: gogService, account: acct),
               let t = try? JSONDecoder().decode(StoredToken.self, from: Data(raw.utf8)) {
                return (t, "gog")
            }
        }
        return nil
    }

    public static func store(_ t: StoredToken, for email: String) throws {
        let b64 = try JSONEncoder().encode(t).base64EncodedString()
        let cmd = "add-generic-password -U -A -s \(service) -a refresh:\(email.lowercased()) -l \"Reply (gmail)\" -w \(b64)\n"
        let (rc, _) = security(["-i"], stdin: cmd)
        guard rc == 0, read(service: service, account: "refresh:\(email.lowercased())") == b64 else {
            throw AuthError.keychain("could not store token for \(email)")
        }
    }

    public static func remove(_ email: String) {
        _ = security(["delete-generic-password", "-s", service, "-a", "refresh:\(email.lowercased())"])
    }

    /// Accounts gog has a token for — names only, no secrets are read.
    public static func gogAccounts() -> [String] {
        let (rc, out) = security(["dump-keychain"])
        guard rc == 0 else { return [] }
        var found: [String] = []
        var inGog = false
        var acct: String?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("keychain:") {
                if inGog, let a = acct { found.append(a) }
                inGog = false; acct = nil
            } else if line.contains("\"svce\"<blob>=\"\(gogService)\"") {
                inGog = true
            } else if let r = line.range(of: "\"acct\"<blob>=\"token:") {
                let rest = line[r.upperBound...].dropLast()
                acct = String(rest.split(separator: ":").last ?? "")
            }
        }
        if inGog, let a = acct { found.append(a) }
        var seen = Set<String>()
        return found.filter { $0.contains("@") && seen.insert($0.lowercased()).inserted }
    }
}

public actor TokenProvider {
    public static let shared = TokenProvider()

    private var access: [String: (token: String, expires: Date)] = [:]
    private var granted: [String: Set<String>] = [:]
    private var client: OAuthClient?

    public init() {}

    private func oauthClient() throws -> OAuthClient {
        if let client { return client }
        let c = try OAuthClient.load()
        client = c
        return c
    }

    public func accessToken(_ email: String) async throws -> String {
        if let a = access[email], a.expires > Date().addingTimeInterval(60) { return a.token }
        guard let (stored, _) = Keychain.token(for: email) else { throw AuthError.noToken(email) }
        let c = try oauthClient()
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["client_id": c.clientID, "client_secret": c.clientSecret,
                             "refresh_token": stored.refreshToken, "grant_type": "refresh_token"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AuthError.refresh(email, code, String(decoding: data, as: UTF8.self)) }
        struct R: Decodable { let access_token: String; let expires_in: Int; let scope: String? }
        let r = try JSONDecoder().decode(R.self, from: data)
        access[email] = (r.access_token, Date().addingTimeInterval(TimeInterval(r.expires_in)))
        granted[email] = Set((r.scope ?? stored.scopes.joined(separator: " ")).split(separator: " ").map(String.init))
        return r.access_token
    }

    public func scopes(_ email: String) async throws -> Set<String> {
        _ = try await accessToken(email)
        return granted[email] ?? []
    }

    /// IMAP needs the full mail scope; gog's tokens stop at gmail.modify.
    public func canIMAP(_ email: String) async -> Bool {
        (try? await scopes(email).contains(Scope.full)) ?? false
    }

    public func forget(_ email: String) { access[email] = nil; granted[email] = nil }
}

func form(_ p: [String: String]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return Data(p.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
        .joined(separator: "&").utf8)
}

/// Installed-app consent with the same oauth client gog uses: a loopback
/// listener catches the redirect, PKCE guards the code.
public enum Consent {
    public static func run(email: String?, open: (URL) -> Void) async throws -> (email: String, token: StoredToken) {
        let client = try OAuthClient.load()
        let verifier = MIME.base64URLEncode(Data((0..<48).map { _ in UInt8.random(in: 0...255) }))
        let challenge = MIME.base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = UUID().uuidString

        let (port, codeTask) = try await listen(state: state)
        let redirect = "http://127.0.0.1:\(port)"
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: client.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Scope.requested.joined(separator: " ")),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ] + (email.map { [URLQueryItem(name: "login_hint", value: $0)] } ?? [])
        open(comps.url!)
        let code = try await codeTask.value

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["client_id": client.clientID, "client_secret": client.clientSecret, "code": code,
                             "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": redirect])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.consent("code exchange failed: \(String(decoding: data, as: UTF8.self))")
        }
        struct R: Decodable { let access_token: String; let refresh_token: String?; let scope: String }
        let r = try JSONDecoder().decode(R.self, from: data)
        guard let refresh = r.refresh_token else { throw AuthError.consent("google returned no refresh token") }

        var preq = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        preq.setValue("Bearer \(r.access_token)", forHTTPHeaderField: "Authorization")
        let (pdata, _) = try await URLSession.shared.data(for: preq)
        struct P: Decodable { let emailAddress: String }
        let who = try JSONDecoder().decode(P.self, from: pdata).emailAddress
        let token = StoredToken(refreshToken: refresh, scopes: r.scope.split(separator: " ").map(String.init))
        try Keychain.store(token, for: who)
        await TokenProvider.shared.forget(who)
        return (who, token)
    }

    private static func listen(state: String) async throws -> (UInt16, Task<String, Error>) {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "post.consent")
        let ready = AsyncStream<UInt16?>.makeStream()
        let result = AsyncStream<Result<String, Error>>.makeStream()

        listener.stateUpdateHandler = { s in
            switch s {
            case .ready: ready.continuation.yield(listener.port?.rawValue)
            case .failed: ready.continuation.yield(nil)
            default: break
            }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let req = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let line = req.split(separator: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let items = URLComponents(string: "http://x\(path)")?.queryItems ?? []
                let get = { (n: String) in items.first { $0.name == n }?.value }
                let ok = get("code") != nil && get("state") == state
                let page = ok ? "Signed in. You can close this tab and go back to Reply."
                              : "Sign-in failed: \(get("error") ?? "no code"). Close this tab and try again."
                let body = "<!doctype html><meta charset=utf-8><body style=\"font:15px -apple-system;padding:40px\">\(page)</body>"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
                guard path != "/favicon.ico" else { return }
                if ok, let code = get("code") { result.continuation.yield(.success(code)) }
                else { result.continuation.yield(.failure(AuthError.consent(get("error") ?? "no code in redirect"))) }
            }
        }
        listener.start(queue: queue)
        var port: UInt16?
        for await p in ready.stream { port = p; break }
        guard let port else { throw AuthError.consent("could not open a loopback port") }
        let task = Task<String, Error> {
            defer { listener.cancel() }
            for await r in result.stream { return try r.get() }
            throw AuthError.consent("listener closed")
        }
        return (port, task)
    }
}
