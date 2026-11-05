import Foundation
import HDCore

// OWNER: inbox area. Messages that need the user, read and answered through a Claude account's MCP
// connectors (see ARCHITECTURE "Inbox"). Every run is a click; sending needs a confirmed text.
extension AppModel {
    var inboxAccount: Account? {
        account(state.settings.inboxAccount).flatMap { $0.provider == .claude ? $0 : nil }
    }

    var inboxReadTools: [String] { (state.settings.inboxReadTools ?? []).filter(Inbox.isPlainToolName) }
    var inboxSendTool: String? { state.settings.inboxSendTool.flatMap { Inbox.isPlainToolName($0) ? $0 : nil } }
    var inboxIsSetUp: Bool { inboxAccount != nil && !inboxReadTools.isEmpty }

    /// Reads the account's MCP tool names from the `init` event of a tiny run (no tools allowed).
    func loadInboxTools() async {
        guard let account = inboxAccount else { return }
        inbox.isLoadingTools = true
        inbox.toolsError = nil
        defer { inbox.isLoadingTools = false }
        let result = await runAccountCLI(account, arguments: Inbox.toolListArguments,
                                         stdin: Data("Reply with OK.".utf8), timeout: 90)
        if result.launchFailed || AccountCLI.isCommandNotFound(status: result.status, output: result.combined) {
            inbox.toolsError = WorkspaceError.cliMissing(.claude).errorDescription
            return
        }
        let line = result.stdout.split(separator: "\n").first.map(String.init) ?? ""
        let tools = Inbox.mcpTools(fromInitLine: line)
        inbox.availableTools = tools
        inbox.unavailableServers = Inbox.unavailableServers(fromInitLine: line).map { "\($0.name) (\($0.status))" }
        // Claude started but has no MCP tools: say so, not the raw init line it printed first.
        if tools.isEmpty {
            inbox.toolsError = Inbox.isInitLine(line) ? L.inboxNoTools : (result.firstErrorLine() ?? L.inboxNoTools)
        }
    }

    func refreshInbox() async {
        guard let account = inboxAccount, !inbox.isRefreshing,
              let args = Inbox.arguments(model: "sonnet", tools: inboxReadTools,
                                         deny: [inboxSendTool].compactMap { $0 }) else { return }
        inbox.isRefreshing = true
        inbox.error = nil
        defer { inbox.isRefreshing = false }
        let prompt = Inbox.fetchPrompt(focus: state.settings.inboxFocus ?? "", hours: state.settings.inboxHours ?? 24,
                                       language: L.isTurkish ? "Turkish" : "English")
        let result = await runAccountCLI(account, arguments: args, stdin: Data(prompt.utf8), timeout: 300)
        if let problem = cliProblem(result) {
            inbox.error = problem
            return
        }
        guard let text = ClaudePrintOutput.result(from: result.stdout), let items = Inbox.parseItems(text) else {
            inbox.error = result.status != 0 ? (result.firstErrorLine() ?? L.inboxFailed) : L.inboxUnreadable
            return
        }
        inbox.items = items
        inbox.updatedAt = Date()
    }

    /// Sends `reply` to `item` with the configured send tool. Call only after the user confirmed it.
    func sendInboxReply(_ item: Inbox.Item, reply: String) async -> Bool {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account = inboxAccount, let tool = inboxSendTool, !text.isEmpty,
              !inbox.sending.contains(item.id),
              let args = Inbox.arguments(model: "sonnet", tools: [tool]) else { return false }
        inbox.sending.insert(item.id)
        inbox.sendErrors[item.id] = nil
        defer { inbox.sending.remove(item.id) }
        let result = await runAccountCLI(account, arguments: args,
                                         stdin: Data(Inbox.sendPrompt(item: item, reply: text).utf8), timeout: 180)
        if result.timedOut {
            // The tool may have fired before the timeout; hide the item so it isn't sent twice.
            // Hidden rows show no error: say it in the banner.
            inbox.error = L.inboxSendTimedOut
            inbox.hidden.insert(item.id)
            return false
        }
        if let problem = cliProblem(result) {
            inbox.sendErrors[item.id] = problem
            return false
        }
        let answer = ClaudePrintOutput.result(from: result.stdout) ?? ""
        guard Inbox.sendSucceeded(answer) else {
            inbox.sendErrors[item.id] = answer.isEmpty ? (result.firstErrorLine() ?? L.inboxSendFailed) : answer
            return false
        }
        inbox.hidden.insert(item.id)
        return true
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) { change(&state.settings) }

    func dismissInboxItem(_ item: Inbox.Item) { inbox.hidden.insert(item.id) }

    private func cliProblem(_ result: CLIResult) -> String? {
        if result.launchFailed || AccountCLI.isCommandNotFound(status: result.status, output: result.combined) {
            return WorkspaceError.cliMissing(.claude).errorDescription
        }
        if result.timedOut { return WorkspaceError.timedOut.errorDescription }
        return nil
    }
}
