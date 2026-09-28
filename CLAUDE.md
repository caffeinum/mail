# reply (caffeinum/reply)

native macOS gmail client. swiftpm, command line tools only.

- build: `./build.sh` → build/Reply.app + build/mailctl. tests: `./test.sh` (sets SDKROOT to 26.5 and the swift-testing plugin path — plain `swift test` loses the macro plugin on incremental builds; never mix SDKs in one .build)
- MailCore: Store (sqlite wal + fts5, threads table precomputes `view` per thread), Gmail (rest), AccountSync (fill + history deltas), Outbox/OutboxRunner (writes gated by accounts.json writesEnabled; send → draft when off), Actions (undo), Reply/AliasRelay (duck leak guard), IdleBell (imap idle, needs mail.google.com scope)
- tokens: post's keychain item `com.caffeinum.reply` / `refresh:<email>` first, then gog's `gogcli` / `token:default:<email>`; read via /usr/bin/security, secrets never in argv
- bump `Sorter.version` when sorting rules change: the cache re-sorts on open
- UI testing without hands: `POST_SCRIPT="wait 1; key j; key return; snap /path.png; web /path2.png; quit"`; screencapture can't see windows here (no screen recording permission)
- launch timing: `POST_BENCH=1` prints marks; `build/mailctl launchbench build/Reply.app 12` measures from outside
- real accounts are read-only until the operator says yes (bd beads-h87e)
