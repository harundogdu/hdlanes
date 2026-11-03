import HDCore
import SwiftUI

/// One file's diff: line-number gutters, added/removed tints, hunk headers, inline review notes.
struct DiffView: View {
    let sessionID: UUID
    let file: DiffFile

    @Environment(AppModel.self) private var model
    @State private var showAll = false
    /// Copy of the line being annotated. A refresh can shift line numbers, so the editor follows the
    /// line's text and the note is built from this copy, never from whatever row sits at the old number.
    @State private var editingLine: DiffLine?
    @State private var draft = ""

    static let initialLineLimit = 3000
    static let gutterWidth: CGFloat = 36
    static let markerWidth: CGFloat = 14

    var body: some View {
        let notes = (model.reviewNotes[sessionID] ?? []).filter { $0.filePath == file.path }
        let shown = showAll ? file.lines : Array(file.lines.prefix(Self.initialLineLimit))
        let placement = Self.place(notes, in: shown)
        let editingRow = editingLine.flatMap { DiffLineLocator.locate($0, in: shown) }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                fileInfo
                if let editing = editingLine, editingRow == nil {
                    // The line left the diff (or the shown part) while the note was being written.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: L.noteLocation(file.path, editing.kind == .removed ? editing.oldLine : editing.newLine))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(verbatim: editing.text)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.leading, Self.gutterWidth * 2 + Self.markerWidth)
                    .padding(.trailing, 10)
                    .padding(.top, 6)
                    noteEditor
                }
                if !placement.unplaced.isEmpty {
                    Text(L.notesNotInDiff)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                    ForEach(placement.unplaced) { note in
                        NoteBubble(note: note, location: L.noteLocation(note.filePath, note.line ?? note.oldLine),
                                   leading: 10) {
                            model.removeReviewNote(note.id, from: sessionID)
                        }
                    }
                }
                ForEach(shown) { line in
                    DiffLineRow(line: line) {
                        draft = ""
                        editingLine = line
                    }
                    ForEach(placement.byLine[line.id] ?? []) { note in
                        NoteBubble(note: note, location: nil, leading: Self.gutterWidth * 2 + Self.markerWidth) {
                            model.removeReviewNote(note.id, from: sessionID)
                        }
                    }
                    if let editingRow, editingRow.id == line.id {
                        noteEditor
                    }
                }
                if !showAll && file.lines.count > Self.initialLineLimit {
                    HStack(spacing: 8) {
                        Text(L.showingFirstLines(Self.initialLineLimit, file.lines.count))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button(L.showAllLines(file.lines.count)) { showAll = true }
                            .controlSize(.small)
                    }
                    .padding(10)
                }
            }
            .padding(.bottom, 8)
        }
        .onChange(of: file.lines) { _, lines in
            // Follow the line being annotated to its new number, so the next refresh looks near it.
            if let editing = editingLine, let row = DiffLineLocator.locate(editing, in: lines) {
                editingLine = DiffLine(id: row.id, kind: editing.kind, text: editing.text,
                                       oldLine: row.oldLine, newLine: row.newLine)
            }
        }
    }

    private var noteEditor: some View {
        NoteEditor(text: $draft) {
            addNote()
        } onCancel: {
            editingLine = nil
        }
    }

    @ViewBuilder
    private var fileInfo: some View {
        let facts = infoLines
        if !facts.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(facts, id: \.self) { fact in
                    Text(verbatim: fact)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var infoLines: [String] {
        var out: [String] = []
        if let old = file.oldPath { out.append(L.renamedFrom(old)) }
        if let old = file.oldMode, let new = file.newMode { out.append(L.modeChange(old, new)) }
        switch file.omitted {
        case .binary: out.append(L.binaryFile)
        case .tooLarge: out.append(L.fileTooLarge)
        case .directory: out.append(L.nestedRepository)
        case nil: if file.lines.isEmpty { out.append(L.noLineChanges) }
        }
        return out
    }

    /// Builds the note from the remembered line, at the number its text has in the current diff.
    private func addNote() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let editing = editingLine else { return }
        let at = DiffLineLocator.locate(editing, in: file.lines) ?? editing
        let note = ReviewNote(filePath: file.path, line: editing.kind == .removed ? nil : at.newLine,
                              lineText: editing.text, text: text, oldLine: at.oldLine)
        model.addReviewNote(note, to: sessionID)
        editingLine = nil
        draft = ""
    }

    /// Attaches notes to the row that shows their line's text, nearest their recorded number. Notes whose
    /// line is not in `lines` are returned separately.
    static func place(_ notes: [ReviewNote], in lines: [DiffLine]) -> (byLine: [Int: [ReviewNote]], unplaced: [ReviewNote]) {
        guard !notes.isEmpty else { return ([:], []) }
        var placed: [Int: [ReviewNote]] = [:]
        var unplaced: [ReviewNote] = []
        for note in notes {
            if let row = DiffLineLocator.locateNote(newLine: note.line, oldLine: note.oldLine, text: note.lineText, in: lines) {
                placed[row.id, default: []].append(note)
            } else {
                unplaced.append(note)
            }
        }
        return (placed, unplaced)
    }
}

/// A single diff line. Owns its hover state so hovering doesn't re-render the whole list.
struct DiffLineRow: View {
    let line: DiffLine
    let onComment: () -> Void

    @State private var isHovered = false

    var body: some View {
        switch line.kind {
        case .hunkHeader:
            Text(verbatim: line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, DiffView.gutterWidth * 2 + DiffView.markerWidth)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
        case .meta:
            Text(verbatim: line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.leading, DiffView.gutterWidth * 2 + DiffView.markerWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .context, .added, .removed:
            HStack(alignment: .top, spacing: 0) {
                number(line.oldLine)
                number(line.newLine)
                Text(verbatim: marker)
                    .foregroundStyle(.secondary)
                    .frame(width: DiffView.markerWidth)
                Text(verbatim: line.text.isEmpty ? " " : line.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.vertical, 0.5)
            .background(tint)
            .overlay(alignment: .topLeading) {
                if isHovered {
                    Button(action: onComment) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L.addNote)
                    .padding(.leading, 3)
                    .padding(.top, 0.5)
                    .help(L.addNote)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        }
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "-"
        default: return " "
        }
    }

    private var tint: Color {
        switch line.kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        default: return .clear
        }
    }

    private func number(_ n: Int?) -> some View {
        Text(verbatim: n.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: DiffView.gutterWidth - 4, alignment: .trailing)
            .padding(.trailing, 4)
    }
}

struct NoteBubble: View {
    let note: ReviewNote
    /// Shown for notes that are not under their line.
    let location: String?
    let leading: CGFloat
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let location {
                    Text(verbatim: location)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: note.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: onRemove) {
                Label(L.removeNote, systemImage: "xmark").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(L.removeNote)
        }
        .padding(6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        .padding(.leading, leading)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
    }
}

struct NoteEditor: View {
    @Binding var text: String
    let onAdd: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .frame(minHeight: 52, maxHeight: 120)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L.notePlaceholder)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Button(L.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L.addNoteButton, action: onAdd)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(.leading, DiffView.gutterWidth * 2 + DiffView.markerWidth)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .onAppear { isFocused = true }
    }
}
