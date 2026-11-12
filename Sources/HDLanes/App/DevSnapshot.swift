import AppKit
import Foundation
import HDCore
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
            // The Agents tab with made-up tool calls (the test home runs no agent).
            steps.append(("session-agents", {
                let runtime = model.runtimes[first.id] ?? SessionRuntime(sessionID: first.id)
                let now = Date()
                runtime.snapshot.activity = [
                    ActivityItem(id: "1", at: now.addingTimeInterval(-600), agentID: nil, tool: "Read", detail: "UI/SessionRow.swift", isRunning: false),
                    ActivityItem(id: "2", at: now.addingTimeInterval(-420), agentID: nil, tool: "Bash",
                                 detail: "swift build 2>&1 | grep -E 'error|Build comp'", summary: "Build the app", isRunning: false),
                    ActivityItem(id: "3", at: now.addingTimeInterval(-300), agentID: nil, tool: "Edit", detail: "Inspector/AgentsPanel.swift", isRunning: false),
                    ActivityItem(id: "4", at: now.addingTimeInterval(-200), agentID: "a", tool: "Grep", detail: "ActivityItem(", isRunning: false),
                    ActivityItem(id: "5", at: now.addingTimeInterval(-120), agentID: nil, tool: "mcp__claude_ai_Microsoft_365__outlook_email_search",
                                 detail: #"{"query":"invoice"}"#, isRunning: false),
                    ActivityItem(id: "6", at: now.addingTimeInterval(-60), agentID: nil, tool: "Bash", detail: "swift test",
                                 summary: "Run the tests", isRunning: false, failed: true),
                    ActivityItem(id: "7", at: now, agentID: nil, tool: "WebFetch", detail: "https://code.claude.com/docs/en/plugins", isRunning: true),
                ]
                runtime.snapshot.subagents = [SubagentInfo(id: "a", type: "Explore", description: "Find activity callers", startedAt: now.addingTimeInterval(-210))]
                model.runtimes[first.id] = runtime
                model.isInspectorVisible = true
                model.inspectorTab = .agents
            }))
            // The File tab with a file from the session's folder, as after clicking its path.
            let readme = URL(fileURLWithPath: first.worktreePath ?? first.cwd).appendingPathComponent("README.md")
            if FileManager.default.fileExists(atPath: readme.path) {
                steps.append(("session-file", { model.showFile(readme, in: first.id) }))
            }
        }
        steps.append(("tracking", { model.selection = .tracking }))
        steps.append(("tracking-work-items", { model.tracking.tab = .workItems }))
        steps.append(("inbox", { model.selection = .inbox }))
        steps.append(("board", { model.selection = .board }))
        // The Settings scene doesn't open from here; host the same view in a window of our own.
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settingsWindow.identifier = NSUserInterfaceItemIdentifier("dev-settings")
        settingsWindow.isReleasedWhenClosed = false
        steps.append(("settings-add-codex", {
            settingsWindow.setContentSize(NSSize(width: 520, height: 520))
            settingsWindow.contentView = NSHostingView(rootView: AddAccountSheet(provider: .codex).environment(model))
            settingsWindow.center()
            settingsWindow.orderFront(nil)
        }))
        // Inbox setup with a made-up tool list (the test home has no connectors).
        steps.append(("settings-inbox-setup", {
            let m365 = ["chat_message_search", "get_me", "outlook_email_search", "read_resource", "outlook_send_mail",
                        "outlook_create_draft", "outlook_batch_delete_messages", "teams_list_chats", "find_meeting_availability"]
            model.inbox.availableTools = m365.map { "mcp__claude_ai_Microsoft_365__" + $0 }
                + ["mcp__claude_ai_Gmail__search_threads", "mcp__claude_ai_Gmail__get_thread", "mcp__claude_ai_Gmail__create_draft",
                   "mcp__claude_ai_Figma__get_file", "mcp__claude_ai_Higgsfield__website_secrets"]
            model.updateSettings { $0.inboxReadTools = ["mcp__claude_ai_Microsoft_365__outlook_email_search"] }
            settingsWindow.setContentSize(NSSize(width: 600, height: 680))
            settingsWindow.contentView = NSHostingView(rootView: InboxSetupSheet().environment(model))
            settingsWindow.center()
            settingsWindow.orderFront(nil)
        }))
        for tab in ["general", "terminal", "accounts", "connections", "tasks", "mods"] {
            steps.append(("settings-\(tab)", {
                defaults.set(tab, forKey: "hd.settingsTab")
                settingsWindow.contentView = NSHostingView(rootView: SettingsView().environment(model))
                settingsWindow.center()
                settingsWindow.orderFront(nil)
            }))
        }
        // Each app theme on a session (Agents tab, as left by `session-agents`) and on Tracking.
        if let first = model.visibleSessions.first {
            for theme in AppTheme.builtIn {
                steps.append(("theme-\(theme.id)", {
                    model.setAppTheme(theme.id)
                    model.selection = .session(first.id)
                }))
                steps.append(("theme-\(theme.id)-tracking", { model.selection = .tracking }))
            }
        }
        steps.append(("settings-appearance", {
            defaults.set("terminal", forKey: "hd.settingsTab")
            settingsWindow.contentView = NSHostingView(rootView: SettingsView().environment(model))
            settingsWindow.center()
            settingsWindow.orderFront(nil)
        }))
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
            // Work items wait on `az boards query` calls; Mods on `claude plugin list`.
            DispatchQueue.main.asyncAfter(deadline: .now() + (name == "tracking-work-items" ? 60 : name == "settings-mods" ? 10 : 1.5)) {
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
