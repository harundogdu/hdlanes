import Foundation

// OWNER: git area.

/// Parses the output of
/// `git diff --no-color --no-ext-diff -M --src-prefix=a/ --dst-prefix=b/ <base>` into files and lines.
///
/// Inside a hunk the remaining old/new line counts decide what a line is, so content such as
/// `--- triple` or `diff --git` in a file never ends a hunk early.
public enum DiffParser {
    public static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: FileBuilder?

        for rawSlice in text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            var line = Substring(rawSlice)
            if line.utf8.last == 13 { line = Substring(line.utf8.dropLast()) }

            if var b = current, b.inHunk {
                if b.consumeHunkLine(line) {
                    current = b
                    continue
                }
                // Malformed or truncated hunk: fall through and read the line as a header.
                b.endHunk()
                current = b
            }

            if line.hasPrefix("diff --git ") {
                if let b = current { files.append(b.build()) }
                var b = FileBuilder()
                if let (a, bPath) = splitHeader(line.dropFirst("diff --git ".count)) {
                    b.headerOld = a
                    b.headerNew = bPath
                }
                current = b
                continue
            }
            guard var b = current else { continue }
            defer { current = b }

            if line.hasPrefix("@@ ") {
                if let h = parseHunkHeader(line) { b.startHunk(h, text: String(line)) }
            } else if line.hasPrefix("\\") {
                b.appendMeta(String(line))
            } else if line.hasPrefix("--- ") {
                let (path, isNull) = pathField(line.dropFirst(4), prefix: "a/")
                b.minusPath = path
                b.minusIsNull = isNull
            } else if line.hasPrefix("+++ ") {
                let (path, isNull) = pathField(line.dropFirst(4), prefix: "b/")
                b.plusPath = path
                b.plusIsNull = isNull
            } else if line.hasPrefix("new file mode ") {
                b.isNew = true
            } else if line.hasPrefix("deleted file mode ") {
                b.isDeleted = true
            } else if line.hasPrefix("old mode ") {
                b.oldMode = String(line.dropFirst("old mode ".count))
            } else if line.hasPrefix("new mode ") {
                b.newMode = String(line.dropFirst("new mode ".count))
            } else if line.hasPrefix("rename from ") {
                b.renameFrom = unquote(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                b.renameTo = unquote(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("copy from ") {
                b.copyFrom = unquote(line.dropFirst("copy from ".count))
            } else if line.hasPrefix("copy to ") {
                b.copyTo = unquote(line.dropFirst("copy to ".count))
            } else if line.hasPrefix("similarity index ") {
                b.similarity = Int(line.dropFirst("similarity index ".count).filter(\.isNumber))
            } else if line.hasPrefix("Binary files ") && line.hasSuffix(" differ") {
                b.isBinary = true
                if line.hasPrefix("Binary files /dev/null and ") { b.isNew = true }
                if line.hasSuffix(" and /dev/null differ") { b.isDeleted = true }
            } else if line.hasPrefix("GIT binary patch") {
                b.isBinary = true
            }
        }
        if let b = current { files.append(b.build()) }
        return files
    }

    // MARK: Untracked files

    /// Bytes git looks at when deciding whether a file is binary.
    public static let binarySniffLength = 8000

    public static func isBinary(_ data: Data) -> Bool {
        data.prefix(binarySniffLength).contains(0)
    }

    /// A diff entry for an untracked file: every line added.
    /// - Parameter data: the file's contents, or nil when it was too large to read.
    public static func untrackedFile(path: String, data: Data?) -> DiffFile {
        if path.hasSuffix("/") {
            return DiffFile(path: String(path.dropLast()), status: .untracked, additions: 0, deletions: 0, lines: [],
                            omitted: .directory)
        }
        guard let data else {
            return DiffFile(path: path, status: .binary, additions: 0, deletions: 0, lines: [], omitted: .tooLarge)
        }
        if isBinary(data) {
            return DiffFile(path: path, status: .binary, additions: 0, deletions: 0, lines: [], omitted: .binary)
        }
        if data.isEmpty {
            return DiffFile(path: path, status: .untracked, additions: 0, deletions: 0, lines: [])
        }
        let text = String(decoding: data, as: UTF8.self)
        var parts = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map(Substring.init)
        let endsWithNewline = data.last == UInt8(ascii: "\n")
        if endsWithNewline { parts.removeLast() }

        var lines: [DiffLine] = []
        lines.reserveCapacity(parts.count + 2)
        lines.append(DiffLine(id: 0, kind: .hunkHeader, text: "@@ -0,0 +1,\(parts.count) @@", oldLine: nil, newLine: nil))
        for (i, part) in parts.enumerated() {
            var content = part
            if content.utf8.last == 13 { content = Substring(content.utf8.dropLast()) }
            lines.append(DiffLine(id: i + 1, kind: .added, text: String(content), oldLine: nil, newLine: i + 1))
        }
        if !endsWithNewline {
            lines.append(DiffLine(id: lines.count, kind: .meta, text: noNewlineMarker, oldLine: nil, newLine: nil))
        }
        return DiffFile(path: path, status: .untracked, additions: parts.count, deletions: 0, lines: lines)
    }

    public static let noNewlineMarker = "\\ No newline at end of file"

    // MARK: Pieces (internal for tests)

    struct HunkHeader: Equatable {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
    }

    /// `@@ -a[,b] +c[,d] @@[ section]`; a missing count means 1.
    static func parseHunkHeader(_ line: Substring) -> HunkHeader? {
        guard line.hasPrefix("@@ -") else { return nil }
        let body = line.dropFirst(3)
        guard let end = body.range(of: " @@") else { return nil }
        let ranges = body[..<end.lowerBound].split(separator: " ")
        guard ranges.count == 2, ranges[0].hasPrefix("-"), ranges[1].hasPrefix("+"),
              let old = parseRange(ranges[0].dropFirst()), let new = parseRange(ranges[1].dropFirst())
        else { return nil }
        return HunkHeader(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1)
    }

    private static func parseRange(_ s: Substring) -> (Int, Int)? {
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(parts[0]) else { return nil }
        if parts.count == 1 { return (start, 1) }
        guard parts.count == 2, let count = Int(parts[1]) else { return nil }
        return (start, count)
    }

    /// Splits `a/<old> b/<new>` from a `diff --git` line. Either side may be C-quoted.
    static func splitHeader(_ rest: Substring) -> (String, String)? {
        if rest.hasPrefix("\"") {
            guard let (first, after) = readQuoted(rest), after.hasPrefix(" ") else { return nil }
            let second = after.dropFirst()
            let b = second.hasPrefix("\"") ? (readQuoted(second)?.0 ?? String(second)) : String(second)
            return (stripPrefix(first, "a/"), stripPrefix(b, "b/"))
        }
        if let r = rest.range(of: " \"b/") {
            let second = rest[rest.index(after: r.lowerBound)...]
            guard let (b, _) = readQuoted(second) else { return nil }
            return (stripPrefix(String(rest[..<r.lowerBound]), "a/"), stripPrefix(b, "b/"))
        }
        // Unquoted names may contain spaces. Without a rename both halves are the same name.
        let count = rest.count
        if count >= 5, (count - 1) % 2 == 0 {
            let half = (count - 1) / 2
            let first = rest.prefix(half)
            let second = rest.suffix(half)
            let sep = rest[rest.index(rest.startIndex, offsetBy: half)]
            if sep == " ", first.hasPrefix("a/"), second.hasPrefix("b/"), first.dropFirst(2) == second.dropFirst(2) {
                return (String(first.dropFirst(2)), String(second.dropFirst(2)))
            }
        }
        if let r = rest.range(of: " b/") {
            return (stripPrefix(String(rest[..<r.lowerBound]), "a/"), String(rest[r.upperBound...]))
        }
        return nil
    }

    /// Path from a `---` / `+++` line. Git appends a tab when the name contains a space.
    private static func pathField(_ value: Substring, prefix: String) -> (String?, Bool) {
        let raw: String
        if value.hasPrefix("\"") {
            raw = readQuoted(value)?.0 ?? String(value)
        } else if let tab = value.firstIndex(of: "\t") {
            raw = String(value[..<tab])
        } else {
            raw = String(value)
        }
        if raw == "/dev/null" { return (nil, true) }
        return (stripPrefix(raw, prefix), false)
    }

    private static func stripPrefix(_ s: String, _ prefix: String) -> String {
        s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
    }

    /// Decodes a C-quoted name as git writes it (`"a/\303\247.txt"`). Octal escapes are bytes of
    /// UTF-8, so they are collected as bytes and decoded once. Unquoted input is returned as is.
    public static func unquote(_ s: Substring) -> String {
        guard s.hasPrefix("\"") else { return String(s) }
        return readQuoted(s)?.0 ?? String(s)
    }

    /// Reads one quoted token; returns the decoded value and what follows the closing quote.
    static func readQuoted(_ s: Substring) -> (String, Substring)? {
        let u = s.utf8
        guard u.first == UInt8(ascii: "\"") else { return nil }
        var bytes: [UInt8] = []
        var i = u.index(after: u.startIndex)
        while i < u.endIndex {
            let c = u[i]
            if c == UInt8(ascii: "\"") {
                let after = u.index(after: i)
                return (String(decoding: bytes, as: UTF8.self), Substring(u[after...]))
            }
            if c == UInt8(ascii: "\\") {
                let e = u.index(after: i)
                guard e < u.endIndex else { break }
                let esc = u[e]
                if (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(esc) {
                    var value = 0
                    var j = e
                    var digits = 0
                    while j < u.endIndex, digits < 3, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(u[j]) {
                        value = value * 8 + Int(u[j] - UInt8(ascii: "0"))
                        j = u.index(after: j)
                        digits += 1
                    }
                    bytes.append(UInt8(truncatingIfNeeded: value))
                    i = j
                    continue
                }
                switch esc {
                case UInt8(ascii: "n"): bytes.append(10)
                case UInt8(ascii: "t"): bytes.append(9)
                case UInt8(ascii: "r"): bytes.append(13)
                case UInt8(ascii: "a"): bytes.append(7)
                case UInt8(ascii: "b"): bytes.append(8)
                case UInt8(ascii: "f"): bytes.append(12)
                case UInt8(ascii: "v"): bytes.append(11)
                default: bytes.append(esc)  // \\ and \"
                }
                i = u.index(after: e)
                continue
            }
            bytes.append(c)
            i = u.index(after: i)
        }
        return nil
    }
}

/// Accumulates one `diff --git` section.
private struct FileBuilder {
    var headerOld: String?
    var headerNew: String?
    var minusPath: String?
    var minusIsNull = false
    var plusPath: String?
    var plusIsNull = false
    var renameFrom: String?
    var renameTo: String?
    var copyFrom: String?
    var copyTo: String?
    var isNew = false
    var isDeleted = false
    var isBinary = false
    var oldMode: String?
    var newMode: String?
    var similarity: Int?

    var lines: [DiffLine] = []
    var additions = 0
    var deletions = 0
    private var oldNext = 0
    private var newNext = 0
    private var oldRemaining = 0
    private var newRemaining = 0

    var inHunk: Bool { oldRemaining > 0 || newRemaining > 0 }

    mutating func startHunk(_ h: DiffParser.HunkHeader, text: String) {
        lines.append(DiffLine(id: lines.count, kind: .hunkHeader, text: text, oldLine: nil, newLine: nil))
        oldNext = h.oldStart
        newNext = h.newStart
        oldRemaining = h.oldCount
        newRemaining = h.newCount
    }

    mutating func endHunk() {
        oldRemaining = 0
        newRemaining = 0
    }

    mutating func appendMeta(_ text: String) {
        lines.append(DiffLine(id: lines.count, kind: .meta, text: text, oldLine: nil, newLine: nil))
    }

    /// Returns false when the line can't belong to the current hunk.
    mutating func consumeHunkLine(_ line: Substring) -> Bool {
        guard let first = line.utf8.first else {
            // An empty line is blank context when `diff.suppressBlankEmpty` is set.
            appendContext("")
            return true
        }
        switch first {
        case UInt8(ascii: " "):
            appendContext(String(line.dropFirst()))
        case UInt8(ascii: "-"):
            lines.append(DiffLine(id: lines.count, kind: .removed, text: String(line.dropFirst()), oldLine: oldNext, newLine: nil))
            oldNext += 1
            oldRemaining = max(0, oldRemaining - 1)
            deletions += 1
        case UInt8(ascii: "+"):
            lines.append(DiffLine(id: lines.count, kind: .added, text: String(line.dropFirst()), oldLine: nil, newLine: newNext))
            newNext += 1
            newRemaining = max(0, newRemaining - 1)
            additions += 1
        case UInt8(ascii: "\\"):
            appendMeta(String(line))
        default:
            return false
        }
        return true
    }

    private mutating func appendContext(_ text: String) {
        lines.append(DiffLine(id: lines.count, kind: .context, text: text, oldLine: oldNext, newLine: newNext))
        oldNext += 1
        newNext += 1
        oldRemaining = max(0, oldRemaining - 1)
        newRemaining = max(0, newRemaining - 1)
    }

    func build() -> DiffFile {
        let newSide = renameTo ?? copyTo ?? (plusIsNull ? nil : plusPath) ?? headerNew
        let oldSide = renameFrom ?? copyFrom ?? (minusIsNull ? nil : minusPath) ?? headerOld
        let deleted = isDeleted || plusIsNull
        let path = (deleted ? (oldSide ?? newSide) : (newSide ?? oldSide)) ?? ""

        let status: DiffFileStatus
        if isBinary {
            status = .binary
        } else if renameFrom != nil || renameTo != nil {
            status = .renamed
        } else if copyTo != nil || isNew || minusIsNull {
            status = .added
        } else if deleted {
            status = .deleted
        } else {
            status = .modified
        }
        return DiffFile(path: path, oldPath: renameFrom ?? copyFrom, status: status,
                        additions: additions, deletions: deletions, lines: isBinary ? [] : lines,
                        omitted: isBinary ? .binary : nil, oldMode: oldMode, newMode: newMode, similarity: similarity)
    }
}

/// Small parsers for other git / gh output.
public enum GitOutput {
    /// Splits `-z` output.
    public static func nulSeparated(_ text: String) -> [String] {
        text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    public struct StatusEntry: Equatable, Sendable {
        /// Two-letter porcelain code, e.g. ` M`, `??`, `R `.
        public var code: String
        public var path: String
        public var originalPath: String?

        public init(code: String, path: String, originalPath: String? = nil) {
            self.code = code
            self.path = path
            self.originalPath = originalPath
        }
    }

    /// `git status --porcelain=v1 -z`. Renames and copies carry the original path as an extra field.
    public static func statusEntries(_ text: String) -> [StatusEntry] {
        let fields = text.split(separator: "\0", omittingEmptySubsequences: true)
        var out: [StatusEntry] = []
        var i = 0
        while i < fields.count {
            let f = fields[i]
            i += 1
            guard f.count >= 4 else { continue }
            let code = String(f.prefix(2))
            let path = String(f.dropFirst(3))
            var original: String?
            if code.contains("R") || code.contains("C"), i < fields.count {
                original = String(fields[i])
                i += 1
            }
            out.append(StatusEntry(code: code, path: path, originalPath: original))
        }
        return out
    }

    /// The URL `gh pr create` prints (also found in its "already exists" error).
    public static func pullRequestURL(in text: String) -> URL? {
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let start = t.range(of: "https://") {
                let candidate = t[start.lowerBound...].prefix { !$0.isWhitespace }
                if let url = URL(string: String(candidate)), url.host != nil { return url }
            }
        }
        return nil
    }

    /// One branch name per line (`for-each-ref --format=%(refname:short)`), current first.
    public static func branchList(_ text: String, current: String?) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        if let current, let i = names.firstIndex(of: current) {
            names.remove(at: i)
            names.insert(current, at: 0)
        }
        return names
    }
}
