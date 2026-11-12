import HDCore
import SwiftUI

/// Right-hand panel of a session: Changes / Agents / Browser / File.
/// OWNER: git area (Changes, Browser) — Agents tab included.
struct InspectorView: View {
    let sessionID: UUID

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.session(sessionID) == nil {
                CompactEmptyState(title: L.inspectorSessionMissing, symbol: "sidebar.right",
                                  detail: L.inspectorSessionMissingDetail)
            } else {
                InspectorTabBar(selection: $model.inspectorTab, count: count(for:))
                Divider()
                Group {
                    switch model.inspectorTab {
                    case .changes: ChangesView(sessionID: sessionID)
                    case .agents: AgentsPanel(sessionID: sessionID)
                    case .browser: BrowserPanel(sessionID: sessionID)
                    case .file: FilePanel(sessionID: sessionID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(sessionID)
        .task(id: sessionID) { await autoRefresh() }
    }

    private func count(for tab: InspectorTab) -> Int {
        switch tab {
        case .changes: return model.diffs[sessionID]?.files.count ?? 0
        case .agents: return model.runtimes[sessionID]?.snapshot.runningSubagents.count ?? 0
        case .browser, .file: return 0
        }
    }

    /// Refreshes the diff on appear, then every 3 s when the agent did something (a tool call started or
    /// ended, the status changed), and at least every 30 s for edits made outside the agent.
    private func autoRefresh() async {
        guard model.session(sessionID) != nil else { return }
        await model.refreshDiff(sessionID)
        var lastSignature = activitySignature()
        var lastRefresh = Date()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, model.session(sessionID) != nil else { return }
            let signature = activitySignature()
            if signature != lastSignature || Date().timeIntervalSince(lastRefresh) >= 30 {
                lastSignature = signature
                lastRefresh = Date()
                await model.refreshDiff(sessionID)
            }
        }
    }

    private func activitySignature() -> String {
        guard let snapshot = model.runtimes[sessionID]?.snapshot else { return "" }
        let last = snapshot.activity.last
        return "\(snapshot.activity.count)|\(last?.id ?? "")|\(last?.isRunning ?? false)|\(snapshot.status)"
    }
}

/// The inspector's tabs: icon, name and a count badge; the chosen one sits on an accent wash.
/// Narrow panels drop the names and keep icons (names stay in the tooltip).
private struct InspectorTabBar: View {
    @Binding var selection: InspectorTab
    let count: (InspectorTab) -> Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showTitles: true)
            row(showTitles: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func row(showTitles: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases) { tab in
                InspectorTabButton(tab: tab, selected: selection == tab, count: count(tab), showTitle: showTitles) {
                    selection = tab
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct InspectorTabButton: View {
    let tab: InspectorTab
    let selected: Bool
    let count: Int
    let showTitle: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                if showTitle { Text(title).lineLimit(1) }
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(selected ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary)))
                }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var title: String {
        switch tab {
        case .changes: return L.tabChanges
        case .agents: return L.tabAgents
        case .browser: return L.tabBrowser
        case .file: return L.tabFile
        }
    }

    private var symbol: String {
        switch tab {
        case .changes: return "plusminus"
        case .agents: return "person.2"
        case .browser: return "globe"
        case .file: return "doc.text"
        }
    }
}
