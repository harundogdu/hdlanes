import Foundation

/// Folds Claude Code hook events (and OSC 7501 records) into an `AgentRuntimeSnapshot`.
///
/// A value type with a little private bookkeeping (Agent-tool descriptions waiting for their
/// SubagentStart, the current "needs you" reason, turn boundaries). Keep one per session and reset it
/// together with the snapshot when the agent is relaunched.
public struct ClaudeEventReducer: Sendable {
    /// Why the session needs the user, other than a hook-answerable permission (that one is
    /// `snapshot.pendingPermission`, so clearing it from outside clears the reason too).
    struct Block: Equatable, Sendable {
        var kind: NeedsYouKind
        var detail: String?
        /// Set when a specific tool call is waiting (AskUserQuestion); its PostToolUse clears it.
        var tool: String?
        var toolDetail: String?
    }

    struct PendingAgentTask: Equatable, Sendable {
        var toolUseID: String
        var description: String?
    }

    var pendingAgentTasks: [PendingAgentTask] = []
    var block: Block?
    /// A main-agent turn is running (UserPromptSubmit … Stop).
    public private(set) var turnActive = false
    /// Hook start time (`_hd_ts`, ms) of the last turn end. Tool events stamped earlier are late
    /// arrivals (each hook is its own process and connection) and must not revive the status.
    var lastTurnEndStamp: Double?
    var counter = 0
    /// true once any hook event arrived; until then OSC 7501 may drive the status alone.
    public private(set) var hasReceivedEvents = false

    public init() {}

    /// Subagent tool names in Claude Code (renamed from Task to Agent).
    public static let agentTools: Set<String> = ["Agent", "Task"]

    /// AskUserQuestion goes through PermissionRequest in some versions; "allow" would answer it with
    /// nothing, so hdlanes never offers Allow/Deny for it.
    public static func isAnswerablePermission(tool: String) -> Bool { tool != "AskUserQuestion" }

    // MARK: Hook events

    public mutating func apply(event: String, payload: JSONValue, to s: inout AgentRuntimeSnapshot, now: Date) {
        hasReceivedEvents = true
        s.lastEventAt = now
        if let id = payload["session_id"]?.string, !id.isEmpty { s.agentSessionID = id }
        let stamp = payload[ClaudeHookPayload.stampKey]?.double

        switch event {
        case "SessionStart":
            sessionStart(source: payload["source"]?.string, &s, now: now)
        case "UserPromptSubmit":
            turnActive = true
            if let prompt = payload["prompt"]?.string, !prompt.isEmpty { s.lastPrompt = prompt }
            clearBlocks(&s, keepingOpenPermission: true)
            s.status = .working
        case "PreToolUse":
            preToolUse(payload, stamp: stamp, &s, now: now)
        case "PostToolUse":
            postToolUse(payload, failed: false, stamp: stamp, &s, now: now)
        case "PostToolUseFailure":
            postToolUse(payload, failed: true, stamp: stamp, &s, now: now)
        case "PermissionRequest":
            permissionRequest(payload, &s, now: now)
        case "Notification":
            notification(payload, &s)
        case "SubagentStart":
            subagentStart(payload, stamp: stamp, &s, now: now)
        case "SubagentStop":
            subagentStop(payload, &s, now: now)
        case "Stop":
            turnEnded(stamp: stamp, &s)
            if let message = payload["last_assistant_message"]?.string, !message.isEmpty {
                s.lastAssistantMessage = message
            }
            s.backgroundTasks = Self.backgroundWorkCount(payload["background_tasks"])
            // A background agent still waiting on a permission keeps the session from being done.
            s.status = s.backgroundTasks > 0 || s.pendingPermission != nil ? .working : .done
        case "StopFailure":
            turnEnded(stamp: stamp, &s)
            let code = Self.errorCode(payload["error"])
            s.status = code == "authentication_failed" ? .needsYou(.auth, detail: code) : .error(code)
        case "SessionEnd":
            turnEnded(stamp: stamp, &s)
            s.pendingPermission = nil
            s.backgroundTasks = 0
            endSubagents(&s, now: now)
            s.status = .exited(nil)
        default:
            break
        }
        reassertBlock(&s)
    }

    /// The user answered the pending permission from hdlanes (allow or deny): Claude carries on.
    public mutating func resolvePermission(in s: inout AgentRuntimeSnapshot) {
        guard s.pendingPermission != nil else { return }
        s.pendingPermission = nil
        s.status = .working
        reassertBlock(&s)
    }

    /// The hook process went away (the user answered in the terminal, or it timed out). The card stays
    /// until the next tool result or turn end, but can no longer be answered from hdlanes.
    public func permissionConnectionClosed(in s: inout AgentRuntimeSnapshot) {
        s.pendingPermission?.canAnswer = false
    }

    // MARK: OSC 7501

    /// Applies the root OSC 7501 record (`state` idle|working|done|blocked|error, `kind`
    /// permission|question|auth). With `authoritative` (Codex, or Claude before any hook arrived) it
    /// drives the status; otherwise it only refines what the hooks reported: an instant needs-you, or
    /// clearing a needs-you the user already answered in the terminal.
    public mutating func applyProgramStatus(state: String, kind: String?, message: String?,
                                            to s: inout AgentRuntimeSnapshot, now: Date, authoritative: Bool) {
        if case .exited = s.status { return }
        let detail = message.flatMap { $0.isEmpty ? nil : $0 }
        let hookWaiting = s.pendingPermission?.canAnswer == true
        switch state.lowercased() {
        case "blocked":
            if s.status.needsUser { return }
            let needs = Self.needsYouKind(osc: kind)
            block = Block(kind: needs, detail: detail)
            s.status = .needsYou(needs, detail: detail)
        case "working":
            if hookWaiting { return }
            if s.status.needsUser || authoritative || s.status == .ready || s.status == .done || s.status == .starting {
                clearBlocks(&s)
                s.status = .working
            }
        case "idle", "done":
            if hookWaiting { return }
            switch s.status {
            case .starting, .notStarted:
                s.status = .ready
            case .needsYou:
                clearBlocks(&s)
                s.status = .done
            case .working where authoritative:
                s.status = .done
            case .working where state.lowercased() == "idle" && turnActive && s.pendingPermission == nil && block == nil:
                // Esc ends a turn without a Stop hook; Claude then reports "idle" ("done" means the turn
                // completed and Stop is on its way). Stamped now, so the interrupted tool's late
                // PostToolUseFailure can't bring "working" back.
                turnEnded(stamp: now.timeIntervalSince1970 * 1000, &s)
                s.status = .ready
            default:
                break
            }
        case "error":
            if authoritative { s.status = .error(detail ?? "error") }
        default:
            return
        }
        s.lastEventAt = now
    }

    static func needsYouKind(osc kind: String?) -> NeedsYouKind {
        switch kind?.lowercased() {
        case "permission": return .permission
        case "question": return .question
        case "auth": return .auth
        default: return .input
        }
    }

    // MARK: Event handlers

    private mutating func sessionStart(source: String?, _ s: inout AgentRuntimeSnapshot, now: Date) {
        // Auto-compaction mid-turn also fires SessionStart; the turn goes on.
        if source == "compact" { return }
        turnActive = false
        clearBlocks(&s)
        s.backgroundTasks = 0
        endSubagents(&s, now: now)
        if source == "clear" {
            s.lastPrompt = nil
            s.lastAssistantMessage = nil
        }
        s.status = .ready
    }

    private mutating func preToolUse(_ p: JSONValue, stamp: Double?, _ s: inout AgentRuntimeSnapshot, now: Date) {
        let tool = p["tool_name"]?.string ?? "?"
        let input = p["tool_input"]
        let detail = ClaudeToolSummary.detail(tool: tool, input: input)
        let summary = ClaudeToolSummary.summary(tool: tool, input: input)
        let agentID = p["agent_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let late = isLate(stamp)
        let id = p["tool_use_id"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? nextID("tool")

        if let i = s.activity.firstIndex(where: { $0.id == id }) {
            // PostToolUse got here first: keep it finished, fill in what it lacked.
            if s.activity[i].detail.isEmpty { s.activity[i].detail = detail }
            if s.activity[i].summary == nil { s.activity[i].summary = summary }
        } else {
            appendActivity(ActivityItem(id: id, at: now, agentID: agentID, tool: tool, detail: detail,
                                        summary: summary, isRunning: !late), &s)
        }

        if let agentID {
            let i = subagentIndex(agentID, type: p["agent_type"]?.string, &s, now: now)
            s.subagents[i].currentTool = tool
            s.subagents[i].currentToolDetail = detail
            s.subagents[i].toolCount += 1
        }

        if Self.agentTools.contains(tool) {
            let description = input?["description"]?.string ?? input?["prompt"]?.string.map(ClaudeToolSummary.firstLine)
            pendingAgentTasks.append(PendingAgentTask(toolUseID: id, description: description))
        }

        if late { return }
        if tool == "AskUserQuestion" {
            block = Block(kind: .question, detail: ClaudeToolSummary.question(input) ?? detail, tool: tool, toolDetail: detail)
            s.status = .needsYou(.question, detail: block?.detail)
            return
        }
        // A subagent working in parallel doesn't answer the main agent's prompt.
        if agentID == nil, block?.tool == nil { block = nil }
        s.status = .working
    }

    private mutating func postToolUse(_ p: JSONValue, failed: Bool, stamp: Double?, _ s: inout AgentRuntimeSnapshot, now: Date) {
        let tool = p["tool_name"]?.string ?? "?"
        let detail = ClaudeToolSummary.detail(tool: tool, input: p["tool_input"])
        let agentID = p["agent_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let toolUseID = p["tool_use_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }

        let index = toolUseID.flatMap { id in s.activity.firstIndex { $0.id == id } }
            ?? s.activity.lastIndex { $0.isRunning && $0.tool == tool && $0.agentID == agentID && $0.detail == detail }
        if let i = index {
            s.activity[i].isRunning = false
            s.activity[i].failed = failed
        } else {
            appendActivity(ActivityItem(id: toolUseID ?? nextID("tool"), at: now, agentID: agentID, tool: tool,
                                        detail: detail, summary: ClaudeToolSummary.summary(tool: tool, input: p["tool_input"]),
                                        isRunning: false, failed: failed), &s)
        }

        // The tool the user was asked about has run (or failed): the prompt is gone.
        if let pending = s.pendingPermission, pending.tool == tool, pending.detail == detail,
           pending.agentID == nil || pending.agentID == agentID {
            s.pendingPermission = nil
        }
        if let b = block, b.tool == tool, b.toolDetail == nil || b.toolDetail == detail {
            block = nil
        } else if agentID == nil, block?.tool == nil {
            block = nil
        }

        if isLate(stamp) { return }
        s.status = .working
    }

    private mutating func permissionRequest(_ p: JSONValue, _ s: inout AgentRuntimeSnapshot, now: Date) {
        let tool = p["tool_name"]?.string ?? "?"
        let detail = ClaudeToolSummary.detail(tool: tool, input: p["tool_input"])
        guard Self.isAnswerablePermission(tool: tool) else {
            let question = ClaudeToolSummary.question(p["tool_input"]) ?? detail
            block = Block(kind: .question, detail: question, tool: tool, toolDetail: detail)
            s.status = .needsYou(.question, detail: question)
            return
        }
        let agentID = p["agent_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        s.pendingPermission = PendingPermission(id: nextID("permission"), tool: tool, detail: detail,
                                                receivedAt: now, canAnswer: false, agentID: agentID)
        s.status = .needsYou(.permission, detail: Self.permissionDetail(tool: tool, detail: detail))
    }

    private mutating func notification(_ p: JSONValue, _ s: inout AgentRuntimeSnapshot) {
        let message = p["message"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        switch p["notification_type"]?.string {
        case "permission_prompt":
            // Usually the PermissionRequest hook already reported it with more detail.
            guard s.pendingPermission == nil, block == nil else { return }
            block = Block(kind: .permission, detail: message)
            s.status = .needsYou(.permission, detail: message)
        case "elicitation_dialog":
            block = Block(kind: .question, detail: message)
            s.status = .needsYou(.question, detail: message)
        case "agent_needs_input":
            block = Block(kind: .input, detail: message)
            s.status = .needsYou(.input, detail: message)
        case "idle_prompt":
            if s.status.isWorking && s.pendingPermission == nil && block == nil { s.status = .done }
        default:
            break
        }
    }

    private mutating func subagentStart(_ p: JSONValue, stamp: Double?, _ s: inout AgentRuntimeSnapshot, now: Date) {
        guard let agentID = p["agent_id"]?.string, !agentID.isEmpty else { return }
        let description = pendingAgentTasks.isEmpty ? nil : pendingAgentTasks.removeFirst().description
        let type = p["agent_type"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "agent"
        if let i = s.subagents.firstIndex(where: { $0.id == agentID }) {
            s.subagents[i].isRunning = true
            s.subagents[i].endedAt = nil
            if s.subagents[i].description == nil { s.subagents[i].description = description }
        } else {
            s.subagents.append(SubagentInfo(id: agentID, type: type, description: description, startedAt: now))
        }
        if isLate(stamp) { return }
        if !s.status.needsUser { s.status = .working }
    }

    private mutating func subagentStop(_ p: JSONValue, _ s: inout AgentRuntimeSnapshot, now: Date) {
        guard let agentID = p["agent_id"]?.string, !agentID.isEmpty else { return }
        let i = subagentIndex(agentID, type: p["agent_type"]?.string, &s, now: now)
        s.subagents[i].isRunning = false
        s.subagents[i].endedAt = now
        if let message = p["last_assistant_message"]?.string, !message.isEmpty { s.subagents[i].lastMessage = message }
        if let path = p["agent_transcript_path"]?.string, !path.isEmpty { s.subagents[i].transcriptPath = path }
        for j in s.activity.indices where s.activity[j].agentID == agentID && s.activity[j].isRunning {
            s.activity[j].isRunning = false
        }
        if s.pendingPermission?.agentID == agentID {
            // Its prompt ended with it.
            s.pendingPermission = nil
            reassertBlock(&s)
        }
        // A background agent finishing after the main turn ended.
        if !turnActive, s.backgroundTasks > 0 {
            s.backgroundTasks -= 1
            if s.backgroundTasks == 0, s.status.isWorking { s.status = .done }
        }
    }

    // MARK: Helpers

    private mutating func turnEnded(stamp: Double?, _ s: inout AgentRuntimeSnapshot) {
        turnActive = false
        if let stamp { lastTurnEndStamp = max(lastTurnEndStamp ?? stamp, stamp) }
        clearBlocks(&s, keepingOpenPermission: true)
        for i in s.activity.indices where s.activity[i].agentID == nil && s.activity[i].isRunning {
            s.activity[i].isRunning = false
        }
    }

    /// With `keepingOpenPermission` (a main-agent turn boundary) a permission that is still open stays:
    /// one a subagent asked for, or one whose hook is still connected and waiting for our answer (the
    /// main agent can't end its turn while its own prompt is up).
    private mutating func clearBlocks(_ s: inout AgentRuntimeSnapshot, keepingOpenPermission: Bool = false) {
        block = nil
        if keepingOpenPermission, let pending = s.pendingPermission, pending.agentID != nil || pending.canAnswer { return }
        s.pendingPermission = nil
    }

    /// A reason to need the user outlives unrelated events (a subagent's tool call, a status line).
    private func reassertBlock(_ s: inout AgentRuntimeSnapshot) {
        switch s.status {
        case .exited, .error, .done, .notStarted: return
        case .needsYou(.auth, _): return
        default: break
        }
        if let pending = s.pendingPermission {
            s.status = .needsYou(.permission, detail: Self.permissionDetail(tool: pending.tool, detail: pending.detail))
        } else if let block {
            s.status = .needsYou(block.kind, detail: block.detail)
        } else if s.status.needsUser {
            s.status = .working
        }
    }

    private func isLate(_ stamp: Double?) -> Bool {
        guard let stamp, let end = lastTurnEndStamp else { return false }
        return stamp < end
    }

    private mutating func nextID(_ prefix: String) -> String {
        counter += 1
        return "hd-\(prefix)-\(counter)"
    }

    private func appendActivity(_ item: ActivityItem, _ s: inout AgentRuntimeSnapshot) {
        s.activity.append(item)
        let overflow = s.activity.count - AgentRuntimeSnapshot.activityLimit
        if overflow > 0 { s.activity.removeFirst(overflow) }
    }

    private func subagentIndex(_ id: String, type: String?, _ s: inout AgentRuntimeSnapshot, now: Date) -> Int {
        if let i = s.subagents.firstIndex(where: { $0.id == id }) { return i }
        // Its SubagentStart was missed (hdlanes started late): show it anyway.
        s.subagents.append(SubagentInfo(id: id, type: type.flatMap { $0.isEmpty ? nil : $0 } ?? "agent", startedAt: now))
        return s.subagents.count - 1
    }

    private func endSubagents(_ s: inout AgentRuntimeSnapshot, now: Date) {
        for i in s.subagents.indices where s.subagents[i].isRunning {
            s.subagents[i].isRunning = false
            s.subagents[i].endedAt = now
        }
    }

    /// `background_tasks[].type` labels that keep a session working after Stop: agents, which report
    /// their end with SubagentStop (Claude's own idle logic waits for the same kinds). Shells, monitors,
    /// MCP tasks and internal work never send one, so they must not hold "working". An entry without
    /// a type (older versions) counts.
    static let agentBackgroundKinds: Set<String> = ["subagent", "workflow", "teammate", "cloud session"]

    static func backgroundWorkCount(_ value: JSONValue?) -> Int {
        guard let entries = value?.array else { return 0 }
        return entries.filter { entry in
            guard let type = entry["type"]?.string?.lowercased(), !type.isEmpty else { return true }
            return agentBackgroundKinds.contains(type)
        }.count
    }

    static func permissionDetail(tool: String, detail: String) -> String {
        detail.isEmpty ? tool : "\(tool): \(detail)"
    }

    /// StopFailure's `error` is a code string; tolerate an object carrying it.
    static func errorCode(_ value: JSONValue?) -> String {
        if let s = value?.string, !s.isEmpty { return s }
        for key in ["type", "code", "kind", "error"] {
            if let s = value?[key]?.string, !s.isEmpty { return s }
        }
        return "unknown"
    }
}

extension SubagentInfo {
    /// How long a bare subagent (no task text, no tool call) is shown before it counts as a helper.
    public static let helperGrace: TimeInterval = 3

    /// No task text and no tool call yet.
    public var isBare: Bool {
        (description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty && toolCount == 0
    }

    /// Claude's internal helper agents show up as bare "agent" rows that never say what they do. A real
    /// subagent gets its description or a first tool call within `helperGrace`.
    public func isBareHelper(at now: Date) -> Bool {
        isBare && now.timeIntervalSince(startedAt) > Self.helperGrace
    }
}

extension AgentRuntimeSnapshot {
    /// Running subagents worth a line in the sidebar: bare helpers past `SubagentInfo.helperGrace` are left out.
    public func visibleRunningSubagents(at now: Date) -> [SubagentInfo] {
        runningSubagents.filter { !$0.isBareHelper(at: now) }
    }
}

/// One-line summaries of tool inputs for the activity feed and permission cards.
public enum ClaudeToolSummary {
    public static let maxLength = 120

    public static func detail(tool: String, input: JSONValue?) -> String {
        guard let input else { return "" }
        let field: String?
        switch tool {
        case "Bash", "BashOutput":
            field = input["command"]?.string.map(firstLine)
        case "Read", "Edit", "Write", "MultiEdit":
            field = input["file_path"]?.string.map(lastComponents)
        case "NotebookEdit", "NotebookRead":
            field = (input["notebook_path"] ?? input["file_path"])?.string.map(lastComponents)
        case "Grep", "Glob":
            field = input["pattern"]?.string
        case "WebFetch":
            field = input["url"]?.string
        case "WebSearch":
            field = input["query"]?.string
        case "Agent", "Task":
            field = input["description"]?.string ?? input["prompt"]?.string.map(firstLine)
        case "AskUserQuestion":
            field = question(input)
        default:
            field = nil
        }
        if let field, !field.isEmpty { return truncate(field) }
        return truncate(compactJSON(input))
    }

    /// The agent's own one-line purpose for a call, when the tool has one (Bash `description`).
    public static func summary(tool: String, input: JSONValue?) -> String? {
        guard tool == "Bash", let text = input?["description"]?.string else { return nil }
        let line = firstLine(text)
        return line.isEmpty ? nil : truncate(line)
    }

    /// First question text of an AskUserQuestion input.
    public static func question(_ input: JSONValue?) -> String? {
        let first = input?["questions"]?.array?.first
        return (first?["question"]?.string ?? first?["header"]?.string ?? input?["question"]?.string)
            .flatMap { $0.isEmpty ? nil : truncate(firstLine($0)) }
    }

    static func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let more = line.count < trimmed.count
        return line.trimmingCharacters(in: .whitespaces) + (more ? " …" : "")
    }

    /// `/a/b/c/file.swift` → `c/file.swift`.
    static func lastComponents(_ path: String) -> String {
        path.split(separator: "/").suffix(2).joined(separator: "/")
    }

    static func truncate(_ text: String) -> String {
        text.count > maxLength ? String(text.prefix(maxLength - 1)) + "…" : text
    }

    static func compactJSON(_ value: JSONValue) -> String {
        if case .object(let o) = value, o.isEmpty { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Shaping of hook stdin before it is forwarded to the app.
public enum ClaudeHookPayload {
    /// Added by `hdlanes-hook`: its start time in ms since 1970, so the reducer can spot hooks that
    /// connected out of order.
    public static let stampKey = "_hd_ts"
    /// Kept whole up to this size; Claude's last message is what the sidebar quotes.
    public static let messageLimit = 64 * 1024

    /// Drops `tool_response` (unused, can be megabytes) and shortens every other long string, so a
    /// Write of a large file doesn't push its content through the socket.
    public static func slim(_ payload: JSONValue, maxString: Int = 4096, stamp: Double? = nil) -> JSONValue {
        guard case .object(var object) = payload else { return payload }
        object.removeValue(forKey: "tool_response")
        for (key, value) in object {
            let limit = key.hasSuffix("last_assistant_message") || key == "prompt" ? messageLimit : maxString
            object[key] = truncatingStrings(value, limit: limit, maxString: maxString)
        }
        if let stamp { object[stampKey] = .number(stamp) }
        return .object(object)
    }

    static func truncatingStrings(_ value: JSONValue, limit: Int, maxString: Int) -> JSONValue {
        switch value {
        case .string(let s):
            return s.utf8.count > limit ? .string(String(s.prefix(limit)) + "…") : value
        case .array(let a):
            return .array(a.map { truncatingStrings($0, limit: maxString, maxString: maxString) })
        case .object(let o):
            return .object(o.mapValues { truncatingStrings($0, limit: maxString, maxString: maxString) })
        default:
            return value
        }
    }
}
