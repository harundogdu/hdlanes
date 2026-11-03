import Foundation
import Testing
@testable import HDCore

/// Checks behind "Close and Remove Worktree": what would be lost, and where detached commits go.
struct WorktreeRemovalTests {
    @Test func rescueBranchNamesTheSessionAndCommit() {
        let sha = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
        #expect(WorktreePlanner.rescueBranch(sessionBranch: "hd/fix-login", worktreeName: "fix-login", head: sha,
                                             existing: ["main", "hd/fix-login"]) == "hd/rescued-fix-login-a1b2c3d")
        // No recorded branch: the folder name is used.
        #expect(WorktreePlanner.rescueBranch(sessionBranch: nil, worktreeName: "Giriş Ekranı", head: sha, existing: [])
                == "hd/rescued-giris-ekrani-a1b2c3d")
        #expect(WorktreeRemovalTests.isValid(WorktreePlanner.rescueBranch(sessionBranch: "feature/New UI", worktreeName: "x",
                                                                            head: sha, existing: [])))
    }

    @Test func rescueBranchIsUnique() {
        let sha = "abcdef1234567"
        #expect(WorktreePlanner.rescueBranch(sessionBranch: "hd/x", worktreeName: "x", head: sha,
                                             existing: ["hd/rescued-x-abcdef1"]) == "hd/rescued-x-abcdef1-2")
        #expect(WorktreePlanner.rescueBranch(sessionBranch: "hd/x", worktreeName: "x", head: sha,
                                             existing: ["HD/Rescued-X-ABCDEF1", "hd/rescued-x-abcdef1-2"]) == "hd/rescued-x-abcdef1-3")
        // A branch named `hd` blocks the `hd/` folder.
        #expect(WorktreePlanner.rescueBranch(sessionBranch: "hd/x", worktreeName: "x", head: sha, existing: ["hd"])
                == "hd-rescued-x-abcdef1")
    }

    @Test func ignoredFilesKeepSecretsAndDropBuildOutput() {
        // Real `git status --porcelain=v1 -z --untracked-files=normal --ignored=matching` output (git 2.54).
        let z = "!! .build/\0!! .env\0!! node_modules/\0!! secrets/\0!! sub/node_modules/\0!! sub/y.log\0!! x.log\0 M a.txt\0?? new.swift\0"
        let split = WorktreeRemovalRisks.split(GitOutput.statusEntries(z))
        #expect(split.uncommitted == ["a.txt", "new.swift"])
        #expect(split.ignored == [".build/", ".env", "node_modules/", "secrets/", "sub/node_modules/", "sub/y.log", "x.log"])
        #expect(WorktreePlanner.ignoredWorthKeeping(split.ignored) == [".env", "secrets/", "sub/y.log", "x.log"])
    }

    @Test func ignoredJunkAndNestedBuildFoldersAreDropped() {
        let paths = [".DS_Store", "ios/Pods/", "ios/App/GoogleService-Info.plist", "app/build/out.o", "a/__pycache__/m.pyc",
                     "x.pyc", "App.xcodeproj/project.xcworkspace/xcuserdata/", "tsconfig.tsbuildinfo", ".claude/settings.local.json"]
        #expect(WorktreePlanner.ignoredWorthKeeping(paths) == ["ios/App/GoogleService-Info.plist", ".claude/settings.local.json"])
    }

    @Test func operationsInProgressFromGitDirMarkers() {
        #expect(GitOperation.inProgress(existing: []).isEmpty)
        #expect(GitOperation.inProgress(existing: ["rebase-merge", "rebase-apply"]) == [.rebase])
        #expect(GitOperation.inProgress(existing: ["BISECT_LOG", "MERGE_HEAD", "logs", "HEAD"]) == [.merge, .bisect])
        #expect(GitOperation.inProgress(existing: ["CHERRY_PICK_HEAD", "REVERT_HEAD"]) == [.cherryPick, .revert])
    }

    @Test func confirmationNeededForFilesAndOperationsButNotForRescuedCommits() {
        #expect(!WorktreeRemovalRisks().needsConfirmation)
        #expect(WorktreeRemovalRisks(uncommitted: ["a.txt"]).needsConfirmation)
        // A clean status used to mean "nothing lost"; an edited ignored .env would have been deleted.
        #expect(WorktreeRemovalRisks(ignored: [".env"]).needsConfirmation)
        // `rebase -i` stopped at an edit leaves a clean status.
        #expect(WorktreeRemovalRisks(operations: [.rebase]).needsConfirmation)
        // Detached commits are saved to a branch, so they alone don't block the removal.
        #expect(!WorktreeRemovalRisks(unreachableCommits: 2, head: "abc1234", rescueBranch: "hd/rescued-x-abc1234").needsConfirmation)
    }

    @Test func diffBaseUsesUpstreamOnlyWhenLocalIsBehind() {
        #expect(GitRefs.diffBase(baseRef: "main", upstream: "origin/main", localIsAncestorOfUpstream: true) == "origin/main")
        // Local ahead or diverged: the local branch is the better base.
        #expect(GitRefs.diffBase(baseRef: "main", upstream: "origin/main", localIsAncestorOfUpstream: false) == "main")
        #expect(GitRefs.diffBase(baseRef: "main", upstream: nil, localIsAncestorOfUpstream: false) == "main")
        #expect(GitRefs.diffBase(baseRef: "main", upstream: "", localIsAncestorOfUpstream: true) == "main")
        #expect(GitRefs.diffBase(baseRef: "a1b2c3d4", upstream: "origin/main", localIsAncestorOfUpstream: true) == "a1b2c3d4")
    }

    private static func isValid(_ name: String) -> Bool { WorktreePlanner.validateBranchName(name) == nil }
}
