import AppKit
import HDCore
import SwiftUI

// OWNER: tracking area. "Gün sonu": a markdown report of a day, to copy or save.

struct DaySummaryTab: View {
    @Environment(AppModel.self) private var model
    @State private var day = Date()
    @State private var events: [ActivityEvent] = []
    @State private var aiAccountID: UUID?
    @State private var aiText: String?
    @State private var aiError: String?
    @State private var aiRunning = false
    @State private var saveError: String?

    var body: some View {
        let summary = model.daySummary(for: day, events: events)
        let markdown = summary.markdown
        let isToday = Calendar.current.isDateInToday(day)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .help(L.sumPreviousDay)
                    .accessibilityLabel(L.sumPreviousDay)
                DatePicker(L.day, selection: $day, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .fixedSize()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .help(L.sumNextDay)
                    .accessibilityLabel(L.sumNextDay)
                    .disabled(isToday)
                Button(L.sumToday) { day = Date() }
                    .disabled(isToday)
                Spacer()
                Button(L.copy) { Panels.copy(markdown) }
                    .help(L.copyHelp)
                Button(L.saveEllipsisReport) { save(markdown) }
                    .help(L.saveReportHelp)
                Divider().frame(height: 16)
                Picker(L.account, selection: $aiAccountID) {
                    ForEach(model.accounts(for: .claude)) { a in
                        Text(a.label).tag(Optional(a.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(model.accounts(for: .claude).isEmpty)
                .help(L.aiAccountHelp)
                Button {
                    tidy(markdown)
                } label: {
                    if aiRunning { ProgressView().controlSize(.small) } else { Text(L.tidyWithAI) }
                }
                .disabled(aiRunning || selectedAccount == nil)
                .help(selectedAccount == nil ? L.aiNoAccount : L.tidyWithAIHelp)
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if let saveError {
                InlineError(text: saveError) { self.saveError = nil }
            }
            if aiText != nil || aiError != nil {
                AIResultBox(text: aiText, error: aiError) {
                    aiText = nil
                    aiError = nil
                }
            }
            Divider()
            ScrollView {
                DayReportView(title: summary.title, report: summary.report)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            if aiAccountID == nil { aiAccountID = model.aiCategorizationAccount?.id }
        }
        .task(id: "\(Calendar.current.startOfDay(for: day).timeIntervalSince1970)-\(model.tracking.activityVersion)") {
            let log = model.activityLog
            let chosen = day
            events = await Task.detached { log.events(on: chosen) }.value
        }
    }

    private func shift(_ days: Int) {
        let cal = Calendar.current
        guard let next = cal.date(byAdding: .day, value: days, to: day),
              cal.startOfDay(for: next) <= cal.startOfDay(for: Date()) else { return }
        // Today's date with the current time, so the picker's `...Date()` range keeps it.
        day = cal.isDateInToday(next) ? Date() : next
    }

    private var selectedAccount: Account? {
        model.account(aiAccountID).flatMap { $0.provider == .claude ? $0 : nil }
    }

    private func save(_ markdown: String) {
        do {
            let url = try model.saveDayReport(markdown, day: day)
            saveError = nil
            Panels.reveal(url.path)
        } catch {
            saveError = L.saveReportFailed(error.localizedDescription)
        }
    }

    private func tidy(_ markdown: String) {
        guard let account = selectedAccount else { return }
        aiRunning = true
        aiError = nil
        Task {
            do {
                aiText = try await model.tidyDaySummaryWithAI(markdown, account: account)
            } catch {
                aiError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            aiRunning = false
        }
    }
}

private struct InlineError: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
            Text(text).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(L.dismiss)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

private struct AIResultBox: View {
    let text: String?
    let error: String?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L.aiSummary)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let text {
                    Button(L.copy) { Panels.copy(text) }
                        .controlSize(.small)
                }
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(L.dismiss)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let text {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// The day's report as a page: the date, four sections with icons and counts, rows with chips.
private struct DayReportView: View {
    let title: String
    let report: DaySummary.Report
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            ReportSection(title: L.sumDone, symbol: "checkmark.circle", color: .green, count: report.done.count) {
                ForEach(report.done) { d in
                    let open = d.sessionID.flatMap { id in model.session(id).flatMap { $0.isArchived == true ? nil : id } }
                    Button { if let open { model.selection = .session(open) } } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(d.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                if let p = d.project { ReportChip(text: p, color: .secondary) }
                                if d.turns > 1 { ReportChip(text: L.sumTurns(d.turns), color: .blue) }
                                Spacer(minLength: 8)
                                Text(d.at, format: .dateTime.hour().minute())
                                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            if let r = d.result {
                                Text(Self.plain(r)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(open == nil)
                    .help(open == nil ? "" : L.sumOpenSession)
                }
            }
            ReportSection(title: L.sumPullRequests, symbol: "arrow.triangle.pull", color: .purple,
                          count: report.opened.count + report.merged.count) {
                ForEach(Array(report.opened.enumerated()), id: \.offset) { _, pr in prRow(pr, L.sumOpened, .blue) }
                ForEach(Array(report.merged.enumerated()), id: \.offset) { _, pr in prRow(pr, L.sumMerged, .purple) }
            }
            ReportSection(title: L.sumStillOpen, symbol: "exclamationmark.circle", color: .orange, count: report.stillOpen.count) {
                ForEach(Array(report.stillOpen.enumerated()), id: \.offset) { _, item in itemRow(item, .orange) }
            }
            ReportSection(title: L.sumTomorrow, symbol: "sunrise", color: .teal, count: report.tomorrow.count) {
                ForEach(Array(report.tomorrow.enumerated()), id: \.offset) { _, item in itemRow(item, .teal) }
            }
        }
    }

    /// Claude's reply without markdown marks (`**bold**`, `` `code` ``, `# heading`), for a one-line preview.
    /// `__` stays: it is as often part of a name (`__init__`) as emphasis.
    static func plain(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        while t.hasPrefix("#") { t.removeFirst() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private func prRow(_ pr: DaySummary.PullRequestLine, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            ReportChip(text: label, color: color)
            linkText(pr.title, pr.url)
            Spacer(minLength: 0)
        }
    }

    private func itemRow(_ item: DaySummary.Item, _ color: Color) -> some View {
        HStack(spacing: 8) {
            linkText(item.text, item.url)
            if let d = item.detail?.nilIfBlank { ReportChip(text: d, color: color) }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func linkText(_ text: String, _ url: String?) -> some View {
        if let url, url.hasPrefix("http") {
            Button { model.openInBrowser(url) } label: {
                Text(text).font(.system(size: 13)).lineLimit(1).underline(false)
            }
            .buttonStyle(.link)
        } else {
            Text(text).font(.system(size: 13)).lineLimit(1)
        }
    }
}

/// A section of the report: tinted icon, title, count, then its rows on a soft card ("Nothing" when empty).
private struct ReportSection<Rows: View>: View {
    let title: String
    let symbol: String
    let color: Color
    let count: Int
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(color.opacity(0.15)))
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(verbatim: "\(count)")
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
            VStack(alignment: .leading, spacing: 10) {
                if count == 0 {
                    Text(L.sumNothing).font(.system(size: 12)).foregroundStyle(.tertiary)
                } else {
                    rows()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        }
    }
}

private struct ReportChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}
