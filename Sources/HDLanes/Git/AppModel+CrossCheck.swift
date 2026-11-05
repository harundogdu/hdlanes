import Foundation
import HDCore

/// State of one "Check with another account" run.
enum CrossCheckState: Equatable {
    case running(account: String)
    case done(account: String, added: Int)
    case failed(String)
}

// OWNER: git area. A second Claude or Codex account reads the session's diff (one `claude -p` or
// `codex exec`, no tools) and its
// findings become review notes the user can edit and send to the session's agent.
extension AppModel {
    /// Claude and Codex accounts to check with: accounts other than the session's own first.
    func crossCheckAccounts(for sessionID: UUID) -> [Account] {
        let own = session(sessionID)?.accountID
        let all = accounts(for: .claude) + accounts(for: .codex)
        return all.filter { $0.id != own } + all.filter { $0.id == own }
    }

    func runCrossCheck(sessionID: UUID, accountID: UUID) async {
        guard let session = session(sessionID), let account = account(accountID), [.claude, .codex].contains(account.provider) else { return }
        if case .running = crossChecks[sessionID] { return }
        crossChecks[sessionID] = .running(account: account.label)
        await refreshDiff(sessionID)
        // A refresh already in flight returns at once; wait for it so the diff isn't stale or empty.
        for _ in 0..<150 where diffs[sessionID]?.isRefreshing == true {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let files = diffs[sessionID]?.files ?? []
        guard !files.isEmpty else {
            crossChecks[sessionID] = .failed(L.crossCheckNoChanges)
            return
        }
        let diff = CrossCheck.renderDiff(files)
        let prompt = CrossCheck.prompt(title: session.title, diff: diff.text, truncated: diff.truncated,
                                       language: L.isTurkish ? "Turkish" : "English")
        let codex = account.provider == .codex
        let args = codex ? CrossCheck.codexArguments : CrossCheck.claudeArguments
        let result = await runAccountCLI(account, arguments: args, stdin: Data(prompt.utf8), timeout: 300)
        let reply = codex ? CodexExecOutput.lastMessage(from: result.stdout) : ClaudePrintOutput.result(from: result.stdout)
        let failure = codex ? CodexExecOutput.errorText(from: result.stdout) : ClaudePrintOutput.errorText(from: result.stdout)
        let outcome: CrossCheckState
        if result.launchFailed || AccountCLI.isCommandNotFound(status: result.status, output: result.combined) {
            outcome = .failed(WorkspaceError.cliMissing(account.provider).errorDescription ?? L.crossCheckFailed)
        } else if result.timedOut {
            outcome = .failed(WorkspaceError.timedOut.errorDescription ?? L.crossCheckFailed)
        } else if let text = reply, let findings = CrossCheck.parseFindings(text) {
            // Anchor on the snapshot that was sent (its line numbers); later refreshes relocate the notes.
            for a in CrossCheck.anchor(findings, in: files) {
                addReviewNote(ReviewNote(filePath: a.filePath, line: a.newLine, lineText: a.lineText,
                                         text: "[\(account.label)] \(a.note)", oldLine: a.oldLine), to: sessionID)
            }
            outcome = .done(account: account.label, added: findings.count)
        } else {
            let line = result.firstErrorLine().flatMap { $0.hasPrefix("{") ? nil : $0 }
            outcome = .failed(failure ?? (result.status != 0 ? (line ?? L.crossCheckFailed) : L.crossCheckUnreadable))
        }
        crossChecks[sessionID] = outcome
    }
}
