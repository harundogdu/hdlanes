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
                VStack(spacing: 6) {
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
        .modifier(BarBackground(theme: model.appTheme))
        .onChange(of: anyUsage, initial: true) { _, has in if has { usageSeen = true } }
        .sheet(isPresented: $showAccounts) { AccountsSheet() }
    }

    private var hasAgentSession: Bool {
        model.visibleSessions.contains { $0.provider.isAgent }
    }

    /// Every Claude and Codex account, in account order; one that hasn't run yet shows dimmed with "—",
    /// so a new account is there from the start.
    private var footerAccounts: [Account] {
        model.state.accounts.filter { $0.provider.isAgent }
    }
}

private struct UsageRow: View {
    let account: Account
    @Environment(AppModel.self) private var model

    var body: some View {
        let usage = model.usage(for: account.id)
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let stale = usage.map { context.date.timeIntervalSince($0.updatedAt) > 15 * 60 } ?? true
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    AccountDot(colorIndex: account.colorIndex, size: 7)
                    Text(account.label)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let plan = usage?.plan ?? account.plan {
                        Text(plan.capitalized)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 10) {
                    meter(L.fiveHourShort, usage?.fiveHour, now: context.date)
                    meter(L.weekShort, usage?.week, now: context.date)
                }
                .padding(.leading, 13)
            }
            .font(.system(size: 11))
            .opacity(stale ? 0.55 : 1)
            .contentShape(Rectangle())
            .help(L.usageTooltip(account: account, usage: usage, now: context.date))
        }
    }

    private func meter(_ label: String, _ window: UsageWindow?, now: Date) -> some View {
        let pct = window?.percent(at: now)
        return HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
                .fixedSize()
            UsageMeter(percent: pct, color: meterColor(pct), width: nil)
            Text(pct.map { L.percent($0) } ?? L.noValue)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
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
