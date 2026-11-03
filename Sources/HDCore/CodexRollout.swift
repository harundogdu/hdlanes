import Foundation

/// The parts of a Codex rollout line (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`) hdlanes uses.
public enum CodexRolloutRecord: Equatable, Sendable {
    /// First line of every file. `threadID` is what `codex resume` takes.
    case sessionMeta(threadID: String, cwd: String?)
    case taskStarted
    case taskComplete(lastMessage: String?)
    case turnAborted(reason: String?)
    case userMessage(String)
    case agentMessage(String)
    case toolCall(callID: String, name: String, detail: String)
    case toolOutput(callID: String)
    case patchApplied(callID: String?, files: [String], success: Bool)
    case webSearch(callID: String?, query: String)
    /// `rateLimits` is often null; only non-null values are usage readings.
    case tokenCount(rateLimits: JSONValue?, contextPercent: Double?)
}

public struct CodexRolloutLine: Equatable, Sendable {
    public var timestamp: Date?
    public var record: CodexRolloutRecord

    public init(timestamp: Date?, record: CodexRolloutRecord) {
        self.timestamp = timestamp
        self.record = record
    }
}

public enum CodexRollout {
    // MARK: Parsing

    public static func parse(line: Data) -> CodexRolloutLine? {
        guard !line.isEmpty, let json = try? JSONDecoder().decode(JSONValue.self, from: line) else { return nil }
        return parse(json: json)
    }

    public static func parse(line: String) -> CodexRolloutLine? { parse(line: Data(line.utf8)) }

    public static func parse(json: JSONValue) -> CodexRolloutLine? {
        guard let type = json["type"]?.string, let payload = json["payload"] else { return nil }
        let timestamp = json["timestamp"]?.string.flatMap(parseDate)
        guard let record = record(type: type, payload: payload) else { return nil }
        return CodexRolloutLine(timestamp: timestamp, record: record)
    }

    static func record(type: String, payload p: JSONValue) -> CodexRolloutRecord? {
        switch type {
        case "session_meta":
            guard let id = (p["id"] ?? p["session_id"])?.string, !id.isEmpty else { return nil }
            return .sessionMeta(threadID: id, cwd: p["cwd"]?.string)
        case "event_msg":
            switch p["type"]?.string {
            case "task_started": return .taskStarted
            case "task_complete": return .taskComplete(lastMessage: nonEmpty(p["last_agent_message"]?.string))
            case "turn_aborted": return .turnAborted(reason: p["reason"]?.string)
            case "user_message": return p["message"]?.string.map { .userMessage($0) }
            case "agent_message": return nonEmpty(p["message"]?.string).map { .agentMessage($0) }
            case "patch_apply_end":
                let files = (p["changes"]?.object?.keys).map { Array($0).sorted() } ?? []
                return .patchApplied(callID: nonEmpty(p["call_id"]?.string), files: files,
                                     success: p["success"]?.bool ?? true)
            case "web_search_end":
                return .webSearch(callID: nonEmpty(p["call_id"]?.string), query: p["query"]?.string ?? "")
            case "token_count":
                let limits = p["rate_limits"].flatMap { $0 == .null ? nil : $0 }
                return .tokenCount(rateLimits: limits, contextPercent: contextPercent(info: p["info"]))
            default: return nil
            }
        case "response_item":
            switch p["type"]?.string {
            case "function_call":
                let name = p["name"]?.string ?? "?"
                let raw = p["arguments"]?.string
                let args = raw.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
                return .toolCall(callID: callID(p), name: name, detail: toolDetail(name: name, arguments: args, raw: raw))
            case "custom_tool_call":
                let name = p["name"]?.string ?? "?"
                let input = p["input"]?.string
                return .toolCall(callID: callID(p), name: name, detail: toolDetail(name: name, arguments: nil, raw: input))
            case "local_shell_call":
                let command = p["action"]?["command"]
                return .toolCall(callID: callID(p), name: "local_shell", detail: commandText(command) ?? "")
            case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
                return nonEmpty(p["call_id"]?.string).map { .toolOutput(callID: $0) }
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func callID(_ p: JSONValue) -> String {
        nonEmpty(p["call_id"]?.string) ?? nonEmpty(p["id"]?.string) ?? UUID().uuidString
    }

    private static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }

    static func parseDate(_ text: String) -> Date? {
        if let d = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    static func contextPercent(info: JSONValue?) -> Double? {
        guard let window = info?["model_context_window"]?.double, window > 0,
              let used = info?.path("last_token_usage.total_tokens")?.double else { return nil }
        return min(100, max(0, used / window * 100))
    }

    /// Shell tools carry `cmd` (exec_command) or `command` (shell: argv array, often `bash -lc <script>`).
    /// The CLI's tool names here are from codex-rs, not observed in a CLI rollout on this machine.
    public static func toolDetail(name: String, arguments: JSONValue?, raw: String?) -> String {
        if let args = arguments {
            if let text = commandText(args["cmd"]) ?? commandText(args["command"]) {
                return ClaudeToolSummary.truncate(ClaudeToolSummary.firstLine(text))
            }
            for key in ["title", "query", "path", "file_path", "url", "pattern"] {
                if let s = args[key]?.string, !s.isEmpty { return ClaudeToolSummary.truncate(ClaudeToolSummary.firstLine(s)) }
            }
            if args["code"]?.string != nil || args["input"]?.string != nil {
                return ClaudeToolSummary.truncate(ClaudeToolSummary.firstLine((args["code"] ?? args["input"])?.string ?? ""))
            }
            return ClaudeToolSummary.truncate(ClaudeToolSummary.compactJSON(args))
        }
        guard let raw, !raw.isEmpty else { return "" }
        if name == "apply_patch" {
            let files = patchFiles(raw)
            if !files.isEmpty { return fileList(files) }
        }
        return ClaudeToolSummary.truncate(ClaudeToolSummary.firstLine(raw))
    }

    static func commandText(_ value: JSONValue?) -> String? {
        if let s = value?.string, !s.isEmpty { return s }
        guard let argv = value?.array?.compactMap(\.string), !argv.isEmpty else { return nil }
        // ["bash", "-lc", "<script>"]: the script is what the user wants to see.
        if argv.count == 3, ["-c", "-lc", "-ic"].contains(argv[1]) { return argv[2] }
        return argv.joined(separator: " ")
    }

    /// File paths named in an apply_patch body (`*** Update File: path` …).
    static func patchFiles(_ patch: String) -> [String] {
        let markers = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
        var files: [String] = []
        for line in patch.split(separator: "\n") {
            for marker in markers where line.hasPrefix(marker) {
                files.append(String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return files
    }

    static func fileList(_ files: [String]) -> String {
        ClaudeToolSummary.truncate(files.map(ClaudeToolSummary.lastComponents).joined(separator: ", "))
    }

    // MARK: Reducer

    /// Folds one record into the snapshot. Usage (`tokenCount.rateLimits`) is the caller's business.
    public static func apply(_ record: CodexRolloutRecord, to s: inout AgentRuntimeSnapshot, now: Date) {
        s.lastEventAt = now
        switch record {
        case .sessionMeta(let id, _):
            s.agentSessionID = id
            if s.status == .starting || s.status == .notStarted { s.status = .ready }
        case .taskStarted:
            s.status = .working
        case .taskComplete(let message):
            if let message { s.lastAssistantMessage = message }
            finishRunning(&s)
            s.status = .done
        case .turnAborted(let reason):
            finishRunning(&s)
            // An interrupt leaves Codex at its prompt; other reasons (a steer replacing the turn) go on.
            if reason?.lowercased().contains("interrupt") ?? true { s.status = .ready }
        case .userMessage(let text):
            if !text.isEmpty { s.lastPrompt = text }
            s.status = .working
        case .agentMessage(let text):
            s.lastAssistantMessage = text
        case .toolCall(let id, let name, let detail):
            if !s.activity.contains(where: { $0.id == id }) {
                append(ActivityItem(id: id, at: now, agentID: nil, tool: name, detail: detail, isRunning: true), &s)
            }
            if name.hasPrefix("request_user_input") {
                s.status = .needsYou(.question, detail: detail.isEmpty ? nil : detail)
            } else if !s.status.needsUser {
                s.status = .working
            }
        case .toolOutput(let id):
            guard let i = s.activity.firstIndex(where: { $0.id == id }) else { return }
            s.activity[i].isRunning = false
            if s.activity[i].tool.hasPrefix("request_user_input"), case .needsYou(.question, _) = s.status {
                s.status = .working
            }
        case .patchApplied(let id, let files, let success):
            let detail = fileList(files)
            if let id, let i = s.activity.firstIndex(where: { $0.id == id }) {
                s.activity[i].isRunning = false
                s.activity[i].failed = !success
                if !detail.isEmpty { s.activity[i].detail = detail }
            } else {
                append(ActivityItem(id: id ?? UUID().uuidString, at: now, agentID: nil, tool: "apply_patch",
                                    detail: detail, isRunning: false, failed: !success), &s)
            }
        case .webSearch(let id, let query):
            if let id, let i = s.activity.firstIndex(where: { $0.id == id }) {
                s.activity[i].isRunning = false
            } else {
                append(ActivityItem(id: id ?? UUID().uuidString, at: now, agentID: nil, tool: "web_search",
                                    detail: ClaudeToolSummary.truncate(query), isRunning: false), &s)
            }
        case .tokenCount(_, let percent):
            if let percent { s.contextUsedPercent = percent }
        }
    }

    private static func finishRunning(_ s: inout AgentRuntimeSnapshot) {
        for i in s.activity.indices where s.activity[i].isRunning { s.activity[i].isRunning = false }
    }

    private static func append(_ item: ActivityItem, _ s: inout AgentRuntimeSnapshot) {
        s.activity.append(item)
        let overflow = s.activity.count - AgentRuntimeSnapshot.activityLimit
        if overflow > 0 { s.activity.removeFirst(overflow) }
    }

    // MARK: Files

    /// `CODEX_HOME` of an account: its config dir when managed, `~/.codex` for the system default.
    public static func codexHome(for account: Account?, homeDirectory: String) -> String {
        if let account, !account.isSystemDefault, let dir = account.configDir, !dir.isEmpty { return dir }
        return (homeDirectory as NSString).appendingPathComponent(".codex")
    }

    /// `sessions/YYYY/MM/DD` directories for the days around `dates`, in local time and UTC (the
    /// directory date is local, but a UTC check costs nothing and covers a changed time zone).
    public static func dayDirectories(codexHome: String, around dates: [Date]) -> [URL] {
        let sessions = URL(fileURLWithPath: codexHome).appendingPathComponent("sessions", isDirectory: true)
        var result: [URL] = []
        var seen = Set<String>()
        for zone in [TimeZone.current, TimeZone(identifier: "UTC")!] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            for date in dates {
                for offset in [0, -1] {
                    guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
                    let c = calendar.dateComponents([.year, .month, .day], from: day)
                    guard let y = c.year, let m = c.month, let d = c.day else { continue }
                    let rel = String(format: "%04d/%02d/%02d", y, m, d)
                    if seen.insert(rel).inserted { result.append(sessions.appendingPathComponent(rel, isDirectory: true)) }
                }
            }
        }
        return result
    }

    /// The rollout file a freshly launched Codex session writes: the earliest `rollout-*.jsonl` created
    /// at or after `launchedAt - 5 s` whose `session_meta` cwd is `cwd` and whose thread started then
    /// too. Creation time, not modification time: another Codex in the same folder and home keeps
    /// appending to its older file, and a busier file must not beat the session's own. `excluding`
    /// holds files other sessions already claimed (two sessions in one folder).
    public static func findRolloutFile(codexHome: String, cwd: String, launchedAt: Date, now: Date = Date(),
                                       excluding: Set<String> = []) -> URL? {
        let want = canonicalPath(cwd)
        let threshold = launchedAt.addingTimeInterval(-launchSlack)
        let candidates = rolloutFiles(in: dayDirectories(codexHome: codexHome, around: [launchedAt, now]))
            .filter { $0.created >= threshold && !excluding.contains($0.url.path) }
            .sorted { $0.created != $1.created ? $0.created < $1.created : $0.url.path < $1.url.path }
        for candidate in candidates {
            guard let first = readFirstLine(candidate.url),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: first),
                  case .sessionMeta(_, let fileCwd)? = parse(json: json)?.record,
                  let fileCwd, canonicalPath(fileCwd) == want,
                  !isChildThread(meta: json) else { continue }
            // A new file for an older thread (another process resuming it) isn't this session's.
            if let started = threadStart(meta: json), started < threshold { continue }
            return candidate.url
        }
        return nil
    }

    /// How much earlier than hdlanes' own launch time the agent's file may be dated.
    static let launchSlack: TimeInterval = 5

    /// `session_meta.payload.timestamp`: when the thread itself started (UTC).
    static func threadStart(meta json: JSONValue) -> Date? {
        json["payload"]?["timestamp"]?.string.flatMap(parseDate)
    }

    /// A sub-agent's thread (its own rollout file, same cwd) is not the session's main thread.
    static func isChildThread(meta json: JSONValue) -> Bool {
        let payload = json["payload"]
        if let parent = payload?["parent_thread_id"]?.string, !parent.isEmpty { return true }
        if case .object? = payload?["source"] { return true }
        return false
    }

    /// The file of an existing thread (for `codex resume`): its name ends with the thread id. The most
    /// recently written one wins, in case a resume ever starts a new file for the same thread.
    public static func findRolloutFile(codexHome: String, threadID: String) -> URL? {
        let suffix = "-\(threadID.lowercased()).jsonl"
        return rolloutFiles(in: allDayDirectories(codexHome: codexHome))
            .filter { $0.url.lastPathComponent.lowercased().hasSuffix(suffix) }
            .max { $0.modified < $1.modified }?.url
    }

    /// Newest rollout files of a home, newest first (looks at the most recent `maxDays` day folders).
    public static func newestRolloutFiles(codexHome: String, limit: Int, maxDays: Int = 7) -> [URL] {
        let days = allDayDirectories(codexHome: codexHome).prefix(maxDays)
        return rolloutFiles(in: Array(days)).sorted { $0.modified > $1.modified }.prefix(limit).map(\.url)
    }

    /// The latest non-null `token_count.rate_limits` of a home, searching back across its newest files.
    public static func latestRateLimits(codexHome: String, files: Int = 6) -> (rateLimits: JSONValue, at: Date?)? {
        for url in newestRolloutFiles(codexHome: codexHome, limit: files) {
            if let found = lastRateLimits(in: url) { return found }
        }
        return nil
    }

    /// Scans the last `tailBytes` of a file backwards for a token_count with rate limits.
    public static func lastRateLimits(in url: URL, tailBytes: Int = 1 << 20) -> (rateLimits: JSONValue, at: Date?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        let marker = Data(#""rate_limits""#.utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            if let parsed = parse(line: Data(line)), case .tokenCount(let limits?, _) = parsed.record {
                return (limits, parsed.timestamp)
            }
        }
        return nil
    }

    /// First line of a file, read in chunks up to `maxBytes` (session_meta lines carry long instructions).
    public static func readFirstLine(_ url: URL, maxBytes: Int = 4 << 20) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        while buffer.count < maxBytes {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                buffer.append(chunk[chunk.startIndex..<newline])
                return buffer
            }
            buffer.append(chunk)
        }
        return buffer.isEmpty ? nil : buffer
    }

    /// Resolves symlinks (`/tmp` → `/private/tmp`) and `.`/`..`; Codex records the real path.
    public static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return HDPaths.normalizedDirString(String(cString: resolved))
        }
        return HDPaths.normalizedDirString(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    struct RolloutFile {
        var url: URL
        var modified: Date
        /// Birth time (APFS); the modification time when the file system doesn't report one.
        var created: Date
    }

    static func rolloutFiles(in dirs: [URL]) -> [RolloutFile] {
        let fm = FileManager.default
        var result: [RolloutFile] = []
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let url = dir.appendingPathComponent(name)
                let attributes = try? fm.attributesOfItem(atPath: url.path)
                let modified = attributes?[.modificationDate] as? Date ?? .distantPast
                let created = attributes?[.creationDate] as? Date ?? modified
                result.append(RolloutFile(url: url, modified: modified, created: created))
            }
        }
        return result
    }

    /// Every `sessions/YYYY/MM/DD` folder, newest first.
    static func allDayDirectories(codexHome: String) -> [URL] {
        let fm = FileManager.default
        let sessions = URL(fileURLWithPath: codexHome).appendingPathComponent("sessions", isDirectory: true)
        func numericChildren(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? [])
                .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0 > $1 }
                .map { url.appendingPathComponent($0, isDirectory: true) }
        }
        return numericChildren(sessions).flatMap(numericChildren).flatMap(numericChildren)
    }
}

/// Splits a byte stream into newline-terminated lines, keeping an incomplete tail for the next read.
public struct JSONLineSplitter: Sendable {
    public private(set) var pending = Data()
    /// A line longer than this is dropped (its remainder is skipped up to the next newline).
    public let maxLineLength: Int
    private var discarding = false

    public init(maxLineLength: Int = 16 << 20) {
        self.maxLineLength = maxLineLength
    }

    public mutating func append(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var rest = data[...]
        while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
            let piece = rest[rest.startIndex..<newline]
            if discarding {
                discarding = false
            } else {
                pending.append(piece)
                if !pending.isEmpty && pending.count <= maxLineLength { lines.append(pending) }
            }
            pending = Data()
            rest = rest[rest.index(after: newline)...]
        }
        if !discarding {
            pending.append(rest)
            if pending.count > maxLineLength {
                pending = Data()
                discarding = true
            }
        }
        return lines
    }
}
