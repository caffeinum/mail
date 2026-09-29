import AppKit
import WebKit

/// A debugging hook for driving the app without hands: POST_SCRIPT holds
/// steps separated by ";" — `wait 1.5`, `key j`, `key esc`, `snap /tmp/a.png`,
/// `web /tmp/b.png` (the mail web view on its own), `quit`. Keys go through
/// the same router a real key press does.
enum Script {
    static func run(_ main: MainController) {
        guard let s = ProcessInfo.processInfo.environment["POST_SCRIPT"] else { return }
        let steps = s.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        next(steps[...], main)
    }

    private static func next(_ steps: ArraySlice<String>, _ main: MainController) {
        guard let step = steps.first else { return }
        let rest = steps.dropFirst()
        let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        var delay = 0.05
        switch parts[0] {
        case "wait": delay = Double(arg) ?? 1
        case "key": press(arg, main.window)
        case "snap": snap(main.window, to: arg)
        case "web":
            WebRenderer.shared.view.takeSnapshot(with: nil) { img, _ in
                if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
                }
            }
            delay = 0.3
        case "quit": NSApp.terminate(nil)
        default: print("script: unknown step \(step)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { next(rest, main) }
    }

    static let codes: [String: UInt16] = ["esc": 53, "return": 36, "down": 125, "up": 126, "space": 49, "right": 124, "left": 123, "home": 115, "end": 119, "pageup": 116, "pagedown": 121]

    private static func press(_ k: String, _ window: NSWindow) {
        var mods: NSEvent.ModifierFlags = []
        var key = k
        if key.hasPrefix("cmd-") { mods.insert(.command); key = String(key.dropFirst(4)) }
        if key.hasPrefix("ctrl-") { mods.insert(.control); key = String(key.dropFirst(5)) }
        let code = codes[key] ?? 0
        let named = ["return": "\r", "esc": "\u{1b}", "space": " ", "down": "\u{F701}", "up": "\u{F700}", "right": "\u{F703}", "left": "\u{F702}", "home": "\u{F729}", "end": "\u{F72B}", "pageup": "\u{F72C}", "pagedown": "\u{F72D}"]
        let chars = codes[key] != nil ? (named[key] ?? "") : key
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: chars,
                                       charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
        NSApp.sendEvent(e)
    }

    private static func snap(_ window: NSWindow, to path: String) {
        guard let v = window.contentView?.superview ?? window.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
