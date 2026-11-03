import Foundation
import HDCore
import SwiftTerm

/// Long-lived runtime objects (hook socket server, Codex rollout watchers, timers).
/// OWNER: runtime area. Add stored properties here freely.
@MainActor
final class RuntimeServices {
}

// OWNER: runtime area. Signatures are a contract used by the UI and Git areas; keep them.
extension AppModel {
    /// Installs the Claude plugin, starts the hook socket server and usage seeding.
    func startRuntimeServices() {}

    func stopRuntimeServices() {}

    /// Starts (or resumes) the agent of a session in its terminal.
    func launch(_ sessionID: UUID, resume: Bool) {}

    /// Stops the agent process of a session (the terminal view stays).
    func stop(_ sessionID: UUID) {}

    /// Pastes text into the session's agent; `submit` presses Return.
    func sendText(_ text: String, to sessionID: UUID, submit: Bool) {}

    /// Answers a pending Claude permission request from the sidebar.
    func respondToPermission(sessionID: UUID, allow: Bool, message: String?) {}

    /// Clears the unread mark (called when the user selects the session).
    func markSeen(_ sessionID: UUID) {}

    /// Environment for running a vendor CLI as `account` (login, status checks): allowlisted base env,
    /// credential variables stripped, CLAUDE_CONFIG_DIR / CODEX_HOME set for managed accounts only.
    func environment(for account: Account?) -> [String: String] { ProcessInfo.processInfo.environment }

    /// Command for the login sheet's terminal: vendor login for `account` with `method`.
    func loginSpec(account: Account, method: AuthMethod, cwd: String) -> LaunchSpec {
        LaunchSpec(executable: "/bin/zsh", args: ["-l"], environment: environment(for: account), cwd: cwd)
    }

    func usage(for accountID: UUID) -> AccountUsage? { state.usage[accountID.uuidString] }

    // Terminal callbacks (from TerminalRegistry).
    func handleTerminalTitle(sessionID: UUID, title: String) {}
    func handleProgramStatus(sessionID: UUID, records: [TerminalProgramStatus]) {}
    func handleProcessExit(sessionID: UUID, exitCode: Int32?) {}
}
