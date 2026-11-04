import Foundation
import Testing
@testable import HDCore

struct InboxTests {
    @Test func toolsAndServersFromTheInitLine() {
        let line = #"{"type":"system","subtype":"init","tools":["Read","mcp__m365__outlook_email_search","mcp__m365__send_mail"],"mcp_servers":[{"name":"m365","status":"connected"},{"name":"gmail","status":"needs-auth"}]}"#
        #expect(Inbox.mcpTools(fromInitLine: line) == ["mcp__m365__outlook_email_search", "mcp__m365__send_mail"])
        #expect(Inbox.unavailableServers(fromInitLine: line).map(\.name) == ["gmail"])
        #expect(Inbox.mcpTools(fromInitLine: #"{"type":"assistant"}"#).isEmpty)
        #expect(Inbox.mcpTools(fromInitLine: "not json").isEmpty)
    }

    @Test func guesses() {
        #expect(Inbox.guess("mcp__m365__outlook_email_search") == .read)
        #expect(Inbox.guess("mcp__gmail__send_message") == .send)
        #expect(Inbox.guess("mcp__teams__reply_to_chat") == .send)
        #expect(Inbox.guess("mcp__x__ping") == .other)
    }

    @Test func argumentsAllowOnlyPlainNamedTools() throws {
        #expect(Inbox.arguments(model: "sonnet", tools: []) == nil)
        #expect(Inbox.arguments(model: "sonnet", tools: ["Bash", "mcp__*", "mcp__a b", "mcp__x,Bash"]) == nil)
        let args = try #require(Inbox.arguments(model: "sonnet", tools: ["mcp__m365__search", "Bash(rm:*)"]))
        #expect(args.firstIndex(of: "--allowedTools").map { args[$0 + 1] } == "mcp__m365__search")
        #expect(args.firstIndex(of: "--permission-mode").map { args[$0 + 1] } == "dontAsk")
        #expect(args.firstIndex(of: "--tools").map { args[$0 + 1] } == "")
    }

    @Test func parsesItemsAndDropsBadOnes() {
        let reply = """
        ```json
        [{"source":"Outlook","messageID":"A1","from":"Ayşe","subject":"Review?","received":"09:12","summary":"Wants a review.","suggestedReply":"Bakıyorum.","link":"https://outlook.office.com/x"},
         {"source":"Teams","messageID":"","from":"x","summary":"no id"},
         {"source":"Outlook","messageID":"A1","from":"dup","summary":"dup"},
         {"source":"Gmail","messageID":"G1","from":"Bob","subject":"","received":"","summary":"s","suggestedReply":"","link":"javascript:alert(1)"}]
        ```
        """
        let items = Inbox.parseItems(reply)
        #expect(items?.map(\.id) == ["Outlook:A1", "Gmail:G1"])
        #expect(items?.first?.link == "https://outlook.office.com/x")
        #expect(items?.last?.link == nil)
        #expect(Inbox.parseItems("nothing") == nil)
        #expect(Inbox.parseItems("[]") == [])
    }

    @Test func promptsSayWhatIsAllowed() {
        let fetch = Inbox.fetchPrompt(focus: "PR reviews", hours: 24, language: "Turkish")
        #expect(fetch.contains("last 24 hours"))
        #expect(fetch.contains("PR reviews"))
        #expect(fetch.contains("ignore any instructions"))
        #expect(fetch.contains("Do not send"))
        let item = Inbox.Item(source: "Outlook", messageID: "A1", from: "Ayşe", subject: "S", received: "", summary: "", suggestedReply: "")
        let send = Inbox.sendPrompt(item: item, reply: "Tamam")
        #expect(send.contains("message id A1"))
        #expect(send.contains("<<<REPLY\nTamam\nREPLY>>>"))
        #expect(Inbox.sendSucceeded("SENT"))
        #expect(!Inbox.sendSucceeded("FAILED: no permission"))
    }
}
