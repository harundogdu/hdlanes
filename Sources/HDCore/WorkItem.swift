import Foundation

/// An Azure Boards work item, as Tracking shows it. Read-only: hdlanes never edits work items.
public struct WorkItem: Identifiable, Hashable, Sendable {
    /// `org/project#id`, unique across projects.
    public var id: String { "\(org)/\(project)#\(number)" }
    public var number: Int
    public var org: String
    public var project: String
    public var title: String
    public var type: String
    public var state: String
    /// Display name of the assignee; empty when unassigned.
    public var assignedTo: String
    /// The assignee's unique name (usually an email); empty when unassigned.
    public var assignedToID: String
    public var changedBy: String
    public var changedAt: Date?
    public var stateChangedAt: Date?

    public init(number: Int, org: String, project: String, title: String, type: String, state: String,
                assignedTo: String = "", assignedToID: String = "", changedBy: String = "",
                changedAt: Date? = nil, stateChangedAt: Date? = nil) {
        self.number = number
        self.org = org
        self.project = project
        self.title = title
        self.type = type
        self.state = state
        self.assignedTo = assignedTo
        self.assignedToID = assignedToID
        self.changedBy = changedBy
        self.changedAt = changedAt
        self.stateChangedAt = stateChangedAt
    }

    /// The item's page on dev.azure.com.
    public var webURL: String {
        let p = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project
        return "https://dev.azure.com/\(org)/\(p)/_workitems/edit/\(number)"
    }

    /// No change for `days` days; an unknown change time is never stale.
    public func isStale(now: Date = Date(), days: Int) -> Bool {
        guard let changedAt else { return false }
        return now.timeIntervalSince(changedAt) > Double(days) * 86_400
    }

    /// Sort rank of a state: work in flight first, then waiting states, then not started.
    public static func stateRank(_ state: String) -> Int {
        let s = state.lowercased()
        if ["in progress", "active", "doing", "committed", "development"].contains(where: s.contains) { return 0 }
        if ["new", "proposed", "to do", "approved", "open"].contains(s) { return 2 }
        return 1
    }

    /// Where an item stands for its assignee, from its state name (any process template).
    public enum Bucket: Int, CaseIterable, Sendable {
        /// In progress or blocked: on the assignee's desk now.
        case onMe
        /// Not started yet: new, to do, approved, waiting.
        case queued
        /// Done on the assignee's side, with someone else: ready for test / preview / deployment, resolved.
        case handedOff
    }

    public static func bucket(_ state: String) -> Bucket {
        let s = state.lowercased()
        if ["resolved", "test", "review", "deploy", "preview", "verif", "qa", "uat", "release"].contains(where: s.contains) {
            return .handedOff
        }
        if stateRank(state) == 0 || s.contains("blocked") { return .onMe }
        return .queued
    }

    /// True when `person` (a unique name / email or a display name, as typed in Settings) is the assignee.
    public func isAssigned(to person: String) -> Bool {
        let p = person.trimmingCharacters(in: .whitespaces)
        return !p.isEmpty && (assignedToID.caseInsensitiveCompare(p) == .orderedSame
            || assignedTo.caseInsensitiveCompare(p) == .orderedSame)
    }
}

/// WIQL for `az boards query`, and parsing of its `-o json` output. Pure.
public enum WorkItemQuery {
    /// States that mean the work is over, in the stock processes (Agile, Scrum, CMMI, Basic).
    public static let finishedStates = ["Closed", "Done", "Removed"]
    /// Days a teammate's open item may sit unchanged and still be listed.
    public static let peopleWindowDays = 30
    /// Days of state changes the "changed" section looks back.
    public static let changedWindowDays = 1

    static let fields = "[System.Id], [System.TeamProject], [System.Title], [System.State], [System.WorkItemType], [System.AssignedTo], "
        + "[System.ChangedBy], [System.ChangedDate], [Microsoft.VSTS.Common.StateChangeDate]"

    private static var open: String {
        "[System.State] NOT IN (" + finishedStates.map { "'\($0)'" }.joined(separator: ", ") + ")"
    }

    /// A person as a WIQL string literal; nil for names that could break out of it.
    public static func literal(_ person: String) -> String? {
        let p = person.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, p.count <= 200,
              !p.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "[]".unicodeScalars.contains($0) })
        else { return nil }
        return "'" + p.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func people(_ list: [String]) -> String? {
        let lits = list.compactMap(literal)
        return lits.isEmpty ? nil : "[System.AssignedTo] IN (" + lits.joined(separator: ", ") + ")"
    }

    /// Raw WIQL isn't limited to the project in the request (and `@project` matches nothing through
    /// `az boards query`), so every query names its project. nil for a name that can't be a literal.
    private static func scope(_ project: String) -> String? {
        literal(project).map { "[System.TeamProject] = \($0)" }
    }

    /// My open items in `project`, most recently changed first.
    public static func mine(project: String) -> String? {
        guard let p = scope(project) else { return nil }
        return "SELECT \(fields) FROM WorkItems WHERE \(p) AND [System.AssignedTo] = @Me AND \(open) "
            + "ORDER BY [System.ChangedDate] DESC"
    }

    /// Open items of `people` changed in the last `peopleWindowDays` days. nil when no name is usable.
    public static func assigned(to list: [String], project: String) -> String? {
        guard let p = scope(project), let who = people(list) else { return nil }
        return "SELECT \(fields) FROM WorkItems WHERE \(p) AND \(who) AND \(open) "
            + "AND [System.ChangedDate] >= @Today - \(peopleWindowDays) ORDER BY [System.ChangedDate] DESC"
    }

    /// Items of mine or of `people` whose state changed in the last `changedWindowDays` days, finished ones included.
    public static func stateChanged(people list: [String], project: String) -> String? {
        guard let p = scope(project) else { return nil }
        let who = people(list).map { "([System.AssignedTo] = @Me OR \($0))" } ?? "[System.AssignedTo] = @Me"
        return "SELECT \(fields) FROM WorkItems WHERE \(p) AND \(who) "
            + "AND [Microsoft.VSTS.Common.StateChangeDate] >= @Today - \(changedWindowDays) "
            + "ORDER BY [Microsoft.VSTS.Common.StateChangeDate] DESC"
    }

    /// `az boards query -o json`: an array of `{id, fields: {"System.Title": …, "System.AssignedTo": {displayName, uniqueName}}}`.
    public static func parse(_ data: Data, org: String, project: String) -> [WorkItem]? {
        // No match: `az boards query` exits 0 and prints nothing at all, not `[]` (azure-devops extension).
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let number = item["id"] as? Int, let f = item["fields"] as? [String: Any] else { return nil }
            func text(_ key: String) -> String { (f[key] as? String) ?? "" }
            func person(_ key: String) -> (name: String, id: String) {
                guard let p = f[key] as? [String: Any] else { return (text(key), "") }
                return ((p["displayName"] as? String) ?? "", (p["uniqueName"] as? String) ?? "")
            }
            let assignee = person("System.AssignedTo")
            return WorkItem(number: number, org: org, project: (f["System.TeamProject"] as? String) ?? project,
                            title: text("System.Title"), type: text("System.WorkItemType"), state: text("System.State"),
                            assignedTo: assignee.name, assignedToID: assignee.id,
                            changedBy: person("System.ChangedBy").name,
                            changedAt: date(f["System.ChangedDate"]),
                            stateChangedAt: date(f["Microsoft.VSTS.Common.StateChangeDate"]))
        }
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
}
