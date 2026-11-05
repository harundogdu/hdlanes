import HDCore
import SwiftUI

// OWNER: workspace area.

/// Backlog / Active / Review / Done. Cards move by drag and drop or the context menu.
struct TaskBoardView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: IdentifiedID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.board)
                    .font(.system(size: 13, weight: .semibold))
                Text(L.taskCount(model.state.tasks.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.isNewTaskSheetPresented = true } label: {
                    Label(L.newTask, systemImage: "plus")
                }
                .controlSize(.small)
                .help(L.newTaskHelp)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            Divider()
            if model.state.tasks.isEmpty {
                ContentUnavailableView {
                    Label(L.noTasks, systemImage: "checklist")
                } description: {
                    Text(L.noTasksBody)
                } actions: {
                    Button(L.newTaskEllipsis) { model.isNewTaskSheetPresented = true }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        BoardColumn(status: status) { editing = IdentifiedID(id: $0) }
                    }
                }
                .padding(10)
            }
        }
        .sheet(item: $editing) { TaskEditorSheet(taskID: $0.id) }
    }
}

private struct BoardColumn: View {
    let status: TaskStatus
    let edit: (UUID) -> Void
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        let tasks = model.tasks(in: status)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L.taskStatusName(status))
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: "\(tasks.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(tasks) { task in
                        TaskCard(task: task, edit: edit)
                    }
                    if tasks.isEmpty {
                        Text(L.dropTasksHere)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .padding(2)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(isTargeted ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quaternary.opacity(0.35)),
                    in: RoundedRectangle(cornerRadius: 6))
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(UUID.init(uuidString:))
            for id in ids { model.setTaskStatus(id, status) }
            return !ids.isEmpty
        } isTargeted: { isTargeted = $0 }
    }
}

private struct TaskCard: View {
    let task: TaskItem
    let edit: (UUID) -> Void
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    @State private var isCategorizing = false
    @State private var aiError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                CategoryChip(category: task.category)
                    .help(task.categorizedByAI == true ? L.categorizedByAI : L.categoryLabel)
                if isCategorizing { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
                if let p = model.project(task.projectID) {
                    Text(p.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(task.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(3)
            if let notes = task.notes {
                Text(notes)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            LinkedSessions(sessions: model.sessions(forTask: task.id))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { edit(task.id) }
        .draggable(task.id.uuidString) {
            Text(task.title)
                .font(.system(size: 12))
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 5))
        }
        .contextMenu { menu }
        .confirmationDialog(L.deleteTaskTitle(task.title), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L.delete, role: .destructive) { model.deleteTask(task.id) }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.deleteTaskMessage(model.sessions(forTask: task.id).count))
        }
        .alert(L.aiCategorizeFailed, isPresented: isPresented($aiError), presenting: aiError) { _ in
            Button(L.ok) {}
        } message: { Text($0) }
    }

    @ViewBuilder
    private var menu: some View {
        Button(L.startSessionEllipsis) { model.startSession(forTask: task.id) }
        Button(L.editEllipsis) { edit(task.id) }
        if model.isAICategorizationEnabled {
            Button(L.suggestCategoryAI, action: categorize)
                .disabled(isCategorizing)
        }
        Menu(L.moveTo) {
            ForEach(TaskStatus.allCases.filter { $0 != task.status }, id: \.self) { s in
                Button(L.taskStatusName(s)) { model.setTaskStatus(task.id, s) }
            }
        }
        Divider()
        Button(L.deleteEllipsis) { confirmDelete = true }
    }

    private func categorize() {
        isCategorizing = true
        Task {
            do {
                try await model.categorizeTaskWithAI(task.id)
            } catch {
                aiError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isCategorizing = false
        }
    }
}

private struct LinkedSessions: View {
    let sessions: [AgentSession]
    @Environment(AppModel.self) private var model

    var body: some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sessions) { s in
                    Button { model.selection = .session(s.id) } label: {
                        HStack(spacing: 4) {
                            StatusGlyph(status: model.liveStatus(s.id), size: 10)
                            Text(s.title).lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L.openSession)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// New task (taskID nil) or edit. The category follows the title until the user picks one.
struct TaskEditorSheet: View {
    let taskID: UUID?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var notes = ""
    @State private var projectID: UUID?
    @State private var category = Categorizer.defaultID
    @State private var categoryChosen = false
    @State private var startNow = false
    @State private var isSuggesting = false
    @State private var aiCategory: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L.titleLabel, text: $title, prompt: Text(L.taskTitlePlaceholder))
                    LabeledContent(L.notes) {
                        TextEditor(text: $notes)
                            .font(.system(size: 13))
                            .frame(minHeight: 70, maxHeight: 160)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(.background, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                    }
                }
                Section {
                    Picker(L.project, selection: $projectID) {
                        Text(L.noProject).tag(UUID?.none)
                        ForEach(model.state.projects) { p in Text(p.name).tag(Optional(p.id)) }
                    }
                    HStack {
                        Picker(L.categoryLabel, selection: Binding(get: { category }, set: { category = $0; categoryChosen = true })) {
                            ForEach(Categorizer.ids, id: \.self) { id in Text(L.categoryName(id)).tag(id) }
                        }
                        if model.isAICategorizationEnabled {
                            Button(L.suggestWithAI, action: suggest)
                                .disabled(isSuggesting || title.nilIfBlank == nil)
                                .help(L.suggestWithAIHelp(model.aiProvider))
                        }
                        if isSuggesting { ProgressView().controlSize(.small) }
                    }
                    if taskID == nil {
                        Toggle(L.startSessionNow, isOn: $startNow)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button(L.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(taskID == nil ? L.add : L.save, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.nilIfBlank == nil)
            }
            .padding(12)
        }
        .frame(width: 480)
        .onAppear(perform: load)
        .onChange(of: title) { _, _ in autoCategory() }
        .onChange(of: notes) { _, _ in autoCategory() }
    }

    private func load() {
        if let t = model.task(taskID) {
            title = t.title
            notes = t.notes ?? ""
            projectID = t.projectID
            category = t.category
            categoryChosen = true
        } else {
            projectID = model.selectedSessionID.flatMap { model.session($0)?.projectID }
        }
    }

    private func autoCategory() {
        guard !categoryChosen else { return }
        category = Categorizer.categorize(title: title, prompt: notes)
    }

    private func suggest() {
        isSuggesting = true
        error = nil
        Task {
            do {
                let suggested = try await model.aiSuggestCategory(title: title, notes: notes)
                category = suggested
                aiCategory = suggested
                categoryChosen = true
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isSuggesting = false
        }
    }

    private func save() {
        let id: UUID
        if let taskID {
            model.editTask(taskID, title: title, notes: notes, projectID: projectID, category: category)
            id = taskID
        } else {
            id = model.addTask(title: title, notes: notes, projectID: projectID, category: category).id
        }
        if let aiCategory, aiCategory == category { model.updateTask(id) { $0.categorizedByAI = true } }
        dismiss()
        guard taskID == nil else { return }
        if startNow {
            // A second sheet on the same window only appears after the first is gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.startSession(forTask: id) }
        }
    }
}
