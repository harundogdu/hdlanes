import Foundation
import HDCore

// OWNER: git area. Runs git and gh as child processes. Nothing here touches the main actor.

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
    /// stdout went over the cap and the rest was discarded.
    var stdoutTruncated = false

    var out: String { String(decoding: stdout, as: UTF8.self) }
    var err: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedOut: String { out.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum GitError: LocalizedError, Equatable {
    case toolMissing(String)
    case launchFailed(command: String, reason: String)
    case failed(command: String, status: Int32, stderr: String)
    case timedOut(command: String)
    case folderMissing(String)
    case notRepository(String)
    case invalidBranch(String, BranchNameProblem)
    case invalidBaseRef(String)
    case branchInUse(branch: String, path: String)
    /// Uncommitted or untracked files would be lost. `sample` holds a few of the paths.
    case worktreeDirty(path: String, count: Int, sample: [String])
    case sessionNotFound
    case noBranch
    case sameAsBase(String)
    case noPullRequestURL(String)

    var errorDescription: String? { L.describe(self) }
}

/// Async `Process` runner. stdout and stderr are drained on their own threads while the child runs, so
/// a large diff can't fill a pipe and deadlock; a timeout sends SIGTERM, then SIGKILL.
enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    currentDirectory: String? = nil, timeout: TimeInterval, maxOutputBytes: Int = 64 << 20,
                    displayName: String) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true) }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let control = RunControl(process: process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let out = OutputBuffer(limit: maxOutputBytes)
                let err = OutputBuffer(limit: 1 << 20)
                let readers = DispatchGroup()
                readers.enter()
                readers.enter()

                process.terminationHandler = { proc in
                    DispatchQueue.global(qos: .userInitiated).async {
                        // A grandchild that inherited the pipe (ssh, credential helper) can keep it open
                        // after git exits; don't wait for it forever.
                        _ = readers.wait(timeout: .now() + 5)
                        control.finish {
                            if control.wasCancelled {
                                continuation.resume(throwing: CancellationError())
                            } else if control.didTimeOut {
                                continuation.resume(throwing: GitError.timedOut(command: displayName))
                            } else {
                                continuation.resume(returning: ProcessResult(
                                    status: proc.terminationStatus, stdout: out.data, stderr: err.data,
                                    stdoutTruncated: out.truncated))
                            }
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    readers.leave()
                    readers.leave()
                    control.finish {
                        continuation.resume(throwing: GitError.launchFailed(command: displayName,
                                                                            reason: error.localizedDescription))
                    }
                    return
                }
                control.started()

                let queue = DispatchQueue.global(qos: .userInitiated)
                queue.async { out.drain(outPipe.fileHandleForReading); readers.leave() }
                queue.async { err.drain(errPipe.fileHandleForReading); readers.leave() }
                queue.asyncAfter(deadline: .now() + timeout) { control.timeOut() }
            }
        } onCancel: {
            control.cancel()
        }
    }
}

/// Shared between the runner's callbacks; every field behind the lock.
private final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var isStarted = false
    private var isFinished = false
    private var cancelled = false
    private var timedOut = false

    init(process: Process) {
        self.process = process
    }

    var wasCancelled: Bool { lock.withLock { cancelled } }
    var didTimeOut: Bool { lock.withLock { timedOut } }

    /// Runs `body` once, for whichever path ends the run first.
    func finish(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            if isFinished { return false }
            isFinished = true
            return true
        }
        if first { body() }
    }

    func started() {
        let cancelNow = lock.withLock { () -> Bool in
            isStarted = true
            return cancelled
        }
        if cancelNow { stop() }
    }

    func cancel() {
        let running = lock.withLock { () -> Bool in
            cancelled = true
            return isStarted && !isFinished
        }
        if running { stop() }
    }

    func timeOut() {
        let running = lock.withLock { () -> Bool in
            guard isStarted, !isFinished else { return false }
            timedOut = true
            return true
        }
        if running { stop() }
    }

    private func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var didTruncate = false

    init(limit: Int) {
        self.limit = limit
    }

    var data: Data { lock.withLock { storage } }
    var truncated: Bool { lock.withLock { didTruncate } }

    /// Reads until EOF. Keeps reading past the cap (discarding) so the child never blocks on a full pipe.
    func drain(_ handle: FileHandle) {
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 64 * 1024), !next.isEmpty else { return }
                chunk = next
            } catch {
                return
            }
            lock.withLock {
                let room = limit - storage.count
                if room >= chunk.count {
                    storage.append(chunk)
                } else {
                    if room > 0 { storage.append(chunk.prefix(room)) }
                    didTruncate = true
                }
            }
        }
    }
}

/// Finds git and gh. gh is looked up in the usual Homebrew places first, then through a login shell
/// (apps started from Finder get a minimal PATH). Results are cached; a miss is retried after 5 minutes.
actor ToolLocator {
    static let shared = ToolLocator()

    private var gh: (path: String?, checkedAt: Date)?

    nonisolated static let gitCandidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
    nonisolated static let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]

    nonisolated static var gitPath: String? {
        gitCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func ghPath() async -> String? {
        if let gh, gh.path != nil || Date().timeIntervalSince(gh.checkedAt) < 300 { return gh.path }
        let found = await Self.findGH()
        gh = (found, Date())
        return found
    }

    private static func findGH() async -> String? {
        if let path = ghCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }
        guard let result = try? await ProcessRunner.run("/bin/zsh", ["-l", "-c", "command -v gh"],
                                                        environment: ProcessInfo.processInfo.environment,
                                                        timeout: 8, maxOutputBytes: 64 * 1024, displayName: "zsh"),
              result.status == 0 else { return nil }
        return result.out.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum GitService {
    static let untrackedFileLimit = 512 * 1024
    static let untrackedCountLimit = 400
    static let untrackedTotalBudget = 24 << 20
    static let diffOutputLimit = 48 << 20

    // MARK: Environment

    static func augmentedPath(_ path: String?) -> String {
        var parts = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !parts.contains(dir) {
            parts.append(dir)
        }
        return parts.joined(separator: ":")
    }

    /// Inherited environment minus variables that would point git at another repository, plus
    /// no prompts, no optional index locks (the agent may be running git in the same tree) and C locale.
    static func gitEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR",
                    "GIT_NAMESPACE", "GIT_PREFIX", "GIT_EXTERNAL_DIFF", "GIT_DIFF_OPTS", "GIT_ALTERNATE_OBJECT_DIRECTORIES"] {
            env.removeValue(forKey: key)
        }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        env["LC_ALL"] = "C"
        env["PATH"] = augmentedPath(env["PATH"])
        return env
    }

    static func ghEnvironment() -> [String: String] {
        var env = gitEnvironment()
        env.removeValue(forKey: "LC_ALL")
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        return env
    }

    // MARK: Running

    /// `git -C <dir> <args>`. Throws on a non-zero exit unless `check` is false.
    @discardableResult
    static func git(_ args: [String], in dir: String, timeout: TimeInterval = 20, maxOutputBytes: Int = 16 << 20,
                    check: Bool = true) async throws -> ProcessResult {
        guard let git = ToolLocator.gitPath else { throw GitError.toolMissing("git") }
        let name = "git " + (args.first { !$0.hasPrefix("-") && !$0.contains("=") } ?? "")
        let result = try await ProcessRunner.run(git, ["-C", dir] + args, environment: gitEnvironment(),
                                                 timeout: timeout, maxOutputBytes: maxOutputBytes, displayName: name)
        if check && result.status != 0 {
            throw GitError.failed(command: name, status: result.status, stderr: result.err)
        }
        return result
    }

    private static func gitOutput(_ args: [String], in dir: String) async -> String? {
        guard let r = try? await git(args, in: dir, check: false), r.status == 0 else { return nil }
        let s = r.trimmedOut
        return s.isEmpty ? nil : s
    }

    // MARK: Queries

    static func repoRoot(_ path: String) async -> String? {
        await gitOutput(["rev-parse", "--show-toplevel"], in: path)
    }

    /// nil when HEAD is detached or the path isn't a repository.
    static func currentBranch(_ path: String) async -> String? {
        await gitOutput(["symbolic-ref", "--quiet", "--short", "HEAD"], in: path)
    }

    static func resolveCommit(_ ref: String, in dir: String) async -> String? {
        guard !ref.hasPrefix("-") else { return nil }
        return await gitOutput(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: dir)
    }

    static func mergeBase(_ a: String, _ b: String, in dir: String) async -> String? {
        guard !a.hasPrefix("-"), !b.hasPrefix("-") else { return nil }
        return await gitOutput(["merge-base", a, b], in: dir)
    }

    static func branchExists(_ name: String, in dir: String) async -> Bool {
        await gitOutput(["rev-parse", "--verify", "--quiet", "refs/heads/" + name], in: dir) != nil
    }

    /// Local branches, current first, the rest most recently committed first.
    static func branches(_ repo: String) async -> [String] {
        guard let out = await gitOutput(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads"],
                                        in: repo) else { return [] }
        return GitOutput.branchList(out, current: await currentBranch(repo))
    }

    /// `main` from `refs/remotes/origin/HEAD`, when the clone recorded it.
    static func defaultRemoteBranch(_ dir: String) async -> String? {
        guard let ref = await gitOutput(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: dir) else {
            return nil
        }
        return GitRefs.pullRequestBase(fromBaseRef: "refs/remotes/" + ref)
    }

    /// The main checkout of a linked worktree.
    static func mainWorktree(of worktree: String) async -> String? {
        guard let common = await gitOutput(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: worktree)
        else { return nil }
        let url = URL(fileURLWithPath: common)
        return url.lastPathComponent == ".git" ? url.deletingLastPathComponent().path : nil
    }

    static func status(_ dir: String) async throws -> [GitOutput.StatusEntry] {
        let r = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=normal"], in: dir)
        return GitOutput.statusEntries(r.out)
    }

    static func worktreeList(_ repo: String) async throws -> [WorktreeEntry] {
        WorktreeEntry.parseList(try await git(["worktree", "list", "--porcelain"], in: repo).out)
    }

    // MARK: Diff

    struct DiffSnapshot: Sendable {
        var files: [DiffFile]
        /// Ref the diff is against; nil means HEAD.
        var baseName: String?
        var skippedUntracked: Int
        var truncated: Bool
    }

    /// nil when `cwd` is not inside a repository.
    static func loadDiff(cwd: String, baseRef: String?) async throws -> DiffSnapshot? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            throw GitError.folderMissing(cwd)
        }
        guard let top = await repoRoot(cwd) else { return nil }

        var base = "HEAD"
        var baseName: String?
        if let ref = baseRef?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty,
           await resolveCommit(ref, in: top) != nil, let mb = await mergeBase(ref, "HEAD", in: top) {
            base = mb
            baseName = GitRefs.isCommitHash(ref) ? String(ref.prefix(7)) : ref
        } else if await resolveCommit("HEAD", in: top) == nil {
            // No commits yet: compare against the empty tree.
            base = await gitOutput(["hash-object", "-t", "tree", "/dev/null"], in: top) ?? "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        }

        let resolvedBase = base
        async let tracked = diff(top, base: resolvedBase)
        async let untracked = untrackedFiles(top)
        let (t, u) = try await (tracked, untracked)
        let files = (t.files + u.files).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return DiffSnapshot(files: files, baseName: baseName, skippedUntracked: u.skipped, truncated: t.truncated)
    }

    static func diff(_ toplevel: String, base: String) async throws -> (files: [DiffFile], truncated: Bool) {
        let r = try await git(["-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "-M",
                               "--src-prefix=a/", "--dst-prefix=b/", "--no-relative", base, "--"],
                              in: toplevel, timeout: 30, maxOutputBytes: diffOutputLimit)
        return (DiffParser.parse(r.out), r.stdoutTruncated)
    }

    /// Untracked files (respecting .gitignore) as all-added diffs. Text files above the per-file cap,
    /// or past the total budget, are listed without content.
    static func untrackedFiles(_ toplevel: String) async throws -> (files: [DiffFile], skipped: Int) {
        let r = try await git(["ls-files", "--others", "--exclude-standard", "-z"], in: toplevel)
        let paths = GitOutput.nulSeparated(r.out)
        let shown = paths.prefix(untrackedCountLimit)
        let fm = FileManager.default
        var budget = untrackedTotalBudget
        var files: [DiffFile] = []
        files.reserveCapacity(shown.count)
        for rel in shown {
            try Task.checkCancellation()
            if rel.hasSuffix("/") {
                files.append(DiffParser.untrackedFile(path: rel, data: nil))
                continue
            }
            let full = (toplevel as NSString).appendingPathComponent(rel)
            let attrs = try? fm.attributesOfItem(atPath: full)
            var data: Data?
            if attrs?[.type] as? FileAttributeType == .typeSymbolicLink {
                // git stores a symlink's target as its content.
                data = (try? fm.destinationOfSymbolicLink(atPath: full)).map { Data($0.utf8) }
            } else if let size = (attrs?[.size] as? NSNumber)?.intValue, size <= untrackedFileLimit, size <= budget {
                data = try? Data(contentsOf: URL(fileURLWithPath: full))
                budget -= size
            }
            files.append(DiffParser.untrackedFile(path: rel, data: data))
        }
        return (files, paths.count - shown.count)
    }

    // MARK: Worktrees

    /// New branch from `base`, or an existing branch that isn't checked out anywhere.
    static func worktreeAdd(repo: String, path: String, branch: String, base: String) async throws {
        if await branchExists(branch, in: repo) {
            if let holder = try await worktreeList(repo).first(where: { $0.branch == branch }) {
                throw GitError.branchInUse(branch: branch, path: holder.path)
            }
            try await git(["worktree", "add", path, branch], in: repo, timeout: 120)
        } else {
            try await git(["worktree", "add", "-b", branch, path, base], in: repo, timeout: 120)
        }
    }

    static func worktreeRemove(repo: String, path: String, force: Bool) async throws {
        try await git(["worktree", "remove"] + (force ? ["--force"] : []) + [path], in: repo, timeout: 60)
    }

    static func worktreePrune(_ repo: String) async {
        _ = try? await git(["worktree", "prune"], in: repo, check: false)
    }

    /// Copies gitignored files (`.env`, plists) from the project into a fresh worktree. Only when the
    /// source exists and the target doesn't; keeps file modes. Returns the paths that failed.
    static func copyFiles(_ relativePaths: [String], from source: String, to target: String) async -> [String] {
        let fm = FileManager.default
        var failed: [String] = []
        for raw in relativePaths {
            let rel = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = rel.split(separator: "/")
            guard !rel.isEmpty, !rel.hasPrefix("/"), !parts.contains("..") else {
                if !rel.isEmpty { failed.append(rel) }
                continue
            }
            let from = (source as NSString).appendingPathComponent(rel)
            let to = (target as NSString).appendingPathComponent(rel)
            guard fm.fileExists(atPath: from), !fm.fileExists(atPath: to) else { continue }
            do {
                try fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.copyItem(atPath: from, toPath: to)
                if let mode = try fm.attributesOfItem(atPath: from)[.posixPermissions] {
                    try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: to)
                }
            } catch {
                failed.append(rel)
            }
        }
        return failed
    }

    // MARK: Push / pull requests

    static func push(branch: String, in dir: String) async throws {
        try await git(["push", "-u", "origin", branch], in: dir, timeout: 120)
    }

    static func ghAvailable() async -> Bool {
        await ToolLocator.shared.ghPath() != nil
    }

    /// `gh pr create`; a PR that already exists for the branch counts as success.
    static func createPullRequest(in dir: String, title: String, body: String, base: String?, head: String) async throws -> URL {
        guard let gh = await ToolLocator.shared.ghPath() else { throw GitError.toolMissing("gh") }
        var args = ["pr", "create", "--title=\(title)", "--body=\(body)", "--head=\(head)"]
        if let base { args.append("--base=\(base)") }
        let r = try await ProcessRunner.run(gh, args, environment: ghEnvironment(), currentDirectory: dir,
                                            timeout: 120, maxOutputBytes: 1 << 20, displayName: "gh pr create")
        if r.status != 0 {
            if r.err.contains("already exists"), let url = GitOutput.pullRequestURL(in: r.err) { return url }
            throw GitError.failed(command: "gh pr create", status: r.status, stderr: r.err)
        }
        guard let url = GitOutput.pullRequestURL(in: r.out) else { throw GitError.noPullRequestURL(r.trimmedOut) }
        return url
    }
}
