import Foundation

// Persisted model. Every field added after v1 must be Optional (or decoded with decodeIfPresent in a
// custom init): Swift's synthesized Decodable does NOT fall back to a property's default value when a
// key is missing, so a non-optional new field would make old state files fail to load.

public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude, codex, shell

    public var isAgent: Bool { self != .shell }
}

/// How an account authenticates. Only metadata; secrets never live in hdlanes' state file.
public enum AuthMethod: String, Codable, CaseIterable, Sendable {
    /// Vendor's own browser login (`claude auth login`, `codex login`). The "id + password" path.
    case browser
    /// Claude: long-lived token from `claude setup-token`. Codex: access token.
    case token
    /// API key (Anthropic Console / OpenAI platform).
    case apiKey
    /// The account was already logged in before hdlanes (the system default dirs).
    case existing
}

public struct Account: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var provider: Provider
    public var label: String
    public var colorIndex: Int
    /// `true` for the user's existing `~/.claude` / `~/.codex`. hdlanes never sets
    /// CLAUDE_CONFIG_DIR / CODEX_HOME for these: setting CLAUDE_CONFIG_DIR even to `~/.claude`
    /// changes the Keychain service name and the account would look logged out.
    public var isSystemDefault: Bool
    /// Absolute config dir for managed accounts. Computed once and never changed: Claude Code keys its
    /// Keychain entry by a hash of this exact string, so moving/renaming it logs the account out.
    public var configDir: String?
    public var authMethod: AuthMethod
    public var email: String?
    public var plan: String?
    public var createdAt: Date
    /// Use the default account's skills, agents, commands, global instructions and project memory.
    /// nil → on for folders hdlanes created, off for imported ones (see `SharedContext`).
    public var sharesDefaultContext: Bool?

    public init(id: UUID = UUID(), provider: Provider, label: String, colorIndex: Int, isSystemDefault: Bool,
                configDir: String?, authMethod: AuthMethod, email: String? = nil, plan: String? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.provider = provider
        self.label = label
        self.colorIndex = colorIndex
        self.isSystemDefault = isSystemDefault
        self.configDir = configDir
        self.authMethod = authMethod
        self.email = email
        self.plan = plan
        self.createdAt = createdAt
    }
}

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Repository root (or plain folder) the project points at.
    public var path: String
    /// Where new worktrees go. nil → `<parent>/<repo>-worktrees`.
    public var worktreeRoot: String?
    /// Shell command run in a fresh worktree before the agent starts (e.g. `npm ci`).
    public var setupCommand: String?
    /// Gitignored files to copy into new worktrees (e.g. `GoogleService-Info.plist`, `.env`).
    public var copyFiles: [String]?
    /// Default account per provider for new sessions in this project.
    public var defaultClaudeAccount: UUID?
    public var defaultCodexAccount: UUID?
    public var isCollapsed: Bool?
    /// First prompt of a review session started from Tracking; nil → `ReviewPrompt.defaultTemplate`.
    public var reviewPromptTemplate: String?

    public init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

public struct AgentSession: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var provider: Provider
    /// nil for shell sessions.
    public var accountID: UUID?
    /// Working directory: the worktree path, or the project path when no worktree was made.
    public var cwd: String
    public var branch: String?
    /// Set when hdlanes created a worktree for this session (and may offer to remove it).
    public var worktreePath: String?
    /// Ref the worktree branched from; diffs are shown against its merge-base.
    public var baseRef: String?
    /// Claude session id (we pass --session-id) or Codex thread id (read from the rollout file).
    /// Used to resume after the app restarts.
    public var agentSessionID: String?
    public var taskID: UUID?
    /// Category id (see `Category`). Inherited from the task or guessed from the first prompt.
    public var category: String?
    public var initialPrompt: String?
    public var createdAt: Date
    public var lastActivityAt: Date?
    public var isArchived: Bool?
    /// The agent's last finished-turn message (≤500 characters) and when it arrived.
    public var lastResult: String?
    public var lastResultAt: Date?
    /// Web URL of the pull request a review session was started for (its worktree is detached).
    public var reviewPullRequestURL: String?
    /// Conversation this session was forked from (Claude session id / Codex thread id); used on the
    /// first launch only (`claude --resume … --fork-session`, `codex fork …`).
    public var forkedFromAgentSessionID: String?

    public init(id: UUID = UUID(), projectID: UUID, title: String, provider: Provider, accountID: UUID?,
                cwd: String, createdAt: Date = Date()) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.provider = provider
        self.accountID = accountID
        self.cwd = cwd
        self.createdAt = createdAt
    }
}

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case backlog, active, review, done
}

public struct TaskItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String?
    public var category: String
    public var status: TaskStatus
    public var projectID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    /// true when the category came from the AI categorizer rather than rules or the user.
    public var categorizedByAI: Bool?

    public init(id: UUID = UUID(), title: String, notes: String? = nil, category: String, status: TaskStatus = .backlog,
                projectID: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.notes = notes
        self.category = category
        self.status = status
        self.projectID = projectID
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

/// One rate-limit window as a percentage used.
public struct UsageWindow: Codable, Hashable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Date?
    public var windowMinutes: Int?

    public init(usedPercent: Double, resetsAt: Date?, windowMinutes: Int?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }

    /// Usage as of `now`: a window whose reset time has passed is empty again, whatever the last reading said.
    public func percent(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return usedPercent
    }

    public func hasReset(at now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }
}

/// Last known usage for an account. Claude: from the status line JSON of any session on that account.
/// Codex: from `token_count.rate_limits` in that account's rollout files.
public struct AccountUsage: Codable, Hashable, Sendable {
    public var fiveHour: UsageWindow?
    public var week: UsageWindow?
    public var plan: String?
    public var updatedAt: Date

    public init(fiveHour: UsageWindow?, week: UsageWindow?, plan: String?, updatedAt: Date) {
        self.fiveHour = fiveHour
        self.week = week
        self.plan = plan
        self.updatedAt = updatedAt
    }
}

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system, english, turkish
}

public enum AIProvider: String, Codable, CaseIterable, Sendable {
    case claude, jev
}

public struct AppSettings: Codable, Hashable, Sendable {
    /// Show Allow / Deny in hdlanes for Claude permission prompts (via the PermissionRequest hook).
    public var permissionsInSidebar: Bool?
    /// Let the AI categorizer run (`claude -p` on the chosen account) for new tasks.
    public var aiCategorization: Bool?
    public var aiCategorizationAccount: UUID?
    /// Which model suggests categories: a Claude account (`claude -p`, default) or TypeSafe's Jev
    /// (HTTP, key in the Keychain). Jev sees the task title and notes, so it stays off unless chosen.
    public var aiProvider: AIProvider?
    public var language: AppLanguage?
    public var notifyNeedsYou: Bool?
    public var notifyDone: Bool?
    public var terminalFontSize: Double?
    /// `TerminalPalette.id`; nil → hdlanes' own palette.
    public var terminalTheme: String?
    /// `AppTheme.id` of the window's colors; nil → Classic (the system look).
    public var appTheme: String?
    /// Font family of a fixed-pitch font; nil → the system monospaced font.
    public var terminalFont: String?
    /// Inbox: the Claude account whose MCP connectors read and send messages.
    public var inboxAccount: UUID?
    /// Inbox: MCP tools a refresh may use (read only, picked by the user).
    public var inboxReadTools: [String]?
    /// Inbox: the one MCP tool a confirmed reply may use.
    public var inboxSendTool: String?
    /// Inbox: the user's notes on what matters.
    public var inboxFocus: String?
    /// Inbox: how far back a refresh looks, in hours.
    public var inboxHours: Int?
    /// Tracking › Work items: teammates whose Azure Boards items are listed (unique names or display names).
    public var trackedPeople: [String]?

    public init() {}
}

/// Root of `~/.hdlanes/state.json`.
public struct AppState: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var accounts: [Account]
    public var projects: [Project]
    public var sessions: [AgentSession]
    public var tasks: [TaskItem]
    /// Keyed by `Account.id.uuidString` (String keys keep the JSON an object).
    public var usage: [String: AccountUsage]
    public var settings: AppSettings
    /// Tokens, MCP servers and kubeconfigs handed to sessions (secrets are in the Keychain).
    public var connections: [Connection]

    public init() {
        version = Self.currentVersion
        accounts = []
        projects = []
        sessions = []
        tasks = []
        usage = [:]
        settings = AppSettings()
        connections = []
    }

    enum CodingKeys: String, CodingKey { case version, accounts, projects, sessions, tasks, usage, settings, connections }

    // Tolerant decoding: a missing collection is empty, never a load failure.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        sessions = try c.decodeIfPresent([AgentSession].self, forKey: .sessions) ?? []
        tasks = try c.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? []
        usage = try c.decodeIfPresent([String: AccountUsage].self, forKey: .usage) ?? [:]
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        connections = try c.decodeIfPresent([Connection].self, forKey: .connections) ?? []
    }
}
