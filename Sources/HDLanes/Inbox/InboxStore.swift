import Foundation
import HDCore
import Observation

/// Inbox state. Items stay in memory only: message summaries are never written to disk.
@MainActor @Observable
final class InboxStore {
    var items: [Inbox.Item] = []
    var isRefreshing = false
    var error: String?
    var updatedAt: Date?
    /// Ids hidden with Dismiss or answered, until the app quits.
    var hidden: Set<String> = []
    var availableTools: [String] = []
    var isLoadingTools = false
    var toolsError: String?
    /// "name (status)" of MCP servers that aren't connected for the inbox account.
    var unavailableServers: [String] = []
    var sending: Set<String> = []
    var sendErrors: [String: String] = [:]

    var visibleItems: [Inbox.Item] { items.filter { !hidden.contains($0.id) } }
}
