import Foundation
import Testing
@testable import HDCore

/// Every test builds its own folders under a temp dir; nothing reads the real `~`.
struct SharedContextTests {
    private final class TempDir {
        let path: String
        init() throws {
            // Resolved, so paths compare equal to what `repositoryRoot` returns (/var → /private/var).
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("hd-shared-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            path = url.resolvingSymlinksInPath().path
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
        func write(_ rel: String, _ text: String) throws -> String {
            let p = sub(rel)
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: p))
            return p
        }
    }

    private func states(_ results: [SharedContext.LinkResult]) -> [String: SharedContext.LinkState] {
        Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0.state) })
    }

    // MARK: Links

    @Test func linksWhatTheDefaultAccountHasWithAbsoluteTargets() throws {
        let t = try TempDir()
        let source = try t.mkdir("home/.claude")
        try t.mkdir("home/.claude/skills/one")
        try t.mkdir("home/.claude/agents")
        try t.write("home/.claude/settings.json", "{}")
        let account = try t.mkdir("accounts/a")

        let result = states(SharedContext.sync(accountDir: account, sourceDir: source, provider: .claude))
        #expect(result == ["skills": .linked, "agents": .linked, "commands": .missingSource, "CLAUDE.md": .missingSource])
        let fm = FileManager.default
        #expect(try fm.destinationOfSymbolicLink(atPath: t.sub("accounts/a/skills")) == t.sub("home/.claude/skills"))
        #expect(fm.fileExists(atPath: t.sub("accounts/a/skills/one")))
        // Never linked: settings, logins, history.
        #expect(!fm.fileExists(atPath: t.sub("accounts/a/settings.json")))
        #expect((try? fm.destinationOfSymbolicLink(atPath: t.sub("accounts/a/commands"))) == nil)

        // Idempotent.
        #expect(states(SharedContext.sync(accountDir: account, sourceDir: source, provider: .claude))["skills"] == .linked)
    }

    @Test func neverReplacesTheAccountsOwnEntries() throws {
        let t = try TempDir()
        let source = try t.mkdir("home/.claude")
        try t.mkdir("home/.claude/skills")
        try t.write("home/.claude/CLAUDE.md", "default")
        try t.mkdir("home/.claude/commands")
        let account = try t.mkdir("accounts/a")
        try t.mkdir("accounts/a/skills/mine")
        try t.write("accounts/a/CLAUDE.md", "own")
        try FileManager.default.createSymbolicLink(atPath: t.sub("accounts/a/commands"), withDestinationPath: "/elsewhere")

        let result = states(SharedContext.sync(accountDir: account, sourceDir: source, provider: .claude))
        #expect(result["skills"] == .merged)
        #expect(result["CLAUDE.md"] == .occupied)
        #expect(result["commands"] == .occupied)
        #expect(try String(contentsOfFile: t.sub("accounts/a/CLAUDE.md"), encoding: .utf8) == "own")
        #expect(FileManager.default.fileExists(atPath: t.sub("accounts/a/skills/mine")))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: t.sub("accounts/a/commands")) == "/elsewhere")

        // unlink leaves them too.
        #expect(SharedContext.unlink(accountDir: account, sourceDir: source, provider: .claude).isEmpty)
        #expect(FileManager.default.fileExists(atPath: t.sub("accounts/a/CLAUDE.md")))
    }

    @Test func aLaterSourceIsPickedUpAndAVanishedOneIsUnlinked() throws {
        let t = try TempDir()
        let source = try t.mkdir("home/.claude")
        let account = try t.mkdir("accounts/a")
        #expect(states(SharedContext.status(accountDir: account, sourceDir: source, provider: .claude))["CLAUDE.md"] == .missingSource)

        try t.write("home/.claude/CLAUDE.md", "x")
        #expect(states(SharedContext.status(accountDir: account, sourceDir: source, provider: .claude))["CLAUDE.md"] == .notLinked)
        #expect(states(SharedContext.sync(accountDir: account, sourceDir: source, provider: .claude))["CLAUDE.md"] == .linked)

        try FileManager.default.removeItem(atPath: t.sub("home/.claude/CLAUDE.md"))
        #expect(states(SharedContext.status(accountDir: account, sourceDir: source, provider: .claude))["CLAUDE.md"] == .missingSource)
        #expect(states(SharedContext.sync(accountDir: account, sourceDir: source, provider: .claude))["CLAUDE.md"] == .missingSource)
        #expect((try? FileManager.default.attributesOfItem(atPath: t.sub("accounts/a/CLAUDE.md"))) == nil)
    }

    @Test func unlinkRemovesOnlyOurLinks() throws {
        let t = try TempDir()
        let source = try t.mkdir("home/.codex")
        try t.write("home/.codex/AGENTS.md", "x")
        try t.mkdir("home/.codex/skills")
        try t.mkdir("home/.codex/agents")
        let account = try t.mkdir("accounts/c")
        try t.mkdir("accounts/c/agents")

        let result = states(SharedContext.sync(accountDir: account, sourceDir: source, provider: .codex))
        #expect(result == ["AGENTS.md": .linked, "skills": .linked, "agents": .merged, "prompts": .missingSource])
        #expect(Set(SharedContext.unlink(accountDir: account, sourceDir: source, provider: .codex)) == ["AGENTS.md", "skills"])
        #expect(FileManager.default.fileExists(atPath: t.sub("accounts/c/agents")))
        #expect(FileManager.default.fileExists(atPath: t.sub("home/.codex/skills")))
        #expect(!FileManager.default.fileExists(atPath: t.sub("accounts/c/skills")))
    }

    @Test func ownFolderGetsTheSharedItemsInsideIt() throws {
        let t = try TempDir()
        let source = try t.mkdir("home/.claude")
        try t.mkdir("home/.claude/skills/alpha")
        try t.mkdir("home/.claude/skills/beta")
        try t.mkdir("home/.claude/skills/synced")
        try t.write("home/.claude/skills/.DS_Store", "x")
        let account = try t.mkdir("accounts/a")
        try t.mkdir("accounts/a/skills/synced/own-skill")
        try t.mkdir("accounts/a/skills/beta")
        let fm = FileManager.default

        #expect(states(SharedContext.status(accountDir: account, sourceDir: source, provider: .claude))["skills"] == .notLinked)
        #expect(states(SharedContext.sync(accountDir: account, sourceDir: source, provider: .claude))["skills"] == .merged)
        #expect(try fm.destinationOfSymbolicLink(atPath: t.sub("accounts/a/skills/alpha")) == t.sub("home/.claude/skills/alpha"))
        // The account's own items stay: its synced folder and its own beta.
        #expect((try? fm.destinationOfSymbolicLink(atPath: t.sub("accounts/a/skills/beta"))) == nil)
        #expect(fm.fileExists(atPath: t.sub("accounts/a/skills/synced/own-skill")))
        #expect((try? fm.attributesOfItem(atPath: t.sub("accounts/a/skills/.DS_Store"))) == nil)
        #expect(states(SharedContext.status(accountDir: account, sourceDir: source, provider: .claude))["skills"] == .merged)

        // A shared item that goes away loses its link; a new one is linked.
        try fm.removeItem(atPath: t.sub("home/.claude/skills/alpha"))
        try t.mkdir("home/.claude/skills/gamma")
        SharedContext.sync(accountDir: account, sourceDir: source, provider: .claude)
        #expect((try? fm.attributesOfItem(atPath: t.sub("accounts/a/skills/alpha"))) == nil)
        #expect(fm.fileExists(atPath: t.sub("accounts/a/skills/gamma")))

        // The default account's `synced` is never linked into an account that has none yet.
        let other = try t.mkdir("accounts/b")
        try t.mkdir("accounts/b/skills")
        #expect(states(SharedContext.sync(accountDir: other, sourceDir: source, provider: .claude))["skills"] == .merged)
        #expect((try? fm.attributesOfItem(atPath: t.sub("accounts/b/skills/synced"))) == nil)
        #expect(states(SharedContext.status(accountDir: other, sourceDir: source, provider: .claude))["skills"] == .merged)

        // Turning sharing off removes only our item links.
        #expect(SharedContext.unlink(accountDir: account, sourceDir: source, provider: .claude) == ["skills"])
        #expect((try? fm.attributesOfItem(atPath: t.sub("accounts/a/skills/gamma"))) == nil)
        #expect(fm.fileExists(atPath: t.sub("accounts/a/skills/beta")))
        #expect(fm.fileExists(atPath: t.sub("accounts/a/skills/synced/own-skill")))
    }

    @Test func shellHasNothingToShare() {
        #expect(SharedContext.entries(for: .shell).isEmpty)
    }

    // MARK: Memory

    @Test func projectKeyMatchesClaudeCode() {
        #expect(SharedContext.claudeProjectKey("/Users/harundogdu/git/hdlanes") == "-Users-harundogdu-git-hdlanes")
        #expect(SharedContext.claudeProjectKey("/Users/u/Desktop/FI/Fi.Web") == "-Users-u-Desktop-FI-Fi-Web")
        #expect(SharedContext.claudeProjectKey("/a/ç b_c") == "-a---b-c")
        #expect(SharedContext.claudeProjectKey("/" + String(repeating: "a", count: 199)) != nil)
        #expect(SharedContext.claudeProjectKey("/" + String(repeating: "a", count: 200)) == nil)
    }

    @Test func memoryDirIsUnderTheDefaultAccountsProjects() {
        #expect(SharedContext.claudeMemoryDirectory(sourceDir: "/Users/u/.claude", repositoryRoot: "/Users/u/git/app")
                == "/Users/u/.claude/projects/-Users-u-git-app/memory")
    }

    @Test func repositoryRootOfAWorktreeIsTheMainRepository() throws {
        let t = try TempDir()
        try t.mkdir("repo/.git/worktrees/feature")
        try t.write("repo/.git/worktrees/feature/commondir", "../..\n")
        try t.mkdir("repo/src/deep")
        try t.write("wt/feature/.git", "gitdir: \(t.sub("repo/.git/worktrees/feature"))\n")
        try t.mkdir("wt/feature/sub")
        try t.mkdir("plain/folder")

        #expect(SharedContext.repositoryRoot(for: t.sub("repo")) == t.sub("repo"))
        #expect(SharedContext.repositoryRoot(for: t.sub("repo/src/deep")) == t.sub("repo"))
        #expect(SharedContext.repositoryRoot(for: t.sub("wt/feature/sub")) == t.sub("repo"))
        #expect(SharedContext.repositoryRoot(for: t.sub("plain/folder")) == t.sub("plain/folder"))
    }

    @Test func relativeGitdirAndBareCommonDir() throws {
        let t = try TempDir()
        try t.mkdir("repo/.git/worktrees/w")
        try t.write("repo/.git/worktrees/w/commondir", "../..")
        try t.write("repo/w/.git", "gitdir: ../.git/worktrees/w")
        #expect(SharedContext.repositoryRoot(for: t.sub("repo/w")) == t.sub("repo"))

        try t.mkdir("bare.git/worktrees/x")
        try t.write("bare.git/worktrees/x/commondir", "../..")
        try t.write("x/.git", "gitdir: \(t.sub("bare.git/worktrees/x"))")
        #expect(SharedContext.repositoryRoot(for: t.sub("x")) == t.sub("x"))
    }

    @Test func realWorktreeFromGit() throws {
        // A real `git worktree add`, so the .git file format is git's own.
        let t = try TempDir()
        let repo = try t.mkdir("main")
        func git(_ args: [String], in dir: String) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        try git(["init", "-q"], in: repo)
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "x"], in: repo)
        try git(["worktree", "add", "-q", t.sub("linked"), "-b", "b"], in: repo)
        guard FileManager.default.fileExists(atPath: t.sub("linked/.git")) else { return }
        #expect(SharedContext.repositoryRoot(for: t.sub("linked")) == repo)
    }
}
