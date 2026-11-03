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
        let markdown = model.daySummaryMarkdown(for: day, events: events)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DatePicker(L.day, selection: $day, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .fixedSize()
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
                Text(markdown)
                    .font(Theme.monoSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
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
