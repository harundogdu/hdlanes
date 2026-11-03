import Foundation

// OWNER: git area. Names and places for new worktrees, branch-name validation, `git worktree list`.

public enum WorktreePlanner {
    public static let branchPrefix = "hd/"
    public static let maxSlugLength = 40
    public static let fallbackSlug = "session"

    /// Lowercase ASCII slug: Turkish letters transliterated, other accents folded, everything else `-`.
    public static func slug(from title: String, maxLength: Int = maxSlugLength) -> String {
        let turkish: [Character: String] = [
            "ç": "c", "Ç": "c", "ğ": "g", "Ğ": "g", "ı": "i", "İ": "i",
            "ö": "o", "Ö": "o", "ş": "s", "Ş": "s", "ü": "u", "Ü": "u",
        ]
        var mapped = ""
        for ch in title { mapped += turkish[ch] ?? String(ch) }
        let folded = mapped.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                    locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        var lastWasDash = true
        for scalar in folded.unicodeScalars {
            let v = scalar.value
            let isAlnum = (0x61...0x7A).contains(v) || (0x30...0x39).contains(v)
            let isUpper = (0x41...0x5A).contains(v)
            if isAlnum || isUpper {
                out.unicodeScalars.append(isUpper ? Unicode.Scalar(v + 0x20)! : scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        if out.count > maxLength { out = String(out.prefix(maxLength)) }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? fallbackSlug : out
    }

    /// Slug for a worktree directory named after a branch (`hd/fix-login` → `fix-login`).
    public static func slug(forBranch branch: String) -> String {
        let name = branch.hasPrefix(branchPrefix) ? String(branch.dropFirst(branchPrefix.count)) : branch
        return slug(from: name)
    }

    /// `hd/<slug>`, made unique against `existing` with `-2`, `-3`, ….
    /// Also avoids ref directory/file clashes (`hd/x` can't coexist with `hd/x/y` or a branch `hd`).
    public static func defaultBranch(for title: String, existing: [String]) -> String {
        let s = slug(from: title)
        let taken = existing.map { $0.lowercased() }
        let prefix = taken.contains(String(branchPrefix.dropLast())) ? "hd-" : branchPrefix
        let base = prefix + s
        if !refConflicts(base, taken) { return base }
        for n in 2...999 where !refConflicts("\(base)-\(n)", taken) {
            return "\(base)-\(n)"
        }
        return "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func refConflicts(_ candidate: String, _ taken: [String]) -> Bool {
        let c = candidate.lowercased()
        return taken.contains { $0 == c || $0.hasPrefix(c + "/") || c.hasPrefix($0 + "/") }
    }

    /// Folder that holds a repo's worktrees: the project's override or `<parent>/<repo>-worktrees`.
    /// A relative override is taken relative to the repo; `~` is expanded.
    public static func worktreeParent(repoRoot: String, worktreeRoot: String?) -> String {
        let root = URL(fileURLWithPath: repoRoot).standardizedFileURL
        if let custom = worktreeRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded)
            return HDPaths.normalizedDirString(url.standardizedFileURL.path)
        }
        let parent = root.deletingLastPathComponent()
        return HDPaths.normalizedDirString(parent.appendingPathComponent(root.lastPathComponent + "-worktrees").path)
    }

    /// `<parent>/<slug>`, unique against the names already in `parent` (case-insensitive, like APFS).
    public static func worktreePath(slug: String, parent: String, existingNames: [String]) -> String {
        let taken = Set(existingNames.map { $0.lowercased() })
        var name = slug
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "\(slug)-\(n)"
            n += 1
        }
        return (parent as NSString).appendingPathComponent(name)
    }

    /// Mirrors `git check-ref-format` for `refs/heads/<name>` plus git's own branch rules.
    public static func validateBranchName(_ name: String) -> BranchNameProblem? {
        if name.isEmpty { return .empty }
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return .controlCharacter }
            if scalar == " " { return .containsSpace }
            if "~^:?*[\\".unicodeScalars.contains(scalar) { return .invalidCharacter(Character(scalar)) }
        }
        if name.contains("..") { return .doubleDot }
        if name.contains("@{") { return .atBrace }
        if name == "@" { return .isAt }
        if name.hasPrefix("-") { return .leadingDash }
        if name.hasPrefix("/") || name.hasSuffix("/") || name.contains("//") { return .slash }
        if name.hasSuffix(".") { return .trailingDot }
        for part in name.split(separator: "/") {
            if part.hasPrefix(".") { return .componentStartsWithDot }
            if part.hasSuffix(".lock") { return .lockSuffix }
        }
        if name == "HEAD" { return .reserved }
        return nil
    }
}

public enum BranchNameProblem: Equatable, Sendable {
    case empty
    case controlCharacter
    case containsSpace
    case invalidCharacter(Character)
    case doubleDot
    case atBrace
    case isAt
    case leadingDash
    /// Starts or ends with `/`, or contains `//`.
    case slash
    case trailingDot
    case componentStartsWithDot
    case lockSuffix
    case reserved
}

/// One entry of `git worktree list --porcelain`.
public struct WorktreeEntry: Equatable, Sendable {
    public var path: String
    public var head: String?
    /// Short branch name (`refs/heads/` removed); nil when detached or bare.
    public var branch: String?
    public var isDetached = false
    public var isBare = false
    public var isLocked = false
    public var isPrunable = false

    public init(path: String, head: String? = nil, branch: String? = nil) {
        self.path = path
        self.head = head
        self.branch = branch
    }

    public static func parseList(_ text: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                if let c = current { entries.append(c) }
                current = nil
                continue
            }
            if line.hasPrefix("worktree ") {
                if let c = current { entries.append(c) }
                current = WorktreeEntry(path: String(line.dropFirst("worktree ".count)))
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst(5))
            } else if line.hasPrefix("branch ") {
                let ref = line.dropFirst("branch ".count)
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
            } else if line == "detached" {
                current?.isDetached = true
            } else if line == "bare" {
                current?.isBare = true
            } else if line.hasPrefix("locked") {
                current?.isLocked = true
            } else if line.hasPrefix("prunable") {
                current?.isPrunable = true
            }
        }
        if let c = current { entries.append(c) }
        return entries
    }
}

public enum GitRefs {
    /// Looks like an abbreviated or full object id rather than a branch name.
    public static func isCommitHash(_ s: String) -> Bool {
        guard (7...64).contains(s.count) else { return false }
        let hex = s.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
        return hex && s.contains(where: \.isNumber)
    }

    /// Branch name to pass to `gh pr create --base`: `refs/heads/main`, `origin/main`,
    /// `refs/remotes/origin/main` → `main`. nil for HEAD, commit hashes and empty refs, so the caller
    /// can fall back to the repository's default branch.
    public static func pullRequestBase(fromBaseRef ref: String?) -> String? {
        guard var r = ref?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
        if r.hasPrefix("refs/heads/") {
            r = String(r.dropFirst("refs/heads/".count))
        } else if r.hasPrefix("refs/remotes/") {
            let rest = r.dropFirst("refs/remotes/".count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            r = String(rest[rest.index(after: slash)...])
        } else if r.hasPrefix("origin/") {
            r = String(r.dropFirst("origin/".count))
        }
        if r.isEmpty || r == "HEAD" || r.hasPrefix("HEAD~") || r.hasPrefix("HEAD^") || isCommitHash(r) { return nil }
        return r
    }
}
