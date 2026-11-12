import Foundation

/// What a mod can do, as the awesome-claude-code-mods catalogue grades it from `claude plugin validate`
/// (not an Anthropic concept): L0 draws, L1 reads, L2 writes or runs, L3 reaches the network.
public enum ModLevel: Int, Sendable, Comparable, CaseIterable {
    case draws = 0, reads, writes, network

    public static func < (a: ModLevel, b: ModLevel) -> Bool { a.rawValue < b.rawValue }
    /// L2 and up get a confirmation before installing.
    public var needsConfirmation: Bool { self >= .writes }
}

/// A Claude Code mod hdlanes can install into an account's config dir.
public struct ModEntry: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// A marketplace hdlanes adds on install: `owner/repo`, a git URL or a path.
        case marketplace(String)
        /// Anthropic's samples: a local clone of claude-code-playground (`ModCatalog.playgroundRepo`).
        case playground
        /// Shipped inside Claude Code; only enabled or disabled.
        case builtin
    }

    public var name: String
    public var marketplace: String
    public var source: Source
    /// nil when the catalogue hasn't graded it.
    public var level: ModLevel?
    /// Project page.
    public var url: String

    /// `name@marketplace`, as `claude plugin list --json` reports it.
    public var id: String { "\(name)@\(marketplace)" }

    public init(name: String, marketplace: String, source: Source, level: ModLevel?, url: String) {
        self.name = name
        self.marketplace = marketplace
        self.source = source
        self.level = level
        self.url = url
    }
}

public enum ModCatalog {
    public static let playgroundRepo = "https://github.com/anthropics/claude-code-playground"
    /// The marketplace folder inside a playground clone.
    public static let playgroundSubdir = "claude-code/mods"
    public static let youShouldKnowID = "cc-plugin-you-should-know@builtin"

    /// Mods from Anthropic's samples and the awesome-claude-code-mods catalogue, levels as graded there
    /// (the playground's by `claude plugin validate`'s `calls:` line).
    public static let entries: [ModEntry] = [
        ModEntry(name: "cc-plugin-you-should-know", marketplace: "builtin", source: .builtin, level: nil,
                 url: "https://code.claude.com/docs/en/interactive-mode#you-should-know-suggestions"),
        ModEntry(name: "token-weather", marketplace: "claude-code-playground-mods", source: .playground, level: .reads,
                 url: playgroundRepo + "/tree/main/claude-code/mods/token-weather"),
        ModEntry(name: "replay-theater", marketplace: "claude-code-playground-mods", source: .playground, level: .reads,
                 url: playgroundRepo + "/tree/main/claude-code/mods/replay-theater"),
        ModEntry(name: "blast-radius", marketplace: "claude-code-playground-mods", source: .playground, level: .writes,
                 url: playgroundRepo + "/tree/main/claude-code/mods/blast-radius"),
        ModEntry(name: "flightdeck", marketplace: "claude-flightdeck", source: .marketplace("scasella/claude-flightdeck"),
                 level: .reads, url: "https://github.com/scasella/claude-flightdeck"),
        ModEntry(name: "filetree", marketplace: "claude-code-filetree", source: .marketplace("data-goblin/claude-code-filetree"),
                 level: .writes, url: "https://github.com/data-goblin/claude-code-filetree"),
        ModEntry(name: "cache-tax", marketplace: "claude-code-mods", source: .marketplace("karanb192/claude-code-mods"),
                 level: .writes, url: "https://github.com/karanb192/cache-tax"),
        ModEntry(name: "savvy-progress", marketplace: "claude-kit", source: .marketplace("johnnyvizz/claude-kit"),
                 level: .writes, url: "https://github.com/JohnnyVizz/claude-kit/tree/main/plugins/savvy-progress"),
        ModEntry(name: "prismantis", marketplace: "prismantis", source: .marketplace("NahumLitvin/prismantis"),
                 level: .writes, url: "https://github.com/NahumLitvin/prismantis"),
        ModEntry(name: "reflect-mod", marketplace: "claude-reflect-marketplace", source: .marketplace("bayramannakov/claude-reflect"),
                 level: .writes, url: "https://github.com/BayramAnnakov/claude-reflect"),
        ModEntry(name: "recap", marketplace: "miox-team", source: .marketplace("miox-team/claude-recap-tr"),
                 level: .writes, url: "https://github.com/miox-team/claude-recap-tr"),
        ModEntry(name: "skins", marketplace: "hellosverre-mods", source: .marketplace("hellosverre/claude-skins"),
                 level: .network, url: "https://github.com/hellosverre/claude-skins"),
        ModEntry(name: "terminal-browser", marketplace: "terminal-browser", source: .marketplace("zenbu-labs/terminal-browser"),
                 level: .network, url: "https://github.com/zenbu-labs/terminal-browser"),
    ]

    /// `claude plugin …` arguments to install `entry`; `playgroundPath` is the local marketplace folder.
    /// nil for built-ins, which are enabled instead.
    public static func installArguments(_ entry: ModEntry, playgroundPath: String?) -> [String]? {
        let source: String
        switch entry.source {
        case .builtin: return nil
        case .marketplace(let s): source = s
        case .playground:
            guard let playgroundPath else { return nil }
            source = playgroundPath
        }
        return ["plugin", "install", entry.name, "--marketplace", source, "--json"]
    }

    /// Install by hand: `name` from the marketplace at `source` (`owner/repo`, URL or path). nil when
    /// either part is empty or could pass for an option.
    public static func customInstallArguments(name: String, source: String) -> [String]? {
        let n = name.trimmingCharacters(in: .whitespaces), s = source.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !s.isEmpty, !n.hasPrefix("-"), !s.hasPrefix("-"),
              !n.contains(where: \.isWhitespace) else { return nil }
        return ["plugin", "install", n, "--marketplace", s, "--json"]
    }

    public static func arguments(_ verb: String, id: String) -> [String] { ["plugin", verb, id, "--json"] }
}

/// One line of `claude plugin list --json`.
public struct InstalledPlugin: Identifiable, Hashable, Sendable {
    public var id: String
    public var version: String
    public var enabled: Bool

    public var name: String { id.split(separator: "@", maxSplits: 1).first.map(String.init) ?? id }

    public init(id: String, version: String, enabled: Bool) {
        self.id = id
        self.version = version
        self.enabled = enabled
    }

    public static func parseList(_ data: Data) -> [InstalledPlugin]? {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return InstalledPlugin(id: id, version: (item["version"] as? String) ?? "", enabled: (item["enabled"] as? Bool) ?? false)
        }
    }

    /// Built-ins aren't listed; their switch is `enabledPlugins` in the account's settings.json.
    public static func isEnabled(_ id: String, settings data: Data?) -> Bool {
        guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let enabled = root["enabledPlugins"] as? [String: Any] else { return false }
        return (enabled[id] as? Bool) ?? false
    }
}

/// The `--json` result line of `claude plugin install|uninstall|enable|disable`.
public enum PluginCommandResult: Equatable, Sendable {
    case ok
    /// The marketplace runs a command to install; it must be shown to the user, then accepted by sha256.
    case needsCommand(command: String, sha256: String)
    case failed(String)

    public static func parse(_ stdout: String) -> PluginCommandResult? {
        for line in stdout.split(whereSeparator: \.isNewline).reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let shown = obj["shownCommand"] as? [String: Any], let sha = shown["sha256"] as? String,
               (obj["outcome"] as? String) != "ok" {
                let text = (shown["command"] as? String) ?? (shown["display"] as? String) ?? (shown["text"] as? String) ?? ""
                return .needsCommand(command: text, sha256: sha)
            }
            if (obj["outcome"] as? String) == "ok" { return .ok }
            return .failed((obj["message"] as? String) ?? "")
        }
        return nil
    }
}
