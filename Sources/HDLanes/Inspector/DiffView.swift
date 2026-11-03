import HDCore
import SwiftUI

/// One file's diff: line-number gutters, added/removed tints, hunk headers, inline review notes.
struct DiffView: View {
    let sessionID: UUID
    let file: DiffFile

    @Environment(AppModel.self) private var model
    @State private var showAll = false
    /// Line being annotated, by number so a refresh that shifts the array doesn't move the editor.
    @State private var editingAnchor: String?
    @State private var draft = ""

    static let initialLineLimit = 3000
    static let gutterWidth: CGFloat = 36
    static let markerWidth: CGFloat = 14

    var body: some View {
        let notes = (model.reviewNotes[sessionID] ?? []).filter { $0.filePath == file.path }
        let shown = showAll ? file.lines : Array(file.lines.prefix(Self.initialLineLimit))
        let placement = Self.place(notes, in: shown)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                fileInfo
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
                        editingAnchor = Self.anchor(line)
                    }
                    ForEach(placement.byLine[line.id] ?? []) { note in
                        NoteBubble(note: note, location: nil, leading: Self.gutterWidth * 2 + Self.markerWidth) {
                            model.removeReviewNote(note.id, from: sessionID)
                        }
                    }
                    if let anchor = editingAnchor, anchor == Self.anchor(line) {
                        NoteEditor(text: $draft) {
                            addNote(on: line)
                        } onCancel: {
                            editingAnchor = nil
                        }
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

    private func addNote(on line: DiffLine) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let note = ReviewNote(filePath: file.path, line: line.kind == .removed ? nil : line.newLine,
                              lineText: line.text, text: text, oldLine: line.oldLine)
        model.addReviewNote(note, to: sessionID)
        editingAnchor = nil
        draft = ""
    }

    /// `n12` for a line that exists in the new file, `o7` for a removed line, nil for headers.
    static func anchor(_ line: DiffLine) -> String? {
        switch line.kind {
        case .context, .added: return line.newLine.map { "n\($0)" }
        case .removed: return line.oldLine.map { "o\($0)" }
        case .hunkHeader, .meta: return nil
        }
    }

    /// Attaches notes to the line they were written on: by new-file number, or by old-file number for
    /// removed lines. Notes whose line is not in `lines` are returned separately.
    static func place(_ notes: [ReviewNote], in lines: [DiffLine]) -> (byLine: [Int: [ReviewNote]], unplaced: [ReviewNote]) {
        guard !notes.isEmpty else { return ([:], []) }
        var byNew: [Int: Int] = [:]
        var byOld: [Int: Int] = [:]
        for line in lines {
            switch line.kind {
            case .context, .added: if let n = line.newLine, byNew[n] == nil { byNew[n] = line.id }
            case .removed: if let o = line.oldLine, byOld[o] == nil { byOld[o] = line.id }
            case .hunkHeader, .meta: break
            }
        }
        var placed: [Int: [ReviewNote]] = [:]
        var unplaced: [ReviewNote] = []
        for note in notes {
            let target = note.line.flatMap { byNew[$0] } ?? (note.line == nil ? note.oldLine.flatMap { byOld[$0] } : nil)
            if let target { placed[target, default: []].append(note) } else { unplaced.append(note) }
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
