import AppKit
import Foundation
import SwiftUI

/// Developer aid: with `HDLANES_SNAPSHOT_DIR` set, the app draws its own windows into PNGs (no screen
/// recording permission needed) for a fixed tour, then quits. Use only with a test home
/// (`HDLANES_HOME=/tmp/…`). Off unless the variable is set.
@MainActor
enum DevSnapshot {
    /// Only with a test home too: the tour must never run against the user's real state.
    static var directory: URL? {
        let env = ProcessInfo.processInfo.environment
        guard env["HDLANES_HOME"]?.isEmpty == false else { return nil }
        return env["HDLANES_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func runIfRequested(model: AppModel) {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let previousTab = defaults.string(forKey: "hd.settingsTab")
        var steps: [(String, () -> Void)] = []
        if let first = model.visibleSessions.first {
            steps.append(("session", { model.selection = .session(first.id) }))
        }
        steps.append(("tracking", { model.selection = .tracking }))
        steps.append(("inbox", { model.selection = .inbox }))
        steps.append(("board", { model.selection = .board }))
        // The Settings scene doesn't open from here; host the same view in a window of our own.
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settingsWindow.identifier = NSUserInterfaceItemIdentifier("dev-settings")
        settingsWindow.isReleasedWhenClosed = false
        for tab in ["general", "accounts", "connections", "tasks"] {
            steps.append(("settings-\(tab)", {
                defaults.set(tab, forKey: "hd.settingsTab")
                settingsWindow.contentView = NSHostingView(rootView: SettingsView().environment(model))
                settingsWindow.center()
                settingsWindow.orderFront(nil)
            }))
        }
        run(steps, index: 0, dir: dir) {
            // The test instance shares the real app's defaults; put the user's tab back.
            if let previousTab { defaults.set(previousTab, forKey: "hd.settingsTab") } else { defaults.removeObject(forKey: "hd.settingsTab") }
            NSApp.terminate(nil)
        }
    }

    private static func run(_ steps: [(String, () -> Void)], index: Int, dir: URL, done: @escaping () -> Void) {
        guard index < steps.count else { done(); return }
        let delay: TimeInterval = index == 0 ? 3 : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let (name, action) = steps[index]
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let window = name.hasPrefix("settings")
                    ? NSApp.windows.first { $0.identifier?.rawValue == "dev-settings" }
                    : NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
                      ?? NSApp.mainWindow
                if let window { save(window, to: dir.appendingPathComponent("\(name).png")) }
                run(steps, index: index + 1, dir: dir, done: done)
            }
        }
    }

    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
