import Foundation
import HDCore

// OWNER: runtime area. A managed account sees the default account's skills, agents, commands, global
// instructions and project memory (see ARCHITECTURE "Shared context").
extension AppModel {
    /// Effective setting: on by default for folders hdlanes created, off for imported ones.
    func sharesDefaultContext(_ account: Account) -> Bool {
        guard !account.isSystemDefault, account.provider.isAgent, let dir = account.configDir, !dir.isEmpty else { return false }
        return account.sharesDefaultContext ?? isInsideAccountsDir(dir)
    }

    /// Links are only made in folders hdlanes created; an imported folder is the user's own.
    func canLinkSharedContext(_ account: Account) -> Bool {
        guard !account.isSystemDefault, let dir = account.configDir, !dir.isEmpty else { return false }
        return isInsideAccountsDir(dir)
    }

    /// Creates or removes the account's links to match its setting. Safe to call on every launch.
    @discardableResult
    func syncSharedContext(for account: Account) -> [SharedContext.LinkResult] {
        guard canLinkSharedContext(account), let dir = account.configDir,
              let source = SharedContext.defaultSourceDir(for: account.provider, homeDirectory: homeDirectory)
        else { return [] }
        if sharesDefaultContext(account) {
            prepareAccountDir(dir)
            return SharedContext.sync(accountDir: dir, sourceDir: source, provider: account.provider)
        }
        SharedContext.unlink(accountDir: dir, sourceDir: source, provider: account.provider)
        return []
    }

    /// Read-only view of the links, for the Accounts tab.
    func sharedContextStatus(for account: Account) -> [SharedContext.LinkResult] {
        guard canLinkSharedContext(account), let dir = account.configDir,
              let source = SharedContext.defaultSourceDir(for: account.provider, homeDirectory: homeDirectory)
        else { return [] }
        return SharedContext.status(accountDir: dir, sourceDir: source, provider: account.provider)
    }

    func setSharesDefaultContext(_ accountID: UUID, _ on: Bool) {
        updateAccount(accountID) { $0.sharesDefaultContext = on }
        if let account = account(accountID) { syncSharedContext(for: account) }
    }

    /// `autoMemoryDirectory` for a managed Claude account running in `cwd`: the default account's memory
    /// dir of that repository. nil for the default account itself (it already uses it) or when off.
    func sharedMemoryDirectory(for account: Account, cwd: String) -> String? {
        guard account.provider == .claude, sharesDefaultContext(account),
              let source = SharedContext.defaultSourceDir(for: .claude, homeDirectory: homeDirectory) else { return nil }
        return SharedContext.claudeMemoryDirectory(sourceDir: source,
                                                   repositoryRoot: SharedContext.repositoryRoot(for: cwd))
    }
}
