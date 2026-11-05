import Foundation

/// Builds the environment and command line of every process hdlanes starts for an agent or a vendor
/// CLI. Pure: everything comes in as parameters so the recipe in ARCHITECTURE.md is unit-tested.
public enum EnvBuilder {
    // MARK: Environment

    /// Variables copied from the app's own environment. `LC_*` is matched by prefix.
    public static let allowedKeys: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR", "PATH"]
    /// Never passed on, even if a future allowlist entry would match.
    public static let droppedPrefixes = ["CLAUDE", "ANTHROPIC_", "CODEX_", "OPENAI_", "TMUX"]
    public static let terminalVariables = ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "hdlanes"]
    /// PATH of a process started by launchd when the app's own PATH is missing.
    public static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Allowlisted copy of `processEnv` plus the terminal variables. Agent credentials or a config dir
    /// exported into the app's environment never reach a child.
    public static func baseEnvironment(_ processEnv: [String: String]) -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in processEnv {
            if droppedPrefixes.contains(where: { key.hasPrefix($0) }) { continue }
            if allowedKeys.contains(key) || key.hasPrefix("LC_") { env[key] = value }
        }
        for (key, value) in terminalVariables { env[key] = value }
        if env["PATH"]?.isEmpty ?? true { env["PATH"] = fallbackPath }
        // Finder-launched apps often have no locale; TUIs then draw box characters as '?'.
        if env["LANG"] == nil && env["LC_ALL"] == nil && env["LC_CTYPE"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    /// `CLAUDE_CONFIG_DIR` / `CODEX_HOME` for a managed account, byte-exact as stored. Empty for the
    /// system default account: setting the variable even to `~/.claude` changes Claude's Keychain key.
    public static func accountVariables(_ account: Account?) -> [String: String] {
        guard let account, !account.isSystemDefault, let dir = account.configDir, !dir.isEmpty else { return [:] }
        switch account.provider {
        case .claude: return ["CLAUDE_CONFIG_DIR": dir]
        case .codex: return ["CODEX_HOME": dir]
        case .shell: return [:]
        }
    }

    /// Environment for a one-off vendor CLI call (status checks, API-key login over stdin). No shell
    /// init runs, so the account variable goes straight into the environment. `loginPath` replaces
    /// PATH when the login shell's PATH is known (Finder-launched apps lack nvm/Homebrew dirs).
    public static func cliEnvironment(account: Account?, processEnv: [String: String],
                                      loginPath: String? = nil) -> [String: String] {
        var env = baseEnvironment(processEnv)
        if let loginPath, !loginPath.isEmpty { env["PATH"] = loginPath }
        for (key, value) in accountVariables(account) { env[key] = value }
        return env
    }

    // MARK: Shell

    /// Shells whose `-c` syntax the generated command lines rely on.
    public static let posixShells: Set<String> = ["zsh", "bash", "sh", "ksh", "dash", "mksh"]

    /// The user's login shell: `$SHELL` when it is an absolute path, else `/bin/zsh`.
    public static func userShell(_ processEnv: [String: String]) -> String {
        if let shell = processEnv["SHELL"], shell.hasPrefix("/") { return shell }
        return "/bin/zsh"
    }

    /// Shell that runs generated command lines. A non-POSIX `$SHELL` (fish, nushell, …) can't parse
    /// them, so those run under `/bin/zsh` and only the trailing interactive shell is the user's.
    public static func commandShell(_ processEnv: [String: String]) -> String {
        let shell = userShell(processEnv)
        let name = (shell as NSString).lastPathComponent
        return posixShells.contains(name) ? shell : "/bin/zsh"
    }

    // MARK: Agent command

    /// Unset before `claude` so a token exported by the user's shell init can't win over the account.
    /// The single source of strip lists: `AccountCLI` uses these too.
    public static let claudeStripVariables = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDECODE",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_DISABLE_TERMINAL_TITLE", "CLAUDE_CONFIG_DIR", "CODEX_HOME",
    ]
    /// Provider routing switches. Unset for managed accounts only: a managed account is its own
    /// claude.ai / Console login and must not be rerouted to Bedrock, Vertex, Foundry or a proxy by the
    /// user's shell init. The system default account keeps them, so a `claude` the user deliberately
    /// runs on Bedrock from `.zshrc` behaves the same inside hdlanes.
    /// Every switch claude 2.1.317 reads to pick a non-claude.ai provider (its provider selector checks
    /// these six), plus the base URL that would send the account's token elsewhere.
    public static let claudeProviderSwitchVariables = [
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_USE_ANTHROPIC_AWS", "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD", "CLAUDE_CODE_USE_MANTLE",
        "ANTHROPIC_BASE_URL",
    ]
    public static let codexStripVariables = ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_HOME"]

    public static func stripVariables(for provider: Provider) -> [String] {
        switch provider {
        case .claude: return claudeStripVariables
        case .codex: return codexStripVariables
        case .shell: return []
        }
    }

    /// `stripVariables(for:)`, plus the provider switches for a managed account.
    public static func stripVariables(for provider: Provider, managedAccount: Bool) -> [String] {
        var names = stripVariables(for: provider)
        if provider == .claude, managedAccount { names += claudeProviderSwitchVariables }
        return names
    }

    /// `env -u … [CLAUDE_CONFIG_DIR='<dir>']`: the prefix in front of every vendor CLI invocation.
    public static func envPrefix(provider: Provider, account: Account?) -> String {
        var parts = ["env"]
        let managed = !accountVariables(account).isEmpty
        for name in stripVariables(for: provider, managedAccount: managed) { parts.append("-u \(name)") }
        for (key, value) in accountVariables(account).sorted(by: { $0.key < $1.key }) {
            parts.append("\(key)=\(ShellQuote.quote(value))")
        }
        return parts.joined(separator: " ")
    }

    public struct AgentLaunch: Equatable, Sendable {
        public var provider: Provider
        public var account: Account?
        public var title: String
        /// Claude: the session id (`--session-id`, or `--resume` when `resume`). Codex: the thread id,
        /// used only when `resume`.
        public var agentSessionID: String?
        public var resume: Bool
        public var initialPrompt: String?
        /// nil when the hook binary wasn't found: the agent then runs without hdlanes' hooks.
        public var pluginDir: String?
        public var settingsPath: String?
        /// Claude: per-session `--mcp-config` file of the session's MCP connections.
        public var mcpConfigPath: String? = nil
        /// Raw shell command run before the agent (project setup in a fresh worktree).
        public var setupCommand: String?
        /// Printed when the setup command fails; the agent starts anyway.
        public var setupFailedNotice: String

        public init(provider: Provider, account: Account?, title: String, agentSessionID: String?, resume: Bool,
                    initialPrompt: String? = nil, pluginDir: String? = nil, settingsPath: String? = nil,
                    setupCommand: String? = nil, setupFailedNotice: String = "Setup command failed.") {
            self.provider = provider
            self.account = account
            self.title = title
            self.agentSessionID = agentSessionID
            self.resume = resume
            self.initialPrompt = initialPrompt
            self.pluginDir = pluginDir
            self.settingsPath = settingsPath
            self.setupCommand = setupCommand
            self.setupFailedNotice = setupFailedNotice
        }
    }

    /// The agent invocation alone (no setup, no trailing shell).
    public static func agentInvocation(_ launch: AgentLaunch) -> String {
        var parts = [envPrefix(provider: launch.provider, account: launch.account)]
        let prompt = launch.initialPrompt.flatMap { $0.isEmpty ? nil : $0 }
        switch launch.provider {
        case .claude:
            parts.append("claude")
            if let dir = launch.pluginDir { parts.append("--plugin-dir \(ShellQuote.quote(dir))") }
            if let settings = launch.settingsPath { parts.append("--settings \(ShellQuote.quote(settings))") }
            if let mcp = launch.mcpConfigPath { parts.append("--mcp-config \(ShellQuote.quote(mcp))") }
            if let id = launch.agentSessionID, !id.isEmpty {
                parts.append("\(launch.resume ? "--resume" : "--session-id") \(ShellQuote.quote(id))")
            }
            if !launch.title.isEmpty { parts.append("-n \(ShellQuote.quote(launch.title))") }
            if let prompt { parts.append(promptArgument(prompt)) }
        case .codex:
            parts.append("codex")
            if launch.resume, let id = launch.agentSessionID, !id.isEmpty {
                parts.append("resume \(ShellQuote.quote(id))")
            }
            if let prompt { parts.append(promptArgument(prompt)) }
        case .shell:
            return ""
        }
        return parts.joined(separator: " ")
    }

    /// A prompt starting with `-` would be read as an option; `--` ends option parsing (commander/clap).
    static func promptArgument(_ prompt: String) -> String {
        (prompt.hasPrefix("-") ? "-- " : "") + ShellQuote.quote(prompt)
    }

    /// Setup (when given) followed by the agent.
    ///
    /// The setup runs in a subshell on its own lines, so a trailing `# comment`, `&`, `exit` or `cd`
    /// inside it can't swallow or move the agent. If it fails, one notice line with its exit status
    /// is printed and the agent still starts: the user sees the error above and can fix it in the
    /// shell that remains after the agent.
    public static func agentCommand(_ launch: AgentLaunch) -> String {
        let agent = agentInvocation(launch)
        guard let setup = launch.setupCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !setup.isEmpty else {
            return agent
        }
        let notice = "printf '\\n%s (%s)\\n\\n' \(ShellQuote.quote(launch.setupFailedNotice)) \"$?\""
        return "(\n\(setup)\n) || \(notice)\n\(agent)"
    }

    /// hdlanes variables the hook reads (`HD_*`).
    public struct SessionVariables: Equatable, Sendable {
        public var socketPath: String
        public var sessionID: UUID
        public var accountID: UUID?
        /// The account's own status line command, chained by `hdlanes-hook statusline`.
        public var statusLineChain: String?
        public var accountLabel: String?

        public init(socketPath: String, sessionID: UUID, accountID: UUID?, statusLineChain: String? = nil,
                    accountLabel: String? = nil) {
            self.socketPath = socketPath
            self.sessionID = sessionID
            self.accountID = accountID
            self.statusLineChain = statusLineChain
            self.accountLabel = accountLabel
        }

        public var environment: [String: String] {
            var env = [HookEnv.socket: socketPath, HookEnv.session: sessionID.uuidString]
            if let accountID { env[HookEnv.account] = accountID.uuidString }
            if let chain = statusLineChain, !chain.isEmpty { env[HookEnv.statusLineChain] = chain }
            if let label = accountLabel.map(StatusLine.cleanLabel), !label.isEmpty { env[HookEnv.accountLabel] = label }
            return env
        }
    }

    /// The session terminal: the user's login shell runs the agent, then stays as an interactive shell.
    /// A `.shell` provider gets a plain login shell.
    ///
    /// The terminal itself carries the managed account's dir variable, so a `claude` / `codex` typed in
    /// the shell left after the agent exits runs as the same account. The agent prefix still unsets and
    /// sets it again. Empty for the system default account (see `accountVariables`).
    ///
    /// `connections` (tokens, KUBECONFIG) go into the terminal's environment only, never into the
    /// command line, which is visible in the terminal and in `ps`. Reserved names are dropped.
    public static func launchSpec(_ launch: AgentLaunch, session: SessionVariables, cwd: String,
                                  processEnv: [String: String], connections: [String: String] = [:]) -> LaunchSpec {
        guard launch.provider.isAgent else { return shellSpec(cwd: cwd, processEnv: processEnv, connections: connections) }
        var env = baseEnvironment(processEnv)
        addConnections(connections, to: &env)
        for (key, value) in accountVariables(launch.account) { env[key] = value }
        for (key, value) in session.environment { env[key] = value }
        let script = agentCommand(launch) + "; " + keepShell(processEnv)
        return LaunchSpec(executable: commandShell(processEnv), args: ["-l", "-i", "-c", script],
                          environment: env, cwd: cwd)
    }

    public static func shellSpec(cwd: String, processEnv: [String: String], connections: [String: String] = [:]) -> LaunchSpec {
        var env = baseEnvironment(processEnv)
        addConnections(connections, to: &env)
        return LaunchSpec(executable: userShell(processEnv), args: ["-l", "-i"], environment: env, cwd: cwd)
    }

    /// Connection variables, minus any name that would touch a login, a provider or hdlanes' wiring.
    static func addConnections(_ connections: [String: String], to env: inout [String: String]) {
        for (key, value) in connections where key == "KUBECONFIG" || !ConnectionRules.isReserved(key) { env[key] = value }
    }

    /// `exec '<shell>' -l -i`: replaces the command shell with an interactive one after the agent exits.
    static func keepShell(_ processEnv: [String: String]) -> String {
        "exec \(ShellQuote.quote(userShell(processEnv))) -l -i"
    }

    // MARK: Login

    public enum LoginFlow: String, Sendable {
        /// The vendor's browser login.
        case browser
        /// Claude: `claude setup-token`.
        case token
        /// Codex: device code shown in the terminal.
        case deviceCode
    }

    /// Terminal login command for `account`, with the same strip/account recipe as agents.
    /// nil for flows that don't use a terminal (API keys and Codex access tokens go over stdin).
    public static func loginCommand(provider: Provider, flow: LoginFlow, account: Account?) -> String? {
        let tail: String
        switch (provider, flow) {
        case (.claude, .browser): tail = "claude auth login --claudeai"
        case (.claude, .token): tail = "claude setup-token"
        case (.codex, .browser): tail = "codex login"
        case (.codex, .deviceCode): tail = "codex login --device-auth"
        default: return nil
        }
        return envPrefix(provider: provider, account: account) + " " + tail
    }

    public static func loginCommand(provider: Provider, method: AuthMethod, account: Account?) -> String? {
        switch method {
        case .browser: return loginCommand(provider: provider, flow: .browser, account: account)
        case .token: return provider == .claude ? loginCommand(provider: provider, flow: .token, account: account) : nil
        case .apiKey, .existing: return nil
        }
    }

    /// Runs the login command, prints `doneNotice` when it ends and stays a shell so errors stay visible.
    /// Like a session terminal, the remaining shell carries the managed account's dir variable.
    public static func loginSpec(provider: Provider, flow: LoginFlow, account: Account?, doneNotice: String,
                                 cwd: String, processEnv: [String: String]) -> LaunchSpec? {
        guard let command = loginCommand(provider: provider, flow: flow, account: account) else { return nil }
        let script = "\(command); printf '\\n%s\\n' \(ShellQuote.quote(doneNotice)); " + keepShell(processEnv)
        var env = baseEnvironment(processEnv)
        for (key, value) in accountVariables(account) { env[key] = value }
        return LaunchSpec(executable: commandShell(processEnv), args: ["-l", "-i", "-c", script],
                          environment: env, cwd: cwd)
    }
}

/// Files that inject hdlanes into Claude Code: the plugin (hooks) and the per-session `--settings`
/// (status line wrapper).
public enum ClaudePluginFiles {
    public static let pluginName = "hdlanes"

    /// Hooks that only report; Claude doesn't wait for them.
    public static let asyncEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification",
        "Stop", "StopFailure", "SubagentStart", "SubagentStop", "SessionEnd",
    ]
    public static let permissionEvent = "PermissionRequest"
    /// Seconds Claude waits for the PermissionRequest hook (the hook itself gives up a little earlier).
    public static let permissionTimeout = 600
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]

    /// `'<hook path>' <argument>`, the command string Claude runs through its shell.
    public static func hookCommand(hookPath: String, argument: String) -> String {
        ShellQuote.quote(hookPath) + " " + argument
    }

    public static func pluginJSON(description: String) -> Data {
        encode(.object(["name": .string(pluginName), "version": .string("1"), "description": .string(description)]))
    }

    public static func hooksJSON(hookPath: String, includePermissionRequest: Bool, description: String) -> Data {
        var events: [String: JSONValue] = [:]
        for event in asyncEvents {
            events[event] = group(event: event, hook: [
                "type": .string("command"),
                "command": .string(hookCommand(hookPath: hookPath, argument: event)),
                "async": .bool(true),
            ])
        }
        if includePermissionRequest {
            events[permissionEvent] = group(event: permissionEvent, hook: [
                "type": .string("command"),
                "command": .string(hookCommand(hookPath: hookPath, argument: permissionEvent)),
                "timeout": .number(Double(permissionTimeout)),
            ])
        }
        return encode(.object(["description": .string(description), "hooks": .object(events)]))
    }

    private static func group(event: String, hook: [String: JSONValue]) -> JSONValue {
        var entry: [String: JSONValue] = ["hooks": .array([.object(hook)])]
        if toolEvents.contains(event) { entry["matcher"] = .string("*") }
        return .array([.object(entry)])
    }

    /// Per-session `--settings`: the status line goes through the hook (when there is one), and a
    /// managed account shares the default account's auto memory (`autoMemoryDirectory`).
    public static func sessionSettingsJSON(hookPath: String?, autoMemoryDirectory: String? = nil) -> Data {
        var root: [String: JSONValue] = [:]
        if let hookPath {
            root["statusLine"] = .object([
                "type": .string("command"),
                "command": .string(hookCommand(hookPath: hookPath, argument: "statusline")),
            ])
        }
        if let autoMemoryDirectory { root["autoMemoryDirectory"] = .string(autoMemoryDirectory) }
        return encode(.object(root))
    }

    /// The user's own `statusLine.command` from an account's settings.json, to chain behind ours.
    /// Reads only that key. nil when absent, not a command, or already pointing at hdlanes-hook.
    public static func statusLineCommand(fromSettings data: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              json.path("statusLine.type")?.string ?? "command" == "command",
              let command = json.path("statusLine.command")?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty, !command.contains("hdlanes-hook") else { return nil }
        return command
    }

    static func encode(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }
}
