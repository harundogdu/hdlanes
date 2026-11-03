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

public struct DiffFile: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var oldPath: String?
    public var status: DiffFileStatus
    public var additions: Int
    public var deletions: Int
    public var lines: [DiffLine]

    public init(path: String, oldPath: String? = nil, status: DiffFileStatus, additions: Int, deletions: Int, lines: [DiffLine]) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.lines = lines
    }
}
