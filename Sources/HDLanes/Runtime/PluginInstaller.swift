import Foundation
import HDCore

/// Writes the files that hook hdlanes into Claude Code (see ARCHITECTURE "Claude Code observation").
enum PluginInstaller {
    /// Where `hdlanes-hook` lives: inside the app bundle (`Contents/Resources/bin/hdlanes-hook`), else
    /// next to the running executable (`swift run`, `.build/debug`).
    static func locateHookBinary(bundle: Bundle = .main) -> String? {
        var candidates = [bundle.bundleURL.appendingPathComponent("Contents/Resources/bin/hdlanes-hook")]
        if let exe = bundle.executableURL {
            candidates.append(exe.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("hdlanes-hook"))
        }
        let fm = FileManager.default
        return candidates.map { $0.standardizedFileURL.path }.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Rewrites `plugin/claude/` for the current hook path (the app may have moved since last time).
    static func install(paths: HDPaths, hookPath: String, includePermissionRequest: Bool) throws {
        let root = paths.claudePluginDir
        let manifestDir = root.appendingPathComponent(".claude-plugin", isDirectory: true)
        let hooksDir = root.appendingPathComponent("hooks", isDirectory: true)
        try HDPaths.ensurePrivateDir(manifestDir)
        try HDPaths.ensurePrivateDir(hooksDir)
        try ClaudePluginFiles.pluginJSON(description: L.pluginDescription)
            .write(to: manifestDir.appendingPathComponent("plugin.json"), options: .atomic)
        try ClaudePluginFiles.hooksJSON(hookPath: hookPath, includePermissionRequest: includePermissionRequest,
                                        description: L.pluginDescription)
            .write(to: hooksDir.appendingPathComponent("hooks.json"), options: .atomic)
    }

    /// `run/sessions/<id>/settings.json` with the status line wrapper; returns its path.
    static func writeSessionSettings(paths: HDPaths, sessionID: UUID, hookPath: String) throws -> String {
        let dir = paths.sessionRunDir(sessionID)
        try HDPaths.ensurePrivateDir(dir)
        let file = dir.appendingPathComponent("settings.json")
        try ClaudePluginFiles.sessionSettingsJSON(hookPath: hookPath).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file.path
    }

    /// The account's own `statusLine.command` (managed: `<configDir>/settings.json`, system default:
    /// `~/.claude/settings.json`). Only that key is read; the file can also hold a token.
    static func userStatusLineCommand(for account: Account?, homeDirectory: String) -> String? {
        let dir: String
        if let account, !account.isSystemDefault, let configDir = account.configDir, !configDir.isEmpty {
            dir = configDir
        } else {
            dir = (homeDirectory as NSString).appendingPathComponent(".claude")
        }
        let file = (dir as NSString).appendingPathComponent("settings.json")
        guard let data = FileManager.default.contents(atPath: file) else { return nil }
        return ClaudePluginFiles.statusLineCommand(fromSettings: data)
    }
}
