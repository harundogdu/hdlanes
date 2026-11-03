import Foundation

// OWNER: workspace area (import).

/// An existing Claude Code / Codex account folder found outside hdlanes.
public struct AccountCandidate: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// `claudeCode.environmentVariables` (or a terminal env setting) of a VS Code-family editor.
        case vscodeSettings(String)
        /// An `export` or alias line in a shell profile (file name, e.g. `.zshrc`).
        case shellProfile(String)
        /// A `~/.claude-*` / `~/.codex-*` folder.
        case homeFolder
        /// Picked by the user in an open panel.
        case chosenFolder
    }

    public var provider: Provider
    /// The exact string to use as CLAUDE_CONFIG_DIR / CODEX_HOME. Claude keys its Keychain item by a
    /// hash of this string, so it is kept as the user wrote it (a trailing slash is a different login).
    public var dir: String
    public var sources: [Source]
    /// Claude: `projects/` has entries. Codex: `sessions/` has entries.
    public var hasHistory: Bool

    public var id: String { provider.rawValue + ":" + dir }

    public init(provider: Provider, dir: String, sources: [Source], hasHistory: Bool) {
        self.provider = provider
        self.dir = dir
        self.sources = sources
        self.hasHistory = hasHistory
    }
}

/// Where a past conversation was started.
public enum SessionOrigin: String, Hashable, Sendable {
    case desktop, vscode, terminal, headless, other
}

/// A past Claude / Codex conversation that can be resumed from hdlanes.
public struct SessionCandidate: Identifiable, Hashable, Sendable {
    public var provider: Provider
    /// Claude session id (transcript file name) or Codex thread id: what `--resume` / `codex resume` take.
    public var agentSessionID: String
    public var cwd: String
    public var title: String
    public var firstPrompt: String?
    public var branch: String?
    /// Raw value: Claude `entrypoint`, Codex `originator` (or `source`).
    public var entrypoint: String?
    public var origin: SessionOrigin
    public var startedAt: Date?
    /// Modification time of the transcript / rollout file.
    public var lastActivity: Date
    public var sizeBytes: Int64
    /// The working directory still exists (a removed worktree can't be resumed in place).
    public var cwdExists: Bool

    public var id: String { provider.rawValue + ":" + agentSessionID }

    public init(provider: Provider, agentSessionID: String, cwd: String, title: String, firstPrompt: String? = nil,
                branch: String? = nil, entrypoint: String? = nil, origin: SessionOrigin = .other, startedAt: Date? = nil,
                lastActivity: Date, sizeBytes: Int64 = 0, cwdExists: Bool = true) {
        self.provider = provider
        self.agentSessionID = agentSessionID
        self.cwd = cwd
        self.title = title
        self.firstPrompt = firstPrompt
        self.branch = branch
        self.entrypoint = entrypoint
        self.origin = origin
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.sizeBytes = sizeBytes
        self.cwdExists = cwdExists
    }
}

/// Finds existing account folders and past conversations to bring into hdlanes. File-system reads
/// only; every root comes in as a parameter. From shell profiles and editor settings only the values
/// of `CLAUDE_CONFIG_DIR` and `CODEX_HOME` are extracted, nothing else is kept. Transcripts are read
/// head and tail only (they can be gigabytes).
public enum ImportScanner {
    public static let vscodeApps = ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium"]
    public static let shellProfiles = [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile"]
    public static let defaultLimit = 400
    public static let defaultChunkBytes = 256 * 1024
    static let titleLength = 80

    /// Why a folder isn't offered.
    public enum Exclusion: Equatable, Sendable {
        case missing
        case systemDefault
        case managedByHDLanes
        case alreadyAdded
    }

    public enum ChosenFolderResult: Equatable, Sendable {
        case candidate(AccountCandidate)
        /// Neither Claude's nor Codex's files are in it: ask the user which it is.
        case unknownProvider
        case excluded(Exclusion)
    }

    // MARK: Accounts

    /// Every account folder the user already has outside hdlanes, deduplicated by exact string.
    /// Excludes missing folders, the system defaults (`~/.claude`, `~/.codex`), hdlanes' own account
    /// folders and folders an account already uses.
    public static func accountCandidates(home: String, hdlanesAccountsRoot: String,
                                         existingConfigDirs: [String]) -> [AccountCandidate] {
        var found: [AccountCandidate] = []

        func add(_ provider: Provider, _ dir: String, _ source: AccountCandidate.Source) {
            if let i = found.firstIndex(where: { $0.provider == provider && $0.dir == dir }) {
                if !found[i].sources.contains(source) { found[i].sources.append(source) }
            } else {
                found.append(AccountCandidate(provider: provider, dir: dir, sources: [source], hasHistory: false))
            }
        }

        for app in vscodeApps {
            let path = (home as NSString).appendingPathComponent("Library/Application Support/\(app)/User/settings.json")
            guard let text = readText(path) else { continue }
            for (provider, dir) in parseEditorSettings(text) { add(provider, dir, .vscodeSettings(app)) }
        }
        for name in shellProfiles {
            guard let text = readText((home as NSString).appendingPathComponent(name)) else { continue }
            for (provider, dir) in parseShellProfile(text, home: home) { add(provider, dir, .shellProfile(name)) }
        }
        // A home folder the shell or an editor already names (maybe with a trailing slash) is that
        // candidate: the string the user actually runs with wins.
        for (provider, dir) in homeFolders(home: home) {
            if let i = found.firstIndex(where: { $0.provider == provider && HDPaths.normalizedDirString($0.dir) == dir }) {
                if !found[i].sources.contains(.homeFolder) { found[i].sources.append(.homeFolder) }
            } else {
                add(provider, dir, .homeFolder)
            }
        }

        let kept = found
            .filter { candidate in
                let exactOnly = candidate.sources.contains { if case .homeFolder = $0 { return false } else { return true } }
                return exclusion(dir: candidate.dir, home: home, hdlanesAccountsRoot: hdlanesAccountsRoot,
                                 existingConfigDirs: existingConfigDirs, exactOnly: exactOnly) == nil
            }
            .map { candidate in
                var c = candidate
                c.hasHistory = hasHistory(dir: c.dir, provider: c.provider)
                return c
            }
        // Claude first, discovery order within a provider.
        return kept.filter { $0.provider == .claude } + kept.filter { $0.provider != .claude }
    }

    /// A folder the user picked. `provider` nil → detected from the folder's contents.
    public static func chosenFolder(_ url: URL, provider: Provider?, home: String, hdlanesAccountsRoot: String,
                                    existingConfigDirs: [String]) -> ChosenFolderResult {
        let dir = HDPaths.normalizedDirString(url.standardizedFileURL.path)
        if let reason = exclusion(dir: dir, home: home, hdlanesAccountsRoot: hdlanesAccountsRoot,
                                  existingConfigDirs: existingConfigDirs, exactOnly: false) {
            return .excluded(reason)
        }
        guard let provider = provider ?? providerOfFolder(URL(fileURLWithPath: dir, isDirectory: true)) else {
            return .unknownProvider
        }
        return .candidate(AccountCandidate(provider: provider, dir: dir, sources: [.chosenFolder],
                                           hasHistory: hasHistory(dir: dir, provider: provider)))
    }

    /// Claude when the folder has `.claude.json`, `projects/` or `settings.json`; Codex when it has
    /// `auth.json`, `config.toml` or `sessions/`. Claude 2.x also keeps a `sessions/` folder, so the
    /// stronger markers are checked first.
    public static func providerOfFolder(_ url: URL) -> Provider? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: url.appendingPathComponent(name).path) }
        if has(".claude.json") { return .claude }
        if has("auth.json") || has("config.toml") { return .codex }
        if has("projects") || has("settings.json") { return .claude }
        if has("sessions") { return .codex }
        return nil
    }

    public static func hasHistory(dir: String, provider: Provider) -> Bool {
        let sub = provider == .codex ? "sessions" : "projects"
        let path = (dir as NSString).appendingPathComponent(sub)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.contains { !$0.hasPrefix(".") }
    }

    /// `exactOnly`: compare with existing accounts by exact string (a different string is a different
    /// Claude login). Home and chosen folders compare trailing-slash-insensitively instead, so a folder
    /// already added under another spelling isn't offered again.
    public static func exclusion(dir: String, home: String, hdlanesAccountsRoot: String,
                                 existingConfigDirs: [String], exactOnly: Bool) -> Exclusion? {
        let normalized = HDPaths.normalizedDirString(dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return .missing }
        let homeNorm = HDPaths.normalizedDirString(home)
        if normalized == homeNorm + "/.claude" || normalized == homeNorm + "/.codex" { return .systemDefault }
        let root = HDPaths.normalizedDirString(hdlanesAccountsRoot)
        if normalized == root || normalized.hasPrefix(root + "/") { return .managedByHDLanes }
        if existingConfigDirs.contains(dir) { return .alreadyAdded }
        if !exactOnly, existingConfigDirs.contains(where: { HDPaths.normalizedDirString($0) == normalized }) {
            return .alreadyAdded
        }
        return nil
    }

    /// `.claude-work` → "work", `.codex2` → "2". nil when the name adds nothing to the provider name.
    public static func labelSuffix(forFolder dir: String, provider: Provider) -> String? {
        var name = (HDPaths.normalizedDirString(dir) as NSString).lastPathComponent
        while name.hasPrefix(".") { name.removeFirst() }
        guard name.lowercased().hasPrefix(provider.rawValue) else { return name.isEmpty ? nil : name }
        name = String(name.dropFirst(provider.rawValue.count))
        let separators = CharacterSet(charactersIn: "-_. ")
        let words = name.components(separatedBy: separators).filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    // MARK: Editor settings

    /// `CLAUDE_CONFIG_DIR` / `CODEX_HOME` values in a VS Code-family settings.json (JSONC): entries
    /// `{"name": …, "value": …}` in either key order (`claudeCode.environmentVariables`), and
    /// `"CLAUDE_CONFIG_DIR": "…"` keys (terminal env settings). Commented-out entries don't count.
    /// Values are kept verbatim; only absolute paths are accepted (the editor passes no shell).
    static func parseEditorSettings(_ text: String) -> [(Provider, String)] {
        let clean = stripJSONComments(text)
        let patterns: [(pattern: String, nameGroup: Int, valueGroup: Int)] = [
            (#""name"\s*:\s*"(CLAUDE_CONFIG_DIR|CODEX_HOME)"\s*,\s*"value"\s*:\s*"((?:[^"\\]|\\.)*)""#, 1, 2),
            (#""value"\s*:\s*"((?:[^"\\]|\\.)*)"\s*,\s*"name"\s*:\s*"(CLAUDE_CONFIG_DIR|CODEX_HOME)""#, 2, 1),
            (#""(CLAUDE_CONFIG_DIR|CODEX_HOME)"\s*:\s*"((?:[^"\\]|\\.)*)""#, 1, 2),
        ]
        var hits: [(location: Int, provider: Provider, value: String)] = []
        let ns = clean as NSString
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p.pattern) else { continue }
            for m in regex.matches(in: clean, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: p.nameGroup))
                guard let value = decodeJSONString(ns.substring(with: m.range(at: p.valueGroup))),
                      value.hasPrefix("/"), !value.contains("$") else { continue }
                hits.append((m.range.location, name == "CODEX_HOME" ? .codex : .claude, value))
            }
        }
        var result: [(Provider, String)] = []
        for hit in hits.sorted(by: { $0.location < $1.location })
        where !result.contains(where: { $0.0 == hit.provider && $0.1 == hit.value }) {
            result.append((hit.provider, hit.value))
        }
        return result
    }

    /// Removes `//` and `/* */` comments outside strings.
    static func stripJSONComments(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        var inString = false
        while i < s.count {
            let c = s[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < s.count {
                    out.append(s[i + 1])
                    i += 2
                    continue
                }
                if c == "\"" { inString = false }
                i += 1
            } else if c == "\"" {
                inString = true
                out.append(c)
                i += 1
            } else if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                i += 2
                while i < s.count, s[i] != "\n" { i += 1 }
            } else if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                i += 2
                while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                i += 2
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(out)
    }

    private static func decodeJSONString(_ body: String) -> String? {
        let data = Data(("\"" + body + "\"").utf8)
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String
    }

    // MARK: Shell profiles

    /// `CLAUDE_CONFIG_DIR=<v>` / `CODEX_HOME=<v>` anywhere in a non-comment line: exports, plain
    /// assignments, and alias bodies like `alias c2='CLAUDE_CONFIG_DIR=~/.claude-2 claude'`. A leading
    /// `~`, `$HOME` or `${HOME}` is expanded; values with any other `$` (or a backquote) are skipped.
    static func parseShellProfile(_ text: String, home: String) -> [(Provider, String)] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_${])(CLAUDE_CONFIG_DIR|CODEX_HOME)="#) else {
            return []
        }
        var result: [(Provider, String)] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = stripShellComment(String(raw))
            let ns = line as NSString
            for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                let rest = ns.substring(from: m.range.location + m.range.length)
                guard let word = shellWord(rest), let value = expandHome(word, home: home, quote: rest.first) else { continue }
                let provider: Provider = name == "CODEX_HOME" ? .codex : .claude
                if !result.contains(where: { $0.0 == provider && $0.1 == value }) { result.append((provider, value)) }
            }
        }
        return result
    }

    /// The line up to an unquoted `#` that starts a word (a comment); "" for a comment line.
    static func stripShellComment(_ line: String) -> String {
        var single = false
        var double = false
        var previous: Character = " "
        var out = ""
        for ch in line {
            if ch == "'" && !double { single.toggle() }
            else if ch == "\"" && !single && previous != "\\" { double.toggle() }
            else if ch == "#" && !single && !double && previous.isWhitespace { break }
            out.append(ch)
            previous = ch
        }
        return out
    }

    /// The shell word at the start of `text`: a double- or single-quoted string, or bare characters up
    /// to whitespace or a shell operator. nil when empty or when it holds escapes.
    static func shellWord(_ text: String) -> String? {
        guard let first = text.first else { return nil }
        if first == "\"" || first == "'" {
            let body = text.dropFirst()
            guard let end = body.firstIndex(of: first) else { return nil }
            let value = String(body[..<end])
            if value.isEmpty || value.contains("\\") { return nil }
            return value
        }
        let stops: Set<Character> = [";", "&", "|", ")", "(", "'", "\"", "`", "<", ">"]
        let value = String(text.prefix { !$0.isWhitespace && !stops.contains($0) })
        if value.isEmpty || value.contains("\\") { return nil }
        return value
    }

    /// Absolute path with a leading `~`, `$HOME` or `${HOME}` expanded; nil for anything else dynamic.
    /// The shell expands nothing inside single quotes and no `~` inside double quotes, so those values
    /// reach Claude literally (and a literal "~/…" is not a usable config dir): skip them.
    static func expandHome(_ value: String, home: String, quote: Character? = nil) -> String? {
        var v = value
        let prefixes: [String]
        switch quote {
        case "'": prefixes = []
        case "\"": prefixes = ["${HOME}", "$HOME"]
        default: prefixes = ["${HOME}", "$HOME", "~"]
        }
        for prefix in prefixes where v == prefix || v.hasPrefix(prefix + "/") {
            v = home + v.dropFirst(prefix.count)
            break
        }
        guard v.hasPrefix("/"), !v.contains("$"), !v.contains("`") else { return nil }
        return v
    }

    // MARK: Home folders

    /// `~/.claude*` / `~/.codex*` folders (not the system defaults) that look like that provider's
    /// folder. Plain absolute paths, no trailing slash.
    static func homeFolders(home: String) -> [(Provider, String)] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: home)) ?? []).sorted()
        var result: [(Provider, String)] = []
        for name in names where name != ".claude" && name != ".codex" {
            let provider: Provider
            if name.hasPrefix(".claude") { provider = .claude } else if name.hasPrefix(".codex") { provider = .codex } else { continue }
            let path = HDPaths.normalizedDirString((home as NSString).appendingPathComponent(name))
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            func has(_ child: String) -> Bool { fm.fileExists(atPath: (path as NSString).appendingPathComponent(child)) }
            let looksRight = provider == .claude
                ? has(".claude.json") || has("projects") || has("settings.json")
                : has("auth.json") || has("config.toml") || has("sessions")
            if looksRight { result.append((provider, path)) }
        }
        return result
    }

    // MARK: Claude transcripts

    /// Conversations in `<configDir>/projects/<encoded-cwd>/<session-id>.jsonl`, newest first, modified
    /// at or after `since`, at most `limit`. Non-interactive runs (`entrypoint` `sdk-*`, i.e. `claude -p`)
    /// are left out unless `includeHeadless`. Only the first and last `chunkBytes` of a file are read.
    public static func claudeSessions(configDir: String, since: Date, limit: Int = defaultLimit,
                                      includeHeadless: Bool = false,
                                      chunkBytes: Int = defaultChunkBytes) -> [SessionCandidate] {
        let fm = FileManager.default
        let projects = (configDir as NSString).appendingPathComponent("projects")
        var files: [ListedFile] = []
        for dir in ((try? fm.contentsOfDirectory(atPath: projects)) ?? []) where !dir.hasPrefix(".") {
            let dirPath = (projects as NSString).appendingPathComponent(dir)
            for name in ((try? fm.contentsOfDirectory(atPath: dirPath)) ?? []) where name.hasSuffix(".jsonl") {
                let stem = String(name.dropLast(".jsonl".count))
                guard UUID(uuidString: stem) != nil else { continue }
                let path = (dirPath as NSString).appendingPathComponent(name)
                guard let file = listedFile(path), file.modified >= since else { continue }
                files.append(file)
            }
        }
        var result: [SessionCandidate] = []
        var seen = Set<String>()
        for file in files.sorted(by: { $0.modified > $1.modified }) {
            if result.count >= limit { break }
            let id = String((file.path as NSString).lastPathComponent.dropLast(".jsonl".count))
            // The same conversation can sit under two project folders (repo and a worktree); keep the newest.
            guard !seen.contains(id) else { continue }
            let projectDir = ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if let s = parseClaudeTranscript(file: file, sessionID: id, includeHeadless: includeHeadless,
                                             chunkBytes: chunkBytes, projectDir: projectDir) {
                seen.insert(id)
                result.append(s)
            }
        }
        return result
    }

    /// Claude Code's project folder name for a cwd: every character other than an ASCII letter or digit
    /// becomes "-" (`/Users/x/my.app` → `-Users-x-my-app`).
    public static func claudeProjectDirName(for cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func parseClaudeTranscript(file: ListedFile, sessionID: String, includeHeadless: Bool,
                                      chunkBytes: Int, projectDir: String? = nil) -> SessionCandidate? {
        guard let chunks = readChunks(path: file.path, from: 0, size: file.size, chunkBytes: chunkBytes) else { return nil }
        var cwd: String?
        // A transcript can record several cwds; resume only finds it from the one its folder is named after.
        func matches(_ c: String?) -> Bool { projectDir == nil || c.map { claudeProjectDirName(for: $0) == projectDir } == true }
        func offer(_ c: String?) {
            guard let c = nonEmpty(c) else { return }
            if cwd == nil || (!matches(cwd) && matches(c)) { cwd = c }
        }
        var entrypoint: String?
        var branch: String?
        var startedAt: Date?
        var firstPrompt: String?
        var headTitle: String?
        var lastPrompt: String?

        let userMarker = Array(#""type":"user""#.utf8)
        let titleMarker = Array(#""type":"custom-title""#.utf8)
        let lastPromptMarker = Array(#""type":"last-prompt""#.utf8)

        for line in chunks.head {
            let isUser = contains(line, userMarker)
            let isTitle = contains(line, titleMarker)
            let isLastPrompt = contains(line, lastPromptMarker)
            // User lines can be large (tool results): stop decoding them once everything is known.
            let wantUser = isUser && (firstPrompt == nil || cwd == nil || !matches(cwd))
            guard wantUser || isTitle || isLastPrompt, let json = decode(line) else { continue }
            switch json["type"]?.string {
            case "user":
                offer(json["cwd"]?.string)
                if entrypoint == nil { entrypoint = nonEmpty(json["entrypoint"]?.string) }
                if branch == nil { branch = nonEmpty(json["gitBranch"]?.string) }
                if startedAt == nil { startedAt = json["timestamp"]?.string.flatMap(CodexRollout.parseDate) }
                if firstPrompt == nil, json["isSidechain"]?.bool != true, json["isMeta"]?.bool != true {
                    firstPrompt = promptText(json["message"]?["content"])
                }
            case "custom-title":
                if let t = nonEmpty(json["customTitle"]?.string) { headTitle = t }
            case "last-prompt":
                if let p = nonEmpty(json["lastPrompt"]?.string) { lastPrompt = p }
            default:
                break
            }
        }

        if !includeHeadless, entrypoint?.hasPrefix("sdk-") == true { return nil }

        var tailTitle: String?
        var tailLastPrompt: String?
        var tailUserSeen = false
        for line in chunks.tail.reversed() {
            let wantTitle = tailTitle == nil && contains(line, titleMarker)
            let wantLastPrompt = tailLastPrompt == nil && contains(line, lastPromptMarker)
            let wantUser = !tailUserSeen && contains(line, userMarker)
            guard wantTitle || wantLastPrompt || wantUser, let json = decode(line) else { continue }
            switch json["type"]?.string {
            case "custom-title":
                if tailTitle == nil { tailTitle = nonEmpty(json["customTitle"]?.string) }
            case "last-prompt":
                if tailLastPrompt == nil { tailLastPrompt = nonEmpty(json["lastPrompt"]?.string) }
            case "user" where !tailUserSeen && json["isSidechain"]?.bool != true:
                // The branch the conversation ended on.
                tailUserSeen = true
                if let b = nonEmpty(json["gitBranch"]?.string) { branch = b }
                offer(json["cwd"]?.string)
                if entrypoint == nil { entrypoint = nonEmpty(json["entrypoint"]?.string) }
            default:
                break
            }
            if tailTitle != nil && tailLastPrompt != nil && tailUserSeen { break }
        }
        lastPrompt = tailLastPrompt ?? lastPrompt
        if !includeHeadless, entrypoint?.hasPrefix("sdk-") == true { return nil }

        guard let cwd else { return nil }
        guard let title = singleLine(tailTitle) ?? singleLine(headTitle) ?? singleLine(firstPrompt) ?? singleLine(lastPrompt)
        else { return nil }
        return SessionCandidate(provider: .claude, agentSessionID: sessionID, cwd: cwd, title: title,
                                firstPrompt: firstPrompt, branch: branch, entrypoint: entrypoint,
                                origin: claudeOrigin(entrypoint), startedAt: startedAt, lastActivity: file.modified,
                                sizeBytes: Int64(file.size), cwdExists: directoryExists(cwd))
    }

    static func claudeOrigin(_ entrypoint: String?) -> SessionOrigin {
        guard let e = entrypoint else { return .other }
        if e.hasPrefix("sdk-") { return .headless }
        switch e {
        case "claude-desktop": return .desktop
        case "claude-vscode": return .vscode
        case "cli": return .terminal
        default: return .other
        }
    }

    /// A real prompt from a user message's content: plain text, or the first text block of a list.
    /// Wrappers (`<command-name>`, `<local-command-stdout>`, `<system-reminder>`, …), interruption
    /// notes and tool-result-only content are not prompts.
    static func promptText(_ content: JSONValue?) -> String? {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
                  !t.hasPrefix("<"), !t.hasPrefix("[Request interrupted") else { return nil }
            return t
        }
        if let s = content?.string { return clean(s) }
        for item in content?.array ?? [] where item["type"]?.string == "text" {
            if let t = clean(item["text"]?.string) { return t }
        }
        return nil
    }

    // MARK: Codex rollouts

    /// Threads in `<codexHome>/sessions/YYYY/MM/DD/rollout-*.jsonl` (`.zst` archives skipped), newest
    /// first, modified at or after `since`, at most `limit`. Sub-agent threads are left out, and
    /// `codex exec` runs unless `includeHeadless`. Titles come from `session_index.jsonl` (the
    /// thread names Codex shows) when there, else the first prompt.
    public static func codexSessions(codexHome: String, since: Date, limit: Int = defaultLimit,
                                     includeHeadless: Bool = false,
                                     chunkBytes: Int = defaultChunkBytes) -> [SessionCandidate] {
        let files = CodexRollout.rolloutFiles(in: CodexRollout.allDayDirectories(codexHome: codexHome))
            .filter { $0.modified >= since }
            .sorted { $0.modified > $1.modified }
        guard !files.isEmpty else { return [] }
        let names = codexThreadNames(codexHome: codexHome)
        var result: [SessionCandidate] = []
        for file in files {
            if result.count >= limit { break }
            guard let listed = listedFile(file.url.path),
                  let s = parseCodexRollout(file: listed, threadNames: names, includeHeadless: includeHeadless,
                                            chunkBytes: chunkBytes) else { continue }
            result.append(s)
        }
        return result
    }

    static func parseCodexRollout(file: ListedFile, threadNames: [String: String], includeHeadless: Bool,
                                  chunkBytes: Int) -> SessionCandidate? {
        let url = URL(fileURLWithPath: file.path)
        guard let first = CodexRollout.readFirstLine(url), let meta = decode(first),
              meta["type"]?.string == "session_meta", let payload = meta["payload"],
              let id = nonEmpty((payload["id"] ?? payload["session_id"])?.string),
              let cwd = nonEmpty(payload["cwd"]?.string),
              !CodexRollout.isChildThread(meta: meta) else { return nil }
        let originator = nonEmpty(payload["originator"]?.string)
        let source = payload["source"]?.string
        let origin = codexOrigin(originator: originator, source: source)
        if !includeHeadless, origin == .headless { return nil }

        var firstPrompt: String?
        var lastPrompt: String?
        let marker = Array(#""user_message""#.utf8)
        if let chunks = readChunks(path: file.path, from: UInt64(first.count + 1), size: file.size, chunkBytes: chunkBytes) {
            for line in chunks.head where firstPrompt == nil && contains(line, marker) {
                if case .userMessage(let text)? = decode(line).flatMap(CodexRollout.parse(json:))?.record {
                    firstPrompt = promptText(.string(text))
                }
            }
            for line in chunks.tail.reversed() where contains(line, marker) {
                if case .userMessage(let text)? = decode(line).flatMap(CodexRollout.parse(json:))?.record,
                   let p = promptText(.string(text)) {
                    lastPrompt = p
                    break
                }
            }
        }
        guard let title = singleLine(threadNames[id]) ?? singleLine(firstPrompt) ?? singleLine(lastPrompt) else { return nil }
        return SessionCandidate(provider: .codex, agentSessionID: id, cwd: cwd, title: title, firstPrompt: firstPrompt,
                                branch: nonEmpty(payload["git"]?["branch"]?.string), entrypoint: originator ?? source,
                                origin: origin, startedAt: payload["timestamp"]?.string.flatMap(CodexRollout.parseDate),
                                lastActivity: file.modified, sizeBytes: Int64(file.size), cwdExists: directoryExists(cwd))
    }

    /// Codex Desktop writes `source: "vscode"` too, so the originator decides first.
    static func codexOrigin(originator: String?, source: String?) -> SessionOrigin {
        let o = originator?.lowercased() ?? ""
        if source == "exec" || o.contains("exec") { return .headless }
        if o.contains("desktop") { return .desktop }
        if o.contains("vscode") { return .vscode }
        if o.contains("tui") || o.contains("cli") || source == "cli" { return .terminal }
        if source == "vscode" { return .vscode }
        return .other
    }

    /// `session_index.jsonl` lines `{"id","thread_name","updated_at"}`; the last name of an id wins.
    static func codexThreadNames(codexHome: String, maxBytes: Int = 8 << 20) -> [String: String] {
        let path = (codexHome as NSString).appendingPathComponent("session_index.jsonl")
        guard let handle = FileHandle(forReadingAtPath: path) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return [:] }
        var names: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let json = decode(Data(line)), let id = nonEmpty(json["id"]?.string),
                  let name = nonEmpty(json["thread_name"]?.string) else { continue }
            names[id] = name
        }
        return names
    }

    // MARK: Projects

    /// The project an imported session belongs to: the one whose folder contains `cwd` (deepest wins),
    /// else the one whose worktree folder contains it. nil → a new project is needed.
    public static func matchingProject(cwd: String, projects: [Project]) -> UUID? {
        let path = HDPaths.normalizedDirString(cwd)
        func within(_ base: String) -> Bool {
            let b = HDPaths.normalizedDirString(base)
            return path == b || path.hasPrefix(b == "/" ? "/" : b + "/")
        }
        if let p = projects.filter({ within($0.path) }).max(by: {
            HDPaths.normalizedDirString($0.path).count < HDPaths.normalizedDirString($1.path).count
        }) {
            return p.id
        }
        return projects.first { within(WorktreePlanner.worktreeParent(repoRoot: $0.path, worktreeRoot: $0.worktreeRoot)) }?.id
    }

    // MARK: Files

    struct ListedFile: Sendable {
        var path: String
        var modified: Date
        var size: UInt64
    }

    static func listedFile(_ path: String) -> ListedFile? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return ListedFile(path: path, modified: modified, size: size)
    }

    /// Complete lines of `[offset, size)` as a head and a tail. When that range fits in two chunks it is
    /// read once and both are all of its lines; otherwise only the first and the last `chunkBytes` are
    /// read, and the partial lines at the cuts are dropped. The middle of the file is never read.
    static func readChunks(path: String, from offset: UInt64, size: UInt64, chunkBytes: Int)
        -> (head: [Data], tail: [Data])? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard offset < size else { return ([], []) }
        let newline = UInt8(ascii: "\n")
        do {
            try handle.seek(toOffset: offset)
            let length = size - offset
            if length <= UInt64(chunkBytes) * 2 {
                let all = lines(try handle.read(upToCount: Int(length)) ?? Data())
                return (all, all)
            }
            let headData = try handle.read(upToCount: chunkBytes) ?? Data()
            var head = lines(headData)
            if headData.last != newline, !head.isEmpty { head.removeLast() }
            try handle.seek(toOffset: size - UInt64(chunkBytes))
            var tail = lines(try handle.read(upToCount: chunkBytes) ?? Data())
            if !tail.isEmpty { tail.removeFirst() }
            return (head, tail)
        } catch {
            return nil
        }
    }

    /// Non-empty lines of `data` as slices sharing its storage (memchr; a byte loop is slow on 512 KB).
    static func lines(_ data: Data) -> [Data] {
        var ranges: [Range<Int>] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < raw.count {
                let end: Int
                if let hit = memchr(base + start, Int32(UInt8(ascii: "\n")), raw.count - start) {
                    end = base.distance(to: UnsafeRawPointer(hit))
                } else {
                    end = raw.count
                }
                if end > start { ranges.append(start..<end) }
                start = end + 1
            }
        }
        let offset = data.startIndex
        return ranges.map { data[(offset + $0.lowerBound)..<(offset + $0.upperBound)] }
    }

    /// Byte search with memmem; `Data.range(of:)` is much slower on long transcript lines.
    static func contains(_ data: Data, _ needle: [UInt8]) -> Bool {
        data.withUnsafeBytes { hay in
            needle.withUnsafeBytes { n in
                guard let h = hay.baseAddress, let p = n.baseAddress, n.count > 0 else { return false }
                return memmem(h, hay.count, p, n.count) != nil
            }
        }
    }

    private static func decode(_ line: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: line)
    }

    private static func readText(_ path: String, maxBytes: Int = 2 << 20) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// First line, at most `titleLength` characters.
    static func singleLine(_ text: String?) -> String? {
        SessionNaming.title(fromPrompt: text, maxLength: titleLength)
    }
}
