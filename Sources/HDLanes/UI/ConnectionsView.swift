import AppKit
import HDCore
import SwiftUI

// OWNER: workspace area. Settings › Connections.
struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Connection?
    @State private var isNew = false

    var body: some View {
        Form {
            Section {
                if model.state.connections.isEmpty {
                    Text(L.noConnections)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.state.connections) { c in
                    ConnectionRow(connection: c) { isNew = false; editing = c }
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.connectionsFooter)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button(L.addConnectionEllipsis) {
                        isNew = true
                        editing = Connection(name: "", kind: .token, variable: "")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { c in
            ConnectionEditor(original: c, isNew: isNew)
                .environment(model)
        }
    }
}

private struct ConnectionRow: View {
    let connection: Connection
    let edit: () -> Void
    @Environment(AppModel.self) private var model
    @State private var confirmRemove = false
    /// Read once per appearance and change, not on every render (each read is a Keychain query).
    @State private var secretSaved = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(L.connectionEnabled, isOn: Binding(
                get: { connection.isEnabled },
                set: { on in
                    var c = connection
                    c.isEnabled = on
                    try? model.saveConnection(c, secret: nil)
                }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button(L.editEllipsis, action: edit)
                Button(L.removeEllipsis) { confirmRemove = true }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .task(id: "\(connection.id)|\(model.connectionsRevision)") { secretSaved = model.connectionHasSecret(connection) }
        .confirmationDialog(L.removeConnectionTitle(connection.name), isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(L.remove, role: .destructive) { model.removeConnection(connection.id) }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.removeConnectionMessage)
        }
    }

    private var detail: String {
        var parts = [L.connectionKindName(connection.kind)]
        switch connection.kind {
        case .kubeconfig: parts.append(((connection.filePath ?? "") as NSString).abbreviatingWithTildeInPath)
        case .mcpURL: parts.append(connection.url ?? "")
        case .mcpCommand: parts.append(connection.command ?? "")
        case .token: break
        }
        if connection.hasSecret {
            parts.append("$" + connection.variable)
            parts.append(L.connectionSecretState(secretSaved))
        }
        parts.append(L.connectionScope(connection.projectIDs?.count))
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct ConnectionEditor: View {
    let original: Connection
    let isNew: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Connection
    @State private var secret = ""
    @State private var removeSecret = false
    @State private var argumentsText = ""
    @State private var error: String?
    @State private var hadSecret = false

    init(original: Connection, isNew: Bool) {
        self.original = original
        self.isNew = isNew
        _draft = State(initialValue: original)
        _argumentsText = State(initialValue: (original.arguments ?? []).joined(separator: " "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? L.addConnection : L.editConnection).font(.headline)
            Form {
                TextField(L.connectionName, text: $draft.name)
                Picker(L.connectionKind, selection: $draft.kind) {
                    ForEach(Connection.Kind.allCases, id: \.self) { Text(L.connectionKindName($0)).tag($0) }
                }
                Text(L.connectionKindNote(draft.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                kindFields
                if draft.hasSecret {
                    TextField(L.connectionVariable, text: $draft.variable, prompt: Text(suggestedVariable))
                        .font(.system(size: 12, design: .monospaced))
                    SecureField(L.connectionSecret, text: $secret,
                                prompt: Text(hadSecret ? L.connectionSecretKeep : (draft.kind == .token ? "" : L.connectionSecretOptional)))
                    if hadSecret {
                        Toggle(L.connectionRemoveSecret, isOn: $removeSecret)
                    }
                }
                projectPicker
            }
            .formStyle(.grouped)
            Text(L.connectionAppliesNext)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let message = error ?? problem.map(L.connectionProblem) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L.save, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(16)
        .frame(width: 520, height: 560)
        .onAppear { hadSecret = !isNew && model.connectionHasSecret(original) }
        .onChange(of: draft.kind) { _, kind in
            // The usual header for a token; an empty prefix (e.g. `X-API-Key`) is kept as typed.
            if kind == .mcpURL, draft.headerName == nil, draft.headerPrefix == nil {
                draft.headerName = "Authorization"
                draft.headerPrefix = "Bearer "
            }
        }
    }

    @ViewBuilder private var kindFields: some View {
        switch draft.kind {
        case .token:
            EmptyView()
        case .mcpCommand:
            TextField(L.connectionCommand, text: optional(\.command), prompt: Text(verbatim: "npx"))
                .font(.system(size: 12, design: .monospaced))
            TextField(L.connectionArguments, text: $argumentsText, prompt: Text(verbatim: "-y @scope/server"))
                .font(.system(size: 12, design: .monospaced))
        case .mcpURL:
            TextField(L.connectionURL, text: optional(\.url), prompt: Text(verbatim: "https://example.com/mcp"))
                .font(.system(size: 12, design: .monospaced))
            TextField(L.connectionHeader, text: optional(\.headerName), prompt: Text(verbatim: "Authorization"))
            TextField(L.connectionHeaderPrefix, text: optional(\.headerPrefix), prompt: Text(verbatim: ""))
        case .kubeconfig:
            HStack {
                TextField(L.connectionFile, text: optional(\.filePath), prompt: Text(verbatim: "~/.kube/readonly.yaml"))
                    .font(.system(size: 12, design: .monospaced))
                Button(L.chooseFileEllipsis, action: chooseFile)
            }
        }
    }

    @ViewBuilder private var projectPicker: some View {
        Toggle(L.connectionAllProjects, isOn: Binding(
            get: { (draft.projectIDs ?? []).isEmpty },
            set: { all in draft.projectIDs = all ? nil : model.state.projects.first.map { [$0.id] } }))
        if !(draft.projectIDs ?? []).isEmpty {
            ForEach(model.state.projects) { p in
                Toggle(p.name, isOn: Binding(
                    get: { draft.projectIDs?.contains(p.id) ?? false },
                    set: { on in
                        var ids = draft.projectIDs ?? []
                        if on { if !ids.contains(p.id) { ids.append(p.id) } } else { ids.removeAll { $0 == p.id } }
                        // Unticking the last one would silently mean "all projects"; keep at least one.
                        if !ids.isEmpty { draft.projectIDs = ids }
                    }))
                    .padding(.leading, 12)
            }
        }
    }

    private var suggestedVariable: String {
        let base = draft.name.uppercased().unicodeScalars.map {
            $0.isASCII && CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
        }.joined().split(separator: "_").joined(separator: "_")
        return (base.isEmpty ? "MY" : base) + "_TOKEN"
    }

    /// The draft as it would be saved.
    private var prepared: Connection {
        var c = draft
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        if c.kind == .kubeconfig {
            c.variable = "KUBECONFIG"
            c.filePath = c.filePath.map { ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }
        } else if c.variable.trimmingCharacters(in: .whitespaces).isEmpty {
            c.variable = suggestedVariable
        } else {
            c.variable = c.variable.trimmingCharacters(in: .whitespaces)
        }
        c.arguments = c.kind == .mcpCommand ? argumentsText.split(whereSeparator: \.isWhitespace).map(String.init) : nil
        if c.kind != .mcpCommand { c.command = nil }
        if c.kind != .mcpURL { c.url = nil; c.headerName = nil; c.headerPrefix = nil }
        if c.kind == .mcpURL, (c.headerName ?? "").isEmpty { c.headerName = "Authorization" }
        if c.kind != .kubeconfig { c.filePath = nil }
        return c
    }

    private var problem: ConnectionRules.Problem? { model.connectionProblem(prepared) }

    private func optional(_ key: WritableKeyPath<Connection, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: key] ?? "" }, set: { draft[keyPath: key] = $0.isEmpty ? nil : $0 })
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kube")
        if panel.runModal() == .OK, let url = panel.url { draft.filePath = url.path }
    }

    private func save() {
        do {
            let value: String? = removeSecret ? "" : (secret.isEmpty ? nil : secret)
            try model.saveConnection(prepared, secret: value)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
