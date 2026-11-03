import Foundation
import HDCore

/// Result of the last `claude auth status --json` / `codex login status` for an account.
/// OWNER: workspace area. Add fields freely.
struct AccountHealth: Equatable {
    var loggedIn: Bool?
    var detail: String?
    var checkedAt = Date()
    var isChecking = false
}

struct NewSessionRequest: Equatable {
    var projectID: UUID
    var provider: Provider
    var accountID: UUID?
    var title: String
    var prompt: String?
    var useWorktree: Bool
    var branch: String?
    var baseRef: String?
    var taskID: UUID?
}

// OWNER: workspace area. Signatures are a contract; keep them.
extension AppModel {
    /// Makes sure the user's existing ~/.claude and ~/.codex logins appear as accounts.
    func ensureSystemAccounts() {}

    func addProject(path: String) async {}
    func removeProject(_ id: UUID) {}

    /// Creates the session (worktree if requested), selects it and launches the agent.
    func createSession(_ request: NewSessionRequest) async {}

    func closeSession(_ id: UUID, removeWorktree: Bool) async {}
}
