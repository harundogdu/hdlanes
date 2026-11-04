import Foundation

/// "Check with another account": one `claude -p` call, with no tools, reads a session's diff and
/// returns findings that become review notes on the diff. Pure: building the prompt, reading the reply
/// and anchoring findings to diff lines.
public enum CrossCheck {
    /// Characters of diff text sent at most; the rest is cut and the prompt says so.
    public static let defaultDiffLimit = 120_000

    /// The diff as the reviewer sees it: per file a header, then each line prefixed with its new-file
    /// number (`N123`) or old-file number for removed lines (`O45`), so findings can name a line.
    public static func renderDiff(_ files: [DiffFile], limit: Int = defaultDiffLimit) -> (text: String, truncated: Bool) {
        var out = ""
        for file in files {
            var block = "=== \(file.path)"
            if let old = file.oldPath, old != file.path { block += " (renamed from \(old))" }
            block += " [\(file.status)]\n"
            if let omitted = file.omitted { block += "(\(omitted.rawValue), not shown)\n" }
            for line in file.lines {
                switch line.kind {
                case .added: block += "N\(line.newLine ?? 0) + \(line.text)\n"
                case .removed: block += "O\(line.oldLine ?? 0) - \(line.text)\n"
                case .context: block += "N\(line.newLine ?? 0)   \(line.text)\n"
                case .hunkHeader: block += "\(line.text)\n"
                case .meta: continue
                }
            }
            if out.count + block.count > limit {
                let room = max(0, limit - out.count)
                out += String(block.prefix(room))
                return (out, true)
            }
            out += block
        }
        return (out, false)
    }

    /// `language` is the name of the language the notes should be written in ("English", "Turkish").
    public static func prompt(title: String, diff: String, truncated: Bool, language: String) -> String {
        """
        You are a second reviewer looking at changes another coding agent made. Find real problems only: \
        bugs, wrong logic, data loss, security issues, missing error handling, broken edge cases. Skip \
        style, naming and praise. At most 10 findings; none is a fine answer.

        Reply with only a JSON array, no prose and no code fence. Each item: \
        {"file": "<path as shown after ===>", "line": <number after N, or null>, \
        "removedLine": <number after O when the problem is a removed line, else null>, \
        "note": "<one or two sentences: the problem and the fix>"}. Write "note" in \(language).

        Task title: \(title)
        \(truncated ? "The diff below was cut at a size limit; review what is shown.\n" : "")
        \(diff)
        """
    }

    public struct Finding: Equatable, Sendable {
        public var file: String
        public var line: Int?
        public var removedLine: Int?
        public var note: String

        public init(file: String, line: Int?, removedLine: Int? = nil, note: String) {
            self.file = file
            self.line = line
            self.removedLine = removedLine
            self.note = note
        }
    }

    /// Findings from the model's reply: the first JSON array in it (code fences tolerated). nil when
    /// there is no readable array; items without a note are dropped.
    public static func parseFindings(_ reply: String) -> [Finding]? {
        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let items) = json else { return nil }
        return items.compactMap { item in
            guard let note = item["note"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty
            else { return nil }
            let file = item["file"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            return Finding(file: file, line: item["line"]?.double.map { Int($0) },
                           removedLine: item["removedLine"]?.double.map { Int($0) }, note: note)
        }
    }

    /// Where a finding lands on the diff.
    public struct Anchor: Equatable, Sendable {
        public var filePath: String
        public var newLine: Int?
        public var oldLine: Int?
        public var lineText: String
        public var note: String
    }

    /// Matches each finding to a diff file (exact path, else a unique path suffix) and line. A line that
    /// isn't in the diff becomes a file-level note; a file that isn't in the diff keeps the path the
    /// model gave (or "" when none) so the note is never lost.
    public static func anchor(_ findings: [Finding], in files: [DiffFile]) -> [Anchor] {
        findings.map { f in
            guard let file = matchFile(f.file, files) else {
                return Anchor(filePath: f.file, newLine: nil, oldLine: nil, lineText: "", note: f.note)
            }
            if let n = f.line, let row = file.lines.first(where: { $0.newLine == n && $0.kind != .removed }) {
                return Anchor(filePath: file.path, newLine: n, oldLine: row.oldLine, lineText: row.text, note: f.note)
            }
            if let o = f.removedLine, let row = file.lines.first(where: { $0.kind == .removed && $0.oldLine == o }) {
                return Anchor(filePath: file.path, newLine: nil, oldLine: o, lineText: row.text, note: f.note)
            }
            return Anchor(filePath: file.path, newLine: nil, oldLine: nil, lineText: "", note: f.note)
        }
    }

    private static func matchFile(_ path: String, _ files: [DiffFile]) -> DiffFile? {
        let p = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        guard !p.isEmpty else { return nil }
        if let exact = files.first(where: { $0.path == p }) { return exact }
        let suffix = files.filter { $0.path.hasSuffix("/" + p) || p.hasSuffix("/" + $0.path) }
        return suffix.count == 1 ? suffix[0] : nil
    }
}
