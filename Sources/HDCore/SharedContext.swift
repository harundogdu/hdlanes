import Foundation

/// What a managed account borrows from the system default account: its skills, agents, commands and
/// global instructions (as symlinks in the account dir) and, for Claude, the project's auto memory
/// (through `autoMemoryDirectory` in the session's `--settings`). Pure file-system logic, every root a
/// parameter.
public enum SharedContext {
    /// Entries linked from the default account's dir into a managed account's dir. Only what the CLI
    /// reads as user-level instructions and extensions; never logins, settings or history.
    public static func entries(for provider: Provider) -> [String] {
        switch provider {
        case .claude: return ["CLAUDE.md", "skills", "agents", "commands"]
        case .codex: return ["AGENTS.md", "skills", "agents", "prompts"]
        case .shell: return []
        }
    }

    /// The system default account's dir for `provider` (`~/.claude`, `~/.codex`).
    public static func defaultSourceDir(for provider: Provider, homeDirectory: String) -> String? {
        switch provider {
        case .claude: return (homeDirectory as NSString).appendingPathComponent(".claude")
        case .codex: return (homeDirectory as NSString).appendingPathComponent(".codex")
        case .shell: return nil
        }
    }

    public enum LinkState: Equatable, Sendable {
        /// Our link is in place.
        case linked
        /// The default account has no such entry (a link of ours to it was removed).
        case missingSource
        /// The account has its own file or folder there; left as is.
        case occupied
        /// The account has its own folder there: the default account's items are linked one by one
        /// inside it, next to the account's own (Claude Code creates `skills/synced` by itself).
        case merged
        /// Not linked yet (`status` only; `sync` would link it).
        case notLinked
        case failed(String)
    }

    public struct LinkResult: Equatable, Sendable {
        public var name: String
        public var state: LinkState
    }

    /// Creates the missing links and removes ours whose target is gone. Never replaces anything the
    /// account has of its own. Absolute targets: `~/.claude/skills` itself holds relative symlinks,
    /// which only resolve through the real folder.
    @discardableResult
    public static func sync(accountDir: String, sourceDir: String, provider: Provider,
                            fileManager fm: FileManager = .default) -> [LinkResult] {
        entries(for: provider).map { name in
            let link = (accountDir as NSString).appendingPathComponent(name)
            let target = (sourceDir as NSString).appendingPathComponent(name)
            let sourceExists = fm.fileExists(atPath: target)
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link) {
                guard existing == target else { return LinkResult(name: name, state: .occupied) }
                if sourceExists { return LinkResult(name: name, state: .linked) }
                try? fm.removeItem(atPath: link)
                return LinkResult(name: name, state: .missingSource)
            }
            if itemExists(link, fm) {
                guard isDirectory(link, fm), isFolder(target, fm) else { return LinkResult(name: name, state: .occupied) }
                mergeItems(folder: link, sourceFolder: target, fm)
                return LinkResult(name: name, state: .merged)
            }
            guard sourceExists else { return LinkResult(name: name, state: .missingSource) }
            do {
                try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
                return LinkResult(name: name, state: .linked)
            } catch {
                return LinkResult(name: name, state: .failed(error.localizedDescription))
            }
        }
    }

    /// What `sync` found or would do, without touching anything.
    public static func status(accountDir: String, sourceDir: String, provider: Provider,
                              fileManager fm: FileManager = .default) -> [LinkResult] {
        entries(for: provider).map { name in
            let link = (accountDir as NSString).appendingPathComponent(name)
            let target = (sourceDir as NSString).appendingPathComponent(name)
            let sourceExists = fm.fileExists(atPath: target)
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link) {
                if existing != target { return LinkResult(name: name, state: .occupied) }
                return LinkResult(name: name, state: sourceExists ? .linked : .missingSource)
            }
            if itemExists(link, fm) {
                guard isDirectory(link, fm), isFolder(target, fm) else { return LinkResult(name: name, state: .occupied) }
                let missing = sharedItems(target, fm).contains { !itemExists((link as NSString).appendingPathComponent($0), fm) }
                return LinkResult(name: name, state: missing ? .notLinked : .merged)
            }
            return LinkResult(name: name, state: sourceExists ? .notLinked : .missingSource)
        }
    }

    /// Removes only links that point at `sourceDir`'s entries; returns their names.
    @discardableResult
    public static func unlink(accountDir: String, sourceDir: String, provider: Provider,
                              fileManager fm: FileManager = .default) -> [String] {
        entries(for: provider).filter { name in
            let link = (accountDir as NSString).appendingPathComponent(name)
            let target = (sourceDir as NSString).appendingPathComponent(name)
            if (try? fm.destinationOfSymbolicLink(atPath: link)) == target {
                return (try? fm.removeItem(atPath: link)) != nil
            }
            guard isDirectory(link, fm) else { return false }
            return !ourItemLinks(folder: link, sourceFolder: target, fm).filter { (try? fm.removeItem(atPath: $0)) != nil }.isEmpty
        }
    }

    /// Links each of `sourceFolder`'s items into `folder` where `folder` has nothing of that name, and
    /// removes item links of ours whose target is gone. The folder's own items are never touched.
    private static func mergeItems(folder: String, sourceFolder: String, _ fm: FileManager) {
        for link in ourItemLinks(folder: folder, sourceFolder: sourceFolder, fm) where !fm.fileExists(atPath: link) {
            try? fm.removeItem(atPath: link)
        }
        for item in sharedItems(sourceFolder, fm) {
            let link = (folder as NSString).appendingPathComponent(item)
            guard !itemExists(link, fm) else { continue }
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: (sourceFolder as NSString).appendingPathComponent(item))
        }
    }

    /// Visible items of a default account's folder.
    private static func sharedItems(_ folder: String, _ fm: FileManager) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// Paths in `folder` that are symlinks hdlanes made to `sourceFolder/<same name>`.
    private static func ourItemLinks(folder: String, sourceFolder: String, _ fm: FileManager) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).compactMap { item in
            let path = (folder as NSString).appendingPathComponent(item)
            let mine = (sourceFolder as NSString).appendingPathComponent(item)
            return (try? fm.destinationOfSymbolicLink(atPath: path)) == mine ? path : nil
        }
    }

    /// A folder, following symlinks (the default account's folders may be links themselves).
    private static func isFolder(_ path: String, _ fm: FileManager) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    /// A real folder (not a symlink to one).
    private static func isDirectory(_ path: String, _ fm: FileManager) -> Bool {
        guard let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else { return false }
        return type == .typeDirectory
    }

    /// lstat-style existence: true for a dangling symlink too.
    private static func itemExists(_ path: String, _ fm: FileManager) -> Bool {
        (try? fm.attributesOfItem(atPath: path)) != nil
    }

    // MARK: Claude auto memory

    /// Claude Code's folder name for a project under `<config>/projects/`: every character outside
    /// `[a-zA-Z0-9]` becomes `-` (claude 2.1.318). Longer than 200 characters Claude appends a hash we
    /// don't reproduce, so those return nil and memory isn't shared.
    public static func claudeProjectKey(_ path: String) -> String? {
        let key = String(path.unicodeScalars.map { s -> Character in
            s.isASCII && (CharacterSet.alphanumerics.contains(s)) ? Character(s) : "-"
        })
        return key.count <= 200 ? key : nil
    }

    /// The default account's auto memory dir for the repository at `repositoryRoot`:
    /// `<sourceDir>/projects/<key>/memory`. This is the value for `autoMemoryDirectory`, which Claude
    /// uses as the memory dir itself.
    public static func claudeMemoryDirectory(sourceDir: String, repositoryRoot: String) -> String? {
        guard let key = claudeProjectKey(repositoryRoot) else { return nil }
        return ((sourceDir as NSString).appendingPathComponent("projects") as NSString)
            .appendingPathComponent(key + "/memory")
    }

    /// The folder Claude keys auto memory by: the main working tree of the git repository holding
    /// `cwd` (a linked worktree resolves to its main repository), symlinks resolved; `cwd` itself when
    /// it isn't in a repository. Reads `.git` files only, no `git` process.
    public static func repositoryRoot(for cwd: String, fileManager fm: FileManager = .default) -> String {
        let start = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL
        var dir = start
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue { return dir.path }
                if let main = mainWorktree(gitFile: dotGit, fm: fm) { return main }
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return start.path }
            dir = parent
        }
    }

    /// `.git` file `gitdir: <common>/worktrees/<name>` → `<common>/commondir` → the main tree.
    private static func mainWorktree(gitFile: URL, fm: FileManager) -> String? {
        guard let text = try? String(contentsOf: gitFile, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let base = gitFile.deletingLastPathComponent()
        let gitDir = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : base.appendingPathComponent(raw)
        var common = gitDir
        if let rel = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !rel.isEmpty {
            common = rel.hasPrefix("/") ? URL(fileURLWithPath: rel) : gitDir.appendingPathComponent(rel)
        }
        common = common.resolvingSymlinksInPath().standardizedFileURL
        // A bare repository has no main tree; the worktree then keys memory by itself.
        guard common.lastPathComponent == ".git" else { return nil }
        return common.deletingLastPathComponent().path
    }
}
