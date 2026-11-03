import Foundation
import HDCore

// OWNER: workspace area. Tasks on the board and the optional AI categorizer.
extension AppModel {
    @discardableResult
    func addTask(title: String, notes: String?, projectID: UUID?, category: String?) -> TaskItem {
        let title = title.nilIfBlank ?? L.untitledTask
        let notes = notes?.nilIfBlank
        let category = category.flatMap { Categorizer.isValid($0) ? $0 : nil }
            ?? Categorizer.categorize(title: title, prompt: notes)
        let task = TaskItem(title: title, notes: notes, category: category, projectID: projectID)
        state.tasks.append(task)
        return task
    }

    func editTask(_ id: UUID, title: String, notes: String?, projectID: UUID?, category: String) {
        updateTask(id) { t in
            if let title = title.nilIfBlank { t.title = title }
            t.notes = notes?.nilIfBlank
            t.projectID = projectID
            if t.category != category { t.categorizedByAI = false }
            t.category = Categorizer.isValid(category) ? category : t.category
        }
    }

    func setTaskStatus(_ id: UUID, _ status: TaskStatus) {
        guard task(id)?.status != status else { return }
        updateTask(id) { $0.status = status }
    }

    /// Removes the task; its sessions stay and just lose the link.
    func deleteTask(_ id: UUID) {
        state.tasks.removeAll { $0.id == id }
        for i in state.sessions.indices where state.sessions[i].taskID == id {
            state.sessions[i].taskID = nil
        }
    }

    func linkSession(_ sessionID: UUID, to taskID: UUID?) {
        updateSession(sessionID) { $0.taskID = taskID }
        if let taskID, let t = task(taskID), t.status == .backlog { setTaskStatus(taskID, .active) }
    }

    func sessions(forTask id: UUID) -> [AgentSession] {
        visibleSessions.filter { $0.taskID == id }
    }

    func tasks(in status: TaskStatus) -> [TaskItem] {
        state.tasks.filter { $0.status == status }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var activeTaskCount: Int { state.tasks.filter { $0.status == .active }.count }

    /// Opens the new-session sheet prefilled from a task.
    func startSession(forTask id: UUID) {
        guard let t = task(id) else { return }
        newSessionPreset = NewSessionPreset(projectID: t.projectID, taskID: t.id, title: t.title, prompt: t.notes)
        isNewSessionSheetPresented = true
    }

    // MARK: AI categorization (explicit, never per keystroke)

    var isAICategorizationEnabled: Bool { state.settings.aiCategorization == true }

    var aiCategorizationAccount: Account? {
        if let a = account(state.settings.aiCategorizationAccount), a.provider == .claude { return a }
        return accounts(for: .claude).first
    }

    /// One `claude -p` call on the chosen Claude account (uses that account's quota).
    func aiSuggestCategory(title: String, notes: String?) async throws -> String {
        guard isAICategorizationEnabled else { throw WorkspaceError.aiDisabled }
        guard let account = aiCategorizationAccount else { throw WorkspaceError.noAccount(.claude) }
        let prompt = Categorizer.aiPrompt(title: title, notes: notes)
        let args = ["-p", "--output-format", "json", "--model", "haiku", "--no-session-persistence", prompt]
        let result = await runAccountCLI(account, arguments: args, timeout: 60)
        if result.launchFailed || AccountCLI.isCommandNotFound(status: result.status, output: result.combined) {
            throw WorkspaceError.cliMissing(.claude)
        }
        if result.timedOut { throw WorkspaceError.timedOut }
        guard let id = Categorizer.parseAIAnswer(result.stdout) else {
            if result.status != 0, let line = result.firstErrorLine() { throw WorkspaceError.commandFailed(line) }
            throw WorkspaceError.aiUnreadable
        }
        return id
    }

    func categorizeTaskWithAI(_ id: UUID) async throws {
        guard let t = task(id) else { return }
        let category = try await aiSuggestCategory(title: t.title, notes: t.notes)
        updateTask(id) {
            $0.category = category
            $0.categorizedByAI = true
        }
    }
}
