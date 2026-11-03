import Foundation
import HDCore

/// One sidebar section: a project or a category.
struct SidebarSection: Identifiable {
    var id: String
    var title: String
    var project: Project?
    var category: String?
    var sessions: [AgentSession]
}

// OWNER: workspace area. Sidebar order: filter, grouping, needs-you first, then last activity.
// ⌘1…⌘9 and ⌃⇥ use the same order the sidebar renders.
extension AppModel {
    var sidebarFilterKind: SessionFilterKind { SessionFilterKind(rawValue: sidebarFilter.rawValue) ?? .all }

    private func orderingItem(_ s: AgentSession) -> SessionOrdering.Item {
        SessionOrdering.Item(id: s.id, projectID: s.projectID, category: s.category, status: liveStatus(s.id),
                             lastActivity: s.lastActivityAt ?? s.createdAt)
    }

    func sidebarSections(filter: SessionFilterKind? = nil) -> [SidebarSection] {
        let filter = filter ?? sidebarFilterKind
        let sessions = visibleSessions
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items = sessions.map(orderingItem)
        switch sidebarGrouping {
        case .project:
            let groups = SessionOrdering.groupedByProject(items, filter: filter, projectOrder: state.projects.map(\.id),
                                                          includeEmpty: filter == .all)
            return groups.map { g in
                let p = UUID(uuidString: g.key).flatMap { project($0) }
                return SidebarSection(id: "p-" + g.key, title: p?.name ?? L.otherProjects, project: p, category: nil,
                                      sessions: g.items.compactMap { byID[$0.id] })
            }
        case .category:
            return SessionOrdering.groupedByCategory(items, filter: filter).map { g in
                SidebarSection(id: "c-" + g.key, title: L.categoryName(g.key), project: nil, category: g.key,
                               sessions: g.items.compactMap { byID[$0.id] })
            }
        }
    }

    /// Session ids in the order the sidebar shows them (collapsed projects skipped).
    var sidebarSessionIDs: [UUID] {
        sidebarSections().filter { $0.project?.isCollapsed != true }.flatMap { $0.sessions.map(\.id) }
    }

    func sessionCount(for filter: SidebarFilter) -> Int {
        let kind = SessionFilterKind(rawValue: filter.rawValue) ?? .all
        return visibleSessions.filter { SessionOrdering.matches(liveStatus($0.id), kind) }.count
    }

    func selectSession(atSidebarIndex index: Int) {
        let ids = sidebarSessionIDs
        guard ids.indices.contains(index) else { return }
        selection = .session(ids[index])
    }

    /// Jumps to the next session that needs the user, revealing it if the filter or a collapsed
    /// project hides it.
    func selectNextNeedsYou() {
        let ordered = sidebarSections(filter: .all).flatMap(\.sessions).map(orderingItem)
        guard let next = SessionOrdering.nextNeedingUser(in: ordered, after: selectedSessionID),
              let s = session(next) else { return }
        if !SessionOrdering.matches(liveStatus(next), sidebarFilterKind) { sidebarFilter = .all }
        if project(s.projectID)?.isCollapsed == true { updateProject(s.projectID) { $0.isCollapsed = false } }
        selection = .session(next)
    }

    var hasSessionNeedingUser: Bool {
        visibleSessions.contains { liveStatus($0.id).needsUser }
    }
}
