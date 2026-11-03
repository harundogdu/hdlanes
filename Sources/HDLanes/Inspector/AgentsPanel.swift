import HDCore
import SwiftUI

/// Agents tab: live subagents and the tool-call feed of one session.
struct AgentsPanel: View {
    let sessionID: UUID

    @Environment(AppModel.self) private var model

    static let activityLimit = 60

    var body: some View {
        let snapshot = model.runtimes[sessionID]?.snapshot ?? AgentRuntimeSnapshot()
        if snapshot.subagents.isEmpty && snapshot.activity.isEmpty {
            ContentUnavailableView(L.agentsEmptyTitle, systemImage: "person.2",
                                   description: Text(L.agentsEmptyDetail))
        } else {
            let running = snapshot.subagents.filter(\.isRunning).sorted { $0.startedAt > $1.startedAt }
            let finished = snapshot.subagents.filter { !$0.isRunning }
                .sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
            let activity = Array(snapshot.activity.suffix(Self.activityLimit).reversed())
            let types = Dictionary(snapshot.subagents.map { ($0.id, $0.type) }, uniquingKeysWith: { a, _ in a })

            List {
                Section(L.subagentsSection) {
                    if snapshot.subagents.isEmpty {
                        Text(L.noSubagents)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(running) { RunningSubagentRow(agent: $0) }
                    ForEach(finished) { FinishedSubagentRow(agent: $0) }
                }
                Section(L.activitySection) {
                    if activity.isEmpty {
                        Text(L.noActivity)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(activity) { item in
                        ActivityRow(item: item, agentLabel: item.agentID.map { types[$0] ?? L.subagent } ?? L.mainAgent)
                    }
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 20)
        }
    }
}

struct AgentTypeBadge: View {
    let type: String

    var body: some View {
        Text(verbatim: type)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }
}

enum ElapsedFormat {
    static func string(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds).formatted(.time(pattern: pattern))
    }
}

struct RunningSubagentRow: View {
    let agent: SubagentInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                AgentTypeBadge(type: agent.type)
                Text(verbatim: agent.description ?? "")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: ElapsedFormat.string(from: agent.startedAt, to: context.date))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                if let tool = agent.currentTool {
                    Text(verbatim: tool)
                        .font(.system(size: 11, weight: .medium))
                    if let detail = agent.currentToolDetail, !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Text(L.toolCount(agent.toolCount))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .help(agent.description ?? agent.type)
    }
}

struct FinishedSubagentRow: View {
    let agent: SubagentInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                Text(L.lastMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(verbatim: agent.lastMessage?.isEmpty == false ? agent.lastMessage! : L.noLastMessage)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .help(L.finished)
                AgentTypeBadge(type: agent.type)
                Text(verbatim: agent.description ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(verbatim: L.toolCount(agent.toolCount) + " · "
                     + ElapsedFormat.string(from: agent.startedAt, to: agent.endedAt ?? agent.startedAt))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ActivityRow: View {
    let item: ActivityItem
    let agentLabel: String

    var body: some View {
        HStack(spacing: 6) {
            Text(item.at, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(verbatim: agentLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 70, alignment: .leading)
            Text(verbatim: item.tool)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.failed ? Color.red : Color.primary)
                .lineLimit(1)
            Text(verbatim: item.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(item.failed ? Color.red.opacity(0.8) : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if item.isRunning {
                ProgressView().controlSize(.mini)
                    .help(L.running)
            } else if item.failed {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(L.failed)
            }
        }
        .help(item.detail)
    }
}
