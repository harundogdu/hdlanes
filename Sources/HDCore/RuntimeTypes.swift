import Foundation

/// What hdlanes needs to start a process in a terminal.
public struct LaunchSpec: Equatable, Sendable {
    public var executable: String
    public var args: [String]
    /// Full environment for the child (not merged with anything else).
    public var environment: [String: String]
    public var cwd: String

    public init(executable: String, args: [String], environment: [String: String], cwd: String) {
        self.executable = executable
        self.args = args
        self.environment = environment
        self.cwd = cwd
    }

    /// `KEY=value` list in the form SwiftTerm's `startProcess(environment:)` takes.
    public var environmentList: [String] {
        environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}

public enum NeedsYouKind: String, Codable, Sendable {
    /// A tool permission prompt.
    case permission
    /// The agent asked a question (AskUserQuestion, elicitation).
    case question
    /// Waiting for input / idle prompt after a turn.
    case input
    /// Login expired or missing.
    case auth
}

/// Live status of one session, as shown by the sidebar glyph.
public enum AgentStatus: Equatable, Sendable {
    /// Terminal exists but nothing launched yet (or a plain shell).
    case notStarted
    case starting
    /// Agent is up and waiting for the first prompt.
    case ready
    case working
    case needsYou(NeedsYouKind, detail: String?)
    /// Turn finished. `unread` on the runtime tracks whether the user has looked.
    case done
    case error(String)
    /// The agent process exited; the shell may still be alive.
    case exited(Int32?)

    public var isWorking: Bool { if case .working = self { return true } else { return false } }
    public var needsUser: Bool { if case .needsYou = self { return true } else { return false } }

    /// Sort weight for "what wants me" ordering: lower comes first.
    public var urgency: Int {
        switch self {
        case .needsYou: return 0
        case .error: return 1
        case .done: return 2
        case .working, .starting: return 3
        case .ready: return 4
        case .notStarted, .exited: return 5
        }
    }
}

/// A Claude subagent (Task/Agent tool) or a Codex child thread.
public struct SubagentInfo: Identifiable, Equatable, Sendable {
    public var id: String
    public var type: String
    /// What the parent asked it to do (`tool_input.description` of the Agent tool call).
    public var description: String?
    public var isRunning: Bool
    public var currentTool: String?
    public var currentToolDetail: String?
    public var toolCount: Int
    public var startedAt: Date
    public var endedAt: Date?
    public var lastMessage: String?
    public var transcriptPath: String?

    public init(id: String, type: String, description: String? = nil, isRunning: Bool = true,
                currentTool: String? = nil, currentToolDetail: String? = nil, toolCount: Int = 0,
                startedAt: Date, endedAt: Date? = nil, lastMessage: String? = nil, transcriptPath: String? = nil) {
        self.id = id
        self.type = type
        self.description = description
        self.isRunning = isRunning
        self.currentTool = currentTool
        self.currentToolDetail = currentToolDetail
        self.toolCount = toolCount
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastMessage = lastMessage
        self.transcriptPath = transcriptPath
    }
}

/// One tool call, for the activity feed.
public struct ActivityItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var at: Date
    /// nil for the main agent; the subagent id otherwise.
    public var agentID: String?
    public var tool: String
    public var detail: String
    public var isRunning: Bool
    public var failed: Bool

    public init(id: String, at: Date, agentID: String?, tool: String, detail: String, isRunning: Bool, failed: Bool = false) {
        self.id = id
        self.at = at
        self.agentID = agentID
        self.tool = tool
        self.detail = detail
        self.isRunning = isRunning
        self.failed = failed
    }
}

/// A permission request hdlanes can answer from the sidebar.
public struct PendingPermission: Equatable, Sendable {
    public var id: String
    public var tool: String
    public var detail: String
    public var receivedAt: Date
    /// true while the hook process is connected and waiting for our answer.
    public var canAnswer: Bool

    public init(id: String, tool: String, detail: String, receivedAt: Date, canAnswer: Bool) {
        self.id = id
        self.tool = tool
        self.detail = detail
        self.receivedAt = receivedAt
        self.canAnswer = canAnswer
    }
}

/// Everything the event reducers maintain for one session. Value type so reducers stay testable.
public struct AgentRuntimeSnapshot: Equatable, Sendable {
    public var status: AgentStatus
    public var subagents: [SubagentInfo]
    /// Most recent last, capped (see `activityLimit`).
    public var activity: [ActivityItem]
    public var pendingPermission: PendingPermission?
    /// Claude session id / Codex thread id reported by the agent.
    public var agentSessionID: String?
    public var lastPrompt: String?
    public var lastAssistantMessage: String?
    public var backgroundTasks: Int
    public var contextUsedPercent: Double?
    public var lastEventAt: Date?

    public static let activityLimit = 200

    public init(status: AgentStatus = .notStarted) {
        self.status = status
        subagents = []
        activity = []
        backgroundTasks = 0
    }

    public var runningSubagents: [SubagentInfo] { subagents.filter(\.isRunning) }
}
