# mail

a native macOS gmail client. superhuman's speed, a few hey ideas, nothing else.

- swiftpm, swiftui shell + appkit where speed matters (NSTableView lists, one reused WKWebView for html mail)
- sqlite (wal) + fts5 cache: the last view draws from disk before any network
- gmail rest api + history deltas; imap idle as a doorbell while the app is open
- no daemon, no menu bar item: quit means gone

## build

only the command line tools are needed. the macOS 27 SDK's swiftui macros need a plugin the CLT don't ship, so build against 26.5:

```sh
./build.sh          # build/Mail.app
open build/Mail.app
swift test          # with SDKROOT set, see build.sh
```

## run

```sh
./build.sh && open build/Post.app
```

accounts live in `~/Library/Application Support/com.caffeinum.mail/accounts.json` (⌘, in the app, or `build/mailctl accounts …`). an account gog already signed in works with no consent: post reads gog's refresh token from the keychain and uses gog's oauth client. gog's tokens stop at `gmail.modify`, so imap push needs one sign-in with the full mail scope (`build/mailctl auth you@gmail.com`, or "Sign in with Google…" in settings); until then the app polls every 60s while open.

an alias (duck.com) is a per-account rule: mail whose `Duck-Original-To` names the alias shows as its own account, with the sender taken from `Duck-Original-From`. replies go to the relay address, from the gmail account, and a check refuses anything that would reach a non-relay address or carry the gmail address in the text (`Tests/MailCoreTests/AliasTests.swift`).

writes are off per account until turned on in settings: done, trash, sorting and filters stay local, and sending saves a gmail draft instead.

## keys

j/k · gg/G · o/↩ open · u/esc back · e done · # trash · U unread · z undo · / search · ⌘K palette · ? help · c/r/R/F compose/reply/all/forward · ⌘↩ send · gi/gf/gp/gn inbox/feed/paper trail/new senders · 1/2/3 account · in new senders: a let in, f feed, p paper trail, x block

## launch time

`build/mailctl launchbench build/Post.app 12` spawns the app and watches for its window from outside. on an m-series mac under load (load avg ~11), 2026-09-28: the app commits its first frame (rows read from sqlite, no network) at ~150–170ms after process start, and the window is seen on screen at ~210–230ms median from spawn. the first launch after a build is ~950ms (signature + cold dyld). the 150ms target isn't met yet: most of the budget is appkit itself (NSApplication setup ~40ms, first window ~30–45ms, first commit ~35ms).

## debug

`POST_SCRIPT="wait 1; key j; key return; snap /tmp/a.png; quit" build/Post.app/Contents/MacOS/Post` drives the app through its own key router; `POST_BENCH=1` prints launch marks and exits.
