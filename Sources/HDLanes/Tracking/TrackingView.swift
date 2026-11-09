import HDCore
import SwiftUI

// OWNER: tracking area. "What's going on, what needs me, what got done" in one place.

struct TrackingSidebarRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.trackingAttentionCount
        HStack {
            Label(L.tracking, systemImage: "checklist")
            Spacer()
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .help(L.trackingBadgeHelp(count))
            }
        }
        .task {
            // One quiet read at launch so the badge counts PRs before Tracking is first opened.
            if !model.tracking.hasRefreshedOnce && !model.tracking.isRefreshing { await model.refreshPullRequests() }
        }
    }
}

struct TrackingView: View {
    @Environment(AppModel.self) private var model
    @State private var reviewTarget: PullRequest?

    static let refreshInterval: UInt64 = 180

    var body: some View {
        @Bindable var tracking = model.tracking
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker(L.tracking, selection: $tracking.tab) {
                    Text(L.tabToday).tag(TrackingTab.today)
                    Text(L.tabPullRequests).tag(TrackingTab.pullRequests)
                    Text(L.tabWorkItems).tag(TrackingTab.workItems)
                    Text(L.tabDaySummary).tag(TrackingTab.daySummary)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                RefreshStatus()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            switch tracking.tab {
            case .today: TodayTab(review: { reviewTarget = $0 })
            case .pullRequests: PullRequestsTab(review: { reviewTarget = $0 })
            case .workItems: WorkItemsTab()
            case .daySummary: DaySummaryTab()
            }
        }
        .navigationTitle(L.tracking)
        .task {
            // Runs while the view is on screen; cancelled when the user leaves Tracking. The launch-time
            // read from the sidebar row may still be running: don't queue a second sweep behind it.
            if !model.tracking.isRefreshing { await model.refreshPullRequests() }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.refreshInterval * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await model.refreshPullRequests()
            }
        }
        .sheet(item: $reviewTarget) { ReviewSheet(pr: $0) }
    }
}

private struct RefreshStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if model.tracking.isRefreshing {
                ProgressView().controlSize(.small)
                Text(L.refreshing)
            } else if let at = model.tracking.lastRefreshed {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(L.refreshedAt(L.relative(at, now: context.date)))
                }
            }
            Button {
                Task { await model.refreshPullRequests() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.tracking.isRefreshing)
            .help(model.tracking.isRefreshing ? L.refreshing : L.refreshHelp)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

// MARK: Shared pieces

struct TrackingSection<Content: View>: View {
    let title: String
    let count: Int?
    let empty: String
    let isEmpty: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let count, count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 4)
            if isEmpty {
                Text(empty)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A clickable row: leading glyph, title, one secondary line, trailing text.
struct TrackingRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    var help: String? = nil
    let action: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                leading.frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                trailing
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

struct SmallChip: View {
    let text: String
    var symbol: String? = nil
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// Draft, CI, review and conflict chips of a PR. Nothing is shown for "unknown".
struct PullRequestChips: View {
    let pr: PullRequest

    var body: some View {
        HStack(spacing: 4) {
            if pr.isDraft { SmallChip(text: L.prDraft) }
            switch pr.ci {
            case .passing: SmallChip(text: L.prCI, symbol: "checkmark", color: .green).help(L.prCIPassing)
            case .failing: SmallChip(text: L.prCI, symbol: "xmark", color: .red).help(L.prCIFailing)
            case .pending: SmallChip(text: L.prCI, symbol: "ellipsis", color: .secondary).help(L.prCIPending)
            case .none: EmptyView()
            }
            if pr.isMine {
                switch pr.review {
                case .approved: SmallChip(text: L.prApproved, color: .green)
                case .changesRequested: SmallChip(text: L.prChangesRequested, color: .orange)
                case .waiting: SmallChip(text: L.prReviewWaiting)
                case .none: EmptyView()
                }
            } else if pr.reviewRequestedFromMe {
                switch pr.myVote {
                case .approved: SmallChip(text: L.prYouApproved, color: .green)
                case .rejected: SmallChip(text: L.prYouRejected, color: .secondary)
                case .waiting, .none: SmallChip(text: L.prReviewRequested, color: .orange)
                }
            }
            if pr.mergeable == .conflict { SmallChip(text: L.prConflict, color: .red) }
        }
    }
}
