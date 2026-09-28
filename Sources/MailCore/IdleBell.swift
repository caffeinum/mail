import Foundation
import Network

/// IMAP IDLE on the inbox over XOAUTH2, used for nothing but its ring: any
/// untagged EXISTS / EXPUNGE / FETCH means gmail has news, and the sync pulls
/// history. Lives only while the app is open.
public final class IdleBell: @unchecked Sendable {
    let account: String
    let ring: () -> Void
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "post.idle")
    private var buffer = Data()
    private var tag = 0
    private var stopped = false
    private var backoff: TimeInterval = 2
    private var renew: DispatchWorkItem?
    private var debounce: DispatchWorkItem?
    private var waiting: [String: (String) -> Void] = [:]

    public init(account: String, ring: @escaping () -> Void) {
        self.account = account
        self.ring = ring
    }

    public func start() { queue.async { self.connect() } }

    public func stop() {
        queue.async {
            self.stopped = true
            self.renew?.cancel()
            self.conn?.cancel()
            self.conn = nil
        }
    }

    private func connect() {
        guard !stopped else { return }
        buffer = Data(); waiting = [:]
        let c = NWConnection(host: "imap.gmail.com", port: 993, using: .tls)
        conn = c
        c.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .failed(let e), .waiting(let e):
                log("\(self.account): imap \(e)")
                self.retry()
            case .cancelled: break
            default: break
            }
        }
        c.start(queue: queue)
        read()
        waiting["*"] = { [weak self] _ in self?.authenticate() }
    }

    private func retry() {
        guard !stopped else { return }
        conn?.cancel(); conn = nil
        let delay = backoff
        backoff = min(backoff * 2, 300)
        queue.asyncAfter(deadline: .now() + delay) { self.connect() }
    }

    private func send(_ line: String, done: @escaping (String) -> Void) {
        tag += 1
        let t = "p\(tag)"
        waiting[t] = done
        conn?.send(content: Data("\(t) \(line)\r\n".utf8), completion: .contentProcessed { _ in })
    }

    private func authenticate() {
        Task {
            guard let token = try? await TokenProvider.shared.accessToken(account) else { return retry() }
            let blob = Data("user=\(account)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
            queue.async {
                self.send("AUTHENTICATE XOAUTH2 \(blob)") { r in
                    guard r.contains(" OK") else { log("\(self.account): imap auth refused"); return self.retry() }
                    self.send("SELECT INBOX") { r in
                        guard r.contains(" OK") else { return self.retry() }
                        self.backoff = 2
                        self.idle()
                    }
                }
            }
        }
    }

    private func idle() {
        send("IDLE") { [weak self] _ in self?.idle() }
        // Servers drop an IDLE after ~29 minutes; renew well before.
        renew?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.conn?.send(content: Data("DONE\r\n".utf8), completion: .contentProcessed { _ in })
        }
        renew = w
        queue.asyncAfter(deadline: .now() + 20 * 60, execute: w)
    }

    private func read() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.lines() }
            if complete || error != nil { return self.retry() }
            self.read()
        }
    }

    private func lines() {
        while let r = buffer.range(of: Data("\r\n".utf8)) {
            let line = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("* OK"), let greet = waiting.removeValue(forKey: "*") { return greet(line) }
        if line.hasPrefix("* ") {
            let u = line.uppercased()
            if u.hasSuffix(" EXISTS") || u.hasSuffix(" EXPUNGE") || u.contains(" FETCH ") { doorbell() }
            return
        }
        if line.hasPrefix("+") { return }
        let t = String(line.prefix { $0 != " " })
        if let cb = waiting.removeValue(forKey: t) { cb(line) }
    }

    private func doorbell() {
        debounce?.cancel()
        let w = DispatchWorkItem { [ring] in ring() }
        debounce = w
        queue.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
}
