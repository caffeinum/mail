import Foundation
import MailCore
import CoreGraphics

// A terminal handle on the same cache and sync the app uses: for trying the
// engine against real accounts (read-only unless writes are on) and for
// measuring it.

func usage() -> Never {
    print("""
    mailctl accounts                         list configured accounts and mailboxes
    mailctl accounts gog                     list accounts gog has tokens for
    mailctl accounts add <email> [label]     add a gmail account
    mailctl accounts remove <email>          remove an account and its cache
    mailctl alias <email> <address> [label]  show mail forwarded from <address> as its own account
    mailctl auth [email]                     sign in with google (full mail scope, for imap push)
    mailctl scopes <email>                   what the stored token may do
    mailctl sync [email]                     pull changes now
    mailctl list <n> [inbox|feed|paper|new]  first rows of mailbox n (1-based), with timing
    mailctl search <n> <words…>              full-text search in mailbox n
    mailctl show <email> <thread>            messages of a thread
    mailctl bodies <n> [view]                prefetch bodies for the top 50 threads
    mailctl outbox                           queued and recent changes
    mailctl idle <email>                     watch the imap doorbell for 2 minutes
    mailctl launchbench <Post.app> [runs]    time from spawn until the window is on screen, seen from outside
    """)
    exit(2)
}

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data("mailctl: \(s)\n".utf8)); exit(1) }

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
args.removeFirst()

try Paths.ensure()
var config = try AccountsStore.load()
let store = try Store(path: Paths.database.path, config: config)

func mailbox(_ s: String?) -> Mailbox {
    let boxes = config.mailboxes
    guard let s, let n = Int(s), n >= 1, n <= boxes.count else {
        fail("mailbox is 1…\(boxes.count): " + boxes.enumerated().map { "\($0.offset + 1)=\($0.element.title)" }.joined(separator: " "))
    }
    return boxes[n - 1]
}

func ms(_ t: DispatchTime) -> String { String(format: "%.2fms", Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6) }

func row(_ t: ThreadSummary) -> String {
    let d = Date(timeIntervalSince1970: TimeInterval(t.date) / 1000)
    let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"
    return "\(t.unread ? "●" : " ") \(f.string(from: d))  \(t.sender.prefix(24).padding(toLength: 24, withPad: " ", startingAt: 0))  \(t.subject.prefix(60))  [\(t.id)]"
}

switch cmd {
case "accounts":
    switch args.first {
    case nil:
        for (i, b) in config.mailboxes.enumerated() {
            let w = config.writes(b.account) ? "writes on" : "read-only"
            print("\(i + 1). \(b.title)  (\(b.id))  \(w)")
        }
        if config.accounts.isEmpty { print("no accounts; `mailctl accounts gog` then `mailctl accounts add <email>`") }
    case "gog":
        Keychain.gogAccounts().forEach { print($0) }
    case "add":
        guard args.count >= 2 else { usage() }
        let email = args[1]
        guard !config.accounts.contains(where: { $0.email.lowercased() == email.lowercased() }) else { fail("\(email) is already here") }
        guard let (_, src) = Keychain.token(for: email) else { fail("no token for \(email): run `mailctl auth \(email)`") }
        config.accounts.append(AccountConfig(email: email, label: args.count > 2 ? args[2] : nil))
        try AccountsStore.save(config)
        print("added \(email) (token from \(src))")
    case "remove":
        guard args.count >= 2 else { usage() }
        config.accounts.removeAll { $0.email.lowercased() == args[1].lowercased() }
        try AccountsStore.save(config)
        try store.forget(args[1])
        print("removed \(args[1])")
    default: usage()
    }

case "alias":
    guard args.count >= 2, let i = config.accounts.firstIndex(where: { $0.email.lowercased() == args[0].lowercased() }) else { usage() }
    let label = args.count > 2 ? args[2] : String(args[1].split(separator: "@").last ?? "")
    config.accounts[i].aliases.removeAll { $0.address.lowercased() == args[1].lowercased() }
    config.accounts[i].aliases.append(AliasRule(address: args[1], label: label))
    try AccountsStore.save(config)
    store.config = config
    try store.recompute(account: args[0], threads: try store.db.query("SELECT id FROM threads WHERE account=?", args[0]) { $0.text(0) })
    print("mail to \(args[1]) now shows as \(label)")

case "auth":
    let r = try await Consent.run(email: args.first) { url in
        print("opening google sign-in…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url.absoluteString]
        try? p.run()
    }
    print("signed in as \(r.email); scopes: \(r.token.scopes.joined(separator: " "))")

case "scopes":
    guard let e = args.first else { usage() }
    let s = try await TokenProvider.shared.scopes(e)
    print(s.sorted().filter { $0.contains("mail") }.joined(separator: "\n"))
    print("imap push: \(s.contains(Scope.full) ? "yes" : "no (needs \(Scope.full))")")

case "sync":
    let targets = args.first.map { [$0] } ?? config.accounts.map(\.email)
    let outbox = Outbox(store: store)
    for a in targets {
        let t = DispatchTime.now()
        let r = try await AccountSync(account: a, store: store, outbox: outbox).sync()
        print("\(a): \(r.map(String.init(describing:)) ?? "busy") (\(ms(t)))")
    }

case "list":
    let box = mailbox(args.first)
    let view = args.count > 1 ? (View(key: args[1]) ?? .inbox) : .inbox
    let t = DispatchTime.now()
    let rows = store.threads(box, view, limit: 40)
    let took = ms(t)
    rows.forEach { print(row($0)) }
    print("— \(box.title) › \(view.title): \(store.count(box, view)) threads, first 40 read in \(took)")

case "search":
    let box = mailbox(args.first)
    let q = args.dropFirst().joined(separator: " ")
    let t = DispatchTime.now()
    let rows = store.search(box, q, limit: 40)
    let took = ms(t)
    rows.forEach { print(row($0)) }
    print("— \(rows.count) results in \(took)")

case "show":
    guard args.count >= 2 else { usage() }
    for m in store.messages(account: args[0], thread: args[1]) {
        print("From: \(m.shownFrom?.header ?? "?")\(m.duckFrom != nil ? "   (via \(m.from?.email ?? ""))" : "")")
        print("To: \(m.to.header)\nSubject: \(m.subject)\nLabels: \(m.labels.joined(separator: " "))")
        print("Body: \(m.hasBody ? (m.bodyHTML != nil ? "html" : "text") : "not cached — snippet: \(m.snippet)")\n")
    }

case "bodies":
    let box = mailbox(args.first)
    let view = args.count > 1 ? (View(key: args[1]) ?? .inbox) : .inbox
    let ids = store.threadsNeedingBodies(box, view, limit: 50)
    let t = DispatchTime.now()
    await AccountSync(account: box.account, store: store, outbox: Outbox(store: store)).prefetch(ids)
    print("fetched \(ids.count) threads' bodies in \(ms(t))")

case "outbox":
    for r in try store.db.query("SELECT id, account, kind, state, attempts, error, datetime(created/1000,'unixepoch') FROM outbox ORDER BY id DESC LIMIT 30", map: {
        "\($0.int(0))  \($0.text(6))  \($0.text(1))  \($0.text(2))  \($0.text(3))  tries=\($0.int(4)) \($0.string(5) ?? "")"
    }) { print(r) }

case "idle":
    guard let e = args.first else { usage() }
    guard await TokenProvider.shared.canIMAP(e) else { fail("\(e)'s token has no \(Scope.full) scope; run `mailctl auth \(e)`") }
    let bell = IdleBell(account: e) { print("\(Date()) ding") }
    bell.start()
    print("idling on \(e)'s inbox for 2 minutes…")
    try await Task.sleep(nanoseconds: 120_000_000_000)
    bell.stop()

case "launchbench":
    guard let app = args.first else { usage() }
    let runs = args.count > 1 ? Int(args[1]) ?? 10 : 10
    let exe = URL(fileURLWithPath: app).appendingPathComponent("Contents/MacOS/Post").path
    var seen: [Double] = []
    var reported: [Double] = []
    for i in 0..<runs {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        var env = ProcessInfo.processInfo.environment
        env["POST_BENCH"] = "1"; env["POST_BENCH_HOLD"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let t0 = DispatchTime.now()
        try p.run()
        let pid = p.processIdentifier
        var onscreen: Double?
        while p.isRunning, onscreen == nil {
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            if info.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && (($0[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) > 200 }) {
                onscreen = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            }
            usleep(500)
        }
        p.waitUntilExit()
        let line = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let rep = line.split(separator: " ").first { $0.hasPrefix("first_frame_ms=") }.flatMap { Double($0.dropFirst(15)) } ?? -1
        print(String(format: "run %d: on screen %.0fms (app reports %.0fms)", i + 1, onscreen ?? -1, rep))
        if let onscreen { seen.append(onscreen) }; reported.append(rep)
        usleep(300_000)
    }
    let s = seen.sorted()
    if !s.isEmpty { print(String(format: "on screen: min %.0f  median %.0f  max %.0f ms  (n=%d)", s.first!, s[s.count / 2], s.last!, s.count)) }

default: usage()
}
