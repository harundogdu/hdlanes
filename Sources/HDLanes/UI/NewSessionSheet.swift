import HDCore
import SwiftUI

// OWNER: workspace area.

/// Project, agent, account, title, first prompt, worktree. Prefilled from `model.newSessionPreset`.
struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var projectID: UUID?
    @State private var provider: Provider = .claude
    @State private var accountID: UUID?
    @State private var title = ""
    @State private var prompt = ""
    @State private var taskID: UUID?
    @State private var useWorktree = true
    @State private var branch = ""
    @State private var branchEdited = false
    @State private var baseRef: String?
    @State private var branches: [String] = []
    @State private var isGitRepo = false
    @State private var isLoadingRepo = false
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                projectSection
                agentSection
                Section {
                    TextField(L.titleLabel, text: $title, prompt: Text(L.titlePlaceholder))
                    if provider.isAgent {
                        LabeledContent(L.firstPrompt) {
                            TextEditor(text: $prompt)
                                .font(.system(size: 13))
                                .frame(minHeight: 72, maxHeight: 140)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .background(.background, in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                        }
                    }
                    taskPicker
                }
                worktreeSection
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 520)
        .onAppear(perform: applyPreset)
        .onDisappear { model.newSessionPreset = nil }
        .task(id: projectID) { await loadRepoInfo() }
        .onChange(of: provider) { _, _ in pickDefaultAccount() }
        .onChange(of: title) { _, _ in autoBranch() }
        .onChange(of: prompt) { _, _ in autoBranch() }
    }

    // MARK: Sections

    private var projectSection: some View {
        Section {
            HStack {
                Picker(L.project, selection: $projectID) {
                    if projectID == nil { Text(L.chooseProject).tag(UUID?.none) }
                    ForEach(model.state.projects) { p in
                        Text(p.name).tag(Optional(p.id))
                    }
                }
                Button(L.addProjectEllipsis) {
                    Task {
                        if let id = await Panels.addProject(model: model) { projectID = id }
                    }
                }
            }
            if let p = model.project(projectID) {
                Text(p.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var agentSection: some View {
        Section {
            Picker(L.agent, selection: $provider) {
                ForEach(Provider.allCases, id: \.self) { p in
                    Label(L.providerName(p), systemImage: ProviderStyle.symbol(p)).tag(p)
                }
            }
            .pickerStyle(.segmented)
            if provider.isAgent {
                accountPicker
            }
        }
    }

    @ViewBuilder
    private var accountPicker: some View {
        let accounts = model.accounts(for: provider)
        if accounts.isEmpty {
            LabeledContent(L.account) {
                Text(L.errNoAccount(provider))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                Picker(L.account, selection: $accountID) {
                    ForEach(accounts) { a in
                        Text(L.accountPickerLabel(a)).tag(Optional(a.id))
                    }
                }
                if let a = model.account(accountID) {
                    AccountDot(colorIndex: a.colorIndex)
                }
            }
        }
    }

    private var taskPicker: some View {
        Picker(L.task, selection: $taskID) {
            Text(L.noTask).tag(UUID?.none)
            ForEach(model.state.tasks.filter { $0.status != .done || $0.id == taskID }) { t in
                Text(t.title).tag(Optional(t.id))
            }
        }
    }

    private var worktreeSection: some View {
        Section {
            Toggle(L.useWorktree, isOn: $useWorktree)
                .disabled(!isGitRepo)
                .help(isGitRepo ? L.useWorktreeHelp : L.notAGitRepo)
            if useWorktree && isGitRepo {
                TextField(L.branch, text: Binding(get: { branch }, set: { branch = $0; branchEdited = true }))
                    .font(Theme.mono)
                if branchEdited, let problem = model.branchNameProblem(branch), !branch.isEmpty {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                Picker(L.baseBranch, selection: $baseRef) {
                    if branches.isEmpty { Text(L.currentHead).tag(String?.none) }
                    ForEach(branches, id: \.self) { b in
                        Text(b).tag(Optional(b))
                    }
                }
                .disabled(branches.isEmpty)
            }
        } footer: {
            if isLoadingRepo {
                ProgressView().controlSize(.small)
            } else if !isGitRepo && projectID != nil {
                Text(L.notAGitRepoFooter)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer()
            if isCreating { ProgressView().controlSize(.small) }
            Button(L.cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L.create, action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate || isCreating)
                .help(canCreate ? L.createHelp : L.createDisabledHelp)
        }
        .padding(12)
    }

    // MARK: Logic

    private var canCreate: Bool {
        guard model.project(projectID) != nil else { return false }
        return !provider.isAgent || model.account(accountID)?.provider == provider
    }

    private var effectiveTitle: String {
        title.nilIfBlank ?? SessionNaming.title(fromPrompt: prompt) ?? ""
    }

    private func applyPreset() {
        let preset = model.newSessionPreset
        projectID = preset?.projectID ?? model.task(preset?.taskID)?.projectID
            ?? model.selectedSessionID.flatMap { model.session($0)?.projectID } ?? model.state.projects.first?.id
        taskID = preset?.taskID
        title = preset?.title ?? ""
        prompt = preset?.prompt ?? ""
        pickDefaultAccount()
        autoBranch()
    }

    private func pickDefaultAccount() {
        guard provider.isAgent else { accountID = nil; return }
        if model.account(accountID)?.provider == provider { return }
        accountID = model.defaultAccount(for: provider, project: model.project(projectID))?.id
    }

    private func autoBranch() {
        guard !branchEdited else { return }
        branch = SessionNaming.branchSlug(from: effectiveTitle)
        // Refine with the git area's planner: hd/<slug>, unique against existing branches.
        guard let p = model.project(projectID) else { return }
        let title = effectiveTitle
        Task {
            let suggested = await model.suggestedBranchName(title: title, project: p)
            if !branchEdited && title == effectiveTitle { branch = suggested }
        }
    }

    private func loadRepoInfo() async {
        guard let p = model.project(projectID) else {
            isGitRepo = false
            branches = []
            return
        }
        isLoadingRepo = true
        let git = await model.isGitRepository(p.path)
        var list: [String] = []
        if git { list = await model.branches(at: p.path) }
        isGitRepo = git
        branches = list
        if let current = baseRef, list.contains(current) {} else { baseRef = list.first }
        useWorktree = git
        isLoadingRepo = false
        // A project's default account wins over the previous choice.
        if provider.isAgent {
            let preferred = provider == .claude ? p.defaultClaudeAccount : p.defaultCodexAccount
            if let pref = model.account(preferred), pref.provider == provider {
                accountID = pref.id
            } else if model.account(accountID)?.provider != provider {
                accountID = model.defaultAccount(for: provider, project: p)?.id
            }
        }
    }

    private func create() {
        guard let projectID else { return }
        let request = NewSessionRequest(projectID: projectID, provider: provider,
                                        accountID: provider.isAgent ? accountID : nil,
                                        title: title, prompt: provider.isAgent ? prompt.nilIfBlank : nil,
                                        useWorktree: useWorktree && isGitRepo,
                                        branch: branch.nilIfBlank, baseRef: baseRef, taskID: taskID)
        error = nil
        isCreating = true
        Task {
            do {
                try await model.startSession(request)
                isCreating = false
                dismiss()
            } catch {
                isCreating = false
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
