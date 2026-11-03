import Foundation
import HDCore

// OWNER: workspace area. Import: existing account folders and past Claude / Codex conversations.

enum ImportTab: String, CaseIterable, Identifiable {
    case accounts, sessions
    var id: String { rawValue }
}

/// What the import sheet opens with (from the File menu, the welcome screen or a project's menu).
struct ImportPreset: Identifiable, Equatable {
    let id = UUID()
    var tab: ImportTab
    /// Prefilled search, e.g. a project's path.
    var search: String?
}

/// A past conversation found on disk, tagged with the hdlanes account whose folder holds it.
struct ImportableSession: Identifiable, Hashable {
    var candidate: SessionCandidate
    var accountID: UUID
    /// A session in the sidebar already has this agent session id.
    var isImported: Bool
    /// A closed (archived) hdlanes session with this id: importing brings that one back.
    var archivedSessionID: UUID?

    var id: String { accountID.uuidString + ":" + candidate.agentSessionID }
    var isSelectable: Bool { !isImported && candidate.cwdExists }
}

extension AppModel {
    // MARK: Accounts

    /// Account folders the user already has (editor settings, shell profiles, `~/.claude-*`), read off
    /// the main thread.
    func scanAccountCandidates() async -> [AccountCandidate] {
        let home = homeDirectory
        let root = paths.accountsDir.path
        let existing = state.accounts.compactMap(\.configDir)
        return await Task.detached(priority: .userInitiated) {
            ImportScanner.accountCandidates(home: home, hdlanesAccountsRoot: root, existingConfigDirs: existing)
        }.value
    }

    /// A folder picked in an open panel; `provider` nil detects it from the folder's contents.
    func chosenFolderCandidate(_ url: URL, provider: Provider?) -> ImportScanner.ChosenFolderResult {
        ImportScanner.chosenFolder(url, provider: provider, home: homeDirectory, hdlanesAccountsRoot: paths.accountsDir.path,
                                   existingConfigDirs: state.accounts.compactMap(\.configDir))
    }

    /// Adds each folder as an account that uses it in place: no login, nothing copied or moved. The dir
    /// string is stored exactly as found (it keys Claude's Keychain item). Returns the new account ids.
    @discardableResult
    func importAccounts(_ candidates: [AccountCandidate]) -> [UUID] {
        var added: [UUID] = []
        for c in candidates where c.provider.isAgent {
            if state.accounts.contains(where: { $0.configDir == c.dir }) { continue }
            let n = accounts(for: c.provider).count + 1
            let label = ImportScanner.labelSuffix(forFolder: c.dir, provider: c.provider)
                .map { L.importedAccountLabel(c.provider, $0) } ?? L.defaultAccountLabel(c.provider, n)
            let account = Account(provider: c.provider, label: label, colorIndex: nextAccountColorIndex(),
                                  isSystemDefault: false, configDir: c.dir, authMethod: .existing)
            state.accounts.append(account)
            added.append(account.id)
        }
        for id in added { Task { await refreshAccountHealth(id) } }
        return added
    }

    // MARK: Sessions

    /// Past conversations of `accounts` modified since `since`, newest first. System accounts read
    /// `~/.claude` / `~/.codex`, the others their own folder.
    func sessionCandidates(accounts: [Account], since: Date, includeHeadless: Bool) async -> [ImportableSession] {
        let home = homeDirectory
        let jobs: [(id: UUID, provider: Provider, dir: String)] = accounts.compactMap { a in
            switch a.provider {
            case .claude:
                let dir = a.isSystemDefault ? (home as NSString).appendingPathComponent(".claude") : a.configDir
                return dir.map { (a.id, .claude, $0) }
            case .codex:
                return (a.id, .codex, CodexRollout.codexHome(for: a, homeDirectory: home))
            case .shell:
                return nil
            }
        }
        let found = await withTaskGroup(of: [(UUID, SessionCandidate)].self) { group in
            for job in jobs {
                group.addTask(priority: .userInitiated) {
                    let list = job.provider == .claude
                        ? ImportScanner.claudeSessions(configDir: job.dir, since: since, includeHeadless: includeHeadless)
                        : ImportScanner.codexSessions(codexHome: job.dir, since: since, includeHeadless: includeHeadless)
                    return list.map { (job.id, $0) }
                }
            }
            var all: [(UUID, SessionCandidate)] = []
            for await part in group { all += part }
            return all
        }

        let visible = Set(visibleSessions.compactMap(\.agentSessionID))
        var archived: [String: UUID] = [:]
        for s in state.sessions where s.isArchived == true {
            if let agentID = s.agentSessionID { archived[agentID] = s.id }
        }
        return found
            .map { accountID, c in
                ImportableSession(candidate: c, accountID: accountID, isImported: visible.contains(c.agentSessionID),
                                  archivedSessionID: archived[c.agentSessionID])
            }
            .sorted { $0.candidate.lastActivity > $1.candidate.lastActivity }
    }

    /// Adds each conversation as a sidebar session that isn't running; Resume continues it
    /// (`claude --resume` / `codex resume`) in its own folder with its own account. No worktree is made
    /// or claimed, no prompt is sent. The project is the one whose folder holds the session's folder,
    /// else a new one for its repository. Selects the most recent imported session; returns the ids.
    @discardableResult
    func importSessions(_ items: [ImportableSession]) async -> [UUID] {
        var imported: [(id: UUID, at: Date)] = []
        // Shorter folders first: a repo's own sessions create its project before sessions in its
        // subfolders or worktrees look for one.
        let ordered = items.sorted {
            $0.candidate.cwd.count != $1.candidate.cwd.count
                ? $0.candidate.cwd.count < $1.candidate.cwd.count
                : $0.candidate.lastActivity > $1.candidate.lastActivity
        }
        for item in ordered where item.isSelectable {
            let c = item.candidate
            if visibleSessions.contains(where: { $0.agentSessionID == c.agentSessionID }) { continue }
            if let archivedID = item.archivedSessionID, let old = session(archivedID), old.isArchived == true {
                // Removing a project archives its sessions; bring one back into a project that exists.
                var projectID = old.projectID
                if project(projectID) == nil {
                    guard let found = await projectForImport(cwd: c.cwd) else { continue }
                    projectID = found
                }
                // The account it ran on may have been removed since; the folder that holds the transcript
                // belongs to item.accountID, so resume there.
                let accountID = account(old.accountID) == nil ? item.accountID : old.accountID
                updateSession(archivedID) {
                    $0.projectID = projectID
                    $0.accountID = accountID
                    $0.isArchived = nil
                }
                imported.append((archivedID, c.lastActivity))
                continue
            }
            guard account(item.accountID) != nil, let projectID = await projectForImport(cwd: c.cwd) else { continue }
            var session = AgentSession(projectID: projectID, title: c.title, provider: c.provider,
                                       accountID: item.accountID, cwd: c.cwd, createdAt: c.startedAt ?? c.lastActivity)
            session.agentSessionID = c.agentSessionID
            session.branch = c.branch
            session.category = Categorizer.categorize(title: c.title, prompt: c.firstPrompt, branch: c.branch)
            // Non-nil: launch() then treats it as launched before and sends no prompt or setup.
            session.lastActivityAt = c.lastActivity
            state.sessions.append(session)
            imported.append((session.id, c.lastActivity))
        }
        if let newest = imported.max(by: { $0.at < $1.at }) {
            if let projectID = session(newest.id)?.projectID { updateProject(projectID) { $0.isCollapsed = nil } }
            selection = .session(newest.id)
        }
        return imported.map(\.id)
    }

    /// The project whose folder (or worktree folder) holds `cwd`, else a new one for its repository.
    private func projectForImport(cwd: String) async -> UUID? {
        if let existing = ImportScanner.matchingProject(cwd: cwd, projects: state.projects) { return existing }
        return await addProjectReturningID(path: cwd)
    }
}
