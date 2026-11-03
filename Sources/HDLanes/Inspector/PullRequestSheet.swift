import AppKit
import HDCore
import SwiftUI

/// Push the session branch and open a pull request with `gh`.
struct PullRequestSheet: View {
    let sessionID: UUID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var bodyText = ""
    @State private var info: PullRequestInfo?
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var createdURL: URL?
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.prSheetTitle)
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(L.prBranches)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    branchesLabel
                }
                GridRow {
                    Text(L.prTitleField)
                        .foregroundStyle(.secondary)
                    TextField(L.prTitleField, text: $title)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking || createdURL != nil)
                }
                GridRow(alignment: .top) {
                    Text(L.prBodyField)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $bodyText)
                        .font(.system(size: 12))
                        .frame(minHeight: 140)
                        .padding(3)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                        .disabled(isWorking || createdURL != nil)
                }
            }

            messages

            HStack(spacing: 8) {
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text(L.prWorking)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let createdURL {
                    Button(L.done) { dismiss() }
                    Button(L.prOpen) { NSWorkspace.shared.open(createdURL) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L.cancel) {
                        work?.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(L.prCreate) { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(createDisabledReason != nil)
                        .help(createDisabledReason ?? L.createPRHelp)
                }
            }
        }
        .font(.system(size: 13))
        .padding(20)
        .frame(width: 500)
        .task { await load() }
    }

    @ViewBuilder
    private var branchesLabel: some View {
        if let info {
            Text(verbatim: "\(info.head ?? "?") \u{2192} \(info.base ?? L.prDefaultBase)")
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L.prChecking).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let problem = info?.problem {
            Label(L.describe(problem), systemImage: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if let n = info?.uncommittedCount, n > 0, createdURL == nil {
            Label(L.prUncommitted(n), systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        if let errorText {
            Text(verbatim: errorText)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let createdURL {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(L.prCreated)
                Text(verbatim: createdURL.absoluteString)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var createDisabledReason: String? {
        guard let info else { return L.prChecking }
        if let problem = info.problem { return L.describe(problem) }
        if isWorking { return L.prWorking }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L.prTitleRequired }
        return nil
    }

    private func load() async {
        if let session = model.session(sessionID) {
            if title.isEmpty { title = session.title }
            if bodyText.isEmpty {
                let taskNotes = model.task(session.taskID)?.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
                bodyText = (taskNotes?.isEmpty == false ? taskNotes : session.initialPrompt) ?? ""
            }
        }
        info = await model.pullRequestInfo(sessionID: sessionID)
    }

    private func create() {
        guard createDisabledReason == nil else { return }
        errorText = nil
        isWorking = true
        let title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = bodyText
        work = Task {
            do {
                createdURL = try await model.createPullRequest(sessionID: sessionID, title: title, body: body)
            } catch is CancellationError {
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isWorking = false
        }
    }
}
