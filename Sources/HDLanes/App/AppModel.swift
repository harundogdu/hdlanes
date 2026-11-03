import Foundation
import HDCore
import Observation
import SwiftUI

enum SidebarSelection: Hashable {
    case session(UUID)
    case board
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case changes, agents, browser
    var id: String { rawValue }
}

enum SidebarFilter: String, CaseIterable, Identifiable {
    case all, needsYou, working, done
    var id: String { rawValue }
}

enum SidebarGrouping: String, CaseIterable, Identifiable {
    case project, category
    var id: String { rawValue }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// The single source of truth for the UI. Persisted parts live in `state` (saved to state.json,
/// debounced); live parts (terminals, hook events, diffs) live next to it and are rebuilt on launch.
///
/// Behaviour is split across extensions by area:
///   Runtime/AppModel+Runtime.swift   launching agents, hook events, permissions, usage
///   Git/AppModel+Git.swift           worktrees, diffs, review notes, pull requests
///   UI/AppModel+Workspace.swift      projects, sessions, accounts, tasks
@MainActor
@Observable
final class AppModel {
    let paths: HDPaths
    @ObservationIgnored let store: StateStore

    var state: AppState {
        didSet { scheduleSave() }
    }

    /// Live state per session id. Created lazily by `runtime(for:)`.
    var runtimes: [UUID: SessionRuntime] = [:]

    var selection: SidebarSelection?
    var inspectorTab: InspectorTab = .changes
    var isInspectorVisible = true
    var sidebarFilter: SidebarFilter = .all
    var sidebarGrouping: SidebarGrouping = .project
    var alert: AppAlert?
    /// Set when state.json could not be read and was backed up; shown once as a banner.
    var loadWarning: String?

    // Sheets
    var isNewSessionSheetPresented = false
    var newSessionPreset: NewSessionPreset?
    var isAddAccountSheetPresented = false
    var isNewTaskSheetPresented = false

    @ObservationIgnored let terminals = TerminalRegistry()

    // Runtime area (Runtime/)
    @ObservationIgnored var runtimeServices = RuntimeServices()

    // Git area (Git/)
    var diffs: [UUID: SessionDiff] = [:]
    var reviewNotes: [UUID: [ReviewNote]] = [:]

    // Workspace area (UI/)
    var accountHealth: [UUID: AccountHealth] = [:]

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(paths: HDPaths = .live()) {
        self.paths = paths
        self.store = StateStore(paths: paths)
        let result = store.load()
        self.state = result.state
        if case .recoveredFromCorruption(_, let backup, _) = result {
            loadWarning = L.stateRecovered(backup)
        }
        terminals.model = self
    }

    /// Called once from the app delegate after the window is up.
    func start() {
        ensureSystemAccounts()
        startRuntimeServices()
        if selection == nil, let first = visibleSessions.first {
            selection = .session(first.id)
        }
    }

    func runtime(for id: UUID) -> SessionRuntime {
        if let r = runtimes[id] { return r }
        let r = SessionRuntime(sessionID: id)
        runtimes[id] = r
        return r
    }

    // MARK: Lookups

    func session(_ id: UUID) -> AgentSession? { state.sessions.first { $0.id == id } }
    func project(_ id: UUID) -> Project? { state.projects.first { $0.id == id } }
    func account(_ id: UUID?) -> Account? { id.flatMap { id in state.accounts.first { $0.id == id } } }
    func task(_ id: UUID?) -> TaskItem? { id.flatMap { id in state.tasks.first { $0.id == id } } }

    func accounts(for provider: Provider) -> [Account] { state.accounts.filter { $0.provider == provider } }

    var visibleSessions: [AgentSession] { state.sessions.filter { $0.isArchived != true } }

    var selectedSessionID: UUID? {
        if case .session(let id) = selection { return id }
        return nil
    }

    func updateSession(_ id: UUID, _ change: (inout AgentSession) -> Void) {
        guard let i = state.sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&state.sessions[i])
    }

    func updateTask(_ id: UUID, _ change: (inout TaskItem) -> Void) {
        guard let i = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&state.tasks[i])
        state.tasks[i].updatedAt = Date()
    }

    func updateAccount(_ id: UUID, _ change: (inout Account) -> Void) {
        guard let i = state.accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&state.accounts[i])
    }

    func show(error: Error, title: String) {
        alert = AppAlert(title: title, message: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try store.save(state)
        } catch {
            alert = AppAlert(title: L.saveFailedTitle, message: error.localizedDescription)
        }
    }
}

/// Live, non-persisted state of one session. The reducers produce `snapshot`; the rest is UI state.
@MainActor
@Observable
final class SessionRuntime {
    let sessionID: UUID
    var snapshot = AgentRuntimeSnapshot()
    /// Turn finished (or needs-you raised) while the user wasn't looking at this session.
    var unread = false
    var terminalTitle: String = ""
    /// http(s)://localhost-ish URLs seen in the terminal output, newest last.
    var detectedURLs: [URL] = []
    var isProcessRunning = false
    var exitCode: Int32?
    var startedAt: Date?

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    var status: AgentStatus { snapshot.status }
}

/// Values the "New session" sheet can be opened with (e.g. from a task card).
struct NewSessionPreset: Equatable {
    var projectID: UUID?
    var taskID: UUID?
    var title: String?
    var prompt: String?
}
