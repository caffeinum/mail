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
        for a in store.config.accounts { ring(a.email) }
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
                }
            } catch {
                log("\(account): sync failed: \(error)")
                DispatchQueue.main.async { self.onError?(account, error) }
            }
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
