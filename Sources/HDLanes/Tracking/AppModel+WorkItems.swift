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
    func refreshWorkItems() async {
        guard !tracking.isLoadingWorkItems else { return }
        tracking.isLoadingWorkItems = true
        defer { tracking.isLoadingWorkItems = false }

        var targets: [String: (org: String, project: String)] = [:]
        for project in state.projects where FileManager.default.fileExists(atPath: project.path) {
            if case .azure(let org, let name, _) = await PRService.remote(of: project.path) {
                targets["\(org)/\(name)"] = (org, name)
            }
        }
        tracking.workItemProjects = targets.keys.sorted()
        guard !targets.isEmpty else {
            tracking.myWorkItems = []
            tracking.teamWorkItems = []
            tracking.changedWorkItems = []
            tracking.workItemsIssue = nil
            tracking.workItemsLoadedAt = Date()
            return
        }

        let people = trackedPeople
        var jobs: [(org: String, project: String, kind: Int, wiql: String)] = []
        for t in targets.values {
            jobs.append((t.org, t.project, 0, WorkItemQuery.mine()))
            if let team = WorkItemQuery.assigned(to: people) { jobs.append((t.org, t.project, 1, team)) }
            jobs.append((t.org, t.project, 2, WorkItemQuery.stateChanged(people: people)))
        }
        let results = await PRService.mapLimited(jobs, limit: PRService.concurrency) { job in
            let args = ["boards", "query", "--org", "https://dev.azure.com/\(job.org)", "--project", job.project,
                        "--detect", "false", "-o", "json", "--wiql", job.wiql]
            switch await PRService.runAZ(args, timeout: 60) {
            case .success(let text):
                return (job.kind, Result<[WorkItem], PRIssue>.success(
                    WorkItemQuery.parse(Data(text.utf8), org: job.org, project: job.project) ?? []))
            case .failure(let issue):
                return (job.kind, .failure(issue))
            }
        }

        var lists: [Int: [WorkItem]] = [0: [], 1: [], 2: []]
        var issue: PRIssue?
        for (kind, result) in results {
            switch result {
            case .success(let items): lists[kind, default: []] += items
            case .failure(let e): issue = issue ?? e
            }
        }
        func newestFirst(_ a: WorkItem, _ b: WorkItem) -> Bool { (a.changedAt ?? .distantPast) > (b.changedAt ?? .distantPast) }
        // A failed read keeps the previous list rather than showing an empty one.
        if issue == nil || !(lists[0] ?? []).isEmpty { tracking.myWorkItems = (lists[0] ?? []).sorted(by: newestFirst) }
        if issue == nil || !(lists[1] ?? []).isEmpty { tracking.teamWorkItems = (lists[1] ?? []).sorted(by: newestFirst) }
        if issue == nil || !(lists[2] ?? []).isEmpty {
            tracking.changedWorkItems = (lists[2] ?? []).sorted {
                ($0.stateChangedAt ?? .distantPast) > ($1.stateChangedAt ?? .distantPast)
            }
        }
        tracking.workItemsIssue = issue
        tracking.workItemsLoadedAt = Date()
    }
}
