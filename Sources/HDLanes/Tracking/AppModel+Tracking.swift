import AppKit
import Foundation
import HDCore

// OWNER: tracking area. Activity recording (called from the runtime, workspace and git areas with one
// line each), PR refresh, what-needs-me lists and review sessions.
extension AppModel {
    var activityLog: ActivityLog { ActivityLog(paths: paths) }

    // MARK: Recording

    /// Appends an event unless it repeats the session's last one. A write failure is not shown: the log
    /// is a convenience and must never interrupt the work it records.
    func recordActivity(_ kind: ActivityEvent.Kind, sessionID: UUID? = nil, projectID: UUID? = nil,
                        title: String? = nil, detail: String? = nil, prURL: String? = nil) {
        let session = sessionID.flatMap { self.session($0) }
        let event = ActivityEvent(kind: kind, sessionID: sessionID, projectID: projectID ?? session?.projectID,
                                  title: title ?? session?.title ?? "", detail: detail, prURL: prURL)
        guard tracking.debouncer.accepts(event) else { return }
        do {
            try activityLog.append(event)
            tracking.activityVersion += 1
        } catch {
            // Disk full or unwritable ~/.hdlanes: skip the line.
        }
    }

    /// Called by the runtime's `statusChanged` for every transition.
    func trackingStatusChanged(_ id: UUID, from old: AgentStatus, to new: AgentStatus) {
        guard let session = session(id), session.isArchived != true else { return }
        switch new {
        case .done:
            tracking.attentionSince[id] = nil
            let message = ActivityEvent.clip(runtimes[id]?.snapshot.lastAssistantMessage, limit: ActivityEvent.detailLimit)
            updateSession(id) {
                $0.lastResult = message
                $0.lastResultAt = Date()
            }
            recordActivity(.turnDone, sessionID: id, detail: message)
        case .needsYou(let kind, let detail):
            if !old.needsUser { tracking.attentionSince[id] = Date() }
            recordActivity(.needsYou, sessionID: id, detail: [L.notifyNeedsYou(kind), detail].compactMap { $0 }.joined(separator: " · "))
        case .error(let message):
            if case .error = old {} else { tracking.attentionSince[id] = Date() }
            recordActivity(.error, sessionID: id, detail: message)
        default:
            tracking.attentionSince[id] = nil
        }
    }

    func recordTaskMoved(_ id: UUID, to status: TaskStatus) {
        guard let t = task(id) else { return }
        recordActivity(.taskMoved, projectID: t.projectID, title: t.title, detail: L.taskStatusName(status))
    }

    /// Called by `createPullRequest` once gh returned the PR's URL.
    func pullRequestOpened(sessionID: UUID, title: String, url: URL) {
        recordActivity(.prOpened, sessionID: sessionID, title: title, prURL: url.absoluteString)
        Task { await refreshPullRequests() }
    }

    // MARK: Pull requests

    /// Re-reads open PRs for every project whose `origin` is on GitHub or Azure DevOps. Projects sharing a
    /// repository are read once.
    func refreshPullRequests() async {
        if tracking.isRefreshing {
            tracking.refreshQueued = true
            return
        }
        tracking.isRefreshing = true
        defer { tracking.isRefreshing = false }
        repeat {
            tracking.refreshQueued = false
            await refreshPullRequestsOnce()
        } while tracking.refreshQueued
    }

    private func refreshPullRequestsOnce() async {
        var repos: [String: (repo: RemoteRepo, directory: String)] = [:]
        var keys: [UUID: String] = [:]
        for project in state.projects where FileManager.default.fileExists(atPath: project.path) {
            guard let repo = await PRService.remote(of: project.path) else { continue }
            keys[project.id] = repo.key
            if repos[repo.key] == nil { repos[repo.key] = (repo, project.path) }
        }
        tracking.projectRepoKeys = keys
        let targets = repos.values.sorted { $0.repo.key < $1.repo.key }
        let results = await PRService.mapLimited(targets, limit: PRService.concurrency) { target in
            await PRService.fetch(target.repo, directory: target.directory)
        }

        var issues: [String: PRIssue] = [:]
        var prs: [PullRequest] = []
        var readRepos: Set<String> = []
        for r in results {
            prs += r.prs
            if let issue = r.issue {
                issues[issue.tool] = issues[issue.tool] ?? issue
            } else {
                readRepos.insert(r.repo.key)
            }
        }
        let fresh = PullRequest.dedupe(prs)

        // My PRs that left the open list of a repository read cleanly: merged or closed.
        let freshIDs = Set(fresh.map(\.id))
        let gone = tracking.hasRefreshedOnce
            ? tracking.pullRequests.filter { $0.isMine && readRepos.contains($0.repoKey) && !freshIDs.contains($0.id)
                && !tracking.loggedMerged.contains($0.id) }
            : []
        tracking.pullRequests = fresh
        tracking.issues = issues
        tracking.lastRefreshed = Date()
        tracking.hasRefreshedOnce = true

        for pr in gone.prefix(10) where await PRService.wasMerged(pr) == true {
            tracking.loggedMerged.insert(pr.id)
            let session = linkedSessions(for: pr).first
            recordActivity(.prMerged, sessionID: session?.id, projectID: session?.projectID, title: pr.title, prURL: pr.url)
        }
    }

    /// Sessions working on the PR's branch in a project of the same repository; review sessions of the PR
    /// come last for my PRs and first for others'.
    func linkedSessions(for pr: PullRequest) -> [AgentSession] {
        let matches = visibleSessions.filter { s in
            if s.reviewPullRequestURL == pr.url { return true }
            return tracking.projectRepoKeys[s.projectID] == pr.repoKey && s.branch == pr.sourceBranch
        }
        return matches.sorted { a, b in
            let ar = a.reviewPullRequestURL == pr.url, br = b.reviewPullRequestURL == pr.url
            if ar != br { return pr.isMine ? !ar : ar }
            return (a.lastActivityAt ?? a.createdAt) > (b.lastActivityAt ?? b.createdAt)
        }
    }

    var myPullRequests: [PullRequest] { tracking.pullRequests.filter(\.isMine) }

    var reviewRequestedPullRequests: [PullRequest] {
        tracking.pullRequests.filter { $0.reviewRequestedFromMe && !$0.isMine }
    }

    // MARK: Today

    func needsAttention(_ status: AgentStatus) -> Bool {
        if case .error = status { return true }
        return status.needsUser
    }

    /// Sessions that need the user, oldest first.
    var sessionsNeedingYou: [AgentSession] {
        visibleSessions.filter { needsAttention(liveStatus($0.id)) }.sorted { since($0) < since($1) }
    }

    func since(_ s: AgentSession) -> Date {
        tracking.attentionSince[s.id] ?? runtimes[s.id]?.snapshot.lastEventAt ?? s.lastActivityAt ?? s.createdAt
    }

    var workingSessions: [AgentSession] {
        visibleSessions.filter {
            switch liveStatus($0.id) {
            case .working, .starting: return true
            default: return false
            }
        }.sorted { ($0.lastActivityAt ?? $0.createdAt) > ($1.lastActivityAt ?? $1.createdAt) }
    }

    /// Open sessions whose last turn finished on `day`, newest first.
    func sessionsFinished(on day: Date, calendar: Calendar = .current) -> [AgentSession] {
        visibleSessions.filter { s in s.lastResultAt.map { calendar.isDate($0, inSameDayAs: day) } ?? false }
            .sorted { ($0.lastResultAt ?? .distantPast) > ($1.lastResultAt ?? .distantPast) }
    }

    /// What a working session is doing now: a running tool, else a running subagent, else the last prompt.
    func currentActivity(_ id: UUID) -> String? {
        guard let snapshot = runtimes[id]?.snapshot else { return nil }
        if let item = snapshot.activity.last(where: \.isRunning) {
            return [item.tool, item.detail].filter { !$0.isEmpty }.joined(separator: " ")
        }
        if let sub = snapshot.runningSubagents.last {
            return [sub.type, sub.description].compactMap { $0 }.joined(separator: ": ")
        }
        return snapshot.lastPrompt.map { Self.displayText($0) }
    }

    /// Badge on the sidebar row: sessions needing the user plus PRs that need them.
    var trackingAttentionCount: Int {
        visibleSessions.filter { needsAttention(liveStatus($0.id)) }.count + tracking.pullRequests.filter(\.needsMe).count
    }

    func attentionReason(_ s: AgentSession) -> String {
        switch liveStatus(s.id) {
        case .needsYou(let kind, let detail):
            return [L.notifyNeedsYou(kind), detail.map(Self.displayText)].compactMap { $0 }.joined(separator: " · ")
        case .error(let message):
            return Self.displayText(message)
        default:
            return L.statusText(liveStatus(s.id))
        }
    }

    // MARK: Day summary

    func daySummaryMarkdown(for day: Date, events: [ActivityEvent]) -> String {
        let df = DateFormatter()
        df.locale = L.locale
        df.dateStyle = .full
        df.timeStyle = .none
        let tf = DateFormatter()
        tf.locale = L.locale
        tf.dateFormat = "HH:mm"
        let labels = DaySummary.Labels(title: L.daySummaryTitle(df.string(from: day)), done: L.sumDone,
                                       pullRequests: L.sumPullRequests, opened: L.sumOpened, merged: L.sumMerged,
                                       stillOpen: L.sumStillOpen, tomorrow: L.sumTomorrow, nothing: L.sumNothing)
        var stillOpen: [DaySummary.Item] = sessionsNeedingYou.map {
            DaySummary.Item(text: $0.title, detail: attentionReason($0))
        }
        stillOpen += workingSessions.map { DaySummary.Item(text: $0.title, detail: L.statusText(.working)) }
        stillOpen += tracking.pullRequests.filter(\.needsMe).map {
            DaySummary.Item(text: "\($0.title) #\($0.number)", detail: $0.reasons.map(L.prReason).joined(separator: ", "), url: $0.url)
        }
        let tomorrow = state.tasks.filter { $0.status == .active || $0.status == .review }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { DaySummary.Item(text: $0.title, detail: L.taskStatusName($0.status)) }
        var names: [UUID: String] = [:]
        for p in state.projects { names[p.id] = p.name }
        return DaySummary.markdown(events: events, stillOpen: stillOpen, tomorrow: tomorrow, projectNames: names,
                                   labels: labels, time: { tf.string(from: $0) })
    }

    /// Writes `~/.hdlanes/reports/YYYY-MM-DD.md` and returns its URL.
    func saveDayReport(_ markdown: String, day: Date) throws -> URL {
        try HDPaths.ensurePrivateDir(paths.reportsDir)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let url = paths.reportsDir.appendingPathComponent("\(f.string(from: day)).md")
        try Data(markdown.utf8).write(to: url, options: .atomic)
        return url
    }

    /// One `claude -p` call on `account` turning the report into short bullet points. Only on request.
    func tidyDaySummaryWithAI(_ markdown: String, account: Account) async throws -> String {
        let args = ["-p", "--output-format", "json", "--model", "haiku", "--no-session-persistence",
                    DaySummary.aiPrompt(markdown: markdown)]
        let result = await runAccountCLI(account, arguments: args, timeout: 120)
        if result.launchFailed || AccountCLI.isCommandNotFound(status: result.status, output: result.combined) {
            throw WorkspaceError.cliMissing(.claude)
        }
        if result.timedOut { throw WorkspaceError.timedOut }
        guard let text = ClaudePrintOutput.result(from: result.stdout) else {
            if result.status != 0, let line = result.firstErrorLine() { throw WorkspaceError.commandFailed(line) }
            throw WorkspaceError.aiUnreadable
        }
        return text
    }

    // MARK: Review sessions

    /// The project a PR belongs to (first project of its repository).
    func project(for pr: PullRequest) -> Project? {
        state.projects.first { tracking.projectRepoKeys[$0.id] == pr.repoKey }
    }

    /// Default account for reviewing `pr`: a Claude account other than the one that ran its session.
    func defaultReviewAccount(for pr: PullRequest, provider: Provider) -> Account? {
        let used = linkedSessions(for: pr).first { $0.reviewPullRequestURL == nil }?.accountID
        let candidates = accounts(for: provider)
        if let other = candidates.first(where: { $0.id != used }), used != nil { return other }
        if let project = project(for: pr), let d = defaultAccount(for: provider, project: project) { return d }
        return candidates.first
    }

    /// Fetches the PR's branches, adds a detached worktree at `origin/<source>` and starts an agent there
    /// with the project's review prompt. No branch is created; the worktree is removable like any other.
    @discardableResult
    func startReviewSession(pr: PullRequest, projectID: UUID, provider: Provider, accountID: UUID?, title: String) async throws -> UUID {
        guard let project = project(projectID) else { throw WorkspaceError.projectMissing }
        guard let repo = await repositoryRoot(for: project.path) else { throw GitError.notRepository(project.path) }
        for branch in [pr.sourceBranch, pr.targetBranch] where branch.isEmpty || branch.hasPrefix("-") {
            throw WorkspaceError.invalidBranch(branch)
        }
        guard let account = account(accountID).flatMap({ $0.provider == provider ? $0 : nil })
                ?? defaultAccount(for: provider, project: project) else { throw WorkspaceError.noAccount(provider) }

        try await GitService.git(["fetch", "origin", pr.sourceBranch, pr.targetBranch], in: repo, timeout: 180)
        let parent = WorktreePlanner.worktreeParent(repoRoot: repo, worktreeRoot: project.worktreeRoot)
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
        let slug = WorktreePlanner.slug(from: "review-\(pr.number)-\(pr.title)")
        let path = WorktreePlanner.worktreePath(slug: slug, parent: parent, existingNames: existing)
        try await GitService.git(["worktree", "add", "--detach", path, "origin/\(pr.sourceBranch)"], in: repo, timeout: 120)
        let sub = Self.subpath(of: project.path, in: repo)
        let cwd = sub.isEmpty ? path : (path as NSString).appendingPathComponent(sub)
        if let copies = project.copyFiles, !copies.isEmpty {
            _ = await GitService.copyFiles(copies, from: project.path, to: cwd)
        }

        let name = title.nilIfBlank ?? L.reviewTitle(pr.title)
        var session = AgentSession(projectID: project.id, title: name, provider: provider, accountID: account.id, cwd: cwd)
        session.branch = pr.sourceBranch
        session.baseRef = "origin/\(pr.targetBranch)"
        session.worktreePath = path
        session.category = "review"
        session.reviewPullRequestURL = pr.url
        session.initialPrompt = ReviewPrompt.render(project.reviewPromptTemplate, pr: pr)
        state.sessions.append(session)
        selection = .session(session.id)
        launch(session.id, resume: false)
        recordActivity(.reviewStarted, sessionID: session.id, title: name, detail: pr.title, prURL: pr.url)
        return session.id
    }

    func openInBrowser(_ url: String) {
        guard let u = URL(string: url), u.scheme == "https" || u.scheme == "http" else { return }
        NSWorkspace.shared.open(u)
    }
}
