import Foundation
import HDCore
import Observation

enum TrackingTab: String, CaseIterable, Identifiable {
    case today, pullRequests, daySummary
    var id: String { rawValue }
}

/// Live state of the Tracking area. Not persisted: PRs are re-read, activity lives in activity.jsonl.
/// OWNER: tracking area.
@MainActor
@Observable
final class TrackingStore {
    var tab: TrackingTab = .today
    var pullRequests: [PullRequest] = []
    /// Per provider tool ("gh" / "az"): the last refresh's problem, shown inline.
    var issues: [String: PRIssue] = [:]
    var lastRefreshed: Date?
    var isRefreshing = false
    /// Bumped on every activity append; views reload the day's events when it changes.
    var activityVersion = 0
    /// When a session started needing the user (needs-you or error), for "oldest first".
    var attentionSince: [UUID: Date] = [:]
    /// Repository identity (`RemoteRepo.key`) per project, from the last refresh.
    var projectRepoKeys: [UUID: String] = [:]

    @ObservationIgnored var debouncer = ActivityDebouncer()
    @ObservationIgnored var loggedMerged: Set<String> = []
    @ObservationIgnored var refreshQueued = false
    var hasRefreshedOnce = false
    /// Sessions whose turn ended before its final message arrived (OSC done ahead of the Stop hook).
    @ObservationIgnored var awaitingResult: Set<UUID> = []

    var hasPullRequestSources: Bool { !projectRepoKeys.isEmpty }
}
