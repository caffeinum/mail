import Foundation

/// Everything that runs while the app is open, and nothing after: per-account
/// sync, the outbox, the 60s poll and the imap doorbell. Quitting stops it
/// all — there's no daemon to leave behind.
public final class Engine: @unchecked Sendable {
    public let store: Store
    public let outbox: Outbox
    public let runner: OutboxRunner
    public private(set) var syncs: [String: AccountSync] = [:]
    private var bells: [String: IdleBell] = [:]
    private var poll: Timer?
    private var outboxTimer: Timer?
    /// Called on the main queue whenever an account's cache changed.
    public var onChange: ((String) -> Void)?
    public var onError: ((String, Error) -> Void)?
    /// Called on the main queue when the engine itself changed accounts.json
    /// (an alias found in the mail).
    public var onAccountsChanged: (() -> Void)?
    /// Called on the main queue when paging back through old mail starts or stops.
    public var onPaging: ((String, Bool) -> Void)?

    /// Whether gmail may still have older inbox mail for this account.
    public func hasOlder(_ account: String) -> Bool { store.get("backfill.\(account).in:inbox") != "done" }

    public init(store: Store) {
        self.store = store
        outbox = Outbox(store: store)
        runner = OutboxRunner(outbox: outbox, store: store)
        for a in store.config.accounts { syncs[a.email] = AccountSync(account: a.email, store: store, outbox: outbox) }
    }

    public func reload(config: AccountsFile) {
        store.config = config
        for a in config.accounts where syncs[a.email] == nil {
            syncs[a.email] = AccountSync(account: a.email, store: store, outbox: outbox)
        }
        for k in syncs.keys where !config.accounts.contains(where: { $0.email == k }) {
            syncs[k] = nil
            bells[k]?.stop(); bells[k] = nil
        }
    }

    public func start() {
        Task { await runner.setOnChange { [weak self] a in DispatchQueue.main.async { self?.onChange?(a) } } }
        syncAll()
        poll = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.syncAll() }
        outboxTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let due = self.outbox.nextDue(), due <= Date() else { return }
            Task { await self.runner.drain() }
        }
        for a in store.config.accounts { ring(a.email); Task { await judge(a.email) } }
    }

    public func stop() {
        poll?.invalidate(); outboxTimer?.invalidate()
        bells.values.forEach { $0.stop() }
        bells.removeAll()
    }

    public func syncAll() {
        for a in syncs.keys { sync(a) }
    }

    public func sync(_ account: String) {
        guard let s = syncs[account] else { return }
        Task {
            do {
                if let r = try await s.sync() {
                    log("\(account): \(r)")
                    if r.changed > 0 || r.full {
                        DispatchQueue.main.async {
                            self.adoptAliases()
                            self.onChange?(account)
                        }
                    }
                    await self.judge(account)
                    await self.older(account)
                }
            } catch {
                log("\(account): sync failed: \(error)")
                DispatchQueue.main.async { self.onError?(account, error) }
            }
        }
    }

    private var paging = Set<String>()
    /// Accounts whose last try at older mail failed (offline, no token).
    public private(set) var olderFailed = Set<String>()

    /// Older mail, a page at a time: once per sync in the background until
    /// the inbox is fully cached, and at once when the list nears its end.
    public func older(_ account: String) async {
        guard let s = syncs[account] else { return }
        let start: Bool = await MainActor.run { paging.insert(account).inserted }
        guard start else { return }
        DispatchQueue.main.async { self.onPaging?(account, true) }
        defer { Task { @MainActor in self.paging.remove(account); self.onPaging?(account, false) } }
        do {
            // Pages already in the cache cost one list call each; keep going
            // until something older actually arrives (or there's no more).
            for _ in 0..<20 {
                let before = store.count(Mailbox(account: account, kind: .gmail, title: ""), .inbox)
                guard try await s.backfill("in:inbox") else { break }
                if store.count(Mailbox(account: account, kind: .gmail, title: ""), .inbox) != before { break }
            }
            await MainActor.run { _ = self.olderFailed.remove(account) }
            DispatchQueue.main.async { self.onChange?(account) }
            await judge(account)
        } catch {
            await MainActor.run { _ = self.olderFailed.insert(account) }
            log("\(account): backfill failed, will retry next sync: \(error)")
        }
    }

    private var judging = Set<String>()

    /// New senders get Jev's verdict in the background; the list redraws when
    /// it lands. Without a key, or offline, the hand-written rules stand.
    public func judge(_ account: String) async {
        guard Jev.key != nil else { return }
        let start: Bool = await MainActor.run { judging.insert(account).inserted }
        guard start else { return }
        defer { Task { @MainActor in self.judging.remove(account) } }
        // Every waiting sender, a batch at a time — not just the newest 100.
        var total = 0
        let t = Date()
        do {
            while true {
                let samples = store.sendersToJudge(account, limit: 100)
                guard !samples.isEmpty else { break }
                let verdicts = try await Jev.classify(samples)
                try store.saveVerdicts(account, verdicts)
                total += verdicts.count
                DispatchQueue.main.async { self.onChange?(account) }
                if verdicts.count < samples.count { break }   // some unanswered: try them next sync
            }
            if total > 0 { log("\(account): jev placed \(total) new senders in \(Int(Date().timeIntervalSince(t) * 1000))ms") }
        } catch {
            log("\(account): jev failed, keeping the rule-based suggestions: \(error)")
        }
    }

    /// Forwarding aliases show up as accounts on their own, with no setup:
    /// any alias the mail was sent to a few times is adopted.
    public func adoptAliases() {
        var f = store.config
        var found: [String: [String]] = [:]
        for a in f.accounts { found[a.email] = store.foundAliases(a.email) }
        let added = f.adopt(found)
        guard !added.isEmpty else { return }
        do {
            try AccountsStore.save(f)
            store.config = f
            try store.recomputeAll()
            log("found alias \(added.joined(separator: ", ")) in the mail; showing it as an account")
            onAccountsChanged?()
        } catch {
            log("could not adopt aliases \(added): \(error)")
        }
    }

    public func prefetch(_ account: String, _ threads: [String]) {
        guard let s = syncs[account], !threads.isEmpty else { return }
        Task {
            await s.prefetch(threads)
            DispatchQueue.main.async { self.onChange?(account) }
        }
    }

    /// The imap connection is only a doorbell: any change it reports means
    /// "pull history now". Needs the full mail scope, which gog's tokens
    /// don't carry — without it the 60s poll is all there is.
    private func ring(_ account: String) {
        Task {
            guard await TokenProvider.shared.canIMAP(account) else {
                log("\(account): no imap scope; polling every 60s (sign in again in Settings for push)")
                return
            }
            let bell = IdleBell(account: account) { [weak self] in self?.sync(account) }
            DispatchQueue.main.async { self.bells[account] = bell; bell.start() }
        }
    }

    public func pokeOutbox() { Task { await runner.drain() } }
}
