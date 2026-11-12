import HDCore
import SwiftUI

// OWNER: workspace area.

/// How an account (re)authenticates from hdlanes.
enum LoginFlow: Identifiable, Equatable {
    /// Vendor login in an embedded terminal: browser login, or `claude setup-token` (+ paste field).
    case terminal(AuthMethod)
    /// A pasted key or token saved by hdlanes: Claude API key, Codex API key / access token.
    case secret(AuthMethod)
    /// Codex: `codex login --device-auth`, a code entered on any device's browser.
    case deviceCode

    var id: String {
        switch self {
        case .terminal(let m): return "t-" + m.rawValue
        case .secret(let m): return "s-" + m.rawValue
        case .deviceCode: return "device"
        }
    }

    static func `for`(_ account: Account) -> LoginFlow {
        // System default accounts only re-login with the browser; hdlanes doesn't write into ~/.claude.
        if account.isSystemDefault { return .terminal(.browser) }
        return flow(provider: account.provider, method: account.authMethod)
    }

    static func flow(provider: Provider, method: AuthMethod) -> LoginFlow {
        switch (provider, method) {
        case (.claude, .token): return .terminal(.token)
        case (_, .apiKey): return .secret(.apiKey)
        case (.codex, .token): return .secret(.token)
        default: return .terminal(.browser)
        }
    }
}

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var showImport = false

    var body: some View {
        Form {
            ForEach([Provider.claude, .codex], id: \.self) { provider in
                Section {
                    let accounts = model.accounts(for: provider)
                    if accounts.isEmpty {
                        Text(L.noAccounts(provider))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(accounts) { AccountRow(account: $0) }
                } header: {
                    Label(L.providerName(provider), systemImage: ProviderStyle.symbol(provider))
                }
            }
            Section {
                HStack {
                    Text(L.accountsFooter)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L.importExistingAccountEllipsis) { showImport = true }
                        .help(L.importAccountsFootnote)
                    Button(L.addAccountEllipsis) { showAdd = true }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshAllAccountHealth() }
        .sheet(isPresented: $showAdd) { AddAccountSheet() }
        .sheet(isPresented: $showImport) { ImportSheet(preset: ImportPreset(tab: .accounts)) }
    }
}

private struct AccountRow: View {
    let account: Account
    @Environment(AppModel.self) private var model
    @State private var labelDraft = ""
    @State private var confirmRemove = false
    @State private var flow: LoginFlow?
    @State private var error: String?

    var body: some View {
        let health = model.accountHealth[account.id]
        let users = model.sessionsUsing(account.id).count
        HStack(alignment: .top, spacing: 10) {
            ColorMenu(account: account)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                // Inside a grouped Form a labelled TextField renders as "label …… value"; the account name
                // is the row's title, so hide the label and keep it left-aligned and editable in place.
                TextField(L.accountLabel, text: $labelDraft, prompt: Text(L.accountLabel))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .font(.system(size: 13, weight: .medium))
                    .onSubmit(commitLabel)
                    .help(L.accountLabel)
                Text(L.accountDetailLine(account))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HealthLine(health: health) { flow = LoginFlow.for(account) }
                if let usage = model.usage(for: account.id) {
                    Text(L.usageSummary(usage))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if account.isSystemDefault {
                    Text(L.systemAccountNote(account.provider))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else if account.provider == .claude || model.canLinkSharedContext(account) {
                    SharedContextControl(account: account)
                }
                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button(L.check) { Task { await model.refreshAccountHealth(account.id) } }
                    .disabled(health?.isChecking == true)
                    .help(L.checkHelp)
                Button(L.removeEllipsis) { confirmRemove = true }
                    .disabled(account.isSystemDefault || users > 0)
                    .help(account.isSystemDefault ? L.errSystemAccount
                          : (users > 0 ? L.errAccountInUse(users) : (trashesFolder ? L.removeAccountHelp : L.forgetAccountHelp)))
            }
            .controlSize(.small)
        }
        .padding(.vertical, 3)
        .onAppear { labelDraft = account.label }
        .onChange(of: account.label) { _, new in labelDraft = new }
        .confirmationDialog(L.removeAccountTitle(account.label), isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(trashesFolder ? L.moveToTrash : L.remove, role: .destructive, action: remove)
            Button(L.cancel, role: .cancel) {}
        } message: {
            // removeAccount only trashes folders hdlanes created; an imported folder stays.
            Text(trashesFolder ? L.removeAccountMessage(account.configDir ?? "") : L.forgetAccountMessage(account.configDir ?? ""))
        }
        .sheet(item: $flow) { flow in
            LoginSheet(accountID: account.id, flow: flow)
        }
    }

    private var trashesFolder: Bool {
        account.configDir.map(model.isInsideAccountsDir) ?? false
    }

    private func commitLabel() {
        if let label = labelDraft.nilIfBlank {
            model.updateAccount(account.id) { $0.label = label }
        } else {
            labelDraft = account.label
        }
    }

    private func remove() {
        do {
            try model.removeAccount(account.id)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// The "use the default account's skills, agents, … and memory" switch with what is linked now.
private struct SharedContextControl: View {
    let account: Account
    @Environment(AppModel.self) private var model

    var body: some View {
        let on = model.sharesDefaultContext(account)
        VStack(alignment: .leading, spacing: 2) {
            Toggle(L.shareDefaultContext(account.provider), isOn: Binding(
                get: { on },
                set: { model.setSharesDefaultContext(account.id, $0) }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 11))
                .help(L.shareDefaultContextHelp(account.provider))
            if on {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 2)
    }

    private var lines: [String] {
        guard model.canLinkSharedContext(account) else { return [L.sharedMemoryOnly] }
        let status = model.sharedContextStatus(for: account)
        func names(_ state: SharedContext.LinkState) -> [String] { status.filter { $0.state == state }.map(\.name) }
        var out: [String] = []
        if !names(.linked).isEmpty { out.append(L.sharedLinked(names(.linked))) }
        if !names(.notLinked).isEmpty { out.append(L.sharedPending(names(.notLinked))) }
        if !names(.occupied).isEmpty { out.append(L.sharedOwn(names(.occupied))) }
        return out
    }
}

private struct ColorMenu: View {
    let account: Account
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(Theme.accountColors.indices, id: \.self) { i in
                Button { model.updateAccount(account.id) { $0.colorIndex = i } } label: {
                    Label(L.colorName(i), systemImage: i == account.colorIndex ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        } label: {
            AccountDot(colorIndex: account.colorIndex, size: 10)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L.changeColor)
    }
}

private struct HealthLine: View {
    let health: AccountHealth?
    let login: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if health?.isChecking == true {
                ProgressView().controlSize(.mini)
                Text(L.checking)
            } else if let health {
                if health.cliMissing {
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    Text(health.detail ?? L.notInstalled)
                } else if let error = health.error {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).lineLimit(2)
                } else if health.loggedIn == true {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(health.detail.map(L.loggedInVia) ?? L.loggedIn)
                } else {
                    Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                    Text(L.notLoggedIn)
                }
            } else {
                Text(L.notChecked).foregroundStyle(.tertiary)
            }
            if health?.isChecking != true, health?.cliMissing != true {
                Button(health?.loggedIn == true ? L.logInAgain : L.logIn, action: login)
                    .controlSize(.small)
                    .buttonStyle(.link)
                    .fixedSize()
            }
        }
        .font(.system(size: 11))
    }
}

// MARK: Add account

struct AddAccountSheet: View {
    private enum Step: Equatable {
        case form
        case login(UUID, LoginFlow)
    }

    /// A sign-in choice: an `AuthMethod`, or Codex's device code (stored as a browser login).
    private enum Choice: Hashable {
        case method(AuthMethod)
        case deviceCode
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var provider: Provider
    @State private var label = ""
    @State private var choice: Choice = .method(.browser)
    @State private var step: Step = .form
    @State private var error: String?

    init(provider: Provider = .claude) {
        _provider = State(initialValue: provider)
    }

    var body: some View {
        switch step {
        case .form:
            form
        case .login(let id, let flow):
            LoginFlowView(accountID: id, flow: flow) {
                Task { await model.refreshAccountHealth(id) }
                dismiss()
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.addAccount)
                .font(.headline)
            Picker(L.provider, selection: $provider) {
                ForEach([Provider.claude, .codex], id: \.self) { p in
                    Label(L.providerName(p), systemImage: ProviderStyle.symbol(p)).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField(L.accountLabel, text: $label,
                      prompt: Text(L.defaultAccountLabel(provider, model.accounts(for: provider).count + 1)))
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(choices, id: \.self) { c in
                    MethodOption(title: title(c), detail: detail(c), selected: choice == c) { choice = c }
                }
            }
            Text(L.addAccountFootnote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L.continueLabel, action: create)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onChange(of: provider) { if !choices.contains(choice) { choice = .method(.browser) } }
    }

    private var choices: [Choice] {
        provider == .codex ? [.method(.browser), .deviceCode, .method(.token), .method(.apiKey)]
                           : [.method(.browser), .method(.token), .method(.apiKey)]
    }

    private func title(_ c: Choice) -> String {
        switch c {
        case .method(let m): return L.methodTitle(m, provider)
        case .deviceCode: return L.deviceCodeTitle
        }
    }

    private func detail(_ c: Choice) -> String {
        switch c {
        case .method(let m): return L.methodDetail(m, provider)
        case .deviceCode: return L.deviceCodeDetail
        }
    }

    private func create() {
        do {
            let method: AuthMethod
            if case .method(let m) = choice { method = m } else { method = .browser }
            let account = try model.addAccount(provider: provider, label: label, method: method)
            step = .login(account.id, choice == .deviceCode ? .deviceCode : LoginFlow.flow(provider: provider, method: method))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct MethodOption: View {
    let title: String
    let detail: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Login

/// Sheet wrapper used from an account row.
private struct LoginSheet: View {
    let accountID: UUID
    let flow: LoginFlow
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LoginFlowView(accountID: accountID, flow: flow) {
            Task { await model.refreshAccountHealth(accountID) }
            dismiss()
        }
    }
}

private struct LoginFlowView: View {
    let accountID: UUID
    let flow: LoginFlow
    let finish: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if let account = model.account(accountID) {
            switch flow {
            case .terminal(let method):
                LoginTerminalSheet(account: account, method: method, finish: finish)
            case .deviceCode:
                LoginTerminalSheet(account: account, method: .browser, deviceCode: true, finish: finish)
            case .secret(let method):
                SecretEntryPanel(account: account, method: method, finish: finish)
            }
        } else {
            VStack(spacing: 12) {
                Text(L.removedAccount)
                Button(L.close, action: finish)
            }
            .padding(24)
        }
    }
}

/// The vendor's login in an embedded terminal (a throwaway terminal id, not a session). For the
/// Claude token method the printed token is pasted into the field below and saved by hdlanes.
struct LoginTerminalSheet: View {
    let account: Account
    let method: AuthMethod
    let finish: () -> Void
    @Environment(AppModel.self) private var model
    /// Codex browser login run as `codex login --device-auth` instead; switchable in the sheet.
    @State private var deviceCode: Bool
    @State private var terminalID = UUID()
    @State private var token = ""
    @State private var saved = false
    @State private var error: String?

    init(account: Account, method: AuthMethod, deviceCode: Bool = false, finish: @escaping () -> Void) {
        self.account = account
        self.method = method
        self.finish = finish
        _deviceCode = State(initialValue: deviceCode)
    }

    private var isClaudeToken: Bool { account.provider == .claude && method == .token }
    /// Codex's ChatGPT login can run either way.
    private var canSwitchToDeviceCode: Bool { account.provider == .codex && method == .browser }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.loginTitle(account))
                .font(.headline)
            Text(deviceCode ? L.deviceCodeInstructions : L.loginInstructions(account: account, method: method))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TerminalHost(sessionID: terminalID)
                .padding(6)
                .background(Color(nsColor: TerminalTheme.color(model.terminalPalette.background)), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isClaudeToken {
                HStack {
                    SecureField(L.pasteTokenPlaceholder, text: $token)
                        .textFieldStyle(.roundedBorder)
                    Button(L.save, action: saveToken)
                        .disabled(token.nilIfBlank == nil)
                    if saved {
                        Label(L.saved, systemImage: "checkmark").foregroundStyle(.green).font(.system(size: 11))
                    }
                }
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Button(L.runAgain, action: restart)
                    .help(L.runAgainHelp)
                if canSwitchToDeviceCode {
                    Button(deviceCode ? L.useBrowserLogin : L.useDeviceCode) {
                        deviceCode.toggle()
                        restart()
                    }
                    .help(L.deviceCodeDetail)
                }
                Spacer()
                // No default-button shortcut: Return must reach the terminal.
                Button(L.done, action: done)
            }
        }
        .padding(16)
        .frame(width: 720, height: 480)
        .onAppear(perform: start)
        .onDisappear(perform: cleanUp)
    }

    private func start() {
        let cwd = model.accountCLIDirectory()
        let spec = deviceCode && canSwitchToDeviceCode
            ? model.loginSpec(account: account, flow: .deviceCode, cwd: cwd)
            : model.loginSpec(account: account, method: method, cwd: cwd)
        model.terminals.start(terminalID, spec: spec)
    }

    private func cleanUp() {
        model.terminals.remove(terminalID)
        model.runtimes[terminalID] = nil
    }

    private func restart() {
        cleanUp()
        terminalID = UUID()
        start()
    }

    private func saveToken() {
        do {
            try model.saveClaudeToken(token, for: account.id)
            token = ""
            saved = true
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func done() {
        cleanUp()
        finish()
    }
}

/// Paste-and-save for API keys and Codex access tokens. The value only lives in this view until saved.
private struct SecretEntryPanel: View {
    let account: Account
    let method: AuthMethod
    let finish: () -> Void
    @Environment(AppModel.self) private var model
    @State private var secret = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.secretTitle(account: account, method: method))
                .font(.headline)
            Text(L.secretExplanation(provider: account.provider, method: method))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(L.secretPlaceholder(method), text: $secret)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button(L.later) { finish() }
                    .keyboardShortcut(.cancelAction)
                    .help(L.laterHelp)
                Button(L.save, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret.nilIfBlank == nil || isSaving)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    private func save() {
        guard secret.nilIfBlank != nil, !isSaving else { return }
        isSaving = true
        error = nil
        let value = secret
        Task {
            do {
                if account.provider == .claude {
                    try model.saveClaudeAPIKey(value, for: account.id)
                } else {
                    try await model.saveCodexSecret(value, method: method, for: account.id)
                }
                secret = ""
                isSaving = false
                finish()
            } catch {
                isSaving = false
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
