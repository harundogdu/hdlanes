import Foundation
import Testing
@testable import HDCore

struct SessionOrderingTests {
    private let p1 = UUID(), p2 = UUID(), p3 = UUID()

    private func item(_ n: Int, project: UUID, status: AgentStatus = .ready, minutesAgo: Double = 0,
                      category: String? = nil) -> SessionOrdering.Item {
        SessionOrdering.Item(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                             projectID: project, category: category, status: status,
                             lastActivity: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60))
    }

    @Test func needsYouFirstThenMostRecent() {
        let a = item(1, project: p1, status: .done, minutesAgo: 1)
        let b = item(2, project: p1, status: .needsYou(.permission, detail: nil), minutesAgo: 30)
        let c = item(3, project: p1, status: .working, minutesAgo: 0)
        let d = item(4, project: p1, status: .ready, minutesAgo: 1)
        #expect(SessionOrdering.sorted([a, b, c, d]).map(\.id) == [b.id, c.id, a.id, d.id])
    }

    @Test func filters() {
        #expect(SessionOrdering.matches(.needsYou(.question, detail: nil), .needsYou))
        #expect(SessionOrdering.matches(.error("x"), .needsYou))
        #expect(!SessionOrdering.matches(.done, .needsYou))
        #expect(SessionOrdering.matches(.working, .working))
        #expect(SessionOrdering.matches(.starting, .working))
        #expect(!SessionOrdering.matches(.ready, .working))
        #expect(SessionOrdering.matches(.done, .done))
        #expect(!SessionOrdering.matches(.exited(0), .done))
        #expect(SessionOrdering.matches(.exited(0), .all))
    }

    @Test func groupsByProjectInProjectOrder() {
        let items = [item(1, project: p2), item(2, project: p1), item(3, project: UUID())]
        let all = SessionOrdering.groupedByProject(items, filter: .all, projectOrder: [p1, p2, p3], includeEmpty: true)
        #expect(all.map(\.key) == [p1.uuidString, p2.uuidString, p3.uuidString, ""])
        #expect(all[2].items.isEmpty)
        let compact = SessionOrdering.groupedByProject(items, filter: .all, projectOrder: [p1, p2, p3], includeEmpty: false)
        #expect(compact.map(\.key) == [p1.uuidString, p2.uuidString, ""])
    }

    @Test func groupingAppliesFilter() {
        let items = [item(1, project: p1, status: .working), item(2, project: p2, status: .done)]
        let groups = SessionOrdering.groupedByProject(items, filter: .done, projectOrder: [p1, p2], includeEmpty: false)
        #expect(groups.map(\.key) == [p2.uuidString])
    }

    @Test func groupsByCategoryInCanonicalOrder() {
        let items = [item(1, project: p1, category: "ui"), item(2, project: p1, category: "bug"),
                     item(3, project: p1, category: nil), item(4, project: p1, category: "nonsense")]
        let groups = SessionOrdering.groupedByCategory(items, filter: .all)
        #expect(groups.map(\.key) == ["bug", "feature", "ui"])
        #expect(groups[1].items.count == 2)
    }

    @Test func nextNeedingUserWraps() {
        let a = item(1, project: p1, status: .needsYou(.input, detail: nil))
        let b = item(2, project: p1, status: .working)
        let c = item(3, project: p1, status: .needsYou(.permission, detail: nil))
        let ordered = [a, b, c]
        #expect(SessionOrdering.nextNeedingUser(in: ordered, after: nil) == a.id)
        #expect(SessionOrdering.nextNeedingUser(in: ordered, after: a.id) == c.id)
        #expect(SessionOrdering.nextNeedingUser(in: ordered, after: b.id) == c.id)
        #expect(SessionOrdering.nextNeedingUser(in: ordered, after: c.id) == a.id)
        #expect(SessionOrdering.nextNeedingUser(in: [b], after: nil) == nil)
    }

    @Test func neighborAfterRemoval() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(SessionOrdering.neighbor(of: ids[1], in: ids) == ids[2])
        #expect(SessionOrdering.neighbor(of: ids[2], in: ids) == ids[1])
        #expect(SessionOrdering.neighbor(of: ids[0], in: [ids[0]]) == nil)
    }

    @Test func branchSlugs() {
        #expect(SessionNaming.branchSlug(from: "Fix login crash!") == "fix-login-crash")
        #expect(SessionNaming.branchSlug(from: "Ekranı düzelt, şimdi") == "ekrani-duzelt-simdi")
        #expect(SessionNaming.branchSlug(from: "İçerik Güncelle") == "icerik-guncelle")
        #expect(SessionNaming.branchSlug(from: "  ") == "session")
        #expect(SessionNaming.branchSlug(from: "Café au lait") == "cafe-au-lait")
        #expect(SessionNaming.branchSlug(from: "x", prefix: "hd") == "hd/x")
        let long = SessionNaming.branchSlug(from: String(repeating: "word ", count: 30))
        #expect(long.count <= 48)
        #expect(!long.hasSuffix("-"))
    }

    @Test func titleFromPrompt() {
        #expect(SessionNaming.title(fromPrompt: "Fix the tests\nmore details") == "Fix the tests")
        #expect(SessionNaming.title(fromPrompt: "   \n") == nil)
        #expect(SessionNaming.title(fromPrompt: nil) == nil)
        let t = SessionNaming.title(fromPrompt: String(repeating: "abc ", count: 40))
        #expect(t?.hasSuffix("…") == true)
        #expect((t?.count ?? 0) <= 61)
    }

    @Test func colorIndexPicksLeastUsed() {
        #expect(SessionNaming.nextColorIndex(used: [], paletteSize: 8) == 0)
        #expect(SessionNaming.nextColorIndex(used: [0], paletteSize: 8) == 1)
        #expect(SessionNaming.nextColorIndex(used: [0, 1, 2, 3, 4, 5, 6, 7], paletteSize: 8) == 0)
        #expect(SessionNaming.nextColorIndex(used: [0, 1, 2, 3, 4, 5, 6, 7, 0], paletteSize: 8) == 1)
        #expect(SessionNaming.nextColorIndex(used: [9], paletteSize: 8) == 0)
    }
}
