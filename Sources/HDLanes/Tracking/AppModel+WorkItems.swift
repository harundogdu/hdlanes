import Foundation
import HDCore

// OWNER: tracking area. Azure Boards work items: mine, my teammates', and today's state changes.
// Read-only like the rest of Tracking: `az boards query` only.
extension AppModel {
    var trackedPeople: [String] {
        (state.settings.trackedPeople ?? []).filter { WorkItemQuery.literal($0) != nil }
    }

    /// Azure PR authors and reviewers seen in Tracking: likely teammates, offered when adding people.
    var suggestedPeople: [String] {
        let known = Set(trackedPeople.map { $0.lowercased() })
        let authors = tracking.pullRequests.filter { $0.provider == .azure && !$0.isMine }.map(\.author)
        let assignees = (tracking.teamWorkItems + tracking.changedWorkItems).map(\.assignedTo)
        return Array(Set((authors + assignees).filter { !$0.isEmpty && !known.contains($0.lowercased()) }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func setTrackedPeople(_ people: [String]) {
        var seen: Set<String> = []
        let clean = people.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { WorkItemQuery.literal($0) != nil && seen.insert($0.lowercased()).inserted }
        updateSettings { $0.trackedPeople = clean.isEmpty ? nil : clean }
    }

    /// One `az boards query` per question and Azure DevOps project the added projects' remotes point at.
    /// A newer call (e.g. after the people list changed) supersedes a running one: only the latest writes.
    func refreshWorkItems() async {
        tracking.workItemsGeneration += 1
        let generation = tracking.workItemsGeneration
        tracking.isLoadingWorkItems = true
        defer { if tracking.workItemsGeneration == generation { tracking.isLoadingWorkItems = false } }
        func current() -> Bool { !Task.isCancelled && tracking.workItemsGeneration == generation }

        var targets: [String: (org: String, project: String)] = [:]
        for project in state.projects where FileManager.default.fileExists(atPath: project.path) {
            if case .azure(let org, let name, _) = await PRService.remote(of: project.path) {
                targets["\(org)/\(name)"] = (org, name)
            }
        }
        guard current() else { return }
        tracking.workItemProjects = targets.keys.sorted()

        let people = trackedPeople
        var jobs: [(org: String, project: String, kind: WorkItemList, wiql: String)] = []
        for t in targets.values.sorted(by: { ($0.org, $0.project) < ($1.org, $1.project) }) {
            if let q = WorkItemQuery.mine(project: t.project) { jobs.append((t.org, t.project, .mine, q)) }
            if let q = WorkItemQuery.assigned(to: people, project: t.project) { jobs.append((t.org, t.project, .team, q)) }
            if let q = WorkItemQuery.stateChanged(people: people, project: t.project) { jobs.append((t.org, t.project, .changed, q)) }
        }
        let results = await PRService.mapLimited(jobs, limit: PRService.concurrency) { job in
            let args = ["boards", "query", "--org", "https://dev.azure.com/\(job.org)", "--project", job.project,
                        "--detect", "false", "-o", "json", "--wiql", job.wiql]
            switch await PRService.runAZ(args, timeout: 60) {
            case .success(let text):
                if let items = WorkItemQuery.parse(Data(text.utf8), org: job.org, project: job.project) {
                    return (job.kind, Result<[WorkItem], PRIssue>.success(items))
                }
                return (job.kind, .failure(.failed("az", "")))
            case .failure(let issue):
                return (job.kind, .failure(issue))
            }
        }
        // Cancelled (the tab closed, or a newer call started): its errors are not the user's problem.
        guard current() else { return }

        var lists: [WorkItemList: [WorkItem]] = [:]
        var failed: Set<WorkItemList> = []
        var issue: PRIssue?
        for (kind, result) in results {
            switch result {
            case .success(let items): lists[kind, default: []] += items
            case .failure(let e): failed.insert(kind); issue = issue ?? e
            }
        }
        func newestFirst(_ a: WorkItem, _ b: WorkItem) -> Bool { (a.changedAt ?? .distantPast) > (b.changedAt ?? .distantPast) }
        // A list with a failed read keeps what it showed before; the others take the new read.
        if !failed.contains(.mine) { tracking.myWorkItems = (lists[.mine] ?? []).sorted(by: newestFirst) }
        if !failed.contains(.team) { tracking.teamWorkItems = (lists[.team] ?? []).sorted(by: newestFirst) }
        if !failed.contains(.changed) {
            tracking.changedWorkItems = (lists[.changed] ?? []).sorted {
                ($0.stateChangedAt ?? .distantPast) > ($1.stateChangedAt ?? .distantPast)
            }
        }
        tracking.workItemsIssue = issue
        tracking.workItemsLoadedAt = Date()
    }
}

private enum WorkItemList: Hashable, Sendable { case mine, team, changed }
