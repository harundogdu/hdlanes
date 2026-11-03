import Foundation
import Testing
@testable import HDCore

struct AccountCLITests {
    @Test func environmentStripsCredentialsAndSetsDir() {
        let base = ["HOME": "/Users/x", "PATH": "/usr/bin", "ANTHROPIC_API_KEY": "k", "CLAUDE_CODE_OAUTH_TOKEN": "t",
                    "CLAUDECODE": "1", "CLAUDE_CONFIG_DIR": "/elsewhere", "OPENAI_API_KEY": "o", "CODEX_HOME": "/c",
                    "CODEX_ACCESS_TOKEN": "a", "LANG": "en_US.UTF-8"]
        let env = AccountCLI.environment(base: base, provider: .claude, configDir: "/Users/x/.hdlanes/accounts/claude/A",
                                         path: "/opt/bin:/usr/bin")
        #expect(env["CLAUDE_CONFIG_DIR"] == "/Users/x/.hdlanes/accounts/claude/A")
        #expect(env["PATH"] == "/opt/bin:/usr/bin")
        #expect(env["HOME"] == "/Users/x")
        #expect(env["LANG"] == "en_US.UTF-8")
        for key in ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDECODE", "OPENAI_API_KEY", "CODEX_HOME", "CODEX_ACCESS_TOKEN"] {
            #expect(env[key] == nil)
        }
    }

    @Test func systemDefaultAccountRunsWithoutDirVariable() {
        let base = ["CLAUDE_CONFIG_DIR": "/x", "CODEX_HOME": "/y", "PATH": "/usr/bin"]
        #expect(AccountCLI.environment(base: base, provider: .claude, configDir: nil)["CLAUDE_CONFIG_DIR"] == nil)
        let codex = AccountCLI.environment(base: base, provider: .codex, configDir: "/h/codex/B")
        #expect(codex["CODEX_HOME"] == "/h/codex/B")
        #expect(codex["CLAUDE_CONFIG_DIR"] == nil)
        #expect(codex["PATH"] == "/usr/bin")
    }

    @Test func quoting() {
        #expect(AccountCLI.quote("plain") == "'plain'")
        #expect(AccountCLI.quote("it's") == #"'it'\''s'"#)
        #expect(AccountCLI.quote("") == "''")
    }

    @Test func commandLineUnsetsCredentialsFirst() {
        let line = AccountCLI.commandLine(provider: .claude, configDir: "/a b/c", arguments: ["auth", "status", "--json"])
        #expect(line.hasPrefix("env -u ANTHROPIC_API_KEY "))
        #expect(line.contains("-u CLAUDE_CODE_OAUTH_TOKEN"))
        #expect(line.contains("-u CODEX_HOME"))
        #expect(line.hasSuffix("CLAUDE_CONFIG_DIR='/a b/c' claude 'auth' 'status' '--json'"))
        let codex = AccountCLI.commandLine(provider: .codex, configDir: nil, arguments: ["login", "status"])
        #expect(codex.contains("-u CODEX_HOME "))
        #expect(codex.contains("-u CODEX_ACCESS_TOKEN "))
        #expect(codex.hasSuffix(" codex 'login' 'status'"))
        #expect(!codex.contains("CODEX_HOME='"))
    }

    @Test func stripListComesFromEnvBuilder() {
        for name in EnvBuilder.claudeStripVariables + EnvBuilder.codexStripVariables {
            #expect(AccountCLI.strippedVariables.contains(name), "\(name)")
        }
        #expect(Set(AccountCLI.strippedVariables).count == AccountCLI.strippedVariables.count)
        // Before the shared list, AccountCLI lacked this one.
        let system = AccountCLI.commandLine(provider: .claude, configDir: nil, arguments: ["auth", "status"])
        #expect(system.contains("-u CLAUDE_CODE_DISABLE_TERMINAL_TITLE "))
    }

    @Test func providerSwitchesAreUnsetForManagedClaudeAccountsOnly() {
        let managed = AccountCLI.commandLine(provider: .claude, configDir: "/h/claude/A", arguments: ["auth", "status"])
        let system = AccountCLI.commandLine(provider: .claude, configDir: nil, arguments: ["auth", "status"])
        let codex = AccountCLI.commandLine(provider: .codex, configDir: "/h/codex/B", arguments: ["login", "status"])
        for name in ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_BASE_URL"] {
            #expect(managed.contains("-u \(name) "), "\(name)")
            #expect(!system.contains("-u \(name) "), "\(name)")
            #expect(!codex.contains("-u \(name) "), "\(name)")
        }
    }

    @Test func managedClaudeStatusIgnoresABedrockSwitchFromTheShell() throws {
        // A stand-in `claude` that reports which provider it would use.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hdlanes-acli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = "#!/bin/sh\nprintf 'bedrock=%s vertex=%s base=%s' \"$CLAUDE_CODE_USE_BEDROCK\" \"$CLAUDE_CODE_USE_VERTEX\" \"$ANTHROPIC_BASE_URL\"\n"
        let fake = dir.appendingPathComponent("claude")
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        func run(_ configDir: String?) throws -> String {
            let line = AccountCLI.commandLine(provider: .claude, configDir: configDir, arguments: ["auth", "status"])
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", line]
            p.environment = ["PATH": "\(dir.path):/usr/bin:/bin", "CLAUDE_CODE_USE_BEDROCK": "1",
                             "CLAUDE_CODE_USE_VERTEX": "1", "ANTHROPIC_BASE_URL": "https://proxy.invalid"]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        #expect(try run("/h/claude/A") == "bedrock= vertex= base=")
        #expect(try run(nil) == "bedrock=1 vertex=1 base=https://proxy.invalid")
    }

    @Test func commandNotFound() {
        #expect(AccountCLI.isCommandNotFound(status: 127, output: ""))
        #expect(AccountCLI.isCommandNotFound(status: 1, output: "zsh:1: command not found: claude"))
        #expect(AccountCLI.isCommandNotFound(status: 1, output: "env: claude: No such file or directory"))
        #expect(!AccountCLI.isCommandNotFound(status: 1, output: "Not logged in"))
    }

    @Test func extractsBetweenSentinels() {
        let out = "p10k noise\n__B__/a:/b__E__\ntrailing"
        #expect(AccountCLI.extract(between: "__B__", and: "__E__", in: out) == "/a:/b")
        #expect(AccountCLI.extract(between: "__B__", and: "__E__", in: "nothing") == nil)
    }

    @Test func parsesClaudeStatus() {
        let json = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"a@b.c","orgName":"Org","subscriptionType":"max"}"#
        let s = ClaudeAuthStatus.parse("some shell line\n" + json + "\n")
        #expect(s == ClaudeAuthStatus(loggedIn: true, authMethod: "claude.ai", email: "a@b.c", plan: "max", orgName: "Org"))

        let token = ClaudeAuthStatus.parse(#"{"loggedIn":true,"authMethod":"oauth_token"}"#)
        #expect(token?.loggedIn == true)
        #expect(token?.email == nil && token?.plan == nil)

        #expect(ClaudeAuthStatus.parse(#"{"loggedIn":false}"#)?.loggedIn == false)
        #expect(ClaudeAuthStatus.parse("not json") == nil)
        #expect(ClaudeAuthStatus.parse(#"{"other":1}"#) == nil)
    }

    @Test func parsesCodexStatus() {
        #expect(CodexLoginStatus.parse("Logged in using ChatGPT\n") == .loggedIn(.chatgpt))
        #expect(CodexLoginStatus.parse("Logged in using an API key - sk-***abcd") == .loggedIn(.apiKey))
        #expect(CodexLoginStatus.parse("Logged in using an access token") == .loggedIn(.accessToken))
        #expect(CodexLoginStatus.parse("Not logged in") == .loggedOut)
        #expect(CodexLoginStatus.parse("Logged in") == .loggedIn(.other))
        #expect(CodexLoginStatus.parse("error: something") == .unknown)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func tokenMergePreservesOtherKeys() throws {
        let existing = Data(#"{"model":"opus","env":{"FOO":"1"},"permissions":{"allow":["Bash(ls)"]},"n":3}"#.utf8)
        let merged = try object(ClaudeSettingsFile.settingOAuthToken("tok", in: existing))
        let env = try #require(merged["env"] as? [String: Any])
        #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] as? String == "tok")
        #expect(env["FOO"] as? String == "1")
        #expect(merged["model"] as? String == "opus")
        #expect(merged["n"] as? Int == 3)
        #expect((merged["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls)"])
    }

    @Test func tokenMergeIntoMissingOrEmptyFile() throws {
        for existing in [nil, Data(), Data("  \n".utf8)] as [Data?] {
            let merged = try object(ClaudeSettingsFile.settingOAuthToken("t", in: existing))
            #expect((merged["env"] as? [String: Any])?["CLAUDE_CODE_OAUTH_TOKEN"] as? String == "t")
        }
    }

    @Test func mergeRefusesFilesItCannotRead() {
        #expect(throws: ClaudeSettingsFile.MergeError.notAnObject) {
            try ClaudeSettingsFile.settingOAuthToken("t", in: Data("[1,2]".utf8))
        }
        #expect(throws: ClaudeSettingsFile.MergeError.envNotAnObject) {
            try ClaudeSettingsFile.settingOAuthToken("t", in: Data(#"{"env":"x"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try ClaudeSettingsFile.settingAPIKeyHelper(keyFilePath: "/k", in: Data("{broken".utf8))
        }
    }

    @Test func apiKeyHelperMerge() throws {
        let merged = try object(ClaudeSettingsFile.settingAPIKeyHelper(keyFilePath: "/Users/x/it's/.hdlanes-api-key",
                                                                        in: Data(#"{"theme":"dark"}"#.utf8)))
        #expect(merged["apiKeyHelper"] as? String == #"cat '/Users/x/it'\''s/.hdlanes-api-key'"#)
        #expect(merged["theme"] as? String == "dark")
    }

    @Test func privateFileIsOwnerOnlyAndReplacesAtomically() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hdlanes-pf-\(UUID().uuidString)")
        try HDPaths.ensurePrivateDir(dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try Data("old".utf8).write(to: url)
        try PrivateFile.write(Data("new".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp-") }
        #expect(leftovers.isEmpty)
    }
}
