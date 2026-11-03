import HDCore
import SwiftUI

// OWNER: workspace area.
struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 460)
        } detail: {
            VStack(spacing: 0) {
                if let warning = model.loadWarning {
                    LoadWarningBanner(text: warning) { model.loadWarning = nil }
                    Divider()
                }
                DetailContent()
            }
        }
        .toolbar { MainToolbar() }
        .sheet(isPresented: $model.isNewSessionSheetPresented) { NewSessionSheet() }
        .sheet(isPresented: $model.isNewTaskSheetPresented) { TaskEditorSheet(taskID: nil) }
        .sheet(isPresented: $model.isAddAccountSheetPresented) { AddAccountSheet() }
        .alert(model.alert?.title ?? "", isPresented: isPresented($model.alert), presenting: model.alert) { _ in
            Button(L.ok) {}
        } message: { alert in
            Text(alert.message)
        }
        // L.language isn't observable; rebuilding the window applies a language change.
        .id(model.state.settings.language ?? .system)
    }
}

private struct DetailContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.selection {
        case .session(let id):
            if let s = model.session(id), s.isArchived != true {
                SessionDetailView(sessionID: id).id(id)
            } else {
                WelcomeView()
            }
        case .board:
            TaskBoardView()
        case nil:
            WelcomeView()
        }
    }
}

private struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.isNewSessionSheetPresented = true } label: {
                Label(L.newSession, systemImage: "plus")
            }
            .help(L.newSessionHelp)
            Button { model.selection = .board } label: {
                Label(L.board, systemImage: "rectangle.split.3x1")
            }
            .help(L.showBoardHelp)
            Button { model.isInspectorVisible.toggle() } label: {
                Label(L.toggleInspector, systemImage: "sidebar.right")
            }
            .help(L.toggleInspectorHelp)
            .disabled(model.selectedSessionID == nil)
        }
    }
}

private struct LoadWarningBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(L.dismiss)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Shown when no session is selected. On first run it says what hdlanes is and how to begin.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showAccounts = false

    var body: some View {
        let firstRun = model.state.projects.isEmpty
        ContentUnavailableView {
            Label(firstRun ? L.welcomeTitle : L.noSessionSelected, systemImage: "rectangle.split.3x1")
        } description: {
            Text(firstRun ? L.welcomeBody : L.noSessionSelectedBody)
        } actions: {
            HStack {
                if firstRun {
                    Button(L.addProjectEllipsis) { Task { await Panels.addProject(model: model) } }
                }
                Button(L.newSession) { model.isNewSessionSheetPresented = true }
                Button(L.accounts) { showAccounts = true }
            }
        }
        .sheet(isPresented: $showAccounts) { AccountsSheet() }
    }
}
