import HDCore
import SwiftUI

// OWNER: workspace area.

/// Per-account rate-limit meters at the bottom of the sidebar. Click opens the accounts sheet.
struct UsageFooter: View {
    @Environment(AppModel.self) private var model
    @AppStorage("hd.usageSeen") private var usageSeen = false
    @State private var showAccounts = false

    var body: some View {
        let anyUsage = model.state.accounts.contains { model.usage(for: $0.id) != nil }
        VStack(spacing: 0) {
            if anyUsage {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            if let title = group.title.nilIfBlank {
                                Text(title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(group.accounts) { account in
                                Button { showAccounts = true } label: { UsageRow(account: account) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
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
        .modifier(BarBackground(theme: model.appTheme))
        .onChange(of: anyUsage, initial: true) { _, has in if has { usageSeen = true } }
        .sheet(isPresented: $showAccounts) { AccountsSheet() }
    }

    private var hasAgentSession: Bool {
        model.visibleSessions.contains { $0.provider.isAgent }
    }

    /// Claude and Codex accounts grouped by the part of their name before " - " ("Fimple - Claude" →
    /// "Fimple"), groups in order of first appearance; ungrouped names come last under no title.
    private var groups: [(title: String, accounts: [Account])] {
        var out: [(title: String, accounts: [Account])] = []
        for account in model.state.accounts where account.provider.isAgent {
            let title = AccountGrouping.split(account.label).group ?? ""
            if let i = out.firstIndex(where: { $0.title == title }) { out[i].accounts.append(account) } else { out.append((title, [account])) }
        }
        return out.sorted { ($0.title.isEmpty ? 1 : 0) < ($1.title.isEmpty ? 1 : 0) }
    }
}

/// One account on one line: a chip with its color and name, its plan, then the 5-hour and weekly meters.
/// A window not known now shows "—"; an account that never reported shows "no data".
private struct UsageRow: View {
    let account: Account
    @Environment(AppModel.self) private var model

    var body: some View {
        let usage = model.usage(for: account.id)
        let name = AccountGrouping.split(account.label).name
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let stale = usage.map { context.date.timeIntervalSince($0.updatedAt) > 15 * 60 } ?? true
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle().fill(Theme.accountColor(account.colorIndex)).frame(width: 6, height: 6)
                    Text(name).lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.accountColor(account.colorIndex).opacity(0.16), in: Capsule())
                if let plan = usage?.plan ?? account.plan {
                    Text(plan.capitalized)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                }
                Spacer(minLength: 4)
                if let usage {
                    meter(L.fiveHourCompact, usage.percent(\.fiveHour, at: context.date))
                    meter(L.weekCompact, usage.percent(\.week, at: context.date))
                } else {
                    Text(L.usageNoData)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .opacity(stale ? 0.7 : 1)
            .contentShape(Rectangle())
            .help(L.usageTooltip(account: account, usage: usage, now: context.date))
        }
    }

    private func meter(_ label: String, _ percent: Double?) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            UsageMeter(percent: percent, color: meterColor(percent), width: 26)
            Text(percent.map { L.percent($0) } ?? L.noValue)
                .monospacedDigit()
                .foregroundStyle(percent == nil ? .tertiary : .secondary)
                .frame(minWidth: 26, alignment: .trailing)
        }
        .font(.system(size: 10))
        .fixedSize()
    }

    /// Account color normally; orange from 80 %, red at the limit, so a full window stands out.
    private func meterColor(_ percent: Double?) -> Color {
        guard let p = percent else { return Theme.accountColor(account.colorIndex) }
        if p >= 99.5 { return .red }
        if p >= 80 { return .orange }
        return Theme.accountColor(account.colorIndex)
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

/// `.bar`, or the theme's sidebar color.
struct BarBackground: ViewModifier {
    let theme: AppTheme?

    func body(content: Content) -> some View {
        if let theme { content.background(Theme.color(theme.sidebar)) } else { content.background(.bar) }
    }
}
