import AppKit
import HDCore
import SwiftUI

// OWNER: inbox area.
struct InboxSidebarRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.inbox.visibleItems.count
        HStack {
            Label(L.inbox, systemImage: "tray")
            Spacer()
            if model.inbox.isRefreshing {
                ProgressView().controlSize(.mini)
            } else if count > 0 {
                Text(verbatim: "\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var showSetup = false

    var body: some View {
        let store = model.inbox
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L.inbox).font(.system(size: 13, weight: .semibold))
                if let updated = store.updatedAt {
                    Text(L.inboxUpdated(updated.formatted(date: .omitted, time: .shortened)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Button(L.inboxSetUpEllipsis) { showSetup = true }
                Button(L.inboxRefresh) { Task { await model.refreshInbox() } }
                    .disabled(!model.inboxIsSetUp || store.isRefreshing)
                    .help(model.inboxIsSetUp ? L.inboxRefreshHelp : L.inboxNotSetUp)
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            if let error = store.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.08))
            }
            content
        }
        .sheet(isPresented: $showSetup) {
            InboxSetupSheet().environment(model)
        }
    }

    @ViewBuilder private var content: some View {
        let store = model.inbox
        if !model.inboxIsSetUp {
            emptyState(L.inboxNotSetUp, action: L.inboxSetUpEllipsis) { showSetup = true }
        } else if store.visibleItems.isEmpty {
            if store.isRefreshing {
                emptyState(L.inboxReading, action: nil) {}
            } else {
                emptyState(store.updatedAt == nil ? L.inboxNotLoaded : L.inboxEmpty, action: L.inboxRefresh) {
                    Task { await model.refreshInbox() }
                }
            }
        } else {
            List {
                ForEach(store.visibleItems) { item in
                    InboxItemRow(item: item)
                }
            }
            .listStyle(.inset)
        }
    }

    private func emptyState(_ text: String, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let action { Button(action, action: perform).controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InboxItemRow: View {
    let item: Inbox.Item
    @Environment(AppModel.self) private var model
    @State private var reply = ""
    @State private var expanded = false
    @State private var confirm = false

    var body: some View {
        let sending = model.inbox.sending.contains(item.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.source)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(item.from).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                Text(item.received).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            if !item.subject.isEmpty {
                Text(item.subject).font(.system(size: 13)).lineLimit(1)
            }
            Text(item.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if expanded {
                TextEditor(text: $reply)
                    .font(.system(size: 12))
                    .frame(minHeight: 70, maxHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
            HStack(spacing: 6) {
                Button(expanded ? L.cancel : L.inboxReply) {
                    if !expanded { reply = item.suggestedReply }
                    expanded.toggle()
                }
                if expanded {
                    Button(L.inboxSendEllipsis) { confirm = true }
                        .disabled(model.inboxSendTool == nil || sending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(model.inboxSendTool == nil ? L.inboxNoSendTool : L.inboxSendHelp)
                }
                if let link = item.link, let url = URL(string: link) {
                    Button(L.inboxOpen) { NSWorkspace.shared.open(url) }
                }
                Button(L.inboxDismiss) { model.dismissInboxItem(item) }
                if sending {
                    ProgressView().controlSize(.mini)
                    Text(L.inboxSending).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let error = model.inbox.sendErrors[item.id] {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .confirmationDialog(L.inboxConfirmTitle(item.from), isPresented: $confirm, titleVisibility: .visible) {
            Button(L.inboxSend) {
                let text = reply
                Task {
                    if await model.sendInboxReply(item, reply: text) { expanded = false }
                }
            }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(reply)
        }
    }
}

struct InboxSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Groups the user opened or closed by hand; others are open when a tool in them is chosen or a search runs.
    @State private var opened: [String: Bool] = [:]

    var body: some View {
        let settings = model.state.settings
        VStack(alignment: .leading, spacing: 12) {
            Text(L.inboxSetupTitle).font(.headline)
            Text(L.inboxSetupNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Section {
                    Picker(L.inboxAccountLabel, selection: Binding(
                        get: { settings.inboxAccount },
                        set: { id in
                            guard id != settings.inboxAccount else { return }
                            // Tool names belong to an account; a new account starts from a fresh list.
                            model.updateSettings { $0.inboxAccount = id; $0.inboxReadTools = nil; $0.inboxSendTool = nil }
                            model.inbox.availableTools = []
                            model.inbox.unavailableServers = []
                            model.inbox.toolsError = nil
                        })) {
                        Text(L.inboxChooseAccount).tag(UUID?.none)
                        ForEach(model.accounts(for: .claude)) { a in Text(a.label).tag(UUID?.some(a.id)) }
                    }
                    HStack {
                        Button(L.inboxLoadTools) { Task { await model.loadInboxTools() } }
                            .disabled(model.inboxAccount == nil || model.inbox.isLoadingTools)
                            .help(L.inboxLoadToolsHelp)
                        if model.inbox.isLoadingTools {
                            ProgressView().controlSize(.small)
                            Text(L.inboxLoadingTools).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.inbox.toolsError {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    }
                    if !model.inbox.unavailableServers.isEmpty {
                        Text(L.inboxServersUnavailable(model.inbox.unavailableServers))
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    TextField(L.inboxFocusLabel, text: Binding(
                        get: { settings.inboxFocus ?? "" },
                        set: { v in model.updateSettings { $0.inboxFocus = v.isEmpty ? nil : v } }),
                              prompt: Text(L.inboxFocusPrompt))
                    Picker(L.inboxHoursLabel, selection: Binding(
                        get: { settings.inboxHours ?? 24 },
                        set: { v in model.updateSettings { $0.inboxHours = v } })) {
                        ForEach([8, 24, 72], id: \.self) { Text(L.inboxHours($0)).tag($0) }
                    }
                    if !toolList.isEmpty {
                        TextField(L.inboxToolSearch, text: $query, prompt: Text(L.inboxToolSearchPrompt))
                    }
                }
                ForEach(Inbox.groups(filteredTools)) { group in
                    Section { groupRows(group) } header: { groupHeader(group) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L.done) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 600, height: 680)
        .onChange(of: query) { opened.removeAll() }
    }

    private var filteredTools: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return toolList }
        return toolList.filter { $0.localizedCaseInsensitiveContains(q.replacingOccurrences(of: " ", with: "_"))
            || Inbox.toolInfo($0).action.localizedCaseInsensitiveContains(q) }
    }

    private func chosen(_ group: Inbox.ToolGroup) -> (read: Int, send: Bool) {
        let names = Set(group.tools.map(\.name))
        return (model.inboxReadTools.filter(names.contains).count, model.inboxSendTool.map(names.contains) ?? false)
    }

    private func isOpen(_ group: Inbox.ToolGroup) -> Binding<Bool> {
        let c = chosen(group)
        let byDefault = c.read > 0 || c.send || !query.isEmpty
        return Binding(get: { opened[group.server] ?? byDefault }, set: { opened[group.server] = $0 })
    }

    private func groupHeader(_ group: Inbox.ToolGroup) -> some View {
        let c = chosen(group)
        let readable = group.tools.filter { $0.kind == .read }.map(\.name)
        return HStack(spacing: 8) {
            Button { isOpen(group).wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen(group).wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 10)
                    Text(group.server).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                    Text(L.inboxGroupSummary(total: group.tools.count, read: c.read, send: c.send))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if !readable.isEmpty {
                Button(L.inboxSelectReadTools) { selectRead(readable) }
                    .help(L.inboxSelectReadToolsHelp)
                    .disabled(readable.allSatisfy { model.inboxReadTools.contains($0) || model.inboxSendTool == $0 })
            }
            if c.read > 0 || c.send {
                Button(L.inboxClearTools) { clear(group) }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .textCase(nil)
    }

    @ViewBuilder private func groupRows(_ group: Inbox.ToolGroup) -> some View {
        if isOpen(group).wrappedValue {
            ForEach(group.tools.filter { $0.kind != .change }, id: \.name) { toolRow($0) }
            let changing = group.tools.filter { $0.kind == .change }
            if !changing.isEmpty {
                DisclosureGroup {
                    ForEach(changing, id: \.name) { toolRow($0) }
                } label: {
                    Text(L.inboxChangeTools(changing.count)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .help(L.inboxChangeToolsHelp)
                }
            }
        }
    }

    private func toolRow(_ info: Inbox.ToolInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: info.kind == .read ? "eye" : info.kind == .send ? "paperplane" : "pencil")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(info.action).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                .help(info.name)
            Spacer(minLength: 8)
            Picker(selection: role(info.name)) {
                Text(L.inboxToolUnused).tag(Inbox.ToolRole.unused)
                Text(L.inboxRead).tag(Inbox.ToolRole.read)
                Text(L.inboxSendRole).tag(Inbox.ToolRole.send)
            } label: { EmptyView() }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
    }

    private func selectRead(_ names: [String]) {
        model.updateSettings { s in
            var read = s.inboxReadTools ?? []
            for n in names where !read.contains(n) && s.inboxSendTool != n { read.append(n) }
            s.inboxReadTools = read.isEmpty ? nil : read
        }
    }

    private func clear(_ group: Inbox.ToolGroup) {
        let names = Set(group.tools.map(\.name))
        model.updateSettings { s in
            let read = (s.inboxReadTools ?? []).filter { !names.contains($0) }
            s.inboxReadTools = read.isEmpty ? nil : read
            if let send = s.inboxSendTool, names.contains(send) { s.inboxSendTool = nil }
        }
    }

    /// Loaded tools plus any already chosen (so a choice stays visible before Load Tools).
    private var toolList: [String] {
        var tools = model.inbox.availableTools
        for t in model.inboxReadTools + [model.inboxSendTool].compactMap({ $0 }) where !tools.contains(t) { tools.append(t) }
        return tools
    }

    private func role(_ tool: String) -> Binding<Inbox.ToolRole> {
        Binding(
            get: {
                if model.inboxSendTool == tool { return .send }
                return model.inboxReadTools.contains(tool) ? .read : .unused
            },
            set: { new in
                model.updateSettings { s in
                    var read = (s.inboxReadTools ?? []).filter { $0 != tool }
                    if s.inboxSendTool == tool { s.inboxSendTool = nil }
                    switch new {
                    case .read: read.append(tool)
                    case .send: s.inboxSendTool = tool
                    case .unused: break
                    }
                    s.inboxReadTools = read.isEmpty ? nil : read
                }
            })
    }
}
