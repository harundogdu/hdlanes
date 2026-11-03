import HDCore
import SwiftUI

// OWNER: tracking area. "PR'lar": mine and the ones waiting for my review, grouped by repository.

struct PullRequestsTab: View {
    let review: (PullRequest) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let mine = model.myPullRequests
        let reviews = model.reviewRequestedPullRequests
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(model.tracking.issues.values.sorted { $0.tool < $1.tool }, id: \.self) { issue in
                    Label(L.prIssue(issue), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !model.tracking.hasPullRequestSources && model.tracking.hasRefreshedOnce {
                    Text(L.emptyNoRemotes)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                TrackingSection(title: L.sectionMine, count: mine.count, empty: L.emptyMyPullRequests, isEmpty: mine.isEmpty) {
                    RepoGroups(prs: mine, review: review)
                }
                TrackingSection(title: L.sectionReviewRequested, count: reviews.count, empty: L.emptyReviewRequested,
                                isEmpty: reviews.isEmpty) {
                    RepoGroups(prs: reviews, review: review)
                }
            }
            .padding(16)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RepoGroups: View {
    let prs: [PullRequest]
    let review: (PullRequest) -> Void

    var body: some View {
        let groups = Dictionary(grouping: prs, by: \.repoLabel).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups, id: \.key) { label, items in
                VStack(alignment: .leading, spacing: 0) {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 6)
                        .padding(.bottom, 2)
                    ForEach(items.sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }) { pr in
                        PullRequestRow(pr: pr, review: review)
                        Divider().padding(.leading, 6)
                    }
                }
            }
        }
    }
}

private struct PullRequestRow: View {
    let pr: PullRequest
    let review: (PullRequest) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let linked = model.linkedSessions(for: pr).first
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(pr.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(verbatim: "#\(pr.number)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(L.branchArrow(pr.sourceBranch, pr.targetBranch))
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    PullRequestChips(pr: pr)
                }
                HStack(spacing: 4) {
                    if !pr.isMine, !pr.author.isEmpty { Text(pr.author).lineLimit(1); Text(verbatim: "·") }
                    RelativeTimeText(date: pr.createdAt)
                    if let linked {
                        Text(verbatim: "·")
                        Text(L.linkedSession(linked.title)).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button(L.openPR) { model.openInBrowser(pr.url) }
                    .help(L.openInBrowserHelp)
                if let linked {
                    Button(L.goToSession) { model.selection = .session(linked.id) }
                }
                Button(L.reviewEllipsis) { review(pr) }
                    .disabled(model.project(for: pr) == nil)
                    .help(model.project(for: pr) == nil ? L.reviewNoProject : L.reviewHelp)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .contextMenu { PullRequestMenu(pr: pr, review: review) }
    }
}
