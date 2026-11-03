import HDCore
import SwiftUI

// OWNER: workspace area.

struct IdentifiedID: Identifiable, Hashable {
    let id: UUID
}

/// What the close confirmation is about.
struct CloseRequest: Identifiable {
    let id: UUID
    let title: String
    let removeWorktree: Bool
    let worktreePath: String?
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renameTarget: IdentifiedID?
    @State private var renameText = ""
    @State private var closeRequest: CloseRequest?
    @State private var projectSettings: IdentifiedID?
    @State private var projectToRemove: IdentifiedID?

    var body: some View {
        @Bindable var model = model
        let sections = model.sidebarSections()
        List(selection: $model.selection) {
            BoardRow()
                .tag(SidebarSelection.board)
            ForEach(sections) { section in
                SidebarSectionView(section: section, actions: actions)
            }
        }
        .listStyle(.sidebar)
        .overlay { SidebarEmptyState(sections: sections) }
        .safeAreaInset(edge: .top, spacing: 0) { SidebarFilterBar() }
        .safeAreaInset(edge: .bottom, spacing: 0) { UsageFooter() }
        .alert(L.renameSession, isPresented: isPresented($renameTarget), presenting: renameTarget) { target in
            TextField(L.sessionTitlePlaceholder, text: $renameText)
            Button(L.rename) { model.renameSession(target.id, to: renameText) }
            Button(L.cancel, role: .cancel) {}
        }
        .confirmationDialog(closeRequest.map { L.closeSessionTitle($0.title) } ?? "", isPresented: isPresented($closeRequest),
                            titleVisibility: .visible, presenting: closeRequest) { request in
            Button(request.removeWorktree ? L.closeAndRemoveWorktree : L.closeSession,
                   role: request.removeWorktree ? .destructive : nil) {
                Task { await model.closeSession(request.id, removeWorktree: request.removeWorktree) }
            }
            Button(L.cancel, role: .cancel) {}
        } message: { request in
            Text(request.removeWorktree ? L.closeRemoveWorktreeMessage(request.worktreePath ?? "") : L.closeSessionMessage)
        }
        .confirmationDialog(projectToRemove.flatMap { model.project($0.id) }.map { L.removeProjectTitle($0.name) } ?? "",
                            isPresented: isPresented($projectToRemove), titleVisibility: .visible,
                            presenting: projectToRemove) { target in
            Button(L.remove, role: .destructive) { model.removeProject(target.id) }
            Button(L.cancel, role: .cancel) {}
        } message: { target in
            Text(L.removeProjectMessage(model.visibleSessions.filter { $0.projectID == target.id }.count))
        }
        .sheet(item: $projectSettings) { target in
            ProjectSettingsSheet(projectID: target.id)
        }
    }

    private var actions: SidebarActions {
        SidebarActions(
            rename: { id in
                renameText = model.session(id)?.title ?? ""
                renameTarget = IdentifiedID(id: id)
            },
            close: { id, removeWorktree in
                guard let s = model.session(id) else { return }
                closeRequest = CloseRequest(id: id, title: s.title, removeWorktree: removeWorktree, worktreePath: s.worktreePath)
            },
            projectSettings: { projectSettings = IdentifiedID(id: $0) },
            removeProject: { projectToRemove = IdentifiedID(id: $0) }
        )
    }
}

/// Binding that is true while `item` is set (for alerts and dialogs that present an item).
func isPresented<T>(_ item: Binding<T?>) -> Binding<Bool> {
    Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
}

/// Callbacks rows and headers use to ask the sidebar for dialogs.
struct SidebarActions {
    var rename: (UUID) -> Void
    var close: (UUID, Bool) -> Void
    var projectSettings: (UUID) -> Void
    var removeProject: (UUID) -> Void
}

private struct BoardRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Label(L.board, systemImage: "rectangle.split.3x1")
            Spacer()
            if model.activeTaskCount > 0 {
                Text(verbatim: "\(model.activeTaskCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(L.activeTasksHelp(model.activeTaskCount))
            }
        }
    }
}

private struct SidebarFilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Picker(L.filter, selection: $model.sidebarFilter) {
                ForEach(SidebarFilter.allCases) { f in
                    Text(L.filterLabel(f, model.sessionCount(for: f))).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            Menu {
                Picker(L.groupBy, selection: $model.sidebarGrouping) {
                    Text(L.groupByProject).tag(SidebarGrouping.project)
                    Text(L.groupByCategory).tag(SidebarGrouping.category)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L.groupBy)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct SidebarSectionView: View {
    let section: SidebarSection
    let actions: SidebarActions
    @Environment(AppModel.self) private var model

    var body: some View {
        if let project = section.project {
            Section(isExpanded: expanded(project)) {
                rows
                if section.sessions.isEmpty {
                    Button { newSession(project.id) } label: {
                        Label(L.newSession, systemImage: "plus")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                ProjectHeader(project: project, actions: actions)
            }
        } else {
            Section {
                rows
            } header: {
                HStack(spacing: 6) {
                    if let c = section.category {
                        Circle().fill(Theme.categoryColor(c)).frame(width: 6, height: 6)
                    }
                    Text(section.title)
                }
            }
        }
    }

    private var rows: some View {
        ForEach(section.sessions) { session in
            SessionRow(session: session)
                .tag(SidebarSelection.session(session.id))
                .contextMenu { SessionContextMenu(session: session, actions: actions) }
        }
    }

    private func expanded(_ project: Project) -> Binding<Bool> {
        Binding(get: { project.isCollapsed != true },
                set: { open in model.updateProject(project.id) { $0.isCollapsed = !open } })
    }

    private func newSession(_ projectID: UUID) {
        model.newSessionPreset = NewSessionPreset(projectID: projectID)
        model.isNewSessionSheetPresented = true
    }
}

private struct ProjectHeader: View {
    let project: Project
    let actions: SidebarActions
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Text(project.name)
                .lineLimit(1)
                .help(project.path)
            Spacer()
            Button { newSession() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help(L.newSessionIn(project.name))
        }
        .contextMenu {
            Button(L.newSession) { newSession() }
            Button(L.projectSettingsEllipsis) { actions.projectSettings(project.id) }
            Button(L.importPastSessionsEllipsis) { model.importPreset = ImportPreset(tab: .sessions, search: project.path) }
            Button(L.revealInFinder) { Panels.reveal(project.path) }
            Divider()
            Button(L.removeProjectEllipsis) { actions.removeProject(project.id) }
        }
    }

    private func newSession() {
        model.newSessionPreset = NewSessionPreset(projectID: project.id)
        model.isNewSessionSheetPresented = true
    }
}

private struct SessionContextMenu: View {
    let session: AgentSession
    let actions: SidebarActions
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(L.renameEllipsis) { actions.rename(session.id) }
        let running = model.isSessionRunning(session.id)
        if !running || model.agentEndedInLiveShell(session.id) {
            Button(session.provider.isAgent ? L.resume : L.startShell) { model.resumeFromUI(session.id) }
        }
        if running {
            Button(L.stop) { model.stop(session.id) }
        }
        Divider()
        Button(L.closeEllipsis) { actions.close(session.id, false) }
        if session.worktreePath != nil {
            Button(L.closeAndRemoveWorktreeEllipsis) { actions.close(session.id, true) }
        }
        Divider()
        Button(L.revealInFinder) { Panels.reveal(session.worktreePath ?? session.cwd) }
        if let branch = session.branch {
            Button(L.copyBranchName) { Panels.copy(branch) }
        }
    }
}

private struct SidebarEmptyState: View {
    let sections: [SidebarSection]
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.state.projects.isEmpty && model.visibleSessions.isEmpty {
            VStack(spacing: 8) {
                Text(L.sidebarNoProjects)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(L.addProjectEllipsis) { Task { await Panels.addProject(model: model) } }
                    .controlSize(.small)
            }
            .padding(20)
        } else if model.sidebarFilter != .all && sections.allSatisfy(\.sessions.isEmpty) {
            VStack(spacing: 8) {
                Text(L.filterEmpty(model.sidebarFilter))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button(L.showAll) { model.sidebarFilter = .all }
                    .controlSize(.small)
            }
            .padding(20)
        }
    }
}
