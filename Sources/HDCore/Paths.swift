import Foundation

/// Every on-disk location hdlanes uses. The root is `~/.hdlanes`, or `$HDLANES_HOME` (tests, dev builds).
///
/// Layout:
///   state.json                       persisted AppState
///   state.backup-<ts>.json           copy of a state file that failed to decode (never deleted silently)
///   accounts/claude/<uuid>/          CLAUDE_CONFIG_DIR of a managed Claude account
///   accounts/codex/<uuid>/           CODEX_HOME of a managed Codex account
///   plugin/claude/                   generated Claude Code plugin (hooks → hdlanes-hook)
///   run/hd.sock                      Unix socket the hook talks to (dir 0700, socket 0600)
///   run/sessions/<uuid>/settings.json  per-session `--settings` (status line wrapper)
public struct HDPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> HDPaths {
        if let custom = environment["HDLANES_HOME"], custom.hasPrefix("/") {
            return HDPaths(root: URL(fileURLWithPath: custom, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return HDPaths(root: home.appendingPathComponent(".hdlanes", isDirectory: true))
    }

    public var stateFile: URL { root.appendingPathComponent("state.json") }
    public var accountsDir: URL { root.appendingPathComponent("accounts", isDirectory: true) }
    public var claudePluginDir: URL { root.appendingPathComponent("plugin/claude", isDirectory: true) }
    public var runDir: URL { root.appendingPathComponent("run", isDirectory: true) }
    public var socketPath: String { runDir.appendingPathComponent("hd.sock").path }

    public func sessionRunDir(_ id: UUID) -> URL {
        runDir.appendingPathComponent("sessions/\(id.uuidString)", isDirectory: true)
    }

    /// The exact string used as CLAUDE_CONFIG_DIR / CODEX_HOME. Absolute, no trailing slash,
    /// NFC-normalized. Store it on the Account once; never recompute it for an existing account.
    public func accountDir(provider: Provider, id: UUID) -> String {
        let url = accountsDir.appendingPathComponent("\(provider.rawValue)/\(id.uuidString)", isDirectory: true)
        return Self.normalizedDirString(url.path)
    }

    public static func normalizedDirString(_ path: String) -> String {
        var p = path.precomposedStringWithCanonicalMapping
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Creates a directory readable only by the user.
    public static func ensurePrivateDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
