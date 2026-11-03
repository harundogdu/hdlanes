import Foundation
import Testing
@testable import HDCore

/// Every test builds its own home under a temp dir; nothing reads the real `~`.
struct ImportScannerTests {
    // MARK: Helpers

    private final class TempDir {
        let path: String
        init() throws {
            path = HDPaths.normalizedDirString(FileManager.default.temporaryDirectory
                .appendingPathComponent("hd-import-\(UUID().uuidString)").path)
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }

        func sub(_ rel: String) -> String { (path as NSString).appendingPathComponent(rel) }

        @discardableResult
        func mkdir(_ rel: String) throws -> String {
            let p = sub(rel)
            try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
            return p
        }

        @discardableResult
        func write(_ rel: String, _ text: String, modified: Date? = nil) throws -> String {
            let p = sub(rel)
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: p))
            if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: p) }
            return p
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func lines(_ objects: [[String: Any]]) -> String {
        objects.map(json).joined(separator: "\n") + "\n"
    }

    private static func user(_ content: Any, cwd: String = "/repo", branch: String = "main", entrypoint: String = "cli",
                             sidechain: Bool = false, meta: Bool = false) -> [String: Any] {
        var o: [String: Any] = ["type": "user", "cwd": cwd, "gitBranch": branch, "entrypoint": entrypoint,
                                "isSidechain": sidechain, "sessionId": "x", "timestamp": "2026-11-01T10:00:00.000Z",
                                "message": ["role": "user", "content": content]]
        if meta { o["isMeta"] = true }
        return o
    }

    private static func assistant(_ text: String) -> [String: Any] {
        ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]]
    }

    private static let now = Date()

    // MARK: Editor settings

    @Test func editorSettingsBothKeyOrdersAndComments() {
        let text = """
        {
          // "claudeCode.environmentVariables": [{"name": "CLAUDE_CONFIG_DIR", "value": "/commented/out"}],
          /* {"name": "CLAUDE_CONFIG_DIR", "value": "/block/comment"} */
          "editor.fontSize": 13, // url-ish "https://example.com" stays a string
          "claudeCode.environmentVariables": [
            { "name": "CLAUDE_CONFIG_DIR", "value": "/Users/me/.claude-2/" },
            { "value": "\\/Users\\/me\\/.claude-work", "name": "CLAUDE_CONFIG_DIR", },
            { "name": "CLAUDE_CONFIG_DIR", "value": "~/.claude-relative" },
            { "name": "OTHER", "value": "/nope" },
          ],
          "terminal.integrated.env.osx": { "CODEX_HOME": "/Users/me/.codex-alt", },
        }
        """
        let found = ImportScanner.parseEditorSettings(text)
        #expect(found.map(\.0) == [.claude, .claude, .codex])
        #expect(found.map(\.1) == ["/Users/me/.claude-2/", "/Users/me/.claude-work", "/Users/me/.codex-alt"])
    }

    @Test func stripsCommentsOnlyOutsideStrings() {
        #expect(ImportScanner.stripJSONComments(#"{"a": "x // y /* z */"} // tail"#) == #"{"a": "x // y /* z */"} "#)
        #expect(ImportScanner.stripJSONComments("{/* c */\"b\": 1}") == "{\"b\": 1}")
    }

    // MARK: Shell profiles

    @Test func shellProfileExportsAliasesAndExpansion() {
        let home = "/Users/me"
        let text = """
        # export CLAUDE_CONFIG_DIR=/commented/out
          #CODEX_HOME=/also/commented
        export CLAUDE_CONFIG_DIR=~/.claude-2/
        export CLAUDE_CONFIG_DIR="$HOME/.claude-quoted"
        alias c3='CLAUDE_CONFIG_DIR=${HOME}/.claude-3 claude'
        alias cw="CLAUDE_CONFIG_DIR='/opt/claude work' claude"
        export CODEX_HOME=/Users/me/.codex-alt; echo ok # CLAUDE_CONFIG_DIR=/in/trailing/comment
        export CLAUDE_CONFIG_DIR=$OTHER/.claude-x
        export CLAUDE_CONFIG_DIR="$(pwd)/.claude-y"
        echo $CLAUDE_CONFIG_DIR=/not/an/assignment
        MY_CLAUDE_CONFIG_DIR=/not/ours
        export CLAUDE_CONFIG_DIR=relative/path
        """
        let found = ImportScanner.parseShellProfile(text, home: home)
        #expect(found.map(\.1) == ["/Users/me/.claude-2/", "/Users/me/.claude-quoted", "/Users/me/.claude-3",
                                   "/opt/claude work", "/Users/me/.codex-alt"])
        #expect(found.map(\.0) == [.claude, .claude, .claude, .claude, .codex])
    }

    @Test func expandHomeRules() {
        #expect(ImportScanner.expandHome("~", home: "/h") == "/h")
        #expect(ImportScanner.expandHome("~/x", home: "/h") == "/h/x")
        #expect(ImportScanner.expandHome("$HOME/x/", home: "/h") == "/h/x/")
        #expect(ImportScanner.expandHome("${HOME}/x", home: "/h") == "/h/x")
        #expect(ImportScanner.expandHome("$HOMEDIR/x", home: "/h") == nil)
        #expect(ImportScanner.expandHome("~other/x", home: "/h") == nil)
        #expect(ImportScanner.expandHome("/a/$B", home: "/h") == nil)
    }

    // MARK: Account candidates

    @Test func accountCandidatesFromAllSources() throws {
        let t = try TempDir()
        let home = t.path
        let root = try t.mkdir(".hdlanes/accounts")
        // System defaults: never offered, even when a profile names them.
        try t.mkdir(".claude/projects/p")
        try t.mkdir(".codex/sessions")
        // Named by .zshrc with a trailing slash, and found as a home folder: one candidate, exact string kept.
        try t.write(".claude-2/.claude.json", "{}")
        try t.mkdir(".claude-2/projects/-repo")
        // Home folder only.
        try t.write(".claude-work/settings.json", "{}")
        // Starts with ".claude" but isn't a Claude folder, and a file.
        try t.write(".claude_scratch_scripts/run.py", "print(1)")
        try t.write(".claude.json.backup", "{}")
        // Codex home folder.
        try t.write(".codex-alt/config.toml", "")
        // Already an account.
        try t.mkdir(".claude-existing/projects")
        // Named by VS Code (Cursor) only.
        let vs = try t.mkdir("elsewhere/claude-vs")
        let managed = try t.mkdir(".hdlanes/accounts/claude/\(UUID().uuidString)")
        try t.write("Library/Application Support/Cursor/User/settings.json", """
        { "claudeCode.environmentVariables": [
            {"name": "CLAUDE_CONFIG_DIR", "value": "\(vs)"},
            {"name": "CLAUDE_CONFIG_DIR", "value": "\(managed)"},
        ] }
        """)
        try t.write(".zshrc", """
        export CLAUDE_CONFIG_DIR=~/.claude-2/
        alias sys='CLAUDE_CONFIG_DIR=$HOME/.claude/ claude'
        alias gone='CLAUDE_CONFIG_DIR=~/.claude-missing claude'
        export CODEX_HOME=~/.codex
        """)

        let found = ImportScanner.accountCandidates(home: home, hdlanesAccountsRoot: root,
                                                    existingConfigDirs: [t.sub(".claude-existing")])
        #expect(found.map(\.dir) == [vs, t.sub(".claude-2") + "/", t.sub(".claude-work"), t.sub(".codex-alt")])
        #expect(found.map(\.provider) == [.claude, .claude, .claude, .codex])
        let two = try #require(found.first { $0.dir.hasSuffix(".claude-2/") })
        #expect(two.sources == [.shellProfile(".zshrc"), .homeFolder])
        #expect(two.hasHistory)
        #expect(found.first { $0.dir == vs }?.sources == [.vscodeSettings("Cursor")])
        #expect(found.first { $0.dir.hasSuffix(".claude-work") }?.hasHistory == false)
    }

    @Test func existingAccountWithOtherSpellingIsNotOfferedAgainAsHomeFolder() throws {
        let t = try TempDir()
        try t.mkdir(".claude-2/projects")
        // Imported earlier from a profile line with a trailing slash; the profile line is gone now.
        let found = ImportScanner.accountCandidates(home: t.path, hdlanesAccountsRoot: t.sub(".hdlanes/accounts"),
                                                    existingConfigDirs: [t.sub(".claude-2") + "/"])
        #expect(found.isEmpty)
        // A profile still naming the other spelling is a different Claude login: exact match only.
        try t.write(".zshrc", "export CLAUDE_CONFIG_DIR=\(t.sub(".claude-2"))")
        let again = ImportScanner.accountCandidates(home: t.path, hdlanesAccountsRoot: t.sub(".hdlanes/accounts"),
                                                    existingConfigDirs: [t.sub(".claude-2") + "/"])
        #expect(again.map(\.dir) == [t.sub(".claude-2")])
    }

    @Test func chosenFolderDetectionAndExclusions() throws {
        let t = try TempDir()
        let root = t.sub(".hdlanes/accounts")
        let empty = try t.mkdir("empty")
        let claude = try t.mkdir("my-claude/projects")
        let codex = try t.write("work-codex/auth.json", "{}")

        func choose(_ path: String, _ provider: Provider? = nil, existing: [String] = []) -> ImportScanner.ChosenFolderResult {
            ImportScanner.chosenFolder(URL(fileURLWithPath: path), provider: provider, home: t.path,
                                       hdlanesAccountsRoot: root, existingConfigDirs: existing)
        }

        #expect(choose(empty) == .unknownProvider)
        #expect(choose(empty, .codex) == .candidate(AccountCandidate(provider: .codex, dir: empty, sources: [.chosenFolder],
                                                                      hasHistory: false)))
        let parent = (claude as NSString).deletingLastPathComponent
        #expect(choose(parent) == .candidate(AccountCandidate(provider: .claude, dir: parent, sources: [.chosenFolder],
                                                               hasHistory: false)))
        #expect(choose((codex as NSString).deletingLastPathComponent + "/").isCodexCandidate)
        #expect(choose(try t.mkdir(".claude")) == .excluded(.systemDefault))
        #expect(choose(try t.mkdir(".hdlanes/accounts/codex/x")) == .excluded(.managedByHDLanes))
        #expect(choose(parent, existing: [parent + "/"]) == .excluded(.alreadyAdded))
        #expect(choose(t.sub("nope")) == .excluded(.missing))
    }

    @Test func providerOfFolderMarkers() throws {
        let t = try TempDir()
        // Claude 2.x keeps a sessions/ folder too; projects/ makes it Claude.
        try t.mkdir("a/sessions")
        try t.mkdir("a/projects")
        try t.mkdir("b/sessions")
        try t.write("c/.claude.json", "{}")
        try t.mkdir("c/sessions")
        try t.write("d/config.toml", "")
        try t.mkdir("e")
        #expect(ImportScanner.providerOfFolder(URL(fileURLWithPath: t.sub("a"))) == .claude)
        #expect(ImportScanner.providerOfFolder(URL(fileURLWithPath: t.sub("b"))) == .codex)
        #expect(ImportScanner.providerOfFolder(URL(fileURLWithPath: t.sub("c"))) == .claude)
        #expect(ImportScanner.providerOfFolder(URL(fileURLWithPath: t.sub("d"))) == .codex)
        #expect(ImportScanner.providerOfFolder(URL(fileURLWithPath: t.sub("e"))) == nil)
    }

    @Test func labelSuffixFromFolderName() {
        #expect(ImportScanner.labelSuffix(forFolder: "/h/.claude-work", provider: .claude) == "work")
        #expect(ImportScanner.labelSuffix(forFolder: "/h/.claude_personal_2/", provider: .claude) == "personal 2")
        #expect(ImportScanner.labelSuffix(forFolder: "/h/.codex2", provider: .codex) == "2")
        #expect(ImportScanner.labelSuffix(forFolder: "/h/.claude", provider: .claude) == nil)
        #expect(ImportScanner.labelSuffix(forFolder: "/h/work-acc", provider: .claude) == "work-acc")
    }

    // MARK: Claude transcripts

    @Test func claudeTranscriptParsing() throws {
        let t = try TempDir()
        let id = "0b7c2f5e-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
        let repo = try t.mkdir("repo")
        try t.write("cfg/projects/-repo/\(id).jsonl", Self.lines([
            ["type": "queue-operation", "operation": "enqueue"],
            Self.user("<local-command-caveat>Caveat</local-command-caveat>", cwd: repo, meta: true),
            Self.user("<command-name>/clear</command-name>", cwd: repo),
            Self.user("sidechain prompt", cwd: repo, sidechain: true),
            Self.user([["type": "tool_result", "tool_use_id": "t", "content": "ok"]], cwd: repo),
            Self.user([["type": "text", "text": "<ide_opened_file>x</ide_opened_file>"],
                       ["type": "text", "text": "  Fix the login bug\nand add a test  "]], cwd: repo, branch: "fix/login"),
            Self.assistant("On it"),
            ["type": "last-prompt", "lastPrompt": "later prompt", "sessionId": id],
        ]))
        // Subagent folders and non-session files are ignored.
        try t.write("cfg/projects/-repo/\(id)/subagents/agent-1.jsonl", Self.lines([Self.user("sub", cwd: repo)]))
        try t.write("cfg/projects/-repo/notes.jsonl", Self.lines([Self.user("not a session", cwd: repo)]))

        let found = ImportScanner.claudeSessions(configDir: t.sub("cfg"), since: Self.now.addingTimeInterval(-3600))
        #expect(found.count == 1)
        let s = try #require(found.first)
        #expect(s.provider == .claude)
        #expect(s.agentSessionID == id)
        #expect(s.cwd == repo)
        #expect(s.cwdExists)
        #expect(s.firstPrompt == "Fix the login bug\nand add a test")
        #expect(s.title == "Fix the login bug")
        #expect(s.branch == "fix/login")  // the last non-sidechain user record
        #expect(s.entrypoint == "cli")
        #expect(s.origin == .terminal)
        #expect(s.startedAt != nil)
    }

    @Test func claudeCustomTitleAndMissingFolder() throws {
        let t = try TempDir()
        let id = UUID().uuidString.lowercased()
        try t.write("cfg/projects/-gone/\(id).jsonl", Self.lines([
            Self.user("first", cwd: "/definitely/not/here", entrypoint: "claude-desktop"),
            ["type": "custom-title", "customTitle": "Old name", "sessionId": id],
            ["type": "custom-title", "customTitle": "Renamed\nsecond line", "sessionId": id],
        ]))
        let s = try #require(ImportScanner.claudeSessions(configDir: t.sub("cfg"), since: .distantPast).first)
        #expect(s.title == "Renamed")
        #expect(s.cwdExists == false)
        #expect(s.origin == .desktop)
    }

    @Test func claudeHeadlessRunsExcludedByDefault() throws {
        let t = try TempDir()
        let id = UUID().uuidString.lowercased()
        try t.write("cfg/projects/-r/\(id).jsonl", Self.lines([Self.user("categorize this", entrypoint: "sdk-cli")]))
        #expect(ImportScanner.claudeSessions(configDir: t.sub("cfg"), since: .distantPast).isEmpty)
        let all = ImportScanner.claudeSessions(configDir: t.sub("cfg"), since: .distantPast, includeHeadless: true)
        #expect(all.map(\.origin) == [.headless])
    }

    @Test func claudeReadsOnlyHeadAndTailOfLargeFiles() throws {
        let t = try TempDir()
        let filler = String(repeating: "x", count: 1000)
        func big(tailTitle: Bool) -> String {
            var records: [[String: Any]] = [Self.user("Big session", branch: "start"),
                                            ["type": "custom-title", "customTitle": "Head title"]]
            for _ in 0..<320 { records.append(Self.assistant(filler)) }        // ~330 KB: past the head window
            records.append(["type": "custom-title", "customTitle": "Middle title"])
            records.append(Self.user("middle", branch: "middle"))
            for _ in 0..<320 { records.append(Self.assistant(filler)) }        // ~330 KB: before the tail window
            if tailTitle { records.append(["type": "custom-title", "customTitle": "Tail title"]) }
            records.append(Self.user("end", branch: "end"))
            records.append(Self.assistant("done"))
            return Self.lines(records)
        }
        let a = UUID().uuidString.lowercased()
        let b = UUID().uuidString.lowercased()
        let pathA = try t.write("cfg/projects/-r/\(a).jsonl", big(tailTitle: false), modified: Self.now.addingTimeInterval(-10))
        try t.write("cfg/projects/-r/\(b).jsonl", big(tailTitle: true), modified: Self.now)
        let size = try #require(FileManager.default.attributesOfItem(atPath: pathA)[.size] as? Int)
        #expect(size > 600 * 1024)

        let found = ImportScanner.claudeSessions(configDir: t.sub("cfg"), since: .distantPast)
        #expect(found.map(\.agentSessionID) == [b, a])
        // Whole-file reading would have picked "Middle title" for a.
        #expect(found.last?.title == "Head title")
        #expect(found.first?.title == "Tail title")
        #expect(found.first?.branch == "end")
        #expect(found.first?.firstPrompt == "Big session")
    }

    @Test func claudeSinceAndLimit() throws {
        let t = try TempDir()
        var ids: [String] = []
        for i in 0..<4 {
            let id = UUID().uuidString.lowercased()
            ids.append(id)
            try t.write("cfg/projects/-r\(i % 2)/\(id).jsonl", Self.lines([Self.user("prompt \(i)")]),
                        modified: Self.now.addingTimeInterval(TimeInterval(-i * 86_400)))
        }
        let recent = ImportScanner.claudeSessions(configDir: t.sub("cfg"), since: Self.now.addingTimeInterval(-2.5 * 86_400))
        #expect(recent.map(\.agentSessionID) == Array(ids.prefix(3)))
        let limited = ImportScanner.claudeSessions(configDir: t.sub("cfg"), since: .distantPast, limit: 2)
        #expect(limited.map(\.title) == ["prompt 0", "prompt 1"])
        #expect(ImportScanner.claudeSessions(configDir: t.sub("nope"), since: .distantPast).isEmpty)
    }

    // MARK: Codex rollouts

    private static func meta(id: String, cwd: String, originator: String = "codex-tui", source: Any = "cli",
                             parent: String? = nil, branch: String? = "feature/x") -> [String: Any] {
        var payload: [String: Any] = ["id": id, "session_id": id, "cwd": cwd, "originator": originator, "source": source,
                                      "timestamp": "2026-11-02T09:00:00.000Z",
                                      "base_instructions": ["text": String(repeating: "i", count: 5000)]]
        if let parent { payload["parent_thread_id"] = parent }
        if let branch { payload["git"] = ["branch": branch, "commit_hash": "abc"] }
        return ["timestamp": "2026-11-02T09:00:00.000Z", "type": "session_meta", "payload": payload]
    }

    private static func userMessage(_ text: String) -> [String: Any] {
        ["type": "event_msg", "payload": ["type": "user_message", "message": text, "images": []]]
    }

    @Test func codexRolloutParsing() throws {
        let t = try TempDir()
        let repo = try t.mkdir("repo")
        let main = "019a0000-0000-7000-8000-000000000001"
        let named = "019a0000-0000-7000-8000-000000000002"
        let child = "019a0000-0000-7000-8000-000000000003"
        let exec = "019a0000-0000-7000-8000-000000000004"
        let day = "home/sessions/2026/11/02"
        try t.write("\(day)/rollout-2026-11-02T09-00-00-\(main).jsonl", Self.lines([
            Self.meta(id: main, cwd: repo),
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": []]],
            Self.userMessage("<environment_context>x</environment_context>"),
            Self.userMessage("Refactor the parser\nplease"),
            ["type": "event_msg", "payload": ["type": "task_started"]],
            Self.userMessage("and the tests"),
        ]), modified: Self.now.addingTimeInterval(-60))
        try t.write("\(day)/rollout-2026-11-02T09-10-00-\(named).jsonl", Self.lines([
            Self.meta(id: named, cwd: repo, originator: "Codex Desktop", source: "vscode", branch: nil),
            Self.userMessage("first prompt"),
        ]), modified: Self.now.addingTimeInterval(-30))
        try t.write("\(day)/rollout-2026-11-02T09-20-00-\(child).jsonl", Self.lines([
            Self.meta(id: child, cwd: repo, originator: "Codex Desktop", source: ["subagent": ["other": "guardian"]], parent: main),
            Self.userMessage("sub-agent work"),
        ]), modified: Self.now)
        try t.write("\(day)/rollout-2026-11-02T09-30-00-\(exec).jsonl", Self.lines([
            Self.meta(id: exec, cwd: repo, originator: "codex_exec", source: "exec"),
            Self.userMessage("headless"),
        ]), modified: Self.now)
        try t.write("\(day)/rollout-2026-10-01T09-00-00-old.jsonl.zst", "compressed")
        try t.write("home/session_index.jsonl", Self.lines([
            ["id": named, "thread_name": "Old name", "updated_at": "2026-11-02T09:11:00Z"],
            ["id": named, "thread_name": "Desktop thread", "updated_at": "2026-11-02T09:12:00Z"],
        ]))

        let found = ImportScanner.codexSessions(codexHome: t.sub("home"), since: Self.now.addingTimeInterval(-3600))
        #expect(found.map(\.agentSessionID) == [named, main])
        let n = found[0]
        #expect(n.title == "Desktop thread")
        #expect(n.origin == .desktop)
        #expect(n.branch == nil)
        let m = found[1]
        #expect(m.provider == .codex)
        #expect(m.cwd == repo)
        #expect(m.firstPrompt == "Refactor the parser\nplease")
        #expect(m.title == "Refactor the parser")
        #expect(m.branch == "feature/x")
        #expect(m.origin == .terminal)
        #expect(m.entrypoint == "codex-tui")
        #expect(m.startedAt != nil)

        let withExec = ImportScanner.codexSessions(codexHome: t.sub("home"), since: .distantPast, includeHeadless: true)
        #expect(withExec.map(\.agentSessionID) == [exec, named, main])
    }

    @Test func codexSinceAndLimit() throws {
        let t = try TempDir()
        var ids: [String] = []
        for i in 0..<3 {
            let id = "019a0000-0000-7000-8000-00000000001\(i)"
            ids.append(id)
            try t.write("home/sessions/2026/10/2\(i)/rollout-x-\(id).jsonl",
                        Self.lines([Self.meta(id: id, cwd: "/r"), Self.userMessage("p\(i)")]),
                        modified: Self.now.addingTimeInterval(TimeInterval(-i * 86_400)))
        }
        let recent = ImportScanner.codexSessions(codexHome: t.sub("home"), since: Self.now.addingTimeInterval(-1.5 * 86_400))
        #expect(recent.map(\.agentSessionID) == [ids[0], ids[1]])
        #expect(recent.first?.cwdExists == false)
        let limited = ImportScanner.codexSessions(codexHome: t.sub("home"), since: .distantPast, limit: 1)
        #expect(limited.map(\.title) == ["p0"])
    }

    @Test func codexOrigins() {
        #expect(ImportScanner.codexOrigin(originator: "Codex Desktop", source: "vscode") == .desktop)
        #expect(ImportScanner.codexOrigin(originator: "codex_vscode", source: "vscode") == .vscode)
        #expect(ImportScanner.codexOrigin(originator: "codex-tui", source: "vscode") == .terminal)
        #expect(ImportScanner.codexOrigin(originator: "codex_cli_rs", source: "cli") == .terminal)
        #expect(ImportScanner.codexOrigin(originator: "codex_exec", source: "exec") == .headless)
    }

    // MARK: Projects

    @Test func matchingProjectUsesPathComponents() {
        let repo = Project(name: "repo", path: "/w/repo")
        let deep = Project(name: "sub", path: "/w/repo/packages/app")
        let other = Project(name: "repo2", path: "/w/repo2")
        let projects = [repo, deep, other]
        #expect(ImportScanner.matchingProject(cwd: "/w/repo", projects: projects) == repo.id)
        #expect(ImportScanner.matchingProject(cwd: "/w/repo/.claude/worktrees/a", projects: projects) == repo.id)
        #expect(ImportScanner.matchingProject(cwd: "/w/repo/packages/app/src", projects: projects) == deep.id)
        #expect(ImportScanner.matchingProject(cwd: "/w/repo2/x", projects: projects) == other.id)
        #expect(ImportScanner.matchingProject(cwd: "/w/repo-worktrees/fix-bug", projects: projects) == repo.id)
        #expect(ImportScanner.matchingProject(cwd: "/w/rep", projects: projects) == nil)
        #expect(ImportScanner.matchingProject(cwd: "/w/repo3", projects: projects) == nil)
    }
}

private extension ImportScanner.ChosenFolderResult {
    var isCodexCandidate: Bool {
        if case .candidate(let c) = self { return c.provider == .codex && !c.dir.hasSuffix("/") }
        return false
    }
}

struct ImportScannerFixTests {
    @Test func claudeProjectDirNameMatchesClaudeEncoding() {
        #expect(ImportScanner.claudeProjectDirName(for: "/Users/x/git/ios-apps") == "-Users-x-git-ios-apps")
        #expect(ImportScanner.claudeProjectDirName(for: "/tmp/a.b_c d") == "-tmp-a-b-c-d")
    }

    @Test func quotedTildeIsNotExpandedButDoubleQuotedHomeIs() {
        let home = "/Users/x"
        #expect(ImportScanner.parseShellProfile("export CLAUDE_CONFIG_DIR='~/.claude-2'", home: home).isEmpty)
        #expect(ImportScanner.parseShellProfile("export CLAUDE_CONFIG_DIR=\"~/.claude-2\"", home: home).isEmpty)
        #expect(ImportScanner.parseShellProfile("export CLAUDE_CONFIG_DIR=\"$HOME/.claude-2\"", home: home).map(\.1) == ["/Users/x/.claude-2"])
        #expect(ImportScanner.parseShellProfile("alias c2='CLAUDE_CONFIG_DIR=~/.claude-2 claude'", home: home).map(\.1) == ["/Users/x/.claude-2"])
    }
}
