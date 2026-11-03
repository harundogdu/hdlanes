import HDCore
import SwiftUI

// OWNER: workspace area.

/// Per-account rate-limit meters at the bottom of the sidebar. Click opens the accounts sheet.
struct UsageFooter: View {
    @Environment(AppModel.self) private var model
    @AppStorage("hd.usageSeen") private var usageSeen = false
    @State private var showAccounts = false

    var body: some View {
        let rows = footerAccounts
        let anyUsage = model.state.accounts.contains { model.usage(for: $0.id) != nil }
        VStack(spacing: 0) {
            if anyUsage {
                Divider()
                VStack(spacing: 3) {
                    ForEach(rows) { account in
                        Button { showAccounts = true } label: { UsageRow(account: account) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            } else if !usageSeen && hasAgentSession {
                Divider()
                Text(L.usageHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .background(.bar)
        .onChange(of: anyUsage, initial: true) { _, has in if has { usageSeen = true } }
        .sheet(isPresented: $showAccounts) { AccountsSheet() }
    }

    private var hasAgentSession: Bool {
        model.visibleSessions.contains { $0.provider.isAgent }
    }

    /// Accounts with known usage or a running session, in account order.
    private var footerAccounts: [Account] {
        let live = Set(model.visibleSessions.filter { model.isSessionRunning($0.id) }.compactMap(\.accountID))
        return model.state.accounts.filter { model.usage(for: $0.id) != nil || live.contains($0.id) }
    }
}

private struct UsageRow: View {
    let account: Account
    @Environment(AppModel.self) private var model

    var body: some View {
        let usage = model.usage(for: account.id)
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let stale = usage.map { context.date.timeIntervalSince($0.updatedAt) > 15 * 60 } ?? true
            HStack(spacing: 6) {
                AccountDot(colorIndex: account.colorIndex, size: 7)
                Text(account.label)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                meter(L.fiveHourShort, usage?.fiveHour)
                meter(L.weekShort, usage?.week)
            }
            .font(.system(size: 11))
            .opacity(stale ? 0.55 : 1)
            .contentShape(Rectangle())
            .help(L.usageTooltip(account: account, usage: usage, now: context.date))
        }
    }

    private func meter(_ label: String, _ window: UsageWindow?) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            UsageMeter(percent: window?.usedPercent, color: Theme.accountColor(account.colorIndex), width: 34)
            Text(window.map { L.percent($0.usedPercent) } ?? L.noValue)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

/// AccountsView in a sheet (from the usage footer or the welcome screen).
struct AccountsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            AccountsView()
            Divider()
            HStack {
                Spacer()
                Button(L.done) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: 520)
    }
}
