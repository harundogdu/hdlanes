import Foundation
import HDCore

// OWNER: workspace area. Accounts: creation, removal, health checks and saving a token or key.
// Secrets passed to these methods are written to the account's own dir (or piped to the vendor CLI)
// and never logged or kept in state.json.
extension AppModel {
    func nextAccountColorIndex() -> Int {
        SessionNaming.nextColorIndex(used: state.accounts.map(\.colorIndex), paletteSize: Theme.accountColors.count)
    }

    /// The project's default account for `provider`, else the first one.
    func defaultAccount(for provider: Provider, project: Project?) -> Account? {
        let preferred = provider == .claude ? project?.defaultClaudeAccount : project?.defaultCodexAccount
        if let a = account(preferred), a.provider == provider { return a }
        return accounts(for: provider).first
    }

    func sessionsUsing(_ accountID: UUID) -> [AgentSession] {
        visibleSessions.filter { $0.accountID == accountID }
    }

    /// Creates a managed account with its own private config dir.
    @discardableResult
    func addAccount(provider: Provider, label: String, method: AuthMethod) throws -> Account {
        guard provider.isAgent else { throw WorkspaceError.notManaged }
        let id = UUID()
        let dir = paths.accountDir(provider: provider, id: id)
        try HDPaths.ensurePrivateDir(URL(fileURLWithPath: dir, isDirectory: true))
        let n = accounts(for: provider).count + 1
        let account = Account(id: id, provider: provider, label: label.nilIfBlank ?? L.defaultAccountLabel(provider, n),
                              colorIndex: nextAccountColorIndex(), isSystemDefault: false, configDir: dir,
                              authMethod: method)
        state.accounts.append(account)
        syncSharedContext(for: account)
        return account
    }

    /// Refuses system default accounts and accounts used by open sessions. A managed account's dir
    /// (logins, transcripts, history) goes to the Trash, never deleted outright.
    func removeAccount(_ id: UUID) throws {
        guard let account = account(id) else { return }
        if account.isSystemDefault { throw WorkspaceError.systemAccount }
        let users = sessionsUsing(id).count
        if users > 0 { throw WorkspaceError.accountInUse(users) }
        if let dir = account.configDir, isInsideAccountsDir(dir), FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: dir, isDirectory: true), resultingItemURL: nil)
        }
        state.accounts.removeAll { $0.id == id }
        state.usage[id.uuidString] = nil
        accountHealth[id] = nil
        for i in state.projects.indices {
            if state.projects[i].defaultClaudeAccount == id { state.projects[i].defaultClaudeAccount = nil }
            if state.projects[i].defaultCodexAccount == id { state.projects[i].defaultCodexAccount = nil }
        }
        if state.settings.aiCategorizationAccount == id { state.settings.aiCategorizationAccount = nil }
    }

    /// Only dirs hdlanes created are ever moved to the Trash (guards against a hand-edited state file).
    func isInsideAccountsDir(_ dir: String) -> Bool {
        let root = HDPaths.normalizedDirString(paths.accountsDir.path) + "/"
        let normalized = HDPaths.normalizedDirString(URL(fileURLWithPath: dir).standardizedFileURL.path)
        return normalized.hasPrefix(root) && !normalized.contains("/../")
    }

    // MARK: Health

    func refreshAllAccountHealth(olderThan age: TimeInterval = 300) async {
        await withTaskGroup(of: Void.self) { group in
            for account in state.accounts {
                if let h = accountHealth[account.id], h.isChecking || Date().timeIntervalSince(h.checkedAt) < age { continue }
                group.addTask { await self.refreshAccountHealth(account.id) }
            }
        }
    }

    func refreshAccountHealth(_ id: UUID) async {
        guard let account = account(id), account.provider.isAgent else { return }
        if accountHealth[id]?.isChecking == true { return }
        var checking = accountHealth[id] ?? AccountHealth()
        checking.isChecking = true
        accountHealth[id] = checking

        let args = account.provider == .claude ? ["auth", "status", "--json"] : ["login", "status"]
        let result = await runAccountCLI(account, arguments: args, timeout: 20)

        var health = AccountHealth()
        health.checkedAt = Date()
        if result.launchFailed || AccountCLI.isCommandNotFound(status: result.status, output: result.combined) {
            health.cliMissing = true
            health.detail = L.cliMissing(account.provider)
        } else if result.timedOut {
            health.error = L.errTimedOut
        } else if account.provider == .claude {
            applyClaudeStatus(result, to: &health, account: account)
        } else {
            applyCodexStatus(result, to: &health, account: account)
        }
        accountHealth[id] = health
    }

    private func applyClaudeStatus(_ result: CLIResult, to health: inout AccountHealth, account: Account) {
        guard let status = ClaudeAuthStatus.parse(result.stdout) else {
            health.error = result.firstErrorLine() ?? L.errUnreadableStatus
            return
        }
        health.loggedIn = status.loggedIn
        guard status.loggedIn else { return }
        health.detail = L.claudeAuthMethodName(status.authMethod)
        updateAccount(account.id) { a in
            if let email = status.email { a.email = email }
            if let plan = status.plan { a.plan = plan }
            guard !a.isSystemDefault else { return }
            switch status.authMethod {
            case "claude.ai": a.authMethod = .browser
            case "oauth_token": a.authMethod = .token
            case "api_key_helper", "api_key": a.authMethod = .apiKey
            default: break
            }
        }
    }

    private func applyCodexStatus(_ result: CLIResult, to health: inout AccountHealth, account: Account) {
        switch CodexLoginStatus.parse(result.combined) {
        case .loggedIn(let kind):
            health.loggedIn = true
            health.detail = L.codexAuthKindName(kind)
            guard !account.isSystemDefault else { return }
            updateAccount(account.id) { a in
                switch kind {
                case .chatgpt: a.authMethod = .browser
                case .apiKey: a.authMethod = .apiKey
                case .accessToken: a.authMethod = .token
                case .other: break
                }
            }
        case .loggedOut:
            health.loggedIn = false
        case .unknown:
            health.error = result.firstErrorLine() ?? L.errUnreadableStatus
        }
    }

    /// Runs the account's vendor CLI with `arguments` through the login shell, with the account's
    /// environment and the user's resolved PATH. Credential variables are unset in the command line
    /// too, in case the user's shell profile exports them.
    func runAccountCLI(_ account: Account, arguments: [String], variables: [String: String] = [:], stdin: Data? = nil,
                       timeout: TimeInterval) async -> CLIResult {
        let dir = account.isSystemDefault ? nil : account.configDir
        let path = await ShellPath.resolved(base: environment(for: nil))
        let env = AccountCLI.environment(base: environment(for: account), provider: account.provider, configDir: dir, path: path)
        let line = AccountCLI.commandLine(provider: account.provider, configDir: dir, arguments: arguments,
                                              variables: variables)
        return await CLIRunner.runShell(line, environment: env, currentDirectory: accountCLIDirectory(), stdin: stdin, timeout: timeout)
    }

    /// Working directory of vendor CLI calls and the login terminal: an empty folder hdlanes owns.
    /// Claude Code reads `<cwd>/.claude/settings.json` as project settings, so from `$HOME` the system
    /// default account's own settings (an `apiKeyHelper`, hooks) would apply to every managed account.
    func accountCLIDirectory() -> String {
        let url = paths.runDir.appendingPathComponent("cli", isDirectory: true)
        do {
            try HDPaths.ensurePrivateDir(url)
            return url.path
        } catch {
            // A missing cwd would make the launch fail and read as "CLI not installed".
            return NSTemporaryDirectory()
        }
    }

    // MARK: Saving a token or key (managed accounts only)

    private func managedAccount(_ id: UUID, provider: Provider) throws -> (Account, URL) {
        guard let account = account(id), account.provider == provider else { throw WorkspaceError.notManaged }
        guard !account.isSystemDefault, let dir = account.configDir else { throw WorkspaceError.notManaged }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        if isInsideAccountsDir(dir) { try HDPaths.ensurePrivateDir(url) }
        return (account, url)
    }

    /// Reads settings.json when it exists; a file that exists but can't be read is an error, so it is
    /// never replaced by a fresh one.
    private func existingSettings(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Stores a `claude setup-token` token as `env.CLAUDE_CODE_OAUTH_TOKEN` in the account's settings.json.
    func saveClaudeToken(_ token: String, for accountID: UUID) throws {
        guard let token = token.nilIfBlank else { throw WorkspaceError.emptySecret }
        let (_, dir) = try managedAccount(accountID, provider: .claude)
        let settings = dir.appendingPathComponent("settings.json")
        let data = try ClaudeSettingsFile.settingOAuthToken(token, in: existingSettings(at: settings))
        try PrivateFile.write(data, to: settings)
        updateAccount(accountID) { $0.authMethod = .token }
    }

    /// Stores an Anthropic API key in `<dir>/.hdlanes-api-key` and points `apiKeyHelper` at it.
    func saveClaudeAPIKey(_ key: String, for accountID: UUID) throws {
        guard let key = key.nilIfBlank else { throw WorkspaceError.emptySecret }
        let (_, dir) = try managedAccount(accountID, provider: .claude)
        let keyFile = dir.appendingPathComponent(ClaudeSettingsFile.apiKeyFileName)
        let settings = dir.appendingPathComponent("settings.json")
        let data = try ClaudeSettingsFile.settingAPIKeyHelper(keyFilePath: keyFile.path, in: existingSettings(at: settings))
        try PrivateFile.write(Data(key.utf8), to: keyFile)
        try PrivateFile.write(data, to: settings)
        updateAccount(accountID) { $0.authMethod = .apiKey }
    }

    /// `codex login --with-api-key` / `--with-access-token`, the secret on stdin (never in argv).
    func saveCodexSecret(_ secret: String, method: AuthMethod, for accountID: UUID) async throws {
        guard let secret = secret.nilIfBlank else { throw WorkspaceError.emptySecret }
        let (account, _) = try managedAccount(accountID, provider: .codex)
        let flag = method == .apiKey ? "--with-api-key" : "--with-access-token"
        let result = await runAccountCLI(account, arguments: ["login", flag], stdin: Data(secret.utf8), timeout: 30)
        if result.launchFailed || AccountCLI.isCommandNotFound(status: result.status, output: result.combined) {
            throw WorkspaceError.cliMissing(.codex)
        }
        if result.timedOut { throw WorkspaceError.timedOut }
        guard result.status == 0 else {
            throw WorkspaceError.commandFailed(result.firstErrorLine(redacting: secret) ?? L.errExitStatus(result.status))
        }
        updateAccount(accountID) { $0.authMethod = method == .apiKey ? .apiKey : .token }
    }
}
