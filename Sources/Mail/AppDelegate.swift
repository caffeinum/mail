import AppKit
import MailCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var main: MainController!
    var engine: Engine!

    /// The window goes up here, before AppKit finishes launching: the frame
    /// doesn't wait on the rest of the launch sequence.
    func applicationWillFinishLaunching(_ n: Notification) {
        Launch.mark("willFinish")
        do {
            try Paths.ensure()
            let config = try AccountsStore.load()
            let store = try Store(path: Paths.database.path, config: config)
            Launch.mark("store")
            engine = Engine(store: store)
            Launch.mark("engine")
            main = MainController(engine: engine)
        } catch {
            let a = NSAlert()
            a.messageText = "Reply can't open its cache"
            a.informativeText = "\(error)"
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        Launch.mark("controller")
        main.showFirstFrame()
        Launch.mark("shown")
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Launch.mark("didFinishLaunching")
        guard main != nil else { return }
        NSApp.activate(ignoringOtherApps: true)

        // Everything past the first frame waits a turn of the run loop, so
        // none of it is paid for before the list is on screen.
        DispatchQueue.main.async { [self] in
            let ms = Launch.firstFrame
            log(String(format: "first frame %.0fms after process start (%d rows from disk)", ms, main.list.rows.count))
            if Launch.bench {
                print(String(format: "first_frame_ms=%.1f rows=%d  ", ms, main.list.rows.count) + Launch.marks.map { String(format: "%@=%.0f", $0.0, $0.1) }.joined(separator: " "))
                fflush(stdout)
                // Held open a moment so an outside observer can see the
                // window land (mailctl launchbench).
                DispatchQueue.main.asyncAfter(deadline: .now() + (ProcessInfo.processInfo.environment["POST_BENCH_HOLD"] != nil ? 1.5 : 0)) { exit(0) }
                return
            }
            buildMenu()
            WebRenderer.shared.prewarm()
            engine.onChange = { [weak self] a in self?.main.cacheChanged(account: a) }
            engine.onAccountsChanged = { [weak self] in self?.main.accountsChanged() }
            engine.onError = { [weak self] a, e in self?.main.syncFailed(account: a, error: e) }
            // A demo cache (POST_DEMO) never talks to gmail: screenshots only.
            if ProcessInfo.processInfo.environment["POST_DEMO"] == nil { engine.start() }
            main.prefetchVisible()
            Script.run(main)
            if engine.store.config.accounts.isEmpty { openSettings(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ n: Notification) {
        engine?.stop()
        main?.saveState()
    }

    @objc func openSettings(_ sender: Any?) { main.showSettings() }

    private func buildMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        bar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Reply", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Accounts…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Reply", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Reply", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        bar.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem()
        bar.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.mainMenu = bar
        NSApp.windowsMenu = win
    }
}
