import Foundation
import Testing
@testable import HDCore

struct WorktreePlannerTests {
    @Test func slugTransliteratesTurkishAndFoldsAccents() {
        #expect(WorktreePlanner.slug(from: "Giriş ekranındaki çökme") == "giris-ekranindaki-cokme")
        #expect(WorktreePlanner.slug(from: "ĞÜŞİÖÇ ğüşıöç") == "gusioc-gusioc")
        #expect(WorktreePlanner.slug(from: "Café résumé naïve") == "cafe-resume-naive")
        #expect(WorktreePlanner.slug(from: "Fix: login (OAuth) -- v2!") == "fix-login-oauth-v2")
        #expect(WorktreePlanner.slug(from: "  --leading and trailing--  ") == "leading-and-trailing")
    }

    @Test func slugHasFallbackAndLimit() {
        #expect(WorktreePlanner.slug(from: "!!! ???") == WorktreePlanner.fallbackSlug)
        #expect(WorktreePlanner.slug(from: "") == WorktreePlanner.fallbackSlug)
        let long = WorktreePlanner.slug(from: String(repeating: "word ", count: 30))
        #expect(long.count <= WorktreePlanner.maxSlugLength)
        #expect(!long.hasSuffix("-"))
    }

    @Test func slugForBranchDropsPrefix() {
        #expect(WorktreePlanner.slug(forBranch: "hd/fix-login") == "fix-login")
        #expect(WorktreePlanner.slug(forBranch: "feature/New UI") == "feature-new-ui")
    }

    @Test func defaultBranchIsUnique() {
        #expect(WorktreePlanner.defaultBranch(for: "Fix login", existing: ["main"]) == "hd/fix-login")
        #expect(WorktreePlanner.defaultBranch(for: "Fix login", existing: ["main", "hd/fix-login"]) == "hd/fix-login-2")
        #expect(WorktreePlanner.defaultBranch(for: "Fix login", existing: ["HD/Fix-Login", "hd/fix-login-2"]) == "hd/fix-login-3")
    }

    @Test func defaultBranchAvoidsRefDirectoryClashes() {
        #expect(WorktreePlanner.defaultBranch(for: "x", existing: ["hd/x/old"]) == "hd/x-2")
        #expect(WorktreePlanner.defaultBranch(for: "x", existing: ["hd"]) == "hd-x")
    }

    @Test func worktreeParentDefaultsNextToRepo() {
        #expect(WorktreePlanner.worktreeParent(repoRoot: "/Users/me/git/app", worktreeRoot: nil) == "/Users/me/git/app-worktrees")
        #expect(WorktreePlanner.worktreeParent(repoRoot: "/Users/me/git/app/", worktreeRoot: "  ") == "/Users/me/git/app-worktrees")
        #expect(WorktreePlanner.worktreeParent(repoRoot: "/Users/me/git/app", worktreeRoot: "/tmp/wt/") == "/tmp/wt")
        #expect(WorktreePlanner.worktreeParent(repoRoot: "/Users/me/git/app", worktreeRoot: "../trees") == "/Users/me/git/trees")
        let home = WorktreePlanner.worktreeParent(repoRoot: "/r", worktreeRoot: "~/wt")
        #expect(home.hasPrefix("/") && home.hasSuffix("/wt") && !home.contains("~"))
    }

    @Test func worktreePathIsUnique() {
        #expect(WorktreePlanner.worktreePath(slug: "fix", parent: "/w", existingNames: []) == "/w/fix")
        #expect(WorktreePlanner.worktreePath(slug: "fix", parent: "/w", existingNames: ["Fix", "fix-2"]) == "/w/fix-3")
    }

    @Test func validBranchNames() {
        for name in ["main", "hd/fix-login", "feature/x.y", "release/1.2.3", "a@b", "ünï/çode", "x-"] {
            #expect(WorktreePlanner.validateBranchName(name) == nil, "\(name)")
        }
    }

    @Test func invalidBranchNames() {
        let cases: [(String, BranchNameProblem)] = [
            ("", .empty),
            ("has space", .containsSpace),
            ("tab\tname", .controlCharacter),
            ("a~1", .invalidCharacter("~")),
            ("a^b", .invalidCharacter("^")),
            ("a:b", .invalidCharacter(":")),
            ("a?b", .invalidCharacter("?")),
            ("a*b", .invalidCharacter("*")),
            ("a[b", .invalidCharacter("[")),
            ("a\\b", .invalidCharacter("\\")),
            ("a..b", .doubleDot),
            ("a@{1}", .atBrace),
            ("@", .isAt),
            ("-x", .leadingDash),
            ("/x", .slash),
            ("x/", .slash),
            ("a//b", .slash),
            ("x.lock", .lockSuffix),
            ("a.lock/b", .lockSuffix),
            ("x.", .trailingDot),
            (".hidden", .componentStartsWithDot),
            ("a/.b", .componentStartsWithDot),
            ("HEAD", .reserved),
        ]
        for (name, problem) in cases {
            #expect(WorktreePlanner.validateBranchName(name) == problem, "\(name)")
        }
    }

    @Test func parsesWorktreeList() {
        let text = """
            worktree /Users/me/git/app
            HEAD a3995a618f5396ca99c059f58bb6bce4eb07480d
            branch refs/heads/main

            worktree /Users/me/git/app-worktrees/x
            HEAD a3995a618f5396ca99c059f58bb6bce4eb07480d
            branch refs/heads/hd/x
            locked

            worktree /Users/me/git/app-worktrees/detached
            HEAD a3995a618f5396ca99c059f58bb6bce4eb07480d
            detached
            prunable gitdir file points to non-existent location

            """
        let list = WorktreeEntry.parseList(text)
        #expect(list.count == 3)
        #expect(list[0].branch == "main")
        #expect(list[1].branch == "hd/x" && list[1].isLocked)
        #expect(list[2].branch == nil && list[2].isDetached && list[2].isPrunable)
        #expect(list[2].path == "/Users/me/git/app-worktrees/detached")
    }

    @Test func pullRequestBaseFromRef() {
        #expect(GitRefs.pullRequestBase(fromBaseRef: "main") == "main")
        #expect(GitRefs.pullRequestBase(fromBaseRef: "origin/develop") == "develop")
        #expect(GitRefs.pullRequestBase(fromBaseRef: "refs/heads/release/1.2") == "release/1.2")
        #expect(GitRefs.pullRequestBase(fromBaseRef: "refs/remotes/upstream/main") == "main")
        #expect(GitRefs.pullRequestBase(fromBaseRef: "a3995a618f5396ca99c059f58bb6bce4eb07480d") == nil)
        #expect(GitRefs.pullRequestBase(fromBaseRef: "a3995a6") == nil)
        #expect(GitRefs.pullRequestBase(fromBaseRef: "HEAD") == nil)
        #expect(GitRefs.pullRequestBase(fromBaseRef: nil) == nil)
        #expect(GitRefs.pullRequestBase(fromBaseRef: "feature") == "feature")
    }
}
