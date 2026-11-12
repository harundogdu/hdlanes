import HDCore
import SwiftUI

// OWNER: workspace area. Settings › Mods: install Claude Code mods into one Claude account.

struct ModsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("hd.modsAccount") private var accountKey = ""
    @State private var installed: [InstalledPlugin] = []
    @State private var builtinOn: Set<String> = []
    @State private var loaded = false
    @State private var busy: String?
    @State private var error: String?
    @State private var confirm: PendingInstall?
    @State private var customName = ""
    @State private var customSource = ""

    /// An install that waits for the user: a mod that writes, runs or reaches the network, a
    /// hand-typed one, or a marketplace that runs a command.
    struct PendingInstall: Identifiable {
        let id = UUID()
        let key: String
        let title: String
        let message: String
        let arguments: [String]
        let playground: Bool
    }

    private var accounts: [Account] { model.accounts(for: .claude) }
    private var account: Account? { accounts.first { $0.id.uuidString == accountKey } ?? accounts.first }

    var body: some View {
        Form {
            if let account {
                Section {
                    Picker(L.modsAccount, selection: Binding(get: { account.id.uuidString }, set: { accountKey = $0 })) {
                        ForEach(accounts) { Text($0.label).tag($0.id.uuidString) }
                    }
                    Text(L.modsIntro)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Section(L.modsInstalled) {
                    if !loaded {
                        ProgressView().controlSize(.small)
                    } else if installed.isEmpty {
                        Text(L.modsNoneInstalled).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(installed) { installedRow($0, account: account) }
                }
                Section(L.modsCatalog) {
                    ForEach(ModCatalog.entries) { catalogRow($0, account: account) }
                }
                Section(L.modsInstallByHand) {
                    HStack {
                        TextField(L.modsName, text: $customName, prompt: Text(verbatim: "cache-tax"))
                        TextField(L.modsMarketplace, text: $customSource, prompt: Text(verbatim: "owner/repo"))
                        Button(L.modsInstall) { askCustom() }
                            .disabled(busy != nil || ModCatalog.customInstallArguments(name: customName, source: customSource) == nil)
                    }
                    Text(L.modsFooter)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(L.modsNoClaudeAccount).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: account?.id) { await reload() }
        .alert(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
               presenting: confirm) { pending in
            Button(L.modsInstall) { run(pending.key, pending.arguments, playground: pending.playground) }
            Button(L.cancel, role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }

    // MARK: Rows

    private func installedRow(_ plugin: InstalledPlugin, account: Account) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.name).font(.system(size: 13))
                Text(verbatim: plugin.version.isEmpty ? plugin.id : "\(plugin.id) · \(plugin.version)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if busy == plugin.id { ProgressView().controlSize(.small) }
            Toggle(L.modsEnabled, isOn: Binding(get: { plugin.enabled }, set: { on in
                run(plugin.id, ModCatalog.arguments(on ? "enable" : "disable", id: plugin.id))
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(busy != nil)
            .help(L.modsEnabledHelp)
            Button { run(plugin.id, ModCatalog.arguments("uninstall", id: plugin.id)) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(busy != nil)
            .help(L.modsRemove)
        }
    }

    private func catalogRow(_ entry: ModEntry, account: Account) -> some View {
        let isInstalled = installed.contains { $0.id == entry.id }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: L.modDisplayName(entry.name)).font(.system(size: 13))
                    LevelBadge(level: entry.level)
                }
                Text(L.modSummary(entry.name))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { model.openInBrowser(entry.url) } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless)
                .help(L.modsOpenPage)
            if busy == entry.id { ProgressView().controlSize(.small) }
            if entry.source == .builtin {
                Toggle(L.modsEnabled, isOn: Binding(get: { builtinOn.contains(entry.id) }, set: { on in
                    run(entry.id, ModCatalog.arguments(on ? "enable" : "disable", id: entry.id))
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(busy != nil)
                .help(L.modsEnabledHelp)
            } else if isInstalled {
                Label(L.modsInstalledBadge, systemImage: "checkmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button(L.modsInstall) { ask(entry) }
                    .controlSize(.small)
                    .disabled(busy != nil)
            }
        }
    }

    // MARK: Actions

    private func ask(_ entry: ModEntry) {
        let playground = entry.source == .playground
        // The playground path is filled in after the clone; build with a placeholder to check the shape.
        guard let args = ModCatalog.installArguments(entry, playgroundPath: playground ? model.playgroundMarketplace : nil) else { return }
        if entry.level?.needsConfirmation ?? true {
            confirm = PendingInstall(key: entry.id, title: L.modsConfirmTitle(L.modDisplayName(entry.name)),
                                     message: L.modsConfirmBody(entry.level), arguments: args, playground: playground)
        } else {
            run(entry.id, args, playground: playground)
        }
    }

    private func askCustom() {
        guard let args = ModCatalog.customInstallArguments(name: customName, source: customSource) else { return }
        let name = customName.trimmingCharacters(in: .whitespaces)
        confirm = PendingInstall(key: name, title: L.modsConfirmTitle(name), message: L.modsConfirmBody(nil),
                                 arguments: args, playground: false)
    }

    private func run(_ key: String, _ arguments: [String], playground: Bool = false) {
        guard let account, busy == nil else { return }
        busy = key
        error = nil
        Task {
            defer { busy = nil }
            if playground, let failure = await model.preparePlayground() {
                error = failure
                return
            }
            switch await model.runPluginCommand(account, arguments) {
            case .ok:
                if arguments.contains("install") { customName = ""; customSource = "" }
            case .needsCommand(let command, let sha):
                // Shown as-is; only this exact command is accepted.
                confirm = PendingInstall(key: key, title: L.modsCommandTitle, message: L.modsCommandBody(command),
                                         arguments: arguments + ["--accept-command", sha], playground: false)
            case .failed(let message):
                error = message.isEmpty ? L.modsCommandFailed : message
            }
            await reload()
        }
    }

    private func reload() async {
        guard let account else { return }
        switch await model.installedPlugins(account) {
        case .success(let list):
            installed = list.filter { !$0.id.hasSuffix("@builtin") && !$0.id.hasSuffix("@skills-dir") }
        case .failure(let e):
            installed = []
            error = e.message
        }
        builtinOn = Set(ModCatalog.entries.filter { $0.source == .builtin && model.isBuiltinEnabled($0.id, account: account) }.map(\.id))
        loaded = true
    }
}

/// L0–L3 as graded by the awesome-claude-code-mods catalogue.
private struct LevelBadge: View {
    let level: ModLevel?

    var body: some View {
        Text(verbatim: level.map { "L\($0.rawValue)" } ?? "–")
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
            .help(L.modLevelHelp(level))
    }
}
