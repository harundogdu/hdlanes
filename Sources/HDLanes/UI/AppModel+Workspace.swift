import AppKit
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
    case aiUnsure
    case jevKeyMissing
    case invalidBranch(String)
    case connection(ConnectionRules.Problem)

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
        case .aiUnsure: return L.errAIUnsure
        case .jevKeyMissing: return L.errJevKeyMissing
        case .invalidBranch(let problem): return problem
        case .connection(let problem): return L.connectionProblem(problem)
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
        } catch GitError.worktreeDirty(let path, let risks) {
            // Files would be lost: say which and ask before forcing. Nothing was stopped yet.
            let alert = NSAlert()
            alert.messageText = L.worktreeRemoveConfirmTitle
            alert.informativeText = L.worktreeRemoveConfirmBody(path: path, risks: risks)
            alert.addButton(withTitle: L.worktreeRemoveConfirmButton)
            alert.addButton(withTitle: L.cancel)
            alert.alertStyle = .critical
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                stop(id)
                try await self.removeWorktree(sessionID: id, force: true)
                archiveSession(id)
            } catch {
                show(error: error, title: L.removeWorktreeFailed)
            }
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
            var branch: String
            if let typed = request.branch?.nilIfBlank {
                branch = typed
            } else {
                branch = await suggestedBranchName(title: title, project: project)
            }
            if let problem = branchNameProblem(branch) { throw WorkspaceError.invalidBranch(problem) }
            let result = try await createWorktree(project: project, branch: branch,
                                                  baseRef: request.baseRef?.nilIfBlank)
            // A project in a subfolder of its repo keeps working in the same subfolder of the worktree.
            if let repo = await repositoryRoot(for: project.path) {
                let sub = Self.subpath(of: project.path, in: repo)
                session.cwd = sub.isEmpty ? result.path : (result.path as NSString).appendingPathComponent(sub)
            } else {
                session.cwd = result.path
            }
            if !result.copyFailures.isEmpty {
                alert = AppAlert(title: L.copyFilesFailedTitle, message: result.copyFailures.joined(separator: "\n"))
            }
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
        // lastActivityAt stays nil: launch() treats nil as "first launch" and sends the prompt and setup.

        state.sessions.append(session)
        if let task, task.status != .active { setTaskStatus(task.id, .active) }
        selection = .session(session.id)
        launch(session.id, resume: false)
        return session.id
    }

    /// A new session in the same project, folder, provider and account as `id`. With `fork`, it starts
    /// as a copy of `id`'s conversation (Claude `--fork-session`, `codex fork`); otherwise empty. The
    /// copy works in the same folder but never owns its worktree, so closing it can't remove that.
    @discardableResult
    func duplicateSession(_ id: UUID, fork: Bool) -> UUID? {
        guard let source = session(id) else { return nil }
        if fork { guard canFork(source) else { return nil } }
        var copy = AgentSession(projectID: source.projectID, title: L.copyTitle(source.title, fork: fork),
                                provider: source.provider, accountID: source.accountID, cwd: source.cwd)
        copy.branch = source.branch
        copy.baseRef = source.baseRef
        copy.taskID = source.taskID
        copy.category = source.category
        copy.forkedFromAgentSessionID = fork ? source.agentSessionID : nil
        state.sessions.append(copy)
        selection = .session(copy.id)
        launch(copy.id, resume: false)
        return copy.id
    }

    /// A conversation to copy: an agent session that has talked at least once.
    func canFork(_ session: AgentSession) -> Bool {
        session.provider.isAgent && session.agentSessionID?.nilIfBlank != nil && session.lastActivityAt != nil
    }

    func defaultSessionTitle(_ provider: Provider, in projectID: UUID) -> String {
        let n = state.sessions.filter { $0.projectID == projectID && $0.provider == provider }.count + 1
        return L.defaultSessionTitle(provider, n)
    }

    /// The work behind `closeSession`. When the worktree holds work that removal would lose, this throws
    /// `GitError.worktreeDirty` before anything is stopped, so the session and its agent keep running.
    func closeSessionThrowing(_ id: UUID, removeWorktree: Bool) async throws {
        guard let session = session(id) else { return }
        if removeWorktree, let path = session.worktreePath {
            if let risks = try await worktreeRemovalRisks(sessionID: id), risks.needsConfirmation {
                throw GitError.worktreeDirty(path: path, risks: risks)
            }
            stop(id)
            // Checks again: anything written after the first look still stops a non-forced removal.
            try await self.removeWorktree(sessionID: id, force: false)
        }
        archiveSession(id)
    }

    /// Stops a session and hides it; its record stays in state.json.
    func archiveSession(_ id: UUID) {
        let order = sidebarSessionIDs
        stop(id)
        terminals.remove(id)
        // A removed view no longer reports its exit, so clear the running flag and end the runtime
        // side (rollout watcher, waiting hook) here.
        runtimes[id]?.isProcessRunning = false
        endRuntime(id)
        if session(id)?.isArchived != true { recordActivity(.sessionClosed, sessionID: id) }
        updateSession(id) { $0.isArchived = true }
        updateDockBadge()
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
