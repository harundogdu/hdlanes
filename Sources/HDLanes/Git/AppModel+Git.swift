import Foundation
import HDCore

/// Cached diff of one session's working tree against its base.
/// OWNER: git area. Add fields freely.
struct SessionDiff: Equatable {
    var files: [DiffFile] = []
    /// e.g. "vs main" / "vs HEAD".
    var baseDescription: String = ""
    var updatedAt = Date()
    var error: String?
    /// false until the first refresh finished; the view shows a loading state until then.
    var hasLoaded = false
    var isRefreshing = false
    /// A refresh was requested while one was running; it runs again when the current one ends.
    var refreshQueued = false
    var isRepository = true
    /// Untracked files beyond the listing cap.
    var skippedUntracked = 0
    /// The diff output hit the size cap; the last file may be cut short.
    var isTruncated = false
    var pullRequestURL: URL?
}

/// A line comment left in the diff view, sent to the agent as one message.
struct ReviewNote: Identifiable, Hashable {
    var id = UUID()
    var filePath: String
    /// New-file line number when the note is on a line; nil for a file-level note.
    var line: Int?
    var lineText: String
    var text: String
    var createdAt = Date()
    /// Old-file line number; the only number a removed line has.
    var oldLine: Int? = nil
}

struct WorktreeResult: Equatable {
    var path: String
    var branch: String
    var baseRef: String
    /// `copyFiles` entries that could not be copied (invalid path or I/O error).
    var copyFailures: [String] = []
}

/// What the "Create PR…" button and sheet need to know.
struct PullRequestInfo: Equatable {
    enum Problem: Equatable {
        case noSession, notRepository, noBranch, sameAsBase, ghMissing
    }

    var directory: String = ""
    var head: String?
    /// nil → gh picks the repository's default branch.
    var base: String?
    var uncommittedCount = 0
    var problem: Problem?
}

// OWNER: git area. Signatures are a contract used by other areas; keep them.
extension AppModel {
    func repositoryRoot(for path: String) async -> String? { await GitService.repoRoot(path) }

    func currentBranch(at path: String) async -> String? { await GitService.currentBranch(path) }

    /// Local branches of the repo, current first. Used by the new-session sheet's base picker.
    func branches(at repoPath: String) async -> [String] { await GitService.branches(repoPath) }

    /// Creates `branch` from `baseRef` (default: current HEAD of the project) in a new worktree,
    /// copies the project's `copyFiles`, runs nothing else (the session runs setupCommand itself).
    func createWorktree(project: Project, branch: String, baseRef: String?) async throws -> WorktreeResult {
        guard let repo = await GitService.repoRoot(project.path) else { throw GitError.notRepository(project.path) }
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = WorktreePlanner.validateBranchName(name) { throw GitError.invalidBranch(name, problem) }

        let base: String
        if let requested = baseRef?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            guard await GitService.resolveCommit(requested, in: repo) != nil else { throw GitError.invalidBaseRef(requested) }
            base = requested
        } else if let current = await GitService.currentBranch(repo) {
            base = current
        } else if let head = await GitService.resolveCommit("HEAD", in: repo) {
            // Detached HEAD: record the commit, "HEAD" would mean something else once the worktree commits.
            base = head
        } else {
            throw GitError.invalidBaseRef("HEAD")
        }

        let parent = WorktreePlanner.worktreeParent(repoRoot: repo, worktreeRoot: project.worktreeRoot)
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
        let path = WorktreePlanner.worktreePath(slug: WorktreePlanner.slug(forBranch: name), parent: parent,
                                                existingNames: existing)
        try await GitService.worktreeAdd(repo: repo, path: path, branch: name, base: base)

        var failures: [String] = []
        if let copies = project.copyFiles, !copies.isEmpty {
            // A project inside a bigger repo keeps its files at the same subpath of the worktree.
            let target = (path as NSString).appendingPathComponent(Self.subpath(of: project.path, in: repo))
            failures = await GitService.copyFiles(copies, from: project.path, to: target)
        }
        return WorktreeResult(path: path, branch: name, baseRef: base, copyFailures: failures)
    }

    /// Removes the session's worktree (refuses when dirty unless `force`).
    /// Throws `GitError.worktreeDirty` when there are uncommitted or untracked files; the branch and its
    /// commits are never deleted.
    func removeWorktree(sessionID: UUID, force: Bool) async throws {
        guard let session = session(sessionID) else { throw GitError.sessionNotFound }
        guard let worktree = session.worktreePath else { return }
        let fm = FileManager.default
        let mainCheckout = project(session.projectID)?.path

        guard fm.fileExists(atPath: worktree) else {
            if let mainCheckout { await GitService.worktreePrune(mainCheckout) }
            updateSession(sessionID) { $0.worktreePath = nil }
            return
        }
        if !force {
            let changes = try await GitService.status(worktree)
            if !changes.isEmpty {
                throw GitError.worktreeDirty(path: worktree, count: changes.count, sample: changes.prefix(3).map(\.path))
            }
        }
        var runFrom = worktree
        if let mainCheckout, fm.fileExists(atPath: mainCheckout) {
            runFrom = mainCheckout
        } else if let main = await GitService.mainWorktree(of: worktree) {
            runFrom = main
        }
        try await GitService.worktreeRemove(repo: runFrom, path: worktree, force: force)
        updateSession(sessionID) { $0.worktreePath = nil }
        diffs[sessionID] = nil
    }

    func refreshDiff(_ sessionID: UUID) async {
        guard session(sessionID) != nil else { return }
        if diffs[sessionID]?.isRefreshing == true {
            diffs[sessionID]?.refreshQueued = true
            return
        }
        var entry = diffs[sessionID] ?? SessionDiff()
        entry.isRefreshing = true
        entry.refreshQueued = false
        diffs[sessionID] = entry

        repeat {
            diffs[sessionID]?.refreshQueued = false
            guard let session = session(sessionID) else {
                diffs[sessionID] = nil
                return
            }
            let result: Result<GitService.DiffSnapshot?, Error>
            do {
                result = .success(try await GitService.loadDiff(cwd: session.cwd, baseRef: session.baseRef))
            } catch {
                result = .failure(error)
            }
            guard var d = diffs[sessionID] else { return }
            switch result {
            case .success(let snapshot?):
                d.files = snapshot.files
                d.baseDescription = snapshot.baseName.map(L.diffVersus) ?? L.diffVersusHead
                d.skippedUntracked = snapshot.skippedUntracked
                d.isTruncated = snapshot.truncated
                d.isRepository = true
                d.error = nil
            case .success(nil):
                d.files = []
                d.baseDescription = ""
                d.isRepository = false
                d.error = nil
            case .failure(let error):
                // Keep the previous files so the list doesn't flash empty on a transient failure.
                d.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            d.hasLoaded = true
            d.updatedAt = Date()
            diffs[sessionID] = d
        } while diffs[sessionID]?.refreshQueued == true
        diffs[sessionID]?.isRefreshing = false
    }

    func addReviewNote(_ note: ReviewNote, to sessionID: UUID) {
        reviewNotes[sessionID, default: []].append(note)
    }

    func removeReviewNote(_ noteID: UUID, from sessionID: UUID) {
        reviewNotes[sessionID]?.removeAll { $0.id == noteID }
        if reviewNotes[sessionID]?.isEmpty == true { reviewNotes[sessionID] = nil }
    }

    /// Pastes all notes of the session into its agent as one message and clears them.
    func sendReviewNotes(_ sessionID: UUID) {
        guard let notes = reviewNotes[sessionID], !notes.isEmpty else { return }
        let text = Self.reviewMessage(for: notes)
        sendText(text, to: sessionID, submit: true)
        reviewNotes[sessionID] = nil
    }

    /// Pushes the session branch and opens a PR with `gh`. Returns the PR URL.
    func createPullRequest(sessionID: UUID, title: String, body: String) async throws -> URL {
        let info = await pullRequestInfo(sessionID: sessionID)
        switch info.problem {
        case .noSession: throw GitError.sessionNotFound
        case .notRepository: throw GitError.notRepository(info.directory)
        case .noBranch: throw GitError.noBranch
        case .sameAsBase: throw GitError.sameAsBase(info.head ?? "")
        case .ghMissing: throw GitError.toolMissing("gh")
        case nil: break
        }
        guard let head = info.head else { throw GitError.noBranch }
        try await GitService.push(branch: head, in: info.directory)
        let url = try await GitService.createPullRequest(in: info.directory, title: title, body: body,
                                                         base: info.base, head: head)
        diffs[sessionID]?.pullRequestURL = url
        return url
    }

    // MARK: Additions (git area)

    /// Default branch for a new session: `hd/<slug of title>`, unique among the repo's branches.
    func suggestedBranchName(title: String, project: Project) async -> String {
        let existing = await GitService.branches(project.path)
        return WorktreePlanner.defaultBranch(for: title, existing: existing)
    }

    /// Localized reason a user-typed branch name is invalid, or nil when git would accept it.
    func branchNameProblem(_ name: String) -> String? {
        WorktreePlanner.validateBranchName(name.trimmingCharacters(in: .whitespacesAndNewlines)).map(L.describe)
    }

    func isGitHubCLIAvailable() async -> Bool { await GitService.ghAvailable() }

    func pullRequestInfo(sessionID: UUID) async -> PullRequestInfo {
        var info = PullRequestInfo()
        guard let session = session(sessionID) else {
            info.problem = .noSession
            return info
        }
        info.directory = session.worktreePath ?? session.cwd
        guard await GitService.repoRoot(info.directory) != nil else {
            info.problem = .notRepository
            return info
        }
        let head: String?
        if let branch = session.branch { head = branch } else { head = await GitService.currentBranch(info.directory) }
        info.head = head
        if let fromRef = GitRefs.pullRequestBase(fromBaseRef: session.baseRef) {
            info.base = fromRef
        } else {
            info.base = await GitService.defaultRemoteBranch(info.directory)
        }
        info.uncommittedCount = (try? await GitService.status(info.directory).count) ?? 0
        if head == nil {
            info.problem = .noBranch
        } else if head == info.base {
            info.problem = .sameAsBase
        } else if !(await GitService.ghAvailable()) {
            info.problem = .ghMissing
        }
        return info
    }

    static func reviewMessage(for notes: [ReviewNote]) -> String {
        let comments = notes.map {
            ReviewComment(path: $0.filePath, newLine: $0.line, oldLine: $0.oldLine, lineText: $0.lineText, text: $0.text)
        }
        return ReviewMessage.format(header: L.reviewMessageHeader, comments: comments, removedLine: L.reviewRemovedLine)
    }

    /// `project` relative to `repo` ("" when they are the same folder), symlinks resolved on both.
    nonisolated static func subpath(of project: String, in repo: String) -> String {
        let p = URL(fileURLWithPath: project).resolvingSymlinksInPath().standardizedFileURL.path
        let r = URL(fileURLWithPath: repo).resolvingSymlinksInPath().standardizedFileURL.path
        guard p != r, p.hasPrefix(r + "/") else { return "" }
        return String(p.dropFirst(r.count + 1))
    }
}
