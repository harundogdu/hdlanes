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
            CompactEmptyState(title: L.agentsEmptyTitle, symbol: "person.2", detail: L.agentsEmptyDetail)
        } else {
            let running = snapshot.subagents.filter(\.isRunning).sorted { $0.startedAt > $1.startedAt }
            // Finished helpers that never used a tool and had no task text (Claude's internal agents)
            // are noise; keep everything else.
            let finished = snapshot.subagents.filter { !$0.isRunning && ($0.toolCount > 0 || $0.description != nil) }
                .sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
            let activity = Array(snapshot.activity.suffix(Self.activityLimit).reversed())
            let types = Dictionary(snapshot.subagents.map { ($0.id, $0.type) }, uniquingKeysWith: { a, _ in a })

            List {
                Section(L.subagentsSection) {
                    if running.isEmpty && finished.isEmpty {
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
                        ActivityRow(item: item, agentLabel: item.agentID.map { types[$0] ?? L.subagent } ?? L.mainAgent,
                                    isSubagent: item.agentID != nil)
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

/// One tool call: an icon for its kind, what it did in a line, and the tool, agent and time below.
struct ActivityRow: View {
    let item: ActivityItem
    let agentLabel: String
    /// Only subagents are named on the row.
    var isSubagent: Bool = false

    var body: some View {
        let style = ToolStyle(item.tool)
        let headline = item.summary ?? ToolStyle.readableArguments(item.detail).nilIfBlank ?? style.name
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(item.failed ? Color.red : Color.secondary)
                .frame(width: 22, height: 22)
                .background(item.failed ? Color.red.opacity(0.12) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: headline)
                    .font(.system(size: 12))
                    .foregroundStyle(item.failed ? Color.red : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(verbatim: style.name).fontWeight(.medium)
                    // The command itself, under the agent's description of it.
                    if item.summary != nil, !item.detail.isEmpty {
                        Text(verbatim: item.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if isSubagent {
                        Text(verbatim: "·")
                        Text(verbatim: agentLabel).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Group {
                if item.isRunning {
                    ProgressView().controlSize(.mini).help(L.running)
                } else if item.failed {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help(L.failed)
                } else {
                    RelativeTimeText(date: item.at)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .help(Text(item.at, format: .dateTime.hour().minute().second()))
                }
            }
            .padding(.top, 3)
        }
        .padding(.vertical, 3)
        .help(item.detail)
    }
}

/// Icon and readable name of a tool: Claude's built-ins, Codex's, and MCP tools (`mcp__server__action`).
struct ToolStyle {
    let name: String
    let symbol: String

    init(_ tool: String) {
        switch tool {
        case "Bash", "BashOutput", "KillShell", "shell", "exec_command", "local_shell":
            symbol = "terminal"
        case "Read", "NotebookRead", "view_image":
            symbol = "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch":
            symbol = "pencil"
        case "Grep", "Glob", "ToolSearch":
            symbol = "magnifyingglass"
        case "WebFetch", "WebSearch", "web_search":
            symbol = "globe"
        case "Agent", "Task", "SendMessage":
            symbol = "person.2"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "update_plan":
            symbol = "checklist"
        case "AskUserQuestion":
            symbol = "questionmark.bubble"
        case "Skill":
            symbol = "book"
        default:
            symbol = tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
        name = Self.readable(tool)
    }

    /// A compact JSON object of arguments (an MCP call) → its plain values, `{"query":"invoice"}` → `invoice`.
    /// Anything else comes back unchanged.
    static func readableArguments(_ detail: String) -> String {
        guard detail.hasPrefix("{"), let data = detail.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return detail }
        let values = object.keys.sorted().compactMap { key -> String? in
            switch object[key] {
            case let s as String: return s.isEmpty ? nil : s
            case let n as NSNumber:
                // JSON true/false arrive as NSNumber too.
                return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
            default: return nil
            }
        }
        return values.isEmpty ? detail : values.joined(separator: " · ")
    }

    /// `mcp__claude_ai_Microsoft_365__outlook_email_search` → `Microsoft 365 · outlook email search`.
    static func readable(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let rest = tool.dropFirst(5)
        guard let r = rest.range(of: "__") else { return String(rest) }
        var server = String(rest[..<r.lowerBound])
        if server.hasPrefix("claude_ai_") { server.removeFirst("claude_ai_".count) }
        let action = rest[r.upperBound...].replacingOccurrences(of: "_", with: " ")
        return server.replacingOccurrences(of: "_", with: " ") + " · " + action
    }
}
