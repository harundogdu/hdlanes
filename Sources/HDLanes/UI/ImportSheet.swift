import AppKit
import HDCore
import SwiftUI

// OWNER: workspace area.

/// State of one import sheet. Lives as long as the sheet.
@MainActor
@Observable
final class ImportSheetModel {
    var tab: ImportTab

    // Accounts
    var accountCandidates: [AccountCandidate] = []
    var selectedAccounts: Set<String> = []
    var isScanningAccounts = false
    var hasScannedAccounts = false
    /// A chosen folder whose provider couldn't be told from its contents.
    var pendingFolder: String?
    var pendingProvider: Provider = .claude
    var folderMessage: String?
    var addedAccounts = 0

    // Sessions
    var days = 30
    var accountFilter: UUID?
    var search: String
    var includeHeadless = false
    var sessions: [ImportableSession] = []
    var selectedSessions: Set<String> = []
    var isScanningSessions = false
    /// Scan parameters of `sessions`; a tab switch doesn't rescan unless they changed.
    var scannedKey: String?
    var isImporting = false

    init(preset: ImportPreset) {
        tab = preset.tab
        search = preset.search ?? ""
    }
}

/// Brings in existing account folders (no new login) and past Claude / Codex conversations.
struct ImportSheet: View {
    @State private var sheet: ImportSheetModel

    init(preset: ImportPreset) {
        _sheet = State(initialValue: ImportSheetModel(preset: preset))
    }

    var body: some View {
        @Bindable var sheet = sheet
        VStack(spacing: 0) {
            HStack {
                Text(L.importTitle)
                    .font(.headline)
                Spacer()
                Picker(L.importTitle, selection: $sheet.tab) {
                    ForEach(ImportTab.allCases) { Text(L.importTabName($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            switch sheet.tab {
            case .accounts: ImportAccountsTab(sheet: sheet)
            case .sessions: ImportSessionsTab(sheet: sheet)
            }
        }
        .frame(width: 720, height: 560)
    }
}

/// `~/…` for paths in the home folder; the exact string otherwise (a trailing slash stays visible).
private func displayPath(_ path: String, home: String) -> String {
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

// MARK: Accounts

private struct ImportAccountsTab: View {
    @Bindable var sheet: ImportSheetModel
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var selectedCount: Int {
        sheet.accountCandidates.filter { sheet.selectedAccounts.contains($0.id) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let pending = sheet.pendingFolder { pendingRow(pending) }
                if let message = sheet.folderMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                Text(L.importAccountsFootnote + " " + L.desktopAppNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L.chooseFolderEllipsis, action: chooseFolder)
                    if sheet.addedAccounts > 0 {
                        Text(L.accountsAdded(sheet.addedAccounts))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button(L.goToSessions) { sheet.tab = .sessions }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                    Spacer()
                    Button(sheet.addedAccounts > 0 ? L.done : L.cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(L.addCount(selectedCount), action: add)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedCount == 0)
                }
            }
            .padding(16)
        }
        .task {
            guard !sheet.hasScannedAccounts else { return }
            await scan()
        }
    }

    @ViewBuilder private var content: some View {
        if sheet.isScanningAccounts && sheet.accountCandidates.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L.scanningAccounts)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else if sheet.accountCandidates.isEmpty {
            VStack(spacing: 8) {
                Text(L.noAccountCandidates)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button(L.chooseFolderEllipsis, action: chooseFolder)
                    .controlSize(.small)
            }
            .padding(20)
        } else {
            List {
                ForEach(sheet.accountCandidates) { candidate in
                    AccountCandidateRow(candidate: candidate, home: model.homeDirectory, isOn: selection(candidate))
                }
            }
            .listStyle(.inset)
        }
    }

    private func pendingRow(_ path: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .foregroundStyle(.secondary)
            Text(L.whichProvider(displayPath(path, home: model.homeDirectory)))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Picker(L.provider, selection: $sheet.pendingProvider) {
                ForEach([Provider.claude, .codex], id: \.self) { p in
                    Label(L.providerName(p), systemImage: ProviderStyle.symbol(p)).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button(L.add) { use(URL(fileURLWithPath: path, isDirectory: true), provider: sheet.pendingProvider) }
            Button { sheet.pendingFolder = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(L.cancel)
        }
        .controlSize(.small)
    }

    private func selection(_ candidate: AccountCandidate) -> Binding<Bool> {
        Binding(get: { sheet.selectedAccounts.contains(candidate.id) },
                set: { on in
                    if on { sheet.selectedAccounts.insert(candidate.id) } else { sheet.selectedAccounts.remove(candidate.id) }
                })
    }

    private func scan() async {
        sheet.isScanningAccounts = true
        let found = await model.scanAccountCandidates()
        // Folders chosen meanwhile stay.
        let chosen = sheet.accountCandidates.filter { c in !found.contains { $0.id == c.id } }
        sheet.accountCandidates = found + chosen
        sheet.selectedAccounts.formUnion(found.map(\.id))
        sheet.isScanningAccounts = false
        sheet.hasScannedAccounts = true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: model.homeDirectory, isDirectory: true)
        panel.message = L.chooseAccountFolderMessage
        panel.prompt = L.choose
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(url, provider: nil)
    }

    private func use(_ url: URL, provider: Provider?) {
        sheet.folderMessage = nil
        switch model.chosenFolderCandidate(url, provider: provider) {
        case .candidate(let c):
            sheet.pendingFolder = nil
            if let i = sheet.accountCandidates.firstIndex(where: { $0.id == c.id }) {
                if !sheet.accountCandidates[i].sources.contains(.chosenFolder) {
                    sheet.accountCandidates[i].sources.append(.chosenFolder)
                }
            } else {
                sheet.accountCandidates.append(c)
            }
            sheet.selectedAccounts.insert(c.id)
        case .unknownProvider:
            sheet.pendingFolder = HDPaths.normalizedDirString(url.standardizedFileURL.path)
        case .excluded(let reason):
            sheet.pendingFolder = nil
            sheet.folderMessage = L.folderExclusion(reason)
        }
    }

    private func add() {
        let chosen = sheet.accountCandidates.filter { sheet.selectedAccounts.contains($0.id) }
        let added = model.importAccounts(chosen)
        sheet.addedAccounts += added.count
        let done = Set(chosen.map(\.id))
        sheet.accountCandidates.removeAll { done.contains($0.id) }
        sheet.selectedAccounts.subtract(done)
    }
}

private struct AccountCandidateRow: View {
    let candidate: AccountCandidate
    let home: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: $isOn) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: ProviderStyle.symbol(candidate.provider))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .help(L.providerName(candidate.provider))
            VStack(alignment: .leading, spacing: 4) {
                Text(displayPath(candidate.dir, home: home))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(candidate.dir)
                HStack(spacing: 4) {
                    ForEach(candidate.sources, id: \.self) { SourceChip(source: $0) }
                    if candidate.hasHistory {
                        Text(L.hasHistory)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                            .help(L.hasHistoryHelp)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }
}

private struct SourceChip: View {
    let source: AccountCandidate.Source

    var body: some View {
        Text(L.importSourceName(source))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .help(L.importSourceHelp(source))
    }
}

// MARK: Sessions

private struct ImportSessionsTab: View {
    @Bindable var sheet: ImportSheetModel
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private struct FolderGroup: Identifiable {
        var cwd: String
        var items: [ImportableSession]
        var id: String { cwd }
    }

    private var agentAccounts: [Account] { model.state.accounts.filter { $0.provider.isAgent } }

    private var scanKey: String {
        "\(sheet.days)|\(sheet.includeHeadless)|" + agentAccounts.map { $0.id.uuidString + ($0.configDir ?? "") }.joined(separator: ",")
    }

    private var query: String {
        let q = sheet.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if q == "~" || q.hasPrefix("~/") { return model.homeDirectory + q.dropFirst() }
        return q
    }

    /// Sessions whose folder still exists. A removed worktree (the desktop app deletes its own) can't
    /// be resumed in place, so those are counted, not listed.
    private var available: [ImportableSession] { sheet.sessions.filter(\.candidate.cwdExists) }

    private var visible: [ImportableSession] {
        let q = query
        return available.filter { s in
            (sheet.accountFilter == nil || s.accountID == sheet.accountFilter)
                && (q.isEmpty || s.candidate.title.localizedCaseInsensitiveContains(q)
                    || s.candidate.cwd.localizedCaseInsensitiveContains(q))
        }
    }

    /// Grouped by folder; groups and rows newest first (`sessions` is already sorted).
    private var groups: [FolderGroup] {
        var order: [String] = []
        var byCwd: [String: [ImportableSession]] = [:]
        for s in visible {
            if byCwd[s.candidate.cwd] == nil { order.append(s.candidate.cwd) }
            byCwd[s.candidate.cwd, default: []].append(s)
        }
        return order.map { FolderGroup(cwd: $0, items: byCwd[$0] ?? []) }
    }

    private var selected: [ImportableSession] {
        sheet.sessions.filter { $0.isSelectable && sheet.selectedSessions.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                Toggle(L.includeHeadless, isOn: $sheet.includeHeadless)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .help(L.includeHeadlessHelp)
                let missing = sheet.sessions.count - available.count
                if missing > 0 {
                    Text(L.hiddenMissingFolders(missing))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(L.hiddenMissingFoldersHelp)
                }
                Spacer()
                if sheet.isImporting { ProgressView().controlSize(.small) }
                Button(L.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L.importCount(selected.count)) { Task { await importSelected() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || sheet.isImporting)
                    .help(L.importSessionsHelp)
            }
            .padding(16)
        }
        .task(id: scanKey) { await scan(key: scanKey) }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker(L.timeWindow, selection: $sheet.days) {
                ForEach([7, 30, 90], id: \.self) { Text(L.lastNDays($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help(L.timeWindow)
            Picker(L.accountFilter, selection: $sheet.accountFilter) {
                Text(L.allAccounts).tag(UUID?.none)
                Divider()
                ForEach(agentAccounts) { a in
                    Label(a.label, systemImage: ProviderStyle.symbol(a.provider)).tag(UUID?.some(a.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help(L.accountFilter)
            TextField(L.searchSessionsPrompt, text: $sheet.search, prompt: Text(L.searchSessionsPrompt))
                .textFieldStyle(.roundedBorder)
            if sheet.isScanningSessions && !sheet.sessions.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .controlSize(.regular)
    }

    @ViewBuilder private var content: some View {
        if sheet.isScanningSessions && sheet.sessions.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L.scanningSessions)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else if available.isEmpty {
            emptyState(L.noSessions(sheet.days)) {
                if sheet.days < 90 {
                    Button(L.showLast90Days) { sheet.days = 90 }
                } else {
                    Button(L.importAnAccount) { sheet.tab = .accounts }
                }
            }
        } else if visible.isEmpty {
            emptyState(L.noSessionMatches) {
                Button(L.clearFilters) {
                    sheet.search = ""
                    sheet.accountFilter = nil
                }
            }
        } else {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            SessionCandidateRow(item: item, account: model.account(item.accountID), isOn: selection(item))
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func emptyState<A: View>(_ text: String, @ViewBuilder action: () -> A) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action().controlSize(.small)
        }
        .padding(20)
    }

    private func groupHeader(_ group: FolderGroup) -> some View {
        let ids = group.items.filter(\.isSelectable).map(\.id)
        let all = Binding<Bool>(
            get: { !ids.isEmpty && ids.allSatisfy { sheet.selectedSessions.contains($0) } },
            set: { on in
                if on { sheet.selectedSessions.formUnion(ids) } else { sheet.selectedSessions.subtract(ids) }
            })
        return HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(displayPath(group.cwd, home: model.homeDirectory))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(group.cwd)
            Spacer(minLength: 8)
            Toggle(L.selectAll, isOn: all)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .controlSize(.small)
                .disabled(ids.isEmpty)
        }
    }

    private func selection(_ item: ImportableSession) -> Binding<Bool> {
        Binding(get: { item.isSelectable && sheet.selectedSessions.contains(item.id) },
                set: { on in
                    guard item.isSelectable else { return }
                    if on { sheet.selectedSessions.insert(item.id) } else { sheet.selectedSessions.remove(item.id) }
                })
    }

    private func scan(key: String) async {
        guard sheet.scannedKey != key else { return }
        sheet.isScanningSessions = true
        let since = Calendar.current.date(byAdding: .day, value: -sheet.days, to: Date()) ?? Date()
        let found = await model.sessionCandidates(accounts: agentAccounts, since: since, includeHeadless: sheet.includeHeadless)
        guard !Task.isCancelled else { return }
        sheet.sessions = found
        sheet.selectedSessions.formIntersection(found.filter(\.isSelectable).map(\.id))
        sheet.scannedKey = key
        sheet.isScanningSessions = false
    }

    private func importSelected() async {
        let items = selected
        guard !items.isEmpty, !sheet.isImporting else { return }
        sheet.isImporting = true
        let imported = await model.importSessions(items)
        sheet.isImporting = false
        if !imported.isEmpty { dismiss() }
    }
}

private struct SessionCandidateRow: View {
    let item: ImportableSession
    let account: Account?
    @Binding var isOn: Bool

    var body: some View {
        let c = item.candidate
        HStack(spacing: 8) {
            Toggle(isOn: $isOn) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!item.isSelectable)
            Image(systemName: ProviderStyle.symbol(c.provider))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .help(L.providerName(c.provider))
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(L.originName(c.origin))
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .help(L.originHelp(c.origin, raw: c.entrypoint))
                    if let branch = c.branch {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.branch")
                            Text(branch)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Text(L.relative(c.lastActivity))
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if item.isImported {
                Text(L.alreadyImported)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(L.alreadyImportedHelp)
            } else if item.archivedSessionID != nil {
                Text(L.closedEarlier)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(L.closedEarlierHelp)
            }
            if let account {
                AccountDot(colorIndex: account.colorIndex, size: 7)
                    .help(account.label)
            }
        }
        .padding(.vertical, 1)
        .opacity(item.isSelectable ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { if item.isSelectable { isOn.toggle() } }
        .help(c.firstPrompt.map { String($0.prefix(300)) } ?? c.title)
    }
}
