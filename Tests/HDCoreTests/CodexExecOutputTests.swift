import Foundation
import Testing
@testable import HDCore

struct CodexExecOutputTests {
    // Shapes seen live with codex 0.166.0 (`codex exec --json`).
    @Test func lastAgentMessage() {
        let out = """
        {"type":"thread.started","thread_id":"t"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I'll check.\\n"}}
        {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"[{\\"file\\":\\"a.swift\\"}]"}}
        {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
        """
        #expect(CodexExecOutput.lastMessage(from: out) == #"[{"file":"a.swift"}]"#)
        #expect(CodexExecOutput.errorText(from: out) == nil)
        #expect(CodexExecOutput.lastMessage(from: "not json") == nil)
    }

    @Test func failures() {
        let failed = """
        {"type":"turn.started"}
        {"type":"turn.failed","error":{"message":"You've hit your usage limit."}}
        """
        #expect(CodexExecOutput.lastMessage(from: failed) == nil)
        #expect(CodexExecOutput.errorText(from: failed) == "You've hit your usage limit.")
        #expect(CodexExecOutput.errorText(from: #"{"type":"error","message":"stream disconnected"}"#) == "stream disconnected")
        // A retried stream error, then the turn completes: the reply counts and there is no failure.
        let recovered = [
            #"{"type":"error","message":"Reconnecting... 1/5"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"[]"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}"#,
        ].joined(separator: "\n")
        #expect(CodexExecOutput.lastMessage(from: recovered) == "[]")
        #expect(CodexExecOutput.errorText(from: recovered) == nil)
    }

    @Test func argumentsKeepCodexBoxedIn() {
        let a = CrossCheck.codexArguments
        #expect(a.first == "exec" && a.last == "-")
        #expect(a.firstIndex(of: "--sandbox").map { a[$0 + 1] } == "read-only")
        for flag in ["--ignore-user-config", "--ephemeral", "--ignore-rules", "--json"] { #expect(a.contains(flag)) }
        let disabled = a.indices.filter { a[$0] == "--disable" }.map { a[$0 + 1] }
        #expect(disabled.contains("shell_tool") && disabled.contains("unified_exec"))
        #expect(a.contains(#"approval_policy="never""#) && a.contains("project_doc_max_bytes=0"))
    }
}
