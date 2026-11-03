import HDCore
import SwiftUI

// OWNER: workspace area.

struct SessionRow: View {
    let session: AgentSession
    @Environment(AppModel.self) private var model

    var body: some View {
        let runtime = model.runtimes[session.id]
        let status = runtime?.status ?? .notStarted
        let unread = runtime?.unread ?? false
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                StatusGlyph(status: status)
                Text(session.title)
                    .font(.system(size: 13, weight: unread ? .semibold : .regular))
                    .lineLimit(1)
            }
            SessionRowSubtitle(session: session)
                .padding(.leading, 20)
            if let snapshot = runtime?.snapshot {
                RunningSubagentLines(snapshot: snapshot)
                    .padding(.leading, 20)
                if let permission = snapshot.pendingPermission, permission.canAnswer {
                    // Keyed by request: a new request replacing the card drops an open Deny popover
                    // and any click in progress instead of applying them to the new one.
                    PermissionCard(sessionID: session.id, permission: permission)
                        .id(permission.id)
                        .padding(.leading, 20)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SessionRowSubtitle: View {
    let session: AgentSession
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            if session.provider.isAgent {
                if let account = model.account(session.accountID) {
                    AccountDot(colorIndex: account.colorIndex, size: 6)
                    Text(account.label).lineLimit(1)
                } else {
                    Text(L.removedAccount).lineLimit(1)
                }
            } else {
                Image(systemName: ProviderStyle.symbol(.shell))
            }
            if let branch = session.branch {
                Text(verbatim: "·")
                Text(branch).lineLimit(1).truncationMode(.middle)
            }
            Text(verbatim: "·")
            RelativeTimeText(date: session.lastActivityAt ?? session.createdAt)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

/// Running subagents without Claude's bare internal helpers. While a bare one is young it may still
/// turn out to be real, so the lines are redrawn every second until it is decided.
private struct RunningSubagentLines: View {
    let snapshot: AgentRuntimeSnapshot

    var body: some View {
        if snapshot.runningSubagents.contains(where: \.isBare) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                SubagentLines(subagents: snapshot.visibleRunningSubagents(at: context.date))
            }
        } else {
            SubagentLines(subagents: snapshot.runningSubagents)
        }
    }
}

/// Up to three running subagents, then "+N more".
private struct SubagentLines: View {
    let subagents: [SubagentInfo]

    var body: some View {
        if !subagents.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(subagents.prefix(3)) { sub in
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9))
                        Text(L.subagentLine(sub))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help(sub.description ?? sub.type)
                }
                if subagents.count > 3 {
                    Text(L.moreSubagents(subagents.count - 3))
                        .padding(.leading, 13)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}

/// Allow / Deny for a Claude permission prompt, answered through the PermissionRequest hook.
private struct PermissionCard: View {
    let sessionID: UUID
    let permission: PendingPermission
    @Environment(AppModel.self) private var model
    @State private var showDeny = false
    @State private var denyMessage = ""
    /// The request the Deny popover was opened for.
    @State private var denyTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(permission.tool)
                .font(.system(size: 11, weight: .semibold))
            if !permission.detail.isEmpty {
                Text(permission.detail)
                    .font(Theme.monoSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .help(permission.detail)
            }
            HStack(spacing: 6) {
                Button(L.allow) {
                    model.respondToPermission(sessionID: sessionID, permissionID: permission.id, allow: true, message: nil)
                }
                Button(L.denyEllipsis) {
                    denyTarget = permission.id
                    showDeny = true
                }
                    .popover(isPresented: $showDeny, arrowEdge: .bottom) { denyPopover }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
    }

    private var denyPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.denyMessageLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(L.denyMessagePlaceholder, text: $denyMessage, axis: .vertical)
                .lineLimit(2...4)
                .frame(width: 260)
                .onSubmit(deny)
            HStack {
                Spacer()
                Button(L.cancel) { showDeny = false }
                Button(L.deny, action: deny)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func deny() {
        model.respondToPermission(sessionID: sessionID, permissionID: denyTarget ?? permission.id, allow: false,
                                  message: denyMessage.nilIfBlank)
        denyMessage = ""
        denyTarget = nil
        showDeny = false
    }
}
