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
                Picker(selection: $model.inspectorTab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(title(for: tab)).tag(tab)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
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

    private func title(for tab: InspectorTab) -> String {
        switch tab {
        case .changes: return L.tabWithCount(L.tabChanges, model.diffs[sessionID]?.files.count ?? 0)
        case .agents: return L.tabWithCount(L.tabAgents, model.runtimes[sessionID]?.snapshot.runningSubagents.count ?? 0)
        case .browser: return L.tabBrowser
        case .file: return L.tabFile
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
