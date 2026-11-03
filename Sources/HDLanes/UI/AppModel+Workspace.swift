import Foundation
import HDCore

/// Result of the last `claude auth status --json` / `codex login status` for an account.
/// OWNER: workspace area. Add fields freely.
struct AccountHealth: Equatable {
    var loggedIn: Bool?
    var detail: String?
    var checkedAt = Date()
    var isChecking = false
    /// The vendor CLI wasn't found on the user's PATH.
    var cliMissing = false
    /// The check itself failed (timeout, unreadable output). Not the same as "not logged in".
    var error: String?
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

enum WorkspaceError: LocalizedError, Equatable {
    case projectMissing
    case noAccount(Provider)
    case systemAccount
    case accountInUse(Int)
    case notManaged
    case emptySecret
    case cliMissing(Provider)
    case timedOut
    case commandFailed(String)
    case aiDisabled
    case aiUnreadable

    var errorDescription: String? {
        switch self {
        case .projectMissing: return L.errProjectMissing
        case .noAccount(let p): return L.errNoAccount(p)
        case .systemAccount: return L.errSystemAccount
        case .accountInUse(let n): return L.errAccountInUse(n)
        case .notManaged: return L.errNotManaged
        case .emptySecret: return L.errEmptySecret
        case .cliMissing(let p): return L.cliMissing(p)
        case .timedOut: return L.errTimedOut
        case .commandFailed(let line): return line
        case .aiDisabled: return L.errAIDisabled
        case .aiUnreadable: return L.errAIUnreadable
        }
    }
}

// OWNER: workspace area. Signatures are a contract; keep them.
extension AppModel {
    /// Makes sure the user's existing ~/.claude and ~/.codex logins appear as accounts.
    func ensureSystemAccounts() {
        for provider in [Provider.claude, .codex]
        where !state.accounts.contains(where: { $0.provider == provider && $0.isSystemDefault }) {
            let account = Account(provider: provider, label: L.providerName(provider), colorIndex: nextAccountColorIndex(),
                                  isSystemDefault: true, configDir: nil, authMethod: .existing)
            // System accounts lead their provider's list.
            let at = state.accounts.firstIndex { $0.provider == provider } ?? state.accounts.endIndex
            state.accounts.insert(account, at: at)
        }
    }

    func addProject(path: String) async {
        await addProjectReturningID(path: path)
    }

    func removeProject(_ id: UUID) {
        // Sessions are archived, never deleted; their worktrees and files stay on disk.
        for s in visibleSessions where s.projectID == id { archiveSession(s.id) }
        state.projects.removeAll { $0.id == id }
    }

    /// Creates the session (worktree if requested), selects it and launches the agent.
    func createSession(_ request: NewSessionRequest) async {
        do {
            try await startSession(request)
        } catch {
            show(error: error, title: L.createSessionFailed)
        }
    }

    func closeSession(_ id: UUID, removeWorktree: Bool) async {
        do {
            try await closeSessionThrowing(id, removeWorktree: removeWorktree)
        } catch {
            show(error: error, title: L.removeWorktreeFailed)
        }
    }
}

// MARK: Projects and sessions

extension AppModel {
    /// Adds the repository (or folder) at `path`; returns the existing project when already added.
    @discardableResult
    func addProjectReturningID(path: String) async -> UUID? {
        let input = HDPaths.normalizedDirString(URL(fileURLWithPath: path).standardizedFileURL.path)
        guard !input.isEmpty else { return nil }
        let root = HDPaths.normalizedDirString(await repositoryRoot(for: input) ?? input)
        if let existing = state.projects.first(where: { HDPaths.normalizedDirString($0.path) == root }) {
            return existing.id
        }
        let name = URL(fileURLWithPath: root).lastPathComponent
        let project = Project(name: name.isEmpty ? root : name, path: root)
        state.projects.append(project)
        return project.id
    }

    func project(_ id: UUID?) -> Project? { id.flatMap { id in state.projects.first { $0.id == id } } }

    func updateProject(_ id: UUID, _ change: (inout Project) -> Void) {
        guard let i = state.projects.firstIndex(where: { $0.id == id }) else { return }
        change(&state.projects[i])
    }

    /// Whether `path` is inside a git work tree (the git contract, with a cheap `.git` fallback).
    func isGitRepository(_ path: String) async -> Bool {
        if await repositoryRoot(for: path) != nil { return true }
        return FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    /// The work behind `createSession`, throwing so the new-session sheet can show errors inline.
    @discardableResult
    func startSession(_ request: NewSessionRequest) async throws -> UUID {
        guard let project = project(request.projectID) else { throw WorkspaceError.projectMissing }

        var accountID: UUID?
        if request.provider.isAgent {
            if let id = request.accountID, account(id)?.provider == request.provider {
                accountID = id
            } else if let fallback = defaultAccount(for: request.provider, project: project) {
                accountID = fallback.id
            } else {
                throw WorkspaceError.noAccount(request.provider)
            }
        }

        let prompt = request.prompt?.nilIfBlank
        let title = request.title.nilIfBlank ?? SessionNaming.title(fromPrompt: prompt) ?? defaultSessionTitle(request.provider, in: project.id)

        var session = AgentSession(projectID: project.id, title: title, provider: request.provider,
                                   accountID: accountID, cwd: project.path)
        if request.useWorktree {
            let branch = request.branch?.nilIfBlank ?? SessionNaming.branchSlug(from: title)
            let result = try await createWorktree(project: project, branch: branch,
                                                  baseRef: request.baseRef?.nilIfBlank)
            session.cwd = result.path
            session.branch = result.branch
            session.baseRef = result.baseRef
            session.worktreePath = result.path
        } else {
            session.branch = await currentBranch(at: project.path)
        }

        let task = self.task(request.taskID)
        session.taskID = task?.id
        session.category = task?.category ?? Categorizer.categorize(title: title, prompt: prompt, branch: session.branch)
        session.initialPrompt = prompt
        session.lastActivityAt = Date()

        state.sessions.append(session)
        if let task, task.status != .active { updateTask(task.id) { $0.status = .active } }
        selection = .session(session.id)
        launch(session.id, resume: false)
        return session.id
    }

    func defaultSessionTitle(_ provider: Provider, in projectID: UUID) -> String {
        let n = state.sessions.filter { $0.projectID == projectID && $0.provider == provider }.count + 1
        return L.defaultSessionTitle(provider, n)
    }

    /// The work behind `closeSession`. When the worktree can't be removed the session stays (stopped).
    func closeSessionThrowing(_ id: UUID, removeWorktree: Bool) async throws {
        guard let session = session(id) else { return }
        stop(id)
        if removeWorktree, session.worktreePath != nil {
            // On failure the terminal (and its shell) stays, so the session is left as it was.
            try await self.removeWorktree(sessionID: id, force: false)
        }
        archiveSession(id)
    }

    /// Stops a session and hides it; its record stays in state.json.
    func archiveSession(_ id: UUID) {
        let order = sidebarSessionIDs
        stop(id)
        terminals.remove(id)
        // A removed view no longer reports its exit, so clear the running flag here.
        runtimes[id]?.isProcessRunning = false
        updateSession(id) { $0.isArchived = true }
        if selectedSessionID == id {
            selection = SessionOrdering.neighbor(of: id, in: order).map { .session($0) }
        }
    }

    func renameSession(_ id: UUID, to title: String) {
        guard let t = title.nilIfBlank else { return }
        updateSession(id) { $0.title = t }
    }

    /// Restarts a session whose process isn't running: resumes the agent conversation when one is
    /// known, otherwise starts fresh (or starts the shell).
    func resumeSession(_ id: UUID) {
        guard let s = session(id) else { return }
        launch(id, resume: s.provider.isAgent && s.agentSessionID != nil)
    }

    func isSessionRunning(_ id: UUID) -> Bool {
        runtimes[id]?.isProcessRunning ?? false
    }

    /// Status without creating a runtime as a side effect (safe to call from view bodies).
    func liveStatus(_ id: UUID) -> AgentStatus {
        runtimes[id]?.status ?? .notStarted
    }
}

extension String {
    /// Trimmed of whitespace and newlines; nil when nothing is left.
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
