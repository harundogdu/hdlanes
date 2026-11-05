import HDCore
import SwiftUI

// OWNER: workspace area.
struct SettingsView: View {
    @AppStorage("hd.settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label(L.general, systemImage: "gearshape") }
                .tag("general")
            AccountsView()
                .tabItem { Label(L.accounts, systemImage: "person.2") }
                .tag("accounts")
            ConnectionsView()
                .tabItem { Label(L.connectionsTab, systemImage: "key") }
                .tag("connections")
            TaskSettings()
                .tabItem { Label(L.tasksTab, systemImage: "checklist") }
                .tag("tasks")
        }
        .frame(width: 620, height: 500)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker(L.languageLabel, selection: language) {
                    Text(L.languageSystem).tag(AppLanguage.system)
                    Text(L.languageEnglish).tag(AppLanguage.english)
                    Text(L.languageTurkish).tag(AppLanguage.turkish)
                }
                Text(L.languageNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section(L.notifications) {
                Toggle(L.notifyNeedsYou, isOn: flag(\.notifyNeedsYou, default: true))
                Toggle(L.notifyDone, isOn: flag(\.notifyDone, default: true))
            }
            Section(L.permissions) {
                Toggle(L.permissionsInSidebar, isOn: permissionsInSidebar)
                Text(L.permissionsInSidebarNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section(L.terminal) {
                Stepper(value: fontSize, in: 9...24, step: 1) {
                    Text(L.terminalFontSize(Int(fontSize.wrappedValue)))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var language: Binding<AppLanguage> {
        Binding(get: { model.state.settings.language ?? .system },
                set: { lang in
                    L.language = lang
                    model.state.settings.language = lang
                })
    }

    /// The plugin's hooks.json has the PermissionRequest hook only while this is on, so a change rewrites
    /// it; new Claude sessions then load the new one.
    private var permissionsInSidebar: Binding<Bool> {
        Binding(get: { model.state.settings.permissionsInSidebar ?? true },
                set: { on in
                    let old = model.state.settings.permissionsInSidebar ?? true
                    model.state.settings.permissionsInSidebar = on
                    if old != on { model.refreshClaudePlugin() }
                })
    }

    private func flag(_ key: WritableKeyPath<AppSettings, Bool?>, default value: Bool) -> Binding<Bool> {
        Binding(get: { model.state.settings[keyPath: key] ?? value },
                set: { model.state.settings[keyPath: key] = $0 })
    }

    private var fontSize: Binding<Double> {
        Binding(get: { model.state.settings.terminalFontSize ?? 13 },
                set: { size in
                    model.state.settings.terminalFontSize = size
                    model.terminals.applyFontSize(size)
                })
    }
}

private struct TaskSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let claudeAccounts = model.accounts(for: .claude)
        Form {
            Section {
                Toggle(L.aiCategorization, isOn: Binding(get: { model.state.settings.aiCategorization == true },
                                                         set: { model.state.settings.aiCategorization = $0 }))
                Picker(L.aiAccount, selection: Binding(get: { model.aiCategorizationAccount?.id },
                                                       set: { model.state.settings.aiCategorizationAccount = $0 })) {
                    if claudeAccounts.isEmpty { Text(L.noClaudeAccount).tag(UUID?.none) }
                    ForEach(claudeAccounts) { a in
                        Text(L.accountPickerLabel(a)).tag(Optional(a.id))
                    }
                }
                .disabled(model.state.settings.aiCategorization != true || claudeAccounts.isEmpty)
                Text(L.aiCategorizationNote(model.aiCategorizationAccount?.label))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text(L.categories)
            } footer: {
                Text(L.rulesNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Name, worktree location, setup command, files to copy and default accounts of a project.
struct ProjectSettingsSheet: View {
    let projectID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Project?
    @State private var copyFilesText = ""

    var body: some View {
        VStack(spacing: 0) {
            if let draft {
                form(draft)
            } else {
                ContentUnavailableView(L.errProjectMissing, systemImage: "folder.badge.questionmark")
            }
            Divider()
            HStack {
                Spacer()
                Button(L.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L.save, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft?.name.nilIfBlank == nil)
            }
            .padding(12)
        }
        .frame(width: 540)
        .onAppear {
            draft = model.project(projectID)
            copyFilesText = (draft?.copyFiles ?? []).joined(separator: "\n")
        }
    }

    private func binding<T>(_ key: WritableKeyPath<Project, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { draft?[keyPath: key] ?? fallback }, set: { draft?[keyPath: key] = $0 })
    }

    private func form(_ project: Project) -> some View {
        Form {
            Section {
                TextField(L.projectName, text: binding(\.name, ""))
                LabeledContent(L.location) {
                    Text(project.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Section {
                LabeledContent(L.worktreeRoot) {
                    HStack {
                        Text(project.worktreeRoot ?? L.worktreeRootDefault(project.path))
                            .font(.system(size: 11))
                            .foregroundStyle(project.worktreeRoot == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(L.chooseEllipsis) {
                            if let url = Panels.chooseFolder(message: L.worktreeRootMessage, prompt: L.choose) {
                                draft?.worktreeRoot = HDPaths.normalizedDirString(url.path)
                            }
                        }
                        if project.worktreeRoot != nil {
                            Button(L.reset) { draft?.worktreeRoot = nil }
                        }
                    }
                }
                TextField(L.setupCommand, text: Binding(get: { draft?.setupCommand ?? "" },
                                                        set: { draft?.setupCommand = $0.nilIfBlank }),
                          prompt: Text(L.setupCommandPlaceholder))
                    .font(Theme.mono)
                LabeledContent(L.copyFiles) {
                    TextEditor(text: $copyFilesText)
                        .font(Theme.monoSmall)
                        .frame(minHeight: 54, maxHeight: 100)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                }
            } header: {
                Text(L.worktrees)
            } footer: {
                Text(L.worktreeFooter)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section(L.defaultAccounts) {
                accountPicker(.claude, \.defaultClaudeAccount)
                accountPicker(.codex, \.defaultCodexAccount)
            }
            ReviewTemplateSection(template: Binding(get: { draft?.reviewPromptTemplate },
                                                    set: { draft?.reviewPromptTemplate = $0 }))
        }
        .formStyle(.grouped)
    }

    private func accountPicker(_ provider: Provider, _ key: WritableKeyPath<Project, UUID?>) -> some View {
        Picker(L.providerName(provider), selection: binding(key, nil)) {
            Text(L.firstAccount).tag(UUID?.none)
            ForEach(model.accounts(for: provider)) { a in
                Text(L.accountPickerLabel(a)).tag(Optional(a.id))
            }
        }
    }

    private func save() {
        guard var project = draft else { return }
        project.name = project.name.nilIfBlank ?? project.name
        let files = copyFilesText.split(whereSeparator: \.isNewline).compactMap { String($0).nilIfBlank }
        project.copyFiles = files.isEmpty ? nil : files
        model.updateProject(projectID) { $0 = project }
        dismiss()
    }
}
