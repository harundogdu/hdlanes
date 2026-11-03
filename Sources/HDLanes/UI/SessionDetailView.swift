import HDCore
import SwiftUI

// OWNER: workspace area.

/// Header + terminal (+ inspector) of one session.
struct SessionDetailView: View {
    let sessionID: UUID
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.session(sessionID) {
            VStack(spacing: 0) {
                SessionHeader(session: session)
                Divider()
                HSplitView {
                    SessionTerminalArea(session: session)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    if model.isInspectorVisible {
                        InspectorView(sessionID: sessionID)
                            .frame(minWidth: 340, idealWidth: 400, maxWidth: 720, maxHeight: .infinity)
                    }
                }
            }
            .onAppear { model.markSeen(sessionID) }
            .onChange(of: model.runtimes[sessionID]?.unread ?? false) { _, unread in
                // The user is looking at it, so it isn't unread.
                if unread { model.markSeen(sessionID) }
            }
        } else {
            ContentUnavailableView(L.sessionMissing, systemImage: "questionmark.square.dashed")
        }
    }
}

private struct SessionHeader: View {
    let session: AgentSession
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.liveStatus(session.id)
        HStack(spacing: 8) {
            Image(systemName: ProviderStyle.symbol(session.provider))
                .foregroundStyle(.secondary)
                .help(L.providerName(session.provider))
            EditableTitle(title: session.title) { model.renameSession(session.id, to: $0) }
            if session.provider.isAgent {
                AccountChip(account: model.account(session.accountID))
            }
            if let branch = session.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.worktreePath ?? session.cwd)
            }
            Spacer(minLength: 8)
            StatusGlyph(status: status)
            Text(L.statusText(status))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            RunControl(session: session)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }
}

/// Resume when nothing runs in the terminal, Stop while it does.
private struct RunControl: View {
    let session: AgentSession
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isSessionRunning(session.id) {
            Button(L.stop) { model.stop(session.id) }
                .controlSize(.small)
                .help(L.stopHelp)
        } else {
            Button(session.provider.isAgent ? L.resume : L.startShell) { model.resumeSession(session.id) }
                .controlSize(.small)
        }
    }
}

/// Title that turns into a text field on double-click.
struct EditableTitle: View {
    let title: String
    let onCommit: (String) -> Void
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing {
            TextField(L.sessionTitlePlaceholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: 320)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { isEditing = false }
                .onChange(of: focused) { _, now in if !now { commit() } }
                .onAppear { focused = true }
        } else {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .help(L.renameHelp)
                .onTapGesture(count: 2) {
                    draft = title
                    isEditing = true
                }
        }
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        if draft.nilIfBlank != nil, draft != title { onCommit(draft) }
    }
}

private struct SessionTerminalArea: View {
    let session: AgentSession
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if !model.isSessionRunning(session.id) {
                NotRunningStrip(session: session)
            }
            TerminalHost(sessionID: session.id)
                .padding(.leading, 6)
                .padding(.top, 4)
        }
        .background(Color(nsColor: TerminalTheme.background))
    }
}

/// Shown above the terminal when no process runs in it (e.g. a session from a previous app run).
private struct NotRunningStrip: View {
    let session: AgentSession
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
            Text(L.notRunning)
                .font(.system(size: 12))
            Spacer()
            Button(session.provider.isAgent ? L.resume : L.startShell) { model.resumeSession(session.id) }
                .controlSize(.small)
                .help(session.provider.isAgent && session.agentSessionID != nil ? L.resumeHelp : L.startFreshHelp)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .environment(\.colorScheme, .dark)
    }
}
