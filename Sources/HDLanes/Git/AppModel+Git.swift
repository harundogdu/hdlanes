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
}

struct WorktreeResult: Equatable {
    var path: String
    var branch: String
    var baseRef: String
}

// OWNER: git area. Signatures are a contract used by other areas; keep them.
extension AppModel {
    func repositoryRoot(for path: String) async -> String? { nil }

    func currentBranch(at path: String) async -> String? { nil }

    /// Local branches of the repo, current first. Used by the new-session sheet's base picker.
    func branches(at repoPath: String) async -> [String] { [] }

    /// Creates `branch` from `baseRef` (default: current HEAD of the project) in a new worktree,
    /// copies the project's `copyFiles`, runs nothing else (the session runs setupCommand itself).
    func createWorktree(project: Project, branch: String, baseRef: String?) async throws -> WorktreeResult {
        throw CocoaError(.featureUnsupported)
    }

    /// Removes the session's worktree (refuses when dirty unless `force`).
    func removeWorktree(sessionID: UUID, force: Bool) async throws {}

    func refreshDiff(_ sessionID: UUID) async {}

    func addReviewNote(_ note: ReviewNote, to sessionID: UUID) {}
    func removeReviewNote(_ noteID: UUID, from sessionID: UUID) {}
    /// Pastes all notes of the session into its agent as one message and clears them.
    func sendReviewNotes(_ sessionID: UUID) {}

    /// Pushes the session branch and opens a PR with `gh`. Returns the PR URL.
    func createPullRequest(sessionID: UUID, title: String, body: String) async throws -> URL {
        throw CocoaError(.featureUnsupported)
    }
}
