import Foundation
import Testing
@testable import HDCore

private func j(_ text: String) -> JSONValue {
    (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
}

/// Payload with the fields every hook carries, plus `extra`.
private func hook(_ event: String, _ extra: String = "") -> JSONValue {
    let common = #""session_id":"sess-1","transcript_path":"/t.jsonl","cwd":"/repo","hook_event_name":"\#(event)""#
    return j("{" + common + (extra.isEmpty ? "" : "," + extra) + "}")
}

private struct Harness {
    var reducer = ClaudeEventReducer()
    var s = AgentRuntimeSnapshot(status: .starting)
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    mutating func send(_ event: String, _ extra: String = "") {
        clock = clock.addingTimeInterval(1)
        reducer.apply(event: event, payload: hook(event, extra), to: &s, now: clock)
    }

    mutating func osc(_ state: String, _ kind: String? = nil, _ message: String? = nil, authoritative: Bool = false) {
        reducer.applyProgramStatus(state: state, kind: kind, message: message, to: &s, now: clock, authoritative: authoritative)
    }
}

struct ClaudeEventReducerTests {
    @Test func subagentLifecycle() {
        var h = Harness()
        h.send("SessionStart", #""source":"startup""#)
        #expect(h.s.status == .ready)
        #expect(h.s.agentSessionID == "sess-1")
        h.send("UserPromptSubmit", #""prompt":"Find the Swift files""#)
        #expect(h.s.status == .working)
        #expect(h.s.lastPrompt == "Find the Swift files")

        h.send("PreToolUse", #""tool_name":"Agent","tool_use_id":"t1","tool_input":{"description":"Find Swift files","prompt":"Search the repo","subagent_type":"Explore"}"#)
        h.send("SubagentStart", #""agent_id":"a1","agent_type":"Explore""#)
        #expect(h.s.subagents.count == 1)
        #expect(h.s.subagents[0].description == "Find Swift files")
        #expect(h.s.subagents[0].type == "Explore")
        #expect(h.s.runningSubagents.count == 1)

        h.send("PreToolUse", #""tool_name":"Glob","tool_use_id":"t2","tool_input":{"pattern":"**/*.swift"},"agent_id":"a1","agent_type":"Explore""#)
        #expect(h.s.subagents[0].currentTool == "Glob")
        #expect(h.s.subagents[0].currentToolDetail == "**/*.swift")
        #expect(h.s.subagents[0].toolCount == 1)
        #expect(h.s.activity.last?.agentID == "a1")
        #expect(h.s.activity.last?.isRunning == true)
        h.send("PostToolUse", #""tool_name":"Glob","tool_use_id":"t2","tool_input":{"pattern":"**/*.swift"},"tool_response":{"filenames":[]},"agent_id":"a1""#)
        #expect(h.s.activity.first { $0.id == "t2" }?.isRunning == false)

        h.send("SubagentStop", #""agent_id":"a1","agent_type":"Explore","agent_transcript_path":"/sub/agent-a1.jsonl","last_assistant_message":"Found 12 files","background_tasks":[]"#)
        #expect(h.s.subagents[0].isRunning == false)
        #expect(h.s.subagents[0].lastMessage == "Found 12 files")
        #expect(h.s.subagents[0].transcriptPath == "/sub/agent-a1.jsonl")
        #expect(h.s.subagents[0].endedAt != nil)
        #expect(h.s.status == .working)

        h.send("PostToolUse", #""tool_name":"Agent","tool_use_id":"t1","tool_input":{"description":"Find Swift files"}"#)
        h.send("Stop", #""last_assistant_message":"There are 12 Swift files.","background_tasks":[],"stop_hook_active":false"#)
        #expect(h.s.status == .done)
        #expect(h.s.lastAssistantMessage == "There are 12 Swift files.")
        #expect(h.s.activity.map(\.id) == ["t1", "t2"])
        #expect(h.s.activity.allSatisfy { !$0.isRunning })
        #expect(h.s.activity[0].detail == "Find Swift files")
    }

    @Test func agentDescriptionsPairFIFO() {
        var h = Harness()
        h.send("UserPromptSubmit", #""prompt":"go""#)
        h.send("PreToolUse", #""tool_name":"Agent","tool_use_id":"t1","tool_input":{"description":"first"}"#)
        h.send("PreToolUse", #""tool_name":"Task","tool_use_id":"t2","tool_input":{"description":"second"}"#)
        h.send("SubagentStart", #""agent_id":"a1","agent_type":"general-purpose""#)
        h.send("SubagentStart", #""agent_id":"a2","agent_type":"Explore""#)
        #expect(h.s.subagents.map(\.description) == ["first", "second"])
        h.send("SubagentStart", #""agent_id":"a3""#)
        #expect(h.s.subagents.last?.description == nil)
        #expect(h.s.subagents.last?.type == "agent")
    }

    @Test func subagentToolWithoutStartStillShows() {
        var h = Harness()
        h.send("PreToolUse", #""tool_name":"Read","tool_use_id":"t1","tool_input":{"file_path":"/a/b/c/File.swift"},"agent_id":"zz","agent_type":"Plan""#)
        #expect(h.s.subagents.first?.id == "zz")
        #expect(h.s.subagents.first?.type == "Plan")
        #expect(h.s.subagents.first?.currentToolDetail == "c/File.swift")
    }

    @Test func permissionRequestNeedsYouUntilTheToolRuns() throws {
        var h = Harness()
        h.send("UserPromptSubmit", #""prompt":"test""#)
        h.send("PreToolUse", #""tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"npm test"}"#)
        h.send("PermissionRequest", #""tool_name":"Bash","tool_input":{"command":"npm test"},"permission_suggestions":[]"#)
        #expect(h.s.status == .needsYou(.permission, detail: "Bash: npm test"))
        let pending = try #require(h.s.pendingPermission)
        #expect(pending.tool == "Bash")
        #expect(pending.detail == "npm test")
        #expect(pending.canAnswer == false)

        // A subagent working in parallel doesn't hide the prompt.
        h.send("PreToolUse", #""tool_name":"Grep","tool_use_id":"t9","tool_input":{"pattern":"x"},"agent_id":"a1""#)
        #expect(h.s.status.needsUser)
        // A different tool finishing doesn't either.
        h.send("PostToolUse", #""tool_name":"Bash","tool_use_id":"t8","tool_input":{"command":"ls"}"#)
        #expect(h.s.pendingPermission != nil)

        h.send("PostToolUse", #""tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"npm test"}"#)
        #expect(h.s.pendingPermission == nil)
        #expect(h.s.status == .working)
    }

    @Test func permissionClearedByFailurePromptStopAndEnd() {
        for clearing in ["PostToolUseFailure", "UserPromptSubmit", "Stop", "SessionEnd"] {
            var h = Harness()
            h.send("PermissionRequest", #""tool_name":"Write","tool_input":{"file_path":"/r/a/b.txt","content":"x"}"#)
            #expect(h.s.pendingPermission?.detail == "a/b.txt")
            let extra = clearing == "PostToolUseFailure" ? #""tool_name":"Write","tool_use_id":"t1","tool_input":{"file_path":"/r/a/b.txt"},"error":"denied""# : ""
            h.send(clearing, extra)
            #expect(h.s.pendingPermission == nil, "\(clearing)")
            #expect(!h.s.status.needsUser, "\(clearing)")
        }
    }

    @Test func resolvingPermissionResumesWork() {
        var h = Harness()
        h.send("PermissionRequest", #""tool_name":"Bash","tool_input":{"command":"rm -rf build"}"#)
        h.s.pendingPermission?.canAnswer = true
        h.reducer.resolvePermission(in: &h.s)
        #expect(h.s.pendingPermission == nil)
        #expect(h.s.status == .working)
        // Later subagent events don't bring the prompt back.
        h.send("PreToolUse", #""tool_name":"Glob","tool_use_id":"t2","tool_input":{"pattern":"*"},"agent_id":"a""#)
        #expect(h.s.status == .working)
    }

    @Test func connectionCloseKeepsCardButNotAnswerable() {
        var h = Harness()
        h.send("PermissionRequest", #""tool_name":"Bash","tool_input":{"command":"make"}"#)
        h.s.pendingPermission?.canAnswer = true
        h.reducer.permissionConnectionClosed(in: &h.s)
        #expect(h.s.pendingPermission?.canAnswer == false)
        #expect(h.s.status.needsUser)
    }

    @Test func askUserQuestionIsAQuestionNotAPermission() {
        var h = Harness()
        let input = #""tool_input":{"questions":[{"question":"Which database?","header":"DB","options":[]}]}"#
        h.send("PreToolUse", #""tool_name":"AskUserQuestion","tool_use_id":"q1","# + input)
        #expect(h.s.status == .needsYou(.question, detail: "Which database?"))
        h.send("PermissionRequest", #""tool_name":"AskUserQuestion","# + input)
        #expect(h.s.pendingPermission == nil)
        #expect(h.s.status == .needsYou(.question, detail: "Which database?"))
        h.send("PreToolUse", #""tool_name":"Grep","tool_use_id":"g","tool_input":{"pattern":"x"},"agent_id":"a""#)
        #expect(h.s.status.needsUser)
        h.send("PostToolUse", #""tool_name":"AskUserQuestion","tool_use_id":"q1","# + input)
        #expect(h.s.status == .working)
    }

    @Test func notifications() {
        var h = Harness()
        h.send("UserPromptSubmit", #""prompt":"x""#)
        h.send("Notification", #""notification_type":"permission_prompt","message":"Claude needs your permission to use Bash""#)
        #expect(h.s.status == .needsYou(.permission, detail: "Claude needs your permission to use Bash"))
        // The main agent moving on means it was answered in the terminal.
        h.send("PreToolUse", #""tool_name":"Read","tool_use_id":"r","tool_input":{"file_path":"/x"}"#)
        #expect(h.s.status == .working)

        h.send("Notification", #""notification_type":"elicitation_dialog","message":"Pick one""#)
        #expect(h.s.status == .needsYou(.question, detail: "Pick one"))
        h.send("UserPromptSubmit", #""prompt":"y""#)
        h.send("Notification", #""notification_type":"agent_needs_input","message":"Waiting""#)
        #expect(h.s.status == .needsYou(.input, detail: "Waiting"))
        h.send("UserPromptSubmit", #""prompt":"z""#)
        h.send("Notification", #""notification_type":"idle_prompt","message":"Claude is waiting""#)
        #expect(h.s.status == .done)
        h.send("Notification", #""notification_type":"something_new""#)
        #expect(h.s.status == .done)
    }

    @Test func permissionPromptNotificationDoesNotOverrideHookDetail() {
        var h = Harness()
        h.send("PermissionRequest", #""tool_name":"Bash","tool_input":{"command":"make"}"#)
        h.send("Notification", #""notification_type":"permission_prompt","message":"generic""#)
        #expect(h.s.status == .needsYou(.permission, detail: "Bash: make"))
    }

    @Test func stopWithBackgroundTasksKeepsWorkingUntilTheyEnd() {
        var h = Harness()
        h.send("UserPromptSubmit", #""prompt":"x""#)
        h.send("PreToolUse", #""tool_name":"Agent","tool_use_id":"t1","tool_input":{"description":"bg","run_in_background":true}"#)
        h.send("SubagentStart", #""agent_id":"a1","agent_type":"general-purpose""#)
        h.send("PostToolUse", #""tool_name":"Agent","tool_use_id":"t1","tool_input":{"description":"bg"}"#)
        h.send("Stop", #""last_assistant_message":"Started it","background_tasks":[{"id":"a1"}]"#)
        #expect(h.s.status == .working)
        #expect(h.s.backgroundTasks == 1)
        h.send("SubagentStop", #""agent_id":"a1","last_assistant_message":"bg done""#)
        #expect(h.s.backgroundTasks == 0)
        #expect(h.s.status == .done)
    }

    @Test func stopFailure() {
        var h = Harness()
        h.send("UserPromptSubmit", #""prompt":"x""#)
        h.send("StopFailure", #""error":"rate_limit""#)
        #expect(h.s.status == .error("rate_limit"))
        h.send("UserPromptSubmit", #""prompt":"x""#)
        h.send("StopFailure", #""error":"authentication_failed""#)
        #expect(h.s.status == .needsYou(.auth, detail: "authentication_failed"))
        h.send("StopFailure", #""error":{"type":"overloaded"}"#)
        #expect(h.s.status == .error("overloaded"))
        h.send("StopFailure")
        #expect(h.s.status == .error("unknown"))
    }

    @Test func sessionStartCompactDoesNotEndTheTurn() {
        var h = Harness()
        h.send("UserPromptSubmit", #""prompt":"x""#)
        h.send("SessionStart", #""source":"compact""#)
        #expect(h.s.status == .working)
        h.send("SessionStart", #""source":"clear""#)
        #expect(h.s.status == .ready)
        #expect(h.s.lastPrompt == nil)
    }

    @Test func sessionEndExits() {
        var h = Harness()
        h.send("SubagentStart", #""agent_id":"a1""#)
        h.send("SessionEnd", #""reason":"prompt_input_exit""#)
        #expect(h.s.status == .exited(nil))
        #expect(h.s.runningSubagents.isEmpty)
    }

    @Test func sessionIDFollowsClear() {
        var h = Harness()
        h.reducer.apply(event: "SessionStart", payload: j(#"{"session_id":"new-id","source":"clear"}"#), to: &h.s, now: h.clock)
        #expect(h.s.agentSessionID == "new-id")
    }

    @Test func lateToolEventsDoNotReviveFinishedTurn() {
        var h = Harness()
        let stamp = ClaudeHookPayload.stampKey
        h.send("UserPromptSubmit", #""prompt":"x""#)
        h.send("Stop", #""background_tasks":[],"\#(stamp)":2000"#)
        #expect(h.s.status == .done)
        h.send("PreToolUse", #""tool_name":"Bash","tool_use_id":"late","tool_input":{"command":"ls"},"\#(stamp)":1990"#)
        #expect(h.s.status == .done)
        #expect(h.s.activity.last?.isRunning == false)
        h.send("PostToolUse", #""tool_name":"Bash","tool_use_id":"late","tool_input":{"command":"ls"},"\#(stamp)":1995"#)
        #expect(h.s.status == .done)
        // A new turn's tools still count.
        h.send("PreToolUse", #""tool_name":"Bash","tool_use_id":"new","tool_input":{"command":"ls"},"\#(stamp)":3000"#)
        #expect(h.s.status == .working)
    }

    @Test func postBeforePreStaysFinished() {
        var h = Harness()
        h.send("PostToolUse", #""tool_name":"Read","tool_use_id":"t1","tool_input":{"file_path":"/x/y.txt"}"#)
        h.send("PreToolUse", #""tool_name":"Read","tool_use_id":"t1","tool_input":{"file_path":"/x/y.txt"}"#)
        #expect(h.s.activity.count == 1)
        #expect(h.s.activity[0].isRunning == false)
        h.send("PostToolUseFailure", #""tool_name":"Bash","tool_use_id":"t2","tool_input":{"command":"false"}"#)
        #expect(h.s.activity.last?.failed == true)
    }

    @Test func activityIsCapped() {
        var h = Harness()
        for i in 0..<(AgentRuntimeSnapshot.activityLimit + 25) {
            h.send("PreToolUse", #""tool_name":"Read","tool_use_id":"t\#(i)","tool_input":{"file_path":"/f\#(i)"}"#)
        }
        #expect(h.s.activity.count == AgentRuntimeSnapshot.activityLimit)
        #expect(h.s.activity.first?.id == "t25")
    }

    @Test func missingToolUseIDGetsSyntheticOne() {
        var h = Harness()
        h.send("PreToolUse", #""tool_name":"Bash","tool_input":{"command":"ls"}"#)
        h.send("PostToolUse", #""tool_name":"Bash","tool_input":{"command":"ls"}"#)
        #expect(h.s.activity.count == 1)
        #expect(h.s.activity[0].isRunning == false)
        h.reducer.apply(event: "PreToolUse", payload: .null, to: &h.s, now: h.clock)
        #expect(h.s.activity.count == 2)
    }

    // MARK: OSC 7501

    @Test func oscAloneDrivesStatusBeforeHooks() {
        var h = Harness()
        h.osc("idle", authoritative: true)
        #expect(h.s.status == .ready)
        h.osc("working", authoritative: true)
        #expect(h.s.status == .working)
        h.osc("blocked", "permission", "Allow Bash?", authoritative: true)
        #expect(h.s.status == .needsYou(.permission, detail: "Allow Bash?"))
        h.osc("working", authoritative: true)
        #expect(h.s.status == .working)
        h.osc("idle", authoritative: true)
        #expect(h.s.status == .done)
        h.osc("error", nil, "boom", authoritative: true)
        #expect(h.s.status == .error("boom"))
    }

    @Test func oscRefinesHooks() {
        var h = Harness()
        h.send("UserPromptSubmit", #""prompt":"x""#)
        #expect(h.reducer.hasReceivedEvents)
        h.osc("blocked", "question", "Which one?")
        #expect(h.s.status == .needsYou(.question, detail: "Which one?"))
        h.osc("working")
        #expect(h.s.status == .working)
        // Non-authoritative idle/error leave a working session to the hooks.
        h.osc("idle")
        #expect(h.s.status == .working)
        h.osc("error", nil, "x")
        #expect(h.s.status == .working)
    }

    @Test func oscWorkingClearsAPermissionAnsweredInTheTerminal() {
        var h = Harness()
        h.send("PermissionRequest", #""tool_name":"Bash","tool_input":{"command":"make"}"#)
        h.s.pendingPermission?.canAnswer = true
        h.osc("working")
        #expect(h.s.pendingPermission != nil, "the hook is still waiting for us")
        h.reducer.permissionConnectionClosed(in: &h.s)
        h.osc("working")
        #expect(h.s.pendingPermission == nil)
        #expect(h.s.status == .working)
    }

    @Test func oscIdleAfterDeniedInTerminal() {
        var h = Harness()
        h.send("PermissionRequest", #""tool_name":"Bash","tool_input":{"command":"make"}"#)
        h.osc("idle")
        #expect(h.s.status == .done)
        #expect(h.s.pendingPermission == nil)
    }

    @Test func oscIgnoredAfterExit() {
        var h = Harness()
        h.send("SessionEnd")
        h.osc("working", authoritative: true)
        #expect(h.s.status == .exited(nil))
    }

    // MARK: Summaries

    @Test func toolSummaries() {
        func d(_ tool: String, _ input: String) -> String { ClaudeToolSummary.detail(tool: tool, input: j(input)) }
        #expect(d("Bash", #"{"command":"  npm test\n&& echo ok"}"#) == "npm test …")
        #expect(d("Bash", #"{"command":"ls"}"#) == "ls")
        #expect(d("Read", #"{"file_path":"/Users/u/repo/Sources/App/Main.swift"}"#) == "App/Main.swift")
        #expect(d("Edit", #"{"file_path":"Main.swift","old_string":"a"}"#) == "Main.swift")
        #expect(d("Write", #"{"file_path":"/a/b.txt","content":"x"}"#) == "a/b.txt")
        #expect(d("Grep", #"{"pattern":"TODO","path":"/x"}"#) == "TODO")
        #expect(d("Glob", #"{"pattern":"**/*.md"}"#) == "**/*.md")
        #expect(d("WebFetch", #"{"url":"https://example.com/a","prompt":"x"}"#) == "https://example.com/a")
        #expect(d("Agent", #"{"description":"Explore code","prompt":"long"}"#) == "Explore code")
        #expect(d("mcp__x__y", #"{"b":2,"a":"/p"}"#) == #"{"a":"/p","b":2}"#)
        #expect(d("Bash", #"{"timeout":5}"#) == #"{"timeout":5}"#)
        #expect(d("Read", "{}") == "")
        let long = String(repeating: "x", count: 300)
        let summary = d("Bash", #"{"command":"\#(long)"}"#)
        #expect(summary.count == ClaudeToolSummary.maxLength)
        #expect(summary.hasSuffix("…"))
        #expect(ClaudeToolSummary.detail(tool: "Bash", input: nil) == "")
    }

    @Test func slimPayload() {
        let big = String(repeating: "a", count: 10_000)
        let payload = j(#"{"tool_name":"Write","tool_input":{"file_path":"/x","content":"\#(big)"},"tool_response":{"x":1},"last_assistant_message":"\#(big)"}"#)
        let slim = ClaudeHookPayload.slim(payload, stamp: 123)
        #expect(slim["tool_response"] == nil)
        #expect(slim["tool_input"]?["content"]?.string?.count == 4097)
        #expect(slim["tool_input"]?["file_path"]?.string == "/x")
        #expect(slim["last_assistant_message"]?.string?.count == 10_000)
        #expect(slim[ClaudeHookPayload.stampKey]?.double == 123)
        #expect(ClaudeHookPayload.slim(.string("x")) == .string("x"))
    }
}
