import HDCore
import SwiftUI

// OWNER: tracking area. Starts a local review session for a PR in a detached worktree.

struct ReviewSheet: View {
    let pr: PullRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var provider: Provider = .claude
    @State private var accountID: UUID?
    @State private var projectID: UUID?
    @State private var isStarting = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent(L.pullRequest) {
                        Text(verbatim: "#\(pr.number) · \(pr.repoLabel)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(L.branches) {
                        Text(L.branchArrow(pr.sourceBranch, pr.targetBranch))
                            .font(Theme.monoSmall)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    TextField(L.sessionTitle, text: $title)
                }
                Section {
                    if projects.count > 1 {
                        Picker(L.project, selection: $projectID) {
                            ForEach(projects) { p in Text(p.name).tag(Optional(p.id)) }
                        }
                    }
                    Picker(L.agent, selection: $provider) {
                        Text(L.providerName(.claude)).tag(Provider.claude)
                        Text(L.providerName(.codex)).tag(Provider.codex)
                    }
                    .pickerStyle(.segmented)
                    Picker(L.account, selection: $accountID) {
                        ForEach(model.accounts(for: provider)) { a in
                            Text(L.accountPickerLabel(a)).tag(Optional(a.id))
                        }
                    }
                    .disabled(model.accounts(for: provider).isEmpty)
                } footer: {
                    Text(L.reviewFooter)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Section(L.reviewPrompt) {
                    Text(ReviewPrompt.render(model.project(projectID)?.reviewPromptTemplate, pr: pr))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
            Divider()
            HStack {
                if isStarting {
                    ProgressView().controlSize(.small)
                    Text(L.reviewPreparing)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L.startReview, action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isStarting || projectID == nil || selectedAccount == nil)
                    .help(selectedAccount == nil ? L.errNoAccount(provider) : "")
            }
            .padding(12)
        }
        .frame(width: 520)
        .onAppear {
            title = L.reviewTitle(pr.title)
            projectID = model.project(for: pr)?.id
            accountID = model.defaultReviewAccount(for: pr, provider: provider)?.id
        }
        .onChange(of: provider) { _, p in
            accountID = model.defaultReviewAccount(for: pr, provider: p)?.id
        }
    }

    private var projects: [Project] {
        model.state.projects.filter { model.tracking.projectRepoKeys[$0.id] == pr.repoKey }
    }

    private var selectedAccount: Account? {
        model.account(accountID).flatMap { $0.provider == provider ? $0 : nil }
    }

    private func start() {
        guard let projectID, let account = selectedAccount else { return }
        isStarting = true
        error = nil
        Task {
            do {
                try await model.startReviewSession(pr: pr, projectID: projectID, provider: provider,
                                                   accountID: account.id, title: title)
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isStarting = false
        }
    }
}

/// The project settings sheet's review prompt template field.
struct ReviewTemplateSection: View {
    @Binding var template: String?

    var body: some View {
        Section {
            TextEditor(text: Binding(get: { template ?? "" }, set: { template = $0.nilIfBlank == nil ? nil : $0 }))
                .font(Theme.monoSmall)
                .frame(minHeight: 70, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.background, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                .overlay(alignment: .topLeading) {
                    if template == nil {
                        Text(ReviewPrompt.defaultTemplate)
                            .font(Theme.monoSmall)
                            .foregroundStyle(.tertiary)
                            .padding(9)
                            .allowsHitTesting(false)
                    }
                }
        } header: {
            Text(L.reviewPromptTemplate)
        } footer: {
            Text(L.reviewTemplateFooter(ReviewPrompt.placeholders.joined(separator: " ")))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
