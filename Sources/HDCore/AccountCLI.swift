import Foundation

// OWNER: workspace area. Pure helpers for running the vendor CLIs as a given account (status checks,
// saving a token or key) without ever seeing another account's credentials.

public enum AccountCLI {
    /// Credential and account-selection variables that must never leak from the app's or the user's
    /// shell environment into a CLI run for a specific account. Built from `EnvBuilder`'s lists, so a
    /// status check runs with the same recipe as a session.
    public static var strippedVariables: [String] {
        unique(EnvBuilder.claudeStripVariables + EnvBuilder.codexStripVariables)
    }

    /// `strippedVariables`, plus `EnvBuilder`'s provider switches for a managed account.
    public static func strippedVariables(for provider: Provider, managedAccount: Bool) -> [String] {
        unique(strippedVariables + EnvBuilder.stripVariables(for: provider, managedAccount: managedAccount))
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static let strippedPrefixes = ["ANTHROPIC_", "CLAUDE_CODE_", "OPENAI_", "CODEX_"]

    /// The variable that selects an account's dir for `provider`.
    public static func dirVariable(for provider: Provider) -> String? {
        switch provider {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        case .shell: return nil
        }
    }

    /// `base` with every credential variable removed and the account's dir variable set (managed
    /// accounts only; system default accounts run without it). `path` replaces PATH when given.
    public static func environment(base: [String: String], provider: Provider, configDir: String?,
                                   path: String? = nil) -> [String: String] {
        var env = base.filter { key, _ in
            !(key == "CLAUDECODE" || key == "CLAUDE_CONFIG_DIR" || key == "CODEX_HOME"
              || strippedPrefixes.contains { key.hasPrefix($0) })
        }
        if let variable = dirVariable(for: provider), let configDir, !configDir.isEmpty {
            env[variable] = configDir
        }
        if let path, !path.isEmpty { env["PATH"] = path }
        return env
    }

    /// Single-quotes a value for a POSIX shell (`'` → `'\''`).
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A shell line that runs the vendor CLI as the account even if the user's shell init exports
    /// credentials: `env -u … [CLAUDE_CONFIG_DIR='<dir>'] claude 'auth' 'status' '--json'`. A non-empty
    /// `configDir` means a managed account (system default accounts pass nil). `variables` are set on the
    /// same line, after the shell profile has run; names that aren't `[A-Z0-9_]+` are dropped.
    public static func commandLine(provider: Provider, configDir: String?, arguments: [String],
                                   variables: [String: String] = [:]) -> String {
        var parts = ["env"]
        let managed = !(configDir ?? "").isEmpty
        for v in strippedVariables(for: provider, managedAccount: managed) { parts += ["-u", v] }
        if let variable = dirVariable(for: provider), let configDir, !configDir.isEmpty {
            parts.append("\(variable)=\(quote(configDir))")
        }
        for (name, value) in variables.sorted(by: { $0.key < $1.key }) where isVariableName(name) {
            parts.append("\(name)=\(quote(value))")
        }
        parts.append(provider == .codex ? "codex" : "claude")
        parts += arguments.map(quote)
        return parts.joined(separator: " ")
    }

    static func isVariableName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// Exit status / output that means the shell couldn't find the CLI at all.
    public static func isCommandNotFound(status: Int32, output: String) -> Bool {
        if status == 127 { return true }
        let lower = output.lowercased()
        return lower.contains("command not found") || (lower.contains("env:") && lower.contains("no such file"))
    }

    /// Text between two sentinels, e.g. the PATH printed by `zsh -l -i -c 'printf …'`.
    public static func extract(between begin: String, and end: String, in output: String) -> String? {
        guard let b = output.range(of: begin), let e = output.range(of: end, range: b.upperBound..<output.endIndex)
        else { return nil }
        return String(output[b.upperBound..<e.lowerBound])
    }
}

// MARK: Status parsing

/// Parsed `claude auth status --json`. `email` / `plan` are only reported for claude.ai logins.
public struct ClaudeAuthStatus: Equatable, Sendable {
    public var loggedIn: Bool
    /// "claude.ai", "oauth_token", "api_key_helper", …
    public var authMethod: String?
    public var email: String?
    public var plan: String?
    public var orgName: String?

    public init(loggedIn: Bool, authMethod: String? = nil, email: String? = nil, plan: String? = nil, orgName: String? = nil) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.email = email
        self.plan = plan
        self.orgName = orgName
    }

    /// Finds the JSON object in the output (the shell may print other lines) and reads it.
    public static func parse(_ output: String) -> ClaudeAuthStatus? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let loggedIn = json["loggedIn"]?.bool
        else { return nil }
        func text(_ key: String) -> String? {
            guard let s = json[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        return ClaudeAuthStatus(loggedIn: loggedIn, authMethod: text("authMethod"), email: text("email"),
                                plan: text("subscriptionType"), orgName: text("orgName"))
    }
}

/// Parsed `codex login status` (plain text, printed on stderr by current versions).
public enum CodexLoginStatus: Equatable, Sendable {
    public enum Kind: String, Sendable { case chatgpt, apiKey, accessToken, other }

    case loggedIn(Kind)
    case loggedOut
    case unknown

    public static func parse(_ output: String) -> CodexLoginStatus {
        let lower = output.lowercased()
        if lower.contains("not logged in") { return .loggedOut }
        guard lower.contains("logged in") else { return .unknown }
        if lower.contains("chatgpt") { return .loggedIn(.chatgpt) }
        if lower.contains("api key") { return .loggedIn(.apiKey) }
        if lower.contains("access token") { return .loggedIn(.accessToken) }
        return .loggedIn(.other)
    }
}

// MARK: Claude settings.json

/// Edits a Claude config dir's `settings.json` without touching keys hdlanes doesn't own.
public enum ClaudeSettingsFile {
    public enum MergeError: Error, Equatable, LocalizedError {
        /// The existing file isn't a JSON object; it is left as it is.
        case notAnObject
        case envNotAnObject

        public var errorDescription: String? {
            switch self {
            case .notAnObject: return "settings.json is not a JSON object; it was left unchanged."
            case .envNotAnObject: return "settings.json has an \"env\" value that is not an object; it was left unchanged."
            }
        }
    }

    public static let oauthTokenVariable = "CLAUDE_CODE_OAUTH_TOKEN"
    public static let apiKeyFileName = ".hdlanes-api-key"

    /// `existing` with `env.CLAUDE_CODE_OAUTH_TOKEN` set.
    public static func settingOAuthToken(_ token: String, in existing: Data?) throws -> Data {
        try merge(existing) { root in
            var env: [String: Any] = [:]
            if let current = root["env"] {
                guard let dict = current as? [String: Any] else { throw MergeError.envNotAnObject }
                env = dict
            }
            env[oauthTokenVariable] = token
            root["env"] = env
        }
    }

    /// `existing` with `apiKeyHelper` set to print the key file.
    public static func settingAPIKeyHelper(keyFilePath: String, in existing: Data?) throws -> Data {
        try merge(existing) { root in
            root["apiKeyHelper"] = apiKeyHelperCommand(keyFilePath: keyFilePath)
        }
    }

    public static func apiKeyHelperCommand(keyFilePath: String) -> String {
        "cat \(AccountCLI.quote(keyFilePath))"
    }

    static func merge(_ existing: Data?, _ change: (inout [String: Any]) throws -> Void) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !String(decoding: existing, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let dict = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw MergeError.notAnObject
            }
            root = dict
        }
        try change(&root)
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

// MARK: Private files

public enum PrivateFile {
    /// Writes `data` so the file is never readable by others, not even briefly: a 0600 temp file in
    /// the same directory, then an atomic rename over the target.
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        if rename(temp.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
