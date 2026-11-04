import Foundation
import Testing
@testable import HDCore

struct EnvBuilderTests {
    let processEnv = [
        "HOME": "/Users/u", "USER": "u", "LOGNAME": "u", "SHELL": "/bin/zsh", "TMPDIR": "/var/folders/x/",
        "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LANG": "tr_TR.UTF-8", "LC_ALL": "tr_TR.UTF-8",
        "CLAUDE_CONFIG_DIR": "/Users/u/.claude", "CODEX_HOME": "/Users/u/.codex",
        "ANTHROPIC_API_KEY": "sk-leak", "OPENAI_API_KEY": "sk-leak", "CLAUDECODE": "1",
        "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1", "TMUX": "/tmp/tmux", "TMUX_PANE": "%1",
        "XPC_SERVICE_NAME": "app", "SECRET_THING": "x",
    ]

    let systemClaude = Account(provider: .claude, label: "Default", colorIndex: 0, isSystemDefault: true,
                               configDir: "/Users/u/.claude", authMethod: .existing)
    let managedDir = "/Users/u/.hdlanes/accounts/claude/AB CD/e\u{301}"   // space + decomposed é, kept as is
    var managedClaude: Account {
        Account(provider: .claude, label: "Work", colorIndex: 1, isSystemDefault: false, configDir: managedDir,
                authMethod: .browser)
    }
    let managedCodex = Account(provider: .codex, label: "Codex 2", colorIndex: 2, isSystemDefault: false,
                               configDir: "/Users/u/.hdlanes/accounts/codex/X", authMethod: .browser)

    // MARK: Environment

    @Test func baseEnvironmentIsAnAllowlist() {
        let env = EnvBuilder.baseEnvironment(processEnv)
        #expect(Set(env.keys) == ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PATH", "LANG", "LC_ALL",
                                  "TERM", "COLORTERM", "TERM_PROGRAM"])
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == "hdlanes")
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin")
    }

    @Test func baseEnvironmentFillsMissingPathAndLocale() {
        let env = EnvBuilder.baseEnvironment(["HOME": "/Users/u"])
        #expect(env["PATH"] == EnvBuilder.fallbackPath)
        #expect(env["LANG"] == "en_US.UTF-8")
        let withCtype = EnvBuilder.baseEnvironment(["LC_CTYPE": "UTF-8"])
        #expect(withCtype["LANG"] == nil)
    }

    @Test func systemAccountNeverGetsConfigDirEvenIfAppHadOne() {
        #expect(EnvBuilder.accountVariables(systemClaude).isEmpty)
        let cli = EnvBuilder.cliEnvironment(account: systemClaude, processEnv: processEnv)
        #expect(cli["CLAUDE_CONFIG_DIR"] == nil)
        #expect(cli["CODEX_HOME"] == nil)
        #expect(cli["ANTHROPIC_API_KEY"] == nil)

        let launch = EnvBuilder.AgentLaunch(provider: .claude, account: systemClaude, title: "t",
                                            agentSessionID: "11111111-1111-1111-1111-111111111111", resume: false)
        let command = EnvBuilder.agentCommand(launch)
        #expect(command.contains("-u CLAUDE_CONFIG_DIR"))
        #expect(!command.contains("CLAUDE_CONFIG_DIR='"))
        let spec = EnvBuilder.launchSpec(launch, session: .init(socketPath: "/s", sessionID: UUID(), accountID: systemClaude.id),
                                         cwd: "/repo", processEnv: processEnv)
        #expect(spec.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(spec.environment["CODEX_HOME"] == nil)
    }

    @Test func systemCodexAccountGetsNoCodexHome() {
        let system = Account(provider: .codex, label: "Default", colorIndex: 0, isSystemDefault: true,
                             configDir: "/Users/u/.codex", authMethod: .existing)
        let command = EnvBuilder.agentCommand(.init(provider: .codex, account: system, title: "t", agentSessionID: nil, resume: false))
        #expect(command == "env -u OPENAI_API_KEY -u CODEX_API_KEY -u CODEX_ACCESS_TOKEN -u CODEX_HOME codex")
    }

    @Test func managedAccountDirIsPassedByteExact() {
        #expect(EnvBuilder.accountVariables(managedClaude) == ["CLAUDE_CONFIG_DIR": managedDir])
        #expect(Array(EnvBuilder.accountVariables(managedClaude)["CLAUDE_CONFIG_DIR"]!.utf8) == Array(managedDir.utf8))
        let command = EnvBuilder.agentCommand(.init(provider: .claude, account: managedClaude, title: "t",
                                                    agentSessionID: nil, resume: false))
        #expect(Array(command.utf8).firstRange(of: Array("CLAUDE_CONFIG_DIR='\(managedDir)'".utf8)) != nil)
        #expect(EnvBuilder.accountVariables(managedCodex) == ["CODEX_HOME": "/Users/u/.hdlanes/accounts/codex/X"])
        #expect(EnvBuilder.cliEnvironment(account: managedCodex, processEnv: processEnv)["CODEX_HOME"]
                == "/Users/u/.hdlanes/accounts/codex/X")
    }

    @Test func stripListsArePresent() {
        let claude = EnvBuilder.agentCommand(.init(provider: .claude, account: managedClaude, title: "",
                                                   agentSessionID: nil, resume: false))
        for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDECODE",
                     "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_DISABLE_TERMINAL_TITLE", "CLAUDE_CONFIG_DIR", "CODEX_HOME"] {
            #expect(claude.contains("-u \(name) "))
        }
        let codex = EnvBuilder.agentCommand(.init(provider: .codex, account: managedCodex, title: "",
                                                  agentSessionID: nil, resume: false))
        for name in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_HOME"] {
            #expect(codex.contains("-u \(name) "))
        }
        #expect(codex.hasSuffix("CODEX_HOME='/Users/u/.hdlanes/accounts/codex/X' codex"))
    }

    @Test func providerSwitchesAreUnsetForManagedClaudeAccountsOnly() {
        let switches = ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                        "CLAUDE_CODE_USE_ANTHROPIC_AWS", "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD", "CLAUDE_CODE_USE_MANTLE",
                        "ANTHROPIC_BASE_URL"]
        #expect(EnvBuilder.claudeProviderSwitchVariables == switches)
        let managed = EnvBuilder.agentCommand(.init(provider: .claude, account: managedClaude, title: "",
                                                    agentSessionID: nil, resume: false))
        // The system default account keeps the user's own provider setup (e.g. Bedrock from .zshrc).
        let system = EnvBuilder.agentCommand(.init(provider: .claude, account: systemClaude, title: "",
                                                   agentSessionID: nil, resume: false))
        let codex = EnvBuilder.agentCommand(.init(provider: .codex, account: managedCodex, title: "",
                                                  agentSessionID: nil, resume: false))
        let login = EnvBuilder.loginCommand(provider: .claude, flow: .browser, account: managedClaude) ?? ""
        for name in switches {
            #expect(managed.contains("-u \(name) "), "\(name)")
            #expect(login.contains("-u \(name) "), "\(name)")
            #expect(!system.contains("-u \(name) "), "\(name)")
            #expect(!codex.contains("-u \(name) "), "\(name)")
        }
    }

    @Test func managedSessionIgnoresProviderSwitchesFromShellInit() throws {
        let dir = try tempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let script = "#!/bin/sh\nprintf 'bedrock=%s vertex=%s foundry=%s base=%s' \"$CLAUDE_CODE_USE_BEDROCK\" \"$CLAUDE_CODE_USE_VERTEX\" \"$CLAUDE_CODE_USE_FOUNDRY\" \"$ANTHROPIC_BASE_URL\"\n"
        let fake = dir.appendingPathComponent("bin/claude")
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        // What a `.zshrc` exporting the switches leaves in the agent's shell.
        let env = ["PATH": "\(dir.path)/bin:/usr/bin:/bin", "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_USE_VERTEX": "1",
                   "CLAUDE_CODE_USE_FOUNDRY": "1", "ANTHROPIC_BASE_URL": "https://proxy.invalid"]
        let managed = try sh(EnvBuilder.agentInvocation(.init(provider: .claude, account: managedClaude, title: "",
                                                              agentSessionID: nil, resume: false)), env: env)
        #expect(managed == "bedrock= vertex= foundry= base=")
        let system = try sh(EnvBuilder.agentInvocation(.init(provider: .claude, account: systemClaude, title: "",
                                                             agentSessionID: nil, resume: false)), env: env)
        #expect(system == "bedrock=1 vertex=1 foundry=1 base=https://proxy.invalid")
    }

    // MARK: Command line

    @Test func claudeNewSessionCommand() {
        let launch = EnvBuilder.AgentLaunch(provider: .claude, account: systemClaude, title: "Fix login",
                                            agentSessionID: "11111111-1111-1111-1111-111111111111", resume: false,
                                            initialPrompt: "Look at it", pluginDir: "/p/plugin",
                                            settingsPath: "/r/settings.json")
        let tail = EnvBuilder.agentInvocation(launch).components(separatedBy: " -u CODEX_HOME ").last
        #expect(tail == "claude --plugin-dir '/p/plugin' --settings '/r/settings.json' --session-id "
                + "'11111111-1111-1111-1111-111111111111' -n 'Fix login' 'Look at it'")
    }

    @Test func claudeResumeUsesResumeFlag() {
        let launch = EnvBuilder.AgentLaunch(provider: .claude, account: nil, title: "x",
                                            agentSessionID: "22222222-2222-2222-2222-222222222222", resume: true)
        let command = EnvBuilder.agentCommand(launch)
        #expect(command.contains("--resume '22222222-2222-2222-2222-222222222222'"))
        #expect(!command.contains("--session-id"))
    }

    @Test func codexResumeAndPrompt() {
        let resume = EnvBuilder.agentCommand(.init(provider: .codex, account: nil, title: "x",
                                                   agentSessionID: "019a-thread", resume: true))
        #expect(resume.hasSuffix("codex resume '019a-thread'"))
        let fresh = EnvBuilder.agentCommand(.init(provider: .codex, account: nil, title: "x",
                                                  agentSessionID: "019a-thread", resume: false, initialPrompt: "do it"))
        #expect(fresh.hasSuffix("codex 'do it'"))
        #expect(!fresh.contains("resume"))
    }

    @Test func promptStartingWithDashEndsOptions() {
        let command = EnvBuilder.agentCommand(.init(provider: .codex, account: nil, title: "", agentSessionID: nil,
                                                    resume: false, initialPrompt: "-rf everything"))
        #expect(command.hasSuffix("codex -- '-rf everything'"))
    }

    @Test func quotingSurvivesTheShell() throws {
        let nasty = ["it's", "\"$HOME\" `id` $(id)", "line1\nline2", "back\\slash", "!event", "a'b'c''", ""]
        for value in nasty {
            #expect(try sh("printf %s \(ShellQuote.quote(value))") == value)
        }
        #expect(ShellQuote.quote("it's") == #"'it'\''s'"#)
        #expect(ShellQuote.join(["a b", "c"]) == "'a b' 'c'")
    }

    @Test func titleAndPromptReachTheAgentIntact() throws {
        let dir = try tempDir()
        try fakeAgent(named: "claude", in: dir)
        let title = "Fix \"it's\" $HOME"
        let prompt = "first line\nsecond `uname` $(whoami) 'q'"
        let launch = EnvBuilder.AgentLaunch(provider: .claude, account: managedClaude, title: title,
                                            agentSessionID: "33333333-3333-3333-3333-333333333333", resume: false,
                                            initialPrompt: prompt)
        let out = try sh(EnvBuilder.agentCommand(launch),
                         env: ["PATH": "\(dir.path):/usr/bin:/bin", "ANTHROPIC_API_KEY": "leak", "CLAUDECODE": "1"])
        let lines = out.components(separatedBy: "\u{1F}")
        #expect(lines.first?.hasPrefix("dir=\(managedDir) key= cc= pwd=") == true)
        #expect(Array(lines.dropFirst()) == ["--session-id", "33333333-3333-3333-3333-333333333333", "-n", title, prompt])
    }

    @Test func setupFailureStillStartsTheAgent() throws {
        let dir = try tempDir()
        try fakeAgent(named: "codex", in: dir)
        let launch = EnvBuilder.AgentLaunch(provider: .codex, account: managedCodex, title: "", agentSessionID: nil,
                                            resume: false, setupCommand: "cd / ; echo setup-ran # trailing comment\nexit 3",
                                            setupFailedNotice: "Setup failed; starting anyway.")
        let command = EnvBuilder.agentCommand(launch)
        #expect(command.hasPrefix("(\ncd / ; echo setup-ran # trailing comment\nexit 3\n) || printf"))
        let out = try sh(command, env: ["PATH": "\(dir.path):/usr/bin:/bin"], cwd: dir.path)
        #expect(out.contains("setup-ran"))
        #expect(out.contains("Setup failed; starting anyway. (3)"))
        // The agent runs after the setup, in the original directory, with the account's CODEX_HOME.
        #expect(out.contains("dir=/Users/u/.hdlanes/accounts/codex/X"))
        #expect(out.contains("pwd=\(CodexRollout.canonicalPath(dir.path))"))
    }

    @Test func setupSuccessPrintsNoNotice() throws {
        let dir = try tempDir()
        try fakeAgent(named: "codex", in: dir)
        let launch = EnvBuilder.AgentLaunch(provider: .codex, account: nil, title: "", agentSessionID: nil, resume: false,
                                            setupCommand: "true", setupFailedNotice: "NOTICE")
        let out = try sh(EnvBuilder.agentCommand(launch), env: ["PATH": "\(dir.path):/usr/bin:/bin"])
        #expect(!out.contains("NOTICE"))
        #expect(out.contains("dir= "))
    }

    // MARK: Launch spec

    @Test func launchSpecRunsAgentThenKeepsShell() {
        let session = UUID()
        let account = UUID()
        let launch = EnvBuilder.AgentLaunch(provider: .claude, account: nil, title: "t", agentSessionID: nil, resume: false)
        let spec = EnvBuilder.launchSpec(launch, session: .init(socketPath: "/h/run/hd.sock", sessionID: session,
                                                                 accountID: account, statusLineChain: "~/bin/line.sh"),
                                         cwd: "/repo", processEnv: processEnv)
        #expect(spec.executable == "/bin/zsh")
        #expect(spec.args.count == 4)
        #expect(Array(spec.args.prefix(3)) == ["-l", "-i", "-c"])
        #expect(spec.args[3] == EnvBuilder.agentCommand(launch) + "; exec '/bin/zsh' -l -i")
        #expect(spec.cwd == "/repo")
        #expect(spec.environment["HD_SOCKET"] == "/h/run/hd.sock")
        #expect(spec.environment["HD_SESSION_ID"] == session.uuidString)
        #expect(spec.environment["HD_ACCOUNT_ID"] == account.uuidString)
        #expect(spec.environment["HD_STATUSLINE_CHAIN"] == "~/bin/line.sh")
        #expect(spec.environment["TERM_PROGRAM"] == "hdlanes")
        #expect(spec.environment["ANTHROPIC_API_KEY"] == nil)
    }

    @Test func launchSpecOmitsEmptyChainAndAccount() {
        let launch = EnvBuilder.AgentLaunch(provider: .codex, account: nil, title: "t", agentSessionID: nil, resume: false)
        let spec = EnvBuilder.launchSpec(launch, session: .init(socketPath: "/s", sessionID: UUID(), accountID: nil,
                                                                 statusLineChain: ""),
                                         cwd: "/repo", processEnv: processEnv)
        #expect(spec.environment["HD_ACCOUNT_ID"] == nil)
        #expect(spec.environment["HD_STATUSLINE_CHAIN"] == nil)
    }

    @Test func nonPosixShellRunsCommandUnderZsh() {
        var env = processEnv
        env["SHELL"] = "/opt/homebrew/bin/fish"
        let launch = EnvBuilder.AgentLaunch(provider: .codex, account: nil, title: "", agentSessionID: nil, resume: false)
        let spec = EnvBuilder.launchSpec(launch, session: .init(socketPath: "/s", sessionID: UUID(), accountID: nil),
                                         cwd: "/", processEnv: env)
        #expect(spec.executable == "/bin/zsh")
        #expect(spec.args[3].hasSuffix("; exec '/opt/homebrew/bin/fish' -l -i"))
        #expect(EnvBuilder.shellSpec(cwd: "/", processEnv: env).executable == "/opt/homebrew/bin/fish")
    }

    @Test func shellProviderIsAPlainLoginShell() {
        var env = processEnv
        env["SHELL"] = "/bin/bash"
        let launch = EnvBuilder.AgentLaunch(provider: .shell, account: nil, title: "", agentSessionID: nil, resume: false)
        let spec = EnvBuilder.launchSpec(launch, session: .init(socketPath: "/s", sessionID: UUID(), accountID: nil),
                                         cwd: "/w", processEnv: env)
        #expect(spec.executable == "/bin/bash")
        #expect(spec.args == ["-l", "-i"])
        #expect(spec.environment["HD_SESSION_ID"] == nil)
        #expect(EnvBuilder.userShell([:]) == "/bin/zsh")
        #expect(EnvBuilder.userShell(["SHELL": "zsh"]) == "/bin/zsh")
    }

    // MARK: Login

    @Test func loginCommands() {
        #expect(EnvBuilder.loginCommand(provider: .claude, method: .browser, account: managedClaude)?
            .hasSuffix("CLAUDE_CONFIG_DIR='\(managedDir)' claude auth login --claudeai") == true)
        #expect(EnvBuilder.loginCommand(provider: .claude, method: .token, account: systemClaude)?
            .hasSuffix("-u CODEX_HOME claude setup-token") == true)
        #expect(EnvBuilder.loginCommand(provider: .codex, method: .browser, account: managedCodex)?
            .hasSuffix("CODEX_HOME='/Users/u/.hdlanes/accounts/codex/X' codex login") == true)
        #expect(EnvBuilder.loginCommand(provider: .codex, flow: .deviceCode, account: managedCodex)?
            .hasSuffix("codex login --device-auth") == true)
        #expect(EnvBuilder.loginCommand(provider: .codex, method: .token, account: managedCodex) == nil)
        #expect(EnvBuilder.loginCommand(provider: .claude, method: .apiKey, account: managedClaude) == nil)
        #expect(EnvBuilder.loginCommand(provider: .claude, method: .existing, account: systemClaude) == nil)
    }

    @Test func loginSpecPrintsDoneAndKeepsShell() throws {
        let spec = try #require(EnvBuilder.loginSpec(provider: .claude, flow: .browser, account: managedClaude,
                                                     doneNotice: "Login finished.", cwd: "/Users/u", processEnv: processEnv))
        #expect(spec.args.prefix(3) == ["-l", "-i", "-c"])
        #expect(spec.args[3].contains("claude auth login --claudeai; printf '\\n%s\\n' 'Login finished.'; exec '/bin/zsh' -l -i"))
        // The shell left after the login command is the account's too.
        #expect(spec.environment["CLAUDE_CONFIG_DIR"] == managedDir)
        #expect(spec.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(spec.environment["HD_SESSION_ID"] == nil)
        let system = try #require(EnvBuilder.loginSpec(provider: .claude, flow: .token, account: systemClaude,
                                                       doneNotice: "x", cwd: "/", processEnv: processEnv))
        #expect(system.environment["CLAUDE_CONFIG_DIR"] == nil)
    }

    @Test func shellLeftAfterTheAgentKeepsTheManagedAccount() throws {
        let launch = EnvBuilder.AgentLaunch(provider: .claude, account: managedClaude, title: "t", agentSessionID: nil, resume: false)
        let spec = EnvBuilder.launchSpec(launch, session: .init(socketPath: "/s", sessionID: UUID(), accountID: managedClaude.id),
                                         cwd: "/repo", processEnv: processEnv)
        #expect(spec.environment["CLAUDE_CONFIG_DIR"] == managedDir)
        #expect(spec.environment["CODEX_HOME"] == nil)
        let codex = EnvBuilder.launchSpec(.init(provider: .codex, account: managedCodex, title: "t", agentSessionID: nil, resume: false),
                                          session: .init(socketPath: "/s", sessionID: UUID(), accountID: managedCodex.id),
                                          cwd: "/repo", processEnv: processEnv)
        #expect(codex.environment["CODEX_HOME"] == "/Users/u/.hdlanes/accounts/codex/X")
        #expect(codex.environment["CLAUDE_CONFIG_DIR"] == nil)

        // Run the trailing part as the terminal would: a `claude` typed there sees the account's dir.
        let dir = try tempDir()
        try fakeAgent(named: "claude", in: dir)
        var env = spec.environment
        env["PATH"] = "\(dir.path):/usr/bin:/bin"
        let out = try sh("claude", env: env)
        #expect(out.hasPrefix("dir=\(managedDir) "))
    }

    @Test func cliEnvironmentUsesLoginPath() {
        let env = EnvBuilder.cliEnvironment(account: managedClaude, processEnv: processEnv, loginPath: "/nvm/bin:/usr/bin")
        #expect(env["PATH"] == "/nvm/bin:/usr/bin")
        #expect(env["CLAUDE_CONFIG_DIR"] == managedDir)
        #expect(env["OPENAI_API_KEY"] == nil)
    }

    // MARK: Plugin files

    @Test func hooksJSONShape() throws {
        let data = ClaudePluginFiles.hooksJSON(hookPath: "/App Dir/hdlanes-hook", includePermissionRequest: true,
                                               description: "d")
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let hooks = try #require(json["hooks"]?.object)
        #expect(Set(hooks.keys) == Set(ClaudePluginFiles.asyncEvents + ["PermissionRequest"]))
        let stop = try #require(hooks["Stop"]?.array?.first)
        #expect(stop["matcher"] == nil)
        #expect(stop["hooks"]?.array?.first?["command"]?.string == "'/App Dir/hdlanes-hook' Stop")
        #expect(stop["hooks"]?.array?.first?["async"]?.bool == true)
        let pre = try #require(hooks["PreToolUse"]?.array?.first)
        #expect(pre["matcher"]?.string == "*")
        let permission = try #require(hooks["PermissionRequest"]?.array?.first)
        #expect(permission["matcher"]?.string == "*")
        #expect(permission["hooks"]?.array?.first?["async"] == nil)
        #expect(permission["hooks"]?.array?.first?["timeout"]?.double == 600)
        #expect(String(decoding: data, as: UTF8.self).contains("\"timeout\" : 600"))
    }

    @Test func hooksJSONWithoutPermission() throws {
        let data = ClaudePluginFiles.hooksJSON(hookPath: "/h", includePermissionRequest: false, description: "d")
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(json["hooks"]?["PermissionRequest"] == nil)
        #expect(json["hooks"]?["SessionEnd"] != nil)
    }

    @Test func pluginAndSettingsJSON() throws {
        let plugin = try JSONDecoder().decode(JSONValue.self, from: ClaudePluginFiles.pluginJSON(description: "desc"))
        #expect(plugin["name"]?.string == "hdlanes")
        #expect(plugin["version"]?.string == "1")
        let settings = try JSONDecoder().decode(JSONValue.self, from: ClaudePluginFiles.sessionSettingsJSON(hookPath: "/b/hdlanes-hook"))
        #expect(settings.path("statusLine.type")?.string == "command")
        #expect(settings.path("statusLine.command")?.string == "'/b/hdlanes-hook' statusline")
        #expect(settings.path("autoMemoryDirectory") == nil)
    }

    @Test func sessionSettingsCarryTheSharedMemoryDirWithOrWithoutTheHook() throws {
        let both = try JSONDecoder().decode(JSONValue.self, from: ClaudePluginFiles.sessionSettingsJSON(
            hookPath: "/b/hdlanes-hook", autoMemoryDirectory: "/Users/u/.claude/projects/-r/memory"))
        #expect(both.path("autoMemoryDirectory")?.string == "/Users/u/.claude/projects/-r/memory")
        #expect(both.path("statusLine.command") != nil)
        let memoryOnly = try JSONDecoder().decode(JSONValue.self, from: ClaudePluginFiles.sessionSettingsJSON(
            hookPath: nil, autoMemoryDirectory: "/m"))
        #expect(memoryOnly.path("autoMemoryDirectory")?.string == "/m")
        #expect(memoryOnly.path("statusLine") == nil)
    }

    @Test func userStatusLineCommandIsChainedOnlyWhenItIsAnotherCommand() {
        func cmd(_ s: String) -> String? { ClaudePluginFiles.statusLineCommand(fromSettings: Data(s.utf8)) }
        #expect(cmd(#"{"statusLine":{"type":"command","command":"~/.claude/line.sh","padding":0},"env":{"X":"y"}}"#) == "~/.claude/line.sh")
        #expect(cmd(#"{"statusLine":{"command":"bunx ccstatusline"}}"#) == "bunx ccstatusline")
        #expect(cmd(#"{"statusLine":{"type":"command","command":"'/x/hdlanes-hook' statusline"}}"#) == nil)
        #expect(cmd(#"{"statusLine":{"type":"static","command":"x"}}"#) == nil)
        #expect(cmd(#"{"model":"opus"}"#) == nil)
        #expect(cmd("not json") == nil)
    }

    // MARK: Helpers

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hdlanes-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stand-in agent that prints the account dir, leaked credentials and its argv (unit-separated).
    private func fakeAgent(named name: String, in dir: URL) throws {
        let script = """
        #!/bin/sh
        printf 'dir=%s%s key=%s cc=%s pwd=%s' "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" "$ANTHROPIC_API_KEY" "$CLAUDECODE" "$(pwd -P)"
        for a in "$@"; do printf '\\037%s' "$a"; done
        """
        let url = dir.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @discardableResult
    private func sh(_ command: String, env: [String: String] = ["PATH": "/usr/bin:/bin"], cwd: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
