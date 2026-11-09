import HDCore
import SwiftUI

// OWNER: tracking area. "Bugün": what needs me, what runs, what finished, my open PRs, today's log.

private enum WaitingItem: Identifiable {
    case session(AgentSession, since: Date)
    case pullRequest(PullRequest)

    var id: String {
        switch self {
        case .session(let s, _): return "s-" + s.id.uuidString
        case .pullRequest(let pr): return "p-" + pr.id
        }
    }

    var date: Date {
        switch self {
        case .session(_, let since): return since
        case .pullRequest(let pr): return pr.updatedAt ?? pr.createdAt
        }
    }
}

struct TodayTab: View {
    let review: (PullRequest) -> Void
    @Environment(AppModel.self) private var model
    @State private var events: [ActivityEvent] = []

    var body: some View {
        let waiting = (model.sessionsNeedingYou.map { WaitingItem.session($0, since: model.since($0)) }
            + waitingPullRequests.map { WaitingItem.pullRequest($0) })
            .sorted { $0.date < $1.date }
        let working = model.workingSessions
        let finished = model.sessionsFinished(on: Date())
        // Today: my PRs that moved this week and aren't already listed as waiting.
        let waitingIDs = Set(waitingPullRequests.map(\.id))
        let mine = model.myPullRequests.filter { !waitingIDs.contains($0.id) && !$0.isStale(days: 7) }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                TrackingSection(title: L.sectionWaiting, count: waiting.count, empty: L.emptyWaiting, isEmpty: waiting.isEmpty) {
                    ForEach(waiting) { item in waitingRow(item) }
                }
                TrackingSection(title: L.sectionWorking, count: working.count, empty: L.emptyWorking, isEmpty: working.isEmpty) {
                    ForEach(working) { s in
                        TrackingRow(title: s.title, subtitle: subtitle(s, model.currentActivity(s.id)),
                                    action: { select(s.id) }) {
                            StatusGlyph(status: model.liveStatus(s.id))
                        } trailing: {
                            RelativeTimeText(date: s.lastActivityAt ?? s.createdAt)
                        }
                    }
                }
                TrackingSection(title: L.sectionFinishedToday, count: finished.count, empty: L.emptyFinished, isEmpty: finished.isEmpty) {
                    ForEach(finished) { s in
                        TrackingRow(title: s.title, subtitle: subtitle(s, firstLine(s.lastResult)), help: s.lastResult,
                                    action: { select(s.id) }) {
                            Image(systemName: "checkmark").fontWeight(.bold).foregroundStyle(.green).font(.system(size: 10))
                        } trailing: {
                            if let at = s.lastResultAt { Text(at, format: .dateTime.hour().minute()) }
                        }
                    }
                }
                TrackingSection(title: L.sectionMyPullRequests, count: mine.count,
                                empty: !model.tracking.hasRefreshedOnce ? L.loadingPullRequests
                                    : (model.tracking.hasPullRequestSources ? L.emptyMyPullRequests : L.emptyNoRemotes),
                                isEmpty: mine.isEmpty) {
                    ForEach(mine) { pr in pullRequestRow(pr, reason: nil) }
                }
                ActivityTimeline(events: events)
            }
            .padding(16)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: model.tracking.activityVersion) {
            let log = model.activityLog
            // Finished turns are already listed under "Finished today".
            events = await Task.detached { log.events(on: Date()).filter { $0.kind != .turnDone } }.value
        }
    }

    private var waitingPullRequests: [PullRequest] {
        model.tracking.pullRequests.filter { $0.needsMe && !$0.isStale(days: PullRequest.staleDays) }
    }

    @ViewBuilder
    private func waitingRow(_ item: WaitingItem) -> some View {
        switch item {
        case .session(let s, let since):
            TrackingRow(title: s.title, subtitle: subtitle(s, model.attentionReason(s)), action: { select(s.id) }) {
                StatusGlyph(status: model.liveStatus(s.id))
            } trailing: {
                RelativeTimeText(date: since)
            }
        case .pullRequest(let pr):
            pullRequestRow(pr, reason: pr.reasons.map(L.prReason).joined(separator: ", "))
        }
    }

    private func pullRequestRow(_ pr: PullRequest, reason: String?) -> some View {
        let linked = model.linkedSessions(for: pr).first
        let parts = ["#\(pr.number)", pr.repoLabel, reason, linked.map { L.linkedSession($0.title) }]
        return TrackingRow(title: pr.title, subtitle: parts.compactMap { $0 }.joined(separator: " · "),
                           help: L.openInBrowserHelp, action: { model.openInBrowser(pr.url) }) {
            Image(systemName: "arrow.triangle.pull").foregroundStyle(pr.needsMe ? .orange : .secondary).font(.system(size: 11))
        } trailing: {
            PullRequestChips(pr: pr)
        }
        .contextMenu { PullRequestMenu(pr: pr, review: review) }
    }

    private func subtitle(_ s: AgentSession, _ line: String?) -> String {
        [model.project(s.projectID)?.name, line].compactMap { $0?.nilIfBlank }.joined(separator: " · ")
    }

    private func firstLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    private func select(_ id: UUID) {
        model.selection = .session(id)
        model.markSeen(id)
    }
}

/// Today's activity events, newest first, as quiet one-line entries.
private struct ActivityTimeline: View {
    let events: [ActivityEvent]
    @Environment(AppModel.self) private var model

    var body: some View {
        TrackingSection(title: L.sectionFlow, count: nil, empty: L.emptyFlow, isEmpty: events.isEmpty) {
            ForEach(Array(events.reversed().prefix(200).enumerated()), id: \.offset) { _, e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(e.at, format: .dateTime.hour().minute())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    Image(systemName: symbol(e.kind))
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10))
                        .frame(width: 14)
                    Text(line(e))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(e.detail ?? "")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
                .padding(.vertical, 1)
                .contentShape(Rectangle())
                .onTapGesture { open(e) }
            }
        }
    }

    private func line(_ e: ActivityEvent) -> String {
        let project = e.projectID.flatMap { model.project($0)?.name }
        let head = [project, L.activityKind(e.kind), e.title.nilIfBlank].compactMap { $0 }.joined(separator: " · ")
        guard let detail = e.detail?.nilIfBlank else { return head }
        return head + " — " + detail
    }

    private func open(_ e: ActivityEvent) {
        if let id = e.sessionID, let s = model.session(id), s.isArchived != true {
            model.selection = .session(s.id)
        } else if let url = e.prURL {
            model.openInBrowser(url)
        }
    }

    private func symbol(_ kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .sessionStarted: return "play"
        case .turnDone: return "checkmark"
        case .needsYou: return "hand.raised"
        case .error: return "exclamationmark.triangle"
        case .sessionClosed: return "xmark"
        case .prOpened: return "arrow.triangle.pull"
        case .prMerged: return "arrow.triangle.merge"
        case .reviewStarted: return "eye"
        case .taskMoved: return "rectangle.split.3x1"
        }
    }
}

/// Actions on a PR (context menu and row buttons). Read-only: opening, jumping, starting a local review.
struct PullRequestMenu: View {
    let pr: PullRequest
    let review: (PullRequest) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(L.openPR) { model.openInBrowser(pr.url) }
        if let s = model.linkedSessions(for: pr).first {
            Button(L.goToSession) { model.selection = .session(s.id) }
        }
        Button(L.reviewEllipsis) { review(pr) }
            .disabled(model.project(for: pr) == nil)
        Divider()
        Button(L.copyLink) { Panels.copy(pr.url) }
        Button(L.copyBranchName) { Panels.copy(pr.sourceBranch) }
    }
}
