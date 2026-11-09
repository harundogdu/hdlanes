import Foundation
import HDCore

// OWNER: tracking area. Reads open pull requests with `gh` and `az`. READ-ONLY: only `list`, `show`
// and `policy list` calls; nothing here comments, votes, approves, completes or pushes.

/// Why a provider's pull requests couldn't be read.
enum PRIssue: Error, Equatable, Hashable {
    case cliMissing(String)
    case notLoggedIn(String)
    case network(String)
    case failed(String, String)

    var tool: String {
        switch self {
        case .cliMissing(let t), .notLoggedIn(let t), .network(let t), .failed(let t, _): return t
        }
    }
}

/// One repository's result.
struct RepoFetch {
    var repo: RemoteRepo
    var prs: [PullRequest] = []
    var issue: PRIssue?
}

/// Finds `az` like `ToolLocator` finds `gh`: Homebrew paths first, then a login shell. Cached; a miss
/// is retried after 5 minutes. The signed-in Azure user is cached for the app's lifetime once read.
actor AzureCLI {
    static let shared = AzureCLI()

    nonisolated static let candidates = ["/opt/homebrew/bin/az", "/usr/local/bin/az"]
    private var located: (path: String?, checkedAt: Date)?
    private var me: String?

    func path() async -> String? {
        if let located, located.path != nil || Date().timeIntervalSince(located.checkedAt) < 300 { return located.path }
        var found = Self.candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        if found == nil, let r = try? await ProcessRunner.run("/bin/zsh", ["-l", "-c", "command -v az"],
                                                             environment: ProcessInfo.processInfo.environment,
                                                             timeout: 8, maxOutputBytes: 64 * 1024, displayName: "zsh"),
           r.status == 0 {
            found = r.out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        }
        located = (found, Date())
        return found
    }

    /// `az account show --query user.name`: the identity `--creator` / `--reviewer` match.
    func currentUser() async -> Result<String, PRIssue> {
        if let me { return .success(me) }
        switch await PRService.runAZ(["account", "show", "--query", "user.name", "-o", "tsv"]) {
        case .failure(let issue): return .failure(issue)
        case .success(let out):
            let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .failure(.notLoggedIn("az")) }
            me = name
            return .success(name)
        }
    }

    func forgetUser() { me = nil }
}

enum PRService {
    static let timeout: TimeInterval = 30
    static let maxPolicyCalls = 15
    static let concurrency = 4

    // MARK: Running

    static func azEnvironment() -> [String: String] {
        var env = GitService.ghEnvironment()
        env["AZURE_CORE_ONLY_SHOW_ERRORS"] = "1"
        env["AZURE_CORE_NO_COLOR"] = "1"
        env["AZURE_CORE_COLLECT_TELEMETRY"] = "0"
        // Never let a list call stop to install an extension.
        env["AZURE_EXTENSION_USE_DYNAMIC_INSTALL"] = "no"
        return env
    }

    static func runAZ(_ args: [String], timeout: TimeInterval = timeout) async -> Result<String, PRIssue> {
        guard let az = await AzureCLI.shared.path() else { return .failure(.cliMissing("az")) }
        return await run(az, args, environment: azEnvironment(), directory: nil, tool: "az", timeout: timeout)
    }

    static func runGH(_ args: [String], in dir: String?) async -> Result<String, PRIssue> {
        guard let gh = await ToolLocator.shared.ghPath() else { return .failure(.cliMissing("gh")) }
        return await run(gh, args, environment: GitService.ghEnvironment(), directory: dir, tool: "gh")
    }

    private static func run(_ exe: String, _ args: [String], environment: [String: String], directory: String?,
                            tool: String, timeout: TimeInterval = timeout) async -> Result<String, PRIssue> {
        let name = tool + " " + args.prefix(3).joined(separator: " ")
        do {
            let r = try await ProcessRunner.run(exe, args, environment: environment, currentDirectory: directory,
                                                timeout: timeout, maxOutputBytes: 8 << 20, displayName: name)
            if r.status == 0 { return .success(r.out) }
            return .failure(issue(tool: tool, output: r.err.isEmpty ? r.out : r.err))
        } catch GitError.timedOut {
            return .failure(.network(tool))
        } catch {
            return .failure(.failed(tool, (error as? LocalizedError)?.errorDescription ?? String(describing: error)))
        }
    }

    static func issue(tool: String, output: String) -> PRIssue {
        switch CLIFailureKind.classify(output) {
        case .notLoggedIn: return .notLoggedIn(tool)
        case .network: return .network(tool)
        case .other:
            let line = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            return .failed(tool, line.count > 160 ? String(line.prefix(160)) + "…" : line)
        }
    }

    // MARK: Remotes

    static func remote(of path: String) async -> RemoteRepo? {
        guard let r = try? await GitService.git(["remote", "get-url", "origin"], in: path, timeout: 10, check: false),
              r.status == 0 else { return nil }
        return RemoteRepo.parse(r.trimmedOut)
    }

    // MARK: Fetching

    /// Open PRs I authored and PRs waiting for my review, for one repository.
    static func fetch(_ repo: RemoteRepo, directory: String) async -> RepoFetch {
        switch repo {
        case .github(let owner, let name):
            return await fetchGitHub(repo, slug: "\(owner)/\(name)", directory: directory)
        case .azure(let org, let project, let name):
            return await fetchAzure(repo, org: org, project: project, name: name)
        }
    }

    private static func fetchGitHub(_ repo: RemoteRepo, slug: String, directory: String) async -> RepoFetch {
        var result = RepoFetch(repo: repo)
        let common = ["pr", "list", "--repo", slug, "--state", "open", "--limit", "50", "--json", GitHubPRParser.jsonFields]
        async let mineOut = runGH(common + ["--author", "@me"], in: directory)
        async let reviewOut = runGH(common + ["--search", "review-requested:@me"], in: directory)
        var prs: [PullRequest] = []
        for (out, mine) in [(await mineOut, true), (await reviewOut, false)] {
            switch out {
            case .failure(let issue): result.issue = result.issue ?? issue
            case .success(let text):
                do { prs += try GitHubPRParser.parse(Data(text.utf8), repo: repo, mine: mine) } catch {
                    result.issue = result.issue ?? .failed("gh", "")
                }
            }
        }
        result.prs = PullRequest.dedupe(prs)
        return result
    }

    /// Review requests across a whole Azure DevOps project, not only the repos added as hdlanes
    /// projects: being asked to review in another repo is exactly what's easy to lose track of.
    /// One list call per (org, project); PRs are grouped by their repository for parsing.
    static func fetchAzureReviews(org: String, project: String) async -> [PullRequest] {
        guard case .success(let me) = await AzureCLI.shared.currentUser() else { return [] }
        let args = ["repos", "pr", "list", "--org", "https://dev.azure.com/\(org)", "--project", project,
                    "--reviewer", me, "--status", "active", "--top", "100", "--detect", "false", "-o", "json"]
        guard case .success(let text) = await runAZ(args),
              let items = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] else { return [] }
        var byRepo: [String: [[String: Any]]] = [:]
        for item in items {
            guard let name = (item["repository"] as? [String: Any])?["name"] as? String else { continue }
            byRepo[name, default: []].append(item)
        }
        var prs: [PullRequest] = []
        for (name, group) in byRepo {
            guard let data = try? JSONSerialization.data(withJSONObject: group) else { continue }
            prs += (try? AzurePRParser.parse(data, org: org, project: project, repo: name, me: me, reviewList: true)) ?? []
        }
        return prs
    }

    private static func fetchAzure(_ repo: RemoteRepo, org: String, project: String, name: String) async -> RepoFetch {
        var result = RepoFetch(repo: repo)
        let me: String
        switch await AzureCLI.shared.currentUser() {
        case .failure(let issue):
            result.issue = issue
            return result
        case .success(let user): me = user
        }
        let orgURL = "https://dev.azure.com/\(org)"
        let common = ["repos", "pr", "list", "--org", orgURL, "--project", project, "--repository", name,
                      "--status", "active", "--top", "100", "--detect", "false", "-o", "json"]
        async let mineOut = runAZ(common + ["--creator", me])
        async let reviewOut = runAZ(common + ["--reviewer", me])
        var prs: [PullRequest] = []
        for (out, reviewList) in [(await mineOut, false), (await reviewOut, true)] {
            switch out {
            case .failure(let issue):
                if case .notLoggedIn = issue { await AzureCLI.shared.forgetUser() }
                result.issue = result.issue ?? issue
            case .success(let text):
                do {
                    prs += try AzurePRParser.parse(Data(text.utf8), org: org, project: project, repo: name, me: me,
                                                   reviewList: reviewList)
                } catch {
                    result.issue = result.issue ?? .failed("az", "")
                }
            }
        }
        prs = PullRequest.dedupe(prs)

        // CI only for my PRs, capped.
        let mineIndices = Array(prs.indices.filter { prs[$0].isMine }.prefix(maxPolicyCalls))
        let ids = mineIndices.map { prs[$0].number }
        let cis = await mapLimited(ids, limit: concurrency) { id -> PullRequest.CI? in
            guard case .success(let text) = await runAZ(["repos", "pr", "policy", "list", "--org", orgURL,
                                                         "--id", String(id), "--detect", "false", "-o", "json"]) else { return nil }
            return try? AzurePRParser.ci(fromPolicies: Data(text.utf8))
        }
        for (i, ci) in zip(mineIndices, cis) { if let ci { prs[i].ci = ci } }
        result.prs = prs
        return result
    }

    /// Whether a PR that left the open list was merged (true), closed/abandoned (false) or unknown (nil).
    static func wasMerged(_ pr: PullRequest) async -> Bool? {
        switch pr.provider {
        case .github:
            let repo = pr.repoLabel
            guard case .success(let out) = await runGH(["pr", "view", String(pr.number), "--repo", repo,
                                                        "--json", "state", "-q", ".state"], in: nil) else { return nil }
            let state = out.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if state == "MERGED" { return true }
            return state == "OPEN" ? nil : false
        case .azure:
            guard let org = pr.url.split(separator: "/").dropFirst(2).first.map(String.init) else { return nil }
            guard case .success(let out) = await runAZ(["repos", "pr", "show", "--org", "https://dev.azure.com/\(org)",
                                                        "--id", String(pr.number), "--detect", "false",
                                                        "--query", "status", "-o", "tsv"]) else { return nil }
            let status = out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if status == "completed" { return true }
            return status == "abandoned" ? false : nil
        }
    }

    /// `transform` over `items` with at most `limit` running at once; results in input order.
    static func mapLimited<T, R>(_ items: [T], limit: Int, _ transform: @escaping (T) async -> R) async -> [R] {
        guard !items.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var next = 0
            for _ in 0..<min(limit, items.count) {
                let i = next
                group.addTask { (i, await transform(items[i])) }
                next += 1
            }
            while let (i, r) = await group.next() {
                results[i] = r
                if next < items.count {
                    let j = next
                    group.addTask { (j, await transform(items[j])) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }
}
