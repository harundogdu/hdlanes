import Foundation

// OWNER: git area. Parsed `git diff` output.

public enum DiffLineKind: String, Sendable, Equatable {
    case context, added, removed, hunkHeader, meta
}

public struct DiffLine: Identifiable, Equatable, Sendable {
    public var id: Int
    public var kind: DiffLineKind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?

    public init(id: Int, kind: DiffLineKind, text: String, oldLine: Int?, newLine: Int?) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }
}

public enum DiffFileStatus: String, Sendable, Equatable {
    case modified, added, deleted, renamed, untracked, binary
}

/// Why a file's lines are not shown.
public enum DiffOmission: String, Sendable, Equatable {
    case binary
    /// Untracked file above the read cap.
    case tooLarge
    /// Untracked nested repository (`ls-files` lists it as `dir/`).
    case directory
}

public struct DiffFile: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var oldPath: String?
    public var status: DiffFileStatus
    public var additions: Int
    public var deletions: Int
    public var lines: [DiffLine]
    public var omitted: DiffOmission?
    /// Set for mode changes (`old mode 100644` → `new mode 100755`).
    public var oldMode: String?
    public var newMode: String?
    /// Rename similarity in percent.
    public var similarity: Int?

    public init(path: String, oldPath: String? = nil, status: DiffFileStatus, additions: Int, deletions: Int, lines: [DiffLine],
                omitted: DiffOmission? = nil, oldMode: String? = nil, newMode: String? = nil, similarity: Int? = nil) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.lines = lines
        self.omitted = omitted
        self.oldMode = oldMode
        self.newMode = newMode
        self.similarity = similarity
    }

    /// Last path component.
    public var fileName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Directory part with a trailing slash, or "" for top-level files.
    public var directory: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }

    /// Number of lines that carry content (excludes hunk headers and meta lines).
    public var contentLineCount: Int {
        lines.reduce(0) { $0 + ($1.kind == .hunkHeader || $1.kind == .meta ? 0 : 1) }
    }
}

/// A line comment as sent to the agent.
public struct ReviewComment: Equatable, Sendable {
    public var path: String
    /// New-file line number (context and added lines).
    public var newLine: Int?
    /// Old-file line number, used when the comment is on a removed line.
    public var oldLine: Int?
    public var lineText: String
    public var text: String

    public init(path: String, newLine: Int?, oldLine: Int?, lineText: String, text: String) {
        self.path = path
        self.newLine = newLine
        self.oldLine = oldLine
        self.lineText = lineText
        self.text = text
    }
}

/// Builds the single message that carries all review notes to the agent.
public enum ReviewMessage {
    /// - Parameters:
    ///   - header: first line of the message.
    ///   - removedLine: label for a comment on a removed line, e.g. `removed line 7`.
    public static func format(header: String, comments: [ReviewComment], removedLine: (Int) -> String) -> String {
        let ordered = comments.enumerated().sorted { a, b in
            if a.element.path != b.element.path { return a.element.path < b.element.path }
            let la = a.element.newLine ?? a.element.oldLine ?? 0
            let lb = b.element.newLine ?? b.element.oldLine ?? 0
            if la != lb { return la < lb }
            return a.offset < b.offset
        }.map(\.element)

        var blocks: [String] = [header]
        for c in ordered {
            var block: [String] = []
            if let n = c.newLine {
                block.append("\(c.path):\(n)")
            } else if let o = c.oldLine {
                block.append("\(c.path) (\(removedLine(o)))")
            } else {
                block.append(c.path)
            }
            let quoted = c.lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !quoted.isEmpty { block.append("> " + quoted) }
            block.append(c.text.trimmingCharacters(in: .whitespacesAndNewlines))
            blocks.append(block.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }
}
