import HDCore
import SwiftUI

// OWNER: tracking area. "İşler": Azure Boards items: today's state changes, mine by state, my teammates'.

struct WorkItemsTab: View {
    @Environment(AppModel.self) private var model
    @State private var editingPeople = false
    @State private var showOldMine = false

    static let refreshInterval: UInt64 = 300

    var body: some View {
        let t = model.tracking
        let people = model.trackedPeople
        let recentMine = t.myWorkItems.filter { !$0.isStale(days: WorkItemQuery.peopleWindowDays) }
        let oldMine = t.myWorkItems.filter { $0.isStale(days: WorkItemQuery.peopleWindowDays) }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 8) {
                    if let issue = t.workItemsIssue {
                        Label(L.workItemsIssue(issue), systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button(L.workItemsPeopleButton(people.count)) { editingPeople = true }
                        .controlSize(.small)
                        .help(L.workItemsPeopleHelp)
                }
                if t.workItemsLoadedAt != nil && t.workItemProjects.isEmpty {
                    Text(L.workItemsNoProjects).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    TrackingSection(title: L.sectionStateChanged, count: t.changedWorkItems.count,
                                    empty: emptyText(L.emptyStateChanged), isEmpty: t.changedWorkItems.isEmpty) {
                        ForEach(t.changedWorkItems) { item in
                            WorkItemRow(item: item, showAssignee: true, date: item.stateChangedAt, by: item.changedBy)
                        }
                    }
                    TrackingSection(title: L.sectionMyWorkItems, count: recentMine.count,
                                    empty: emptyText(L.emptyMyWorkItems), isEmpty: t.myWorkItems.isEmpty) {
                        Grouped(items: recentMine, key: \.state, byState: true, showAssignee: false)
                        if !oldMine.isEmpty {
                            Button { showOldMine.toggle() } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: showOldMine ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(L.oldWorkItems(oldMine.count))
                                    Text(verbatim: "·")
                                    Text(showOldMine ? L.hide : L.show)
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 6)
                            .padding(.top, 8)
                            if showOldMine {
                                Grouped(items: oldMine, key: \.state, byState: true, showAssignee: false).opacity(0.6)
                            }
                        }
                    }
                    TrackingSection(title: L.sectionTeamWorkItems, count: t.teamWorkItems.count,
                                    empty: people.isEmpty ? L.emptyNoPeople : emptyText(L.emptyTeamWorkItems),
                                    isEmpty: t.teamWorkItems.isEmpty) {
                        Grouped(items: t.teamWorkItems, key: { $0.assignedTo.isEmpty ? $0.assignedToID : $0.assignedTo },
                                byState: false, showAssignee: false)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: people) {
            await model.refreshWorkItems()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.refreshInterval * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await model.refreshWorkItems()
            }
        }
        .sheet(isPresented: $editingPeople) { TrackedPeopleSheet() }
    }

    private func emptyText(_ loaded: String) -> String {
        model.tracking.workItemsLoadedAt == nil ? L.loadingWorkItems : loaded
    }
}

/// Items under small headers (a state, or a person). States go in workflow order; people in first-seen
/// order of the newest-first list. Each group shows its first few items and folds the rest.
private struct Grouped: View {
    let items: [WorkItem]
    let key: (WorkItem) -> String
    let byState: Bool
    let showAssignee: Bool
    @State private var expanded: Set<String> = []

    static let visible = 5

    var body: some View {
        var order = items.reduce(into: [String]()) { if !$0.contains(key($1)) { $0.append(key($1)) } }
        if byState { order.sort { (WorkItem.stateRank($0), $0) < (WorkItem.stateRank($1), $1) } }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(order, id: \.self) { name in
                let group = items.filter { key($0) == name }
                let open = expanded.contains(name)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Text(verbatim: "\(group.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 6)
                    .padding(.bottom, 2)
                    ForEach(open ? group : Array(group.prefix(Self.visible))) {
                        WorkItemRow(item: $0, showAssignee: showAssignee, date: $0.changedAt, by: nil)
                    }
                    if group.count > Self.visible {
                        Button(open ? L.showFewer : L.showMore(group.count - Self.visible)) {
                            if open { expanded.remove(name) } else { expanded.insert(name) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 30)
                        .padding(.top, 2)
                    }
                }
            }
        }
    }
}

private struct WorkItemRow: View {
    let item: WorkItem
    let showAssignee: Bool
    let date: Date?
    let by: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        let parts: [String?] = [
            "#\(item.number)", item.type.nilIfBlank,
            showAssignee ? (item.assignedTo.nilIfBlank ?? L.workItemUnassigned) : nil,
            by?.nilIfBlank.map(L.workItemChangedBy),
        ]
        TrackingRow(title: item.title, subtitle: parts.compactMap { $0 }.joined(separator: " · "),
                    help: L.openInBrowserHelp, action: { model.openInBrowser(item.webURL) }) {
            Image(systemName: symbol).foregroundStyle(.secondary).font(.system(size: 11))
        } trailing: {
            HStack(spacing: 8) {
                Text(item.state)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                if let date { RelativeTimeText(date: date) }
            }
        }
        .contextMenu {
            Button(L.openPR) { model.openInBrowser(item.webURL) }
            Button(L.copyLink) { Panels.copy(item.webURL) }
        }
    }

    private var symbol: String {
        let t = item.type.lowercased()
        if t.contains("bug") { return "ladybug" }
        if t.contains("task") { return "checklist" }
        if t.contains("feature") || t.contains("epic") { return "flag" }
        return "doc.text"
    }
}

/// Teammates whose items are listed: email / unique name or display name, as Azure DevOps shows them.
private struct TrackedPeopleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        let people = model.trackedPeople
        VStack(alignment: .leading, spacing: 12) {
            Text(L.workItemsPeopleTitle).font(.headline)
            Text(L.workItemsPeopleNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(L.workItemsPersonPrompt, text: $draft)
                    .onSubmit(add)
                Button(L.add, action: add)
                    .disabled(WorkItemQuery.literal(draft) == nil)
            }
            List {
                ForEach(people, id: \.self) { person in
                    HStack {
                        Text(person)
                        Spacer()
                        Button { model.setTrackedPeople(people.filter { $0 != person }) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(L.remove)
                    }
                }
            }
            .frame(minHeight: 120)
            let suggestions = model.suggestedPeople
            if !suggestions.isEmpty {
                Text(L.workItemsSuggestions).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(suggestions, id: \.self) { name in
                            Button { model.setTrackedPeople(people + [name]) } label: {
                                Label(name, systemImage: "plus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            HStack {
                Spacer()
                Button(L.done) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440, height: 480)
    }

    private func add() {
        guard WorkItemQuery.literal(draft) != nil else { return }
        model.setTrackedPeople(model.trackedPeople + [draft])
        draft = ""
    }
}
