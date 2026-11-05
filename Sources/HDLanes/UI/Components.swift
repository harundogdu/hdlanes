import AppKit
import HDCore
import SwiftUI

// OWNER: workspace area. Small building blocks shared by the sidebar, header, board and accounts.

enum ProviderStyle {
    static func symbol(_ p: Provider) -> String {
        switch p {
        case .claude: return "asterisk"
        case .codex: return "hexagon"
        case .shell: return "terminal"
        }
    }
}

/// Sidebar/header status glyph: spinner for working, orange dot for needs-you, green check for done,
/// red exclamation for errors, hollow circle otherwise.
struct StatusGlyph: View {
    let status: AgentStatus
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch status {
            case .working, .starting:
                ProgressView().controlSize(.small).scaleEffect(0.7)
            case .needsYou:
                Image(systemName: "circle.fill").foregroundStyle(.orange)
            case .done:
                Image(systemName: "checkmark").fontWeight(.bold).foregroundStyle(.green)
            case .error:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .ready, .notStarted, .exited:
                Image(systemName: "circle").foregroundStyle(Theme.color(for: status))
            }
        }
        .font(.system(size: size - 2))
        .frame(width: size + 2, height: size + 2)
        .help(L.statusText(status))
    }
}

struct AccountDot: View {
    let colorIndex: Int
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(Theme.accountColor(colorIndex)).frame(width: size, height: size)
    }
}

/// Color dot + label of an account (or a muted placeholder when it was removed).
struct AccountChip: View {
    let account: Account?

    var body: some View {
        HStack(spacing: 5) {
            if let account {
                AccountDot(colorIndex: account.colorIndex)
                Text(account.label).lineLimit(1)
            } else {
                Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 8, height: 8)
                Text(L.removedAccount).lineLimit(1)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .help(account.map(L.accountTooltip) ?? L.removedAccount)
    }
}

struct CategoryChip: View {
    let category: String

    var body: some View {
        Text(L.categoryName(category))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.categoryColor(category))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Theme.categoryColor(category).opacity(0.14), in: Capsule())
    }
}

/// Thin capsule meter for a usage window (0…100).
struct UsageMeter: View {
    let percent: Double?
    let color: Color
    /// Fixed width, or nil to fill the space offered.
    var width: CGFloat? = 46

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let percent {
                    Capsule().fill(color).frame(width: max(2, geo.size.width * min(1, max(0, percent / 100))))
                }
            }
        }
        .frame(width: width, height: 4)
        .frame(minWidth: 24)
    }
}

/// Relative time that refreshes once a minute.
struct RelativeTimeText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(L.relative(date, now: context.date))
        }
    }
}

/// Folder chooser and Finder helpers.
@MainActor
enum Panels {
    static func chooseFolder(message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Lets the user pick a folder and adds it as a project; returns its id.
    static func addProject(model: AppModel) async -> UUID? {
        guard let url = chooseFolder(message: L.addProjectMessage, prompt: L.add) else { return nil }
        return await model.addProjectReturningID(path: url.path)
    }
}

/// Empty state sized for side panels: small icon, one 13 pt line, a secondary sentence and at most one
/// action. `ContentUnavailableView`'s large title is out of scale next to a 13 pt list.
struct CompactEmptyState: View {
    let title: String
    let symbol: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .textSelection(.enabled)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
