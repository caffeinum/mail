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
