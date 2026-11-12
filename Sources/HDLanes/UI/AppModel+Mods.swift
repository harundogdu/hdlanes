import Foundation
import HDCore

// OWNER: workspace area. Claude Code mods per account: `claude plugin …` with the account's config dir.
// Mods draw inside Claude Code's own TUI, so the terminal needs nothing more.
extension AppModel {
    /// Anthropic's sample mods, cloned once; the marketplace loads from this folder, so it stays.
    var playgroundClone: URL { paths.root.appendingPathComponent("mods/claude-code-playground", isDirectory: true) }
    var playgroundMarketplace: String { playgroundClone.appendingPathComponent(ModCatalog.playgroundSubdir).path }

    /// Clones claude-code-playground (only its mods folder) or pulls it. Returns an error line or nil.
    func preparePlayground() async -> String? {
        guard let git = ToolLocator.gitPath else { return L.modsGitMissing }
        let env = environment(for: nil)
        let dir = playgroundClone.path
        if FileManager.default.fileExists(atPath: playgroundMarketplace) {
            // Best effort: an offline pull keeps the copy that is there.
            _ = await CLIRunner.run(executable: git, arguments: ["-C", dir, "pull", "--ff-only", "-q"],
                                    environment: env, timeout: 60)
            return nil
        }
        try? FileManager.default.removeItem(at: playgroundClone)
        try? FileManager.default.createDirectory(at: playgroundClone.deletingLastPathComponent(), withIntermediateDirectories: true)
        let clone = await CLIRunner.run(executable: git, arguments: ["clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse",
                                                                    ModCatalog.playgroundRepo, dir],
                                        environment: env, timeout: 120)
        guard clone.status == 0 else { return clone.firstErrorLine() ?? L.modsCloneFailed }
        let sparse = await CLIRunner.run(executable: git, arguments: ["-C", dir, "sparse-checkout", "set", ModCatalog.playgroundSubdir],
                                         environment: env, timeout: 120)
        guard sparse.status == 0, FileManager.default.fileExists(atPath: playgroundMarketplace) else {
            return sparse.firstErrorLine() ?? L.modsCloneFailed
        }
        return nil
    }

    /// `claude plugin list --json` for `account`.
    func installedPlugins(_ account: Account) async -> Result<[InstalledPlugin], ModError> {
        let r = await runAccountCLI(account, arguments: ["plugin", "list", "--json"], timeout: 60)
        guard r.status == 0, let list = InstalledPlugin.parseList(Data(r.stdout.utf8)) else {
            return .failure(ModError(r.firstErrorLine() ?? L.modsListFailed))
        }
        return .success(list)
    }

    /// Built-ins aren't in the list; read the switch from the account's settings.json.
    func isBuiltinEnabled(_ id: String, account: Account) -> Bool {
        let dir = (account.isSystemDefault ? nil : account.configDir)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        let data = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("settings.json"))
        return InstalledPlugin.isEnabled(id, settings: data)
    }

    /// Runs one `claude plugin …` command for `account`.
    func runPluginCommand(_ account: Account, _ arguments: [String]) async -> PluginCommandResult {
        let r = await runAccountCLI(account, arguments: arguments, timeout: 180)
        if r.timedOut { return .failed(L.modsTimedOut) }
        return PluginCommandResult.parse(r.stdout) ?? (r.status == 0 ? .ok : .failed(r.firstErrorLine() ?? L.modsCommandFailed))
    }
}

struct ModError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}
