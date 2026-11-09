import Foundation
import Testing
@testable import HDCore

struct WorkItemTests {
    // Shape seen live from `az boards query -o json` (azure-devops extension).
    static let json = """
    [{"id": 122020, "fields": {"System.Id": 122020, "System.Title": "Login fails for upper-case e-mail",
      "System.State": "In Progress", "System.WorkItemType": "Product Backlog Item",
      "System.AssignedTo": {"displayName": "Ada Lovelace", "uniqueName": "ada@example.com"},
      "System.ChangedBy": {"displayName": "Alan Turing", "uniqueName": "alan@example.com"},
      "System.ChangedDate": "2026-11-09T14:56:21.74Z",
      "Microsoft.VSTS.Common.StateChangeDate": "2026-11-09T07:10:37Z"}},
     {"id": 7, "fields": {"System.Title": "Unassigned", "System.State": "New", "System.WorkItemType": "Bug"}},
     {"fields": {}}]
    """

    @Test func parsesQueryOutput() throws {
        let items = try #require(WorkItemQuery.parse(Data(Self.json.utf8), org: "acme", project: "Main Board"))
        #expect(items.count == 2)
        let a = items[0]
        #expect(a.number == 122020 && a.state == "In Progress" && a.type == "Product Backlog Item")
        #expect(a.assignedTo == "Ada Lovelace" && a.assignedToID == "ada@example.com" && a.changedBy == "Alan Turing")
        #expect(a.changedAt != nil && a.stateChangedAt != nil)
        #expect(a.webURL == "https://dev.azure.com/acme/Main%20Board/_workitems/edit/122020")
        #expect(a.isAssigned(to: "ADA@example.com") && a.isAssigned(to: "Ada Lovelace") && !a.isAssigned(to: ""))
        #expect(items[1].assignedTo.isEmpty && items[1].changedAt == nil)
        #expect(WorkItemQuery.parse(Data("nope".utf8), org: "a", project: "b") == nil)
    }

    @Test func peopleAreSafeLiterals() {
        #expect(WorkItemQuery.literal("O'Brien") == "'O''Brien'")
        #expect(WorkItemQuery.literal(" ada@example.com ") == "'ada@example.com'")
        #expect(WorkItemQuery.literal("a\nb") == nil)
        #expect(WorkItemQuery.literal("x] OR [System.Id") == nil)
        #expect(WorkItemQuery.literal("  ") == nil)
    }

    @Test func queries() throws {
        #expect(WorkItemQuery.mine().contains("[System.AssignedTo] = @Me AND [System.State] NOT IN ('Closed', 'Done', 'Removed')"))
        #expect(WorkItemQuery.assigned(to: ["", "a\nb"]) == nil)
        let team = try #require(WorkItemQuery.assigned(to: ["ada@example.com", "O'Brien"]))
        #expect(team.contains("[System.AssignedTo] IN ('ada@example.com', 'O''Brien')"))
        #expect(team.contains("[System.ChangedDate] >= @Today - 30"))
        #expect(WorkItemQuery.stateChanged(people: []).contains("WHERE [System.AssignedTo] = @Me AND [Microsoft.VSTS.Common.StateChangeDate] >= @Today - 1"))
        #expect(WorkItemQuery.stateChanged(people: ["ada@example.com"])
            .contains("([System.AssignedTo] = @Me OR [System.AssignedTo] IN ('ada@example.com'))"))
    }

    @Test func staleAndStateOrder() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var w = WorkItem(number: 1, org: "o", project: "p", title: "t", type: "Bug", state: "New")
        #expect(!w.isStale(now: now, days: 30))
        w.changedAt = now.addingTimeInterval(-31 * 86_400)
        #expect(w.isStale(now: now, days: 30))
        let sorted = ["New", "Ready for Test", "In Progress", "Active"].sorted { WorkItem.stateRank($0) < WorkItem.stateRank($1) }
        #expect(sorted.prefix(2).sorted() == ["Active", "In Progress"] && sorted.last == "New")
    }
}
