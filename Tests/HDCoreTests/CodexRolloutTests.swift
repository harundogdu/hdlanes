import Foundation
import Testing
@testable import HDCore

struct CodexRolloutTests {
    // Field shapes from codex 0.166 / Codex Desktop rollout files (values made up).
    static let meta = #"{"timestamp":"2026-11-03T08:31:46.123Z","type":"session_meta","payload":{"session_id":"s","id":"01a1a089-2838-71b3-b34e-2d37bf48f53e","timestamp":"2026-11-03T08:31:46.000Z","cwd":"CWD","originator":"codex_cli_rs","cli_version":"0.166.0","base_instructions":{"text":"long"}}}"#

    private func parse(_ line: String) -> CodexRolloutRecord? { CodexRollout.parse(line: line)?.record }

    @Test func parsesSessionMeta() throws {
        let line = try #require(CodexRollout.parse(line: Self.meta.replacingOccurrences(of: "CWD", with: "/repo")))
        #expect(line.record == .sessionMeta(threadID: "01a1a089-2838-71b3-b34e-2d37bf48f53e", cwd: "/repo"))
        #expect(abs((line.timestamp?.timeIntervalSince1970 ?? 0) - 1_793_694_706.123) < 0.001)
    }

    @Test func parsesEvents() {
        #expect(parse(#"{"timestamp":"2026-11-03T08:31:47Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t","started_at":1}}"#) == .taskStarted)
        #expect(parse(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t","last_agent_message":"All done"}}"#) == .taskComplete(lastMessage: "All done"))
        #expect(parse(#"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":null}}"#) == .taskComplete(lastMessage: nil))
        #expect(parse(#"{"type":"event_msg","payload":{"type":"user_message","message":"fix it","local_images":[]}}"#) == .userMessage("fix it"))
        #expect(parse(#"{"type":"event_msg","payload":{"type":"agent_message","message":"Looking"}}"#) == .agentMessage("Looking"))
        #expect(parse(#"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#) == .turnAborted(reason: "interrupted"))
        #expect(parse(#"{"type":"event_msg","payload":{"type":"patch_apply_end","call_id":"c9","success":false,"changes":{"/r/b.swift":{"type":"update"},"/r/a.swift":{"type":"add"}}}}"#)
                == .patchApplied(callID: "c9", files: ["/r/a.swift", "/r/b.swift"], success: false))
        #expect(parse(#"{"type":"event_msg","payload":{"type":"web_search_end","call_id":"w","query":"swift testing"}}"#) == .webSearch(callID: "w", query: "swift testing"))
        #expect(parse(#"{"type":"turn_context","payload":{"cwd":"/x"}}"#) == nil)
        #expect(parse(#"{"type":"event_msg","payload":{"type":"agent_reasoning","text":"…"}}"#) == nil)
        #expect(parse("not json") == nil)
        #expect(parse("") == nil)
        #expect(parse(#"{"type":"session_meta","payload":{"cwd":"/x"}}"#) == nil)
    }

    @Test func parsesToolCalls() {
        #expect(parse(#"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cargo test -p core\",\"workdir\":\"/r\"}","call_id":"c1"}}"#)
                == .toolCall(callID: "c1", name: "exec_command", detail: "cargo test -p core"))
        #expect(parse(#"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"npm test\\nnpm run lint\"]}","call_id":"c2"}}"#)
                == .toolCall(callID: "c2", name: "shell", detail: "npm test …"))
        #expect(parse(#"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"ls\",\"-la\"]}","call_id":"c3"}}"#)
                == .toolCall(callID: "c3", name: "shell", detail: "ls -la"))
        #expect(parse(#"{"type":"response_item","payload":{"type":"function_call","name":"js","arguments":"{\"code\":\"x()\",\"title\":\"Inspect page\"}","call_id":"c4"}}"#)
                == .toolCall(callID: "c4", name: "js", detail: "Inspect page"))
        #expect(parse(#"{"type":"response_item","payload":{"type":"function_call","name":"wait","arguments":"{\"cell_id\":\"1\",\"yield_time_ms\":500}","call_id":"c5"}}"#)
                == .toolCall(callID: "c5", name: "wait", detail: #"{"cell_id":"1","yield_time_ms":500}"#))
        #expect(parse(#"{"type":"response_item","payload":{"type":"function_call","name":"odd","arguments":"not json","call_id":"c6"}}"#)
                == .toolCall(callID: "c6", name: "odd", detail: "not json"))
        let patch = "*** Begin Patch\n*** Update File: Sources/App/Main.swift\n@@\n-a\n+b\n*** Add File: docs/new.md\n+x\n*** End Patch"
        let patchJSON = String(data: try! JSONEncoder().encode(patch), encoding: .utf8)!
        #expect(parse(#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":\#(patchJSON),"call_id":"p1","status":"completed"}}"#)
                == .toolCall(callID: "p1", name: "apply_patch", detail: "App/Main.swift, docs/new.md"))
        #expect(parse(#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const a = 1\nmore","call_id":"e1"}}"#)
                == .toolCall(callID: "e1", name: "exec", detail: "const a = 1 …"))
        #expect(parse(#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"ok"}}"#) == .toolOutput(callID: "c1"))
        #expect(parse(#"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"p1","output":[]}}"#) == .toolOutput(callID: "p1"))
        #expect(parse(#"{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}"#) == nil)
    }

    @Test func parsesTokenCount() {
        #expect(parse(#"{"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}"#)
                == .tokenCount(rateLimits: nil, contextPercent: nil))
        let rec = parse(#"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":64000},"model_context_window":256000},"rate_limits":{"limit_id":"codex","primary":{"used_percent":40.0,"window_minutes":300,"resets_at":1793707612},"secondary":null,"plan_type":"plus"}}}"#)
        guard case .tokenCount(let limits?, let percent)? = rec else { Issue.record("expected token count"); return }
        #expect(percent == 25)
        #expect(limits["plan_type"]?.string == "plus")
    }

    // MARK: Reducer

    @Test func turnFlow() {
        var s = AgentRuntimeSnapshot(status: .starting)
        let now = Date(timeIntervalSince1970: 0)
        func apply(_ r: CodexRolloutRecord) { CodexRollout.apply(r, to: &s, now: now) }
        apply(.sessionMeta(threadID: "th-1", cwd: "/r"))
        #expect(s.status == .ready)
        #expect(s.agentSessionID == "th-1")
        apply(.userMessage("fix the bug"))
        #expect(s.lastPrompt == "fix the bug")
        apply(.taskStarted)
        #expect(s.status == .working)
        apply(.toolCall(callID: "c1", name: "exec_command", detail: "ls"))
        #expect(s.activity.last?.isRunning == true)
        apply(.toolOutput(callID: "c1"))
        #expect(s.activity.last?.isRunning == false)
        apply(.toolCall(callID: "p1", name: "apply_patch", detail: "a.swift"))
        apply(.patchApplied(callID: "p1", files: ["/r/x/a.swift", "/r/y/b.swift"], success: true))
        #expect(s.activity.last?.detail == "x/a.swift, y/b.swift")
        #expect(s.activity.last?.isRunning == false)
        apply(.patchApplied(callID: nil, files: ["/r/z.swift"], success: false))
        #expect(s.activity.last?.tool == "apply_patch")
        #expect(s.activity.last?.failed == true)
        apply(.agentMessage("Fixed it"))
        apply(.toolCall(callID: "c2", name: "exec_command", detail: "make"))
        apply(.taskComplete(lastMessage: nil))
        #expect(s.status == .done)
        #expect(s.lastAssistantMessage == "Fixed it")
        #expect(s.activity.allSatisfy { !$0.isRunning })
        apply(.tokenCount(rateLimits: nil, contextPercent: 31))
        #expect(s.contextUsedPercent == 31)
    }

    @Test func userInputRequestNeedsYou() {
        var s = AgentRuntimeSnapshot(status: .working)
        CodexRollout.apply(.toolCall(callID: "q", name: "request_user_input", detail: "Which branch?"), to: &s, now: Date())
        #expect(s.status == .needsYou(.question, detail: "Which branch?"))
        CodexRollout.apply(.toolCall(callID: "c", name: "exec_command", detail: "ls"), to: &s, now: Date())
        #expect(s.status.needsUser)
        CodexRollout.apply(.toolOutput(callID: "q"), to: &s, now: Date())
        #expect(s.status == .working)
    }

    @Test func interruptLeavesCodexAtItsPrompt() {
        var s = AgentRuntimeSnapshot(status: .working)
        CodexRollout.apply(.turnAborted(reason: "replaced"), to: &s, now: Date())
        #expect(s.status == .working)
        CodexRollout.apply(.turnAborted(reason: "interrupted"), to: &s, now: Date())
        #expect(s.status == .ready)
    }

    // MARK: Files

    @Test func findsTheSessionFileByCwdAndTime() throws {
        let home = try tempDir()
        let repo = try tempDir()
        let other = try tempDir()
        // A symlinked spelling of the same folder must still match (Codex records the real path).
        let link = home.appendingPathComponent("link-to-repo")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)

        let now = Date()
        let day = try dayDir(home, now)
        let launchedAt = now.addingTimeInterval(-2)
        let otherFile = try write(day, "rollout-a-0001.jsonl", meta(cwd: other.path))
        let oldFile = try write(day, "rollout-b-0002.jsonl", meta(cwd: repo.path))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: oldFile.path)
        let mine = try write(day, "rollout-c-0003.jsonl", meta(cwd: CodexRollout.canonicalPath(repo.path)) + "\n")
        _ = otherFile

        let found = CodexRollout.findRolloutFile(codexHome: home.path, cwd: link.path, launchedAt: launchedAt, now: now)
        #expect(found?.lastPathComponent == mine.lastPathComponent)
        #expect(CodexRollout.findRolloutFile(codexHome: home.path, cwd: repo.path, launchedAt: launchedAt, now: now,
                                             excluding: [mine.path]) == nil)
        #expect(CodexRollout.findRolloutFile(codexHome: home.path, cwd: "/nowhere", launchedAt: launchedAt, now: now) == nil)
        #expect(CodexRollout.findRolloutFile(codexHome: "/nonexistent-home", cwd: repo.path, launchedAt: launchedAt) == nil)
    }

    @Test func findsAFileByThreadID() throws {
        let home = try tempDir()
        let day = try dayDir(home, Date(timeIntervalSince1970: 1_700_000_000))
        let file = try write(day, "rollout-2023-11-14T22-13-20-01A1A089-2838-71b3-b34e-2d37bf48f53e.jsonl", "{}")
        #expect(CodexRollout.findRolloutFile(codexHome: home.path, threadID: "01a1a089-2838-71b3-b34e-2d37bf48f53e")?.path == file.path)
        #expect(CodexRollout.findRolloutFile(codexHome: home.path, threadID: "missing") == nil)
    }

    @Test func latestRateLimitsWalksBackPastNullReadings() throws {
        let home = try tempDir()
        let day = try dayDir(home, Date())
        let reading = #"{"timestamp":"2026-11-02T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1793707612}}}}"#
        let older = try write(day, "rollout-1.jsonl", [meta(cwd: "/a"), reading,
                                                       #"{"type":"event_msg","payload":{"type":"task_complete"}}"#].joined(separator: "\n"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100)], ofItemAtPath: older.path)
        _ = try write(day, "rollout-2.jsonl", [meta(cwd: "/b"),
                                               #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#].joined(separator: "\n"))
        let found = try #require(CodexRollout.latestRateLimits(codexHome: home.path))
        #expect(found.rateLimits.path("primary.used_percent")?.double == 12)
        #expect(found.at == CodexRollout.parseDate("2026-11-02T10:00:00Z"))
        #expect(CodexRollout.latestRateLimits(codexHome: try tempDir().path) == nil)
    }

    @Test func codexHomeForAccounts() {
        let system = Account(provider: .codex, label: "d", colorIndex: 0, isSystemDefault: true, configDir: "/ignored", authMethod: .existing)
        let managed = Account(provider: .codex, label: "m", colorIndex: 0, isSystemDefault: false, configDir: "/h/acc", authMethod: .browser)
        #expect(CodexRollout.codexHome(for: system, homeDirectory: "/Users/u") == "/Users/u/.codex")
        #expect(CodexRollout.codexHome(for: nil, homeDirectory: "/Users/u") == "/Users/u/.codex")
        #expect(CodexRollout.codexHome(for: managed, homeDirectory: "/Users/u") == "/h/acc")
    }

    @Test func dayDirectoriesCoverYesterday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 12))!
        let dirs = CodexRollout.dayDirectories(codexHome: "/h", around: [date]).map(\.path)
        #expect(dirs.contains("/h/sessions/2026/03/01"))
        #expect(dirs.contains("/h/sessions/2026/02/28"))
    }

    // MARK: Line splitting

    @Test func lineSplitterKeepsPartialLines() {
        var splitter = JSONLineSplitter()
        #expect(splitter.append(Data("{\"a\":1}\n{\"b\"".utf8)).map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#])
        #expect(splitter.append(Data(":2}\n\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == [#"{"b":2}"#])
        #expect(splitter.append(Data()).isEmpty)
        #expect(splitter.pending.isEmpty)
    }

    @Test func lineSplitterDropsOverlongLines() {
        var splitter = JSONLineSplitter(maxLineLength: 8)
        #expect(splitter.append(Data("0123456789".utf8)).isEmpty)
        #expect(splitter.append(Data("abc\nok\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["ok"])
        #expect(splitter.append(Data("0123456789abc\nfine\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["fine"])
    }

    @Test func readFirstLineHandlesLongLines() throws {
        let dir = try tempDir()
        let long = String(repeating: "x", count: 200_000)
        let file = try write(dir, "f.jsonl", long + "\nsecond")
        #expect(CodexRollout.readFirstLine(file)?.count == 200_000)
    }

    // MARK: Helpers

    private func meta(cwd: String) -> String {
        let quoted = String(data: try! JSONEncoder().encode(cwd), encoding: .utf8)!
        return Self.meta.replacingOccurrences(of: "\"CWD\"", with: quoted)
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hdlanes-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func dayDir(_ home: URL, _ date: Date) throws -> URL {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let url = home.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ dir: URL, _ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
