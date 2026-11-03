import Foundation

// OWNER: tracking area. Parsers for `gh pr list --json …` and `az repos pr list -o json` output.

public enum PullRequestParseError: Error, Equatable {
    case notJSON
}

/// `gh pr list --state open --json number,title,url,headRefName,baseRefName,isDraft,reviewDecision,
/// statusCheckRollup,mergeable,createdAt,updatedAt,author`.
public enum GitHubPRParser {
    public static let jsonFields = "number,title,url,headRefName,baseRefName,isDraft,reviewDecision,statusCheckRollup,mergeable,createdAt,updatedAt,author"

    struct Item: Decodable {
        struct Author: Decodable { var login: String? }
        struct Check: Decodable {
            var __typename: String?
            var status: String?
            var conclusion: String?
            var state: String?
        }
        var number: Int
        var title: String?
        var url: String?
        var headRefName: String?
        var baseRefName: String?
        var isDraft: Bool?
        var reviewDecision: String?
        var statusCheckRollup: [Check]?
        var mergeable: String?
        var createdAt: String?
        var updatedAt: String?
        var author: Author?
    }

    /// `mine`: the list came from `--author @me`; otherwise from `--search review-requested:@me`.
    public static func parse(_ data: Data, repo: RemoteRepo, mine: Bool) throws -> [PullRequest] {
        guard let items = try? JSONDecoder().decode([Item].self, from: data) else { throw PullRequestParseError.notJSON }
        return items.map { item in
            PullRequest(
                id: "\(repo.key)#\(item.number)", provider: .github, number: item.number,
                title: item.title ?? "", url: item.url ?? "", repoKey: repo.key, repoLabel: repo.label,
                sourceBranch: item.headRefName ?? "", targetBranch: item.baseRefName ?? "",
                author: item.author?.login ?? "", isMine: mine, isDraft: item.isDraft ?? false,
                createdAt: ISODate.parse(item.createdAt) ?? Date(timeIntervalSince1970: 0),
                updatedAt: ISODate.parse(item.updatedAt), ci: ci(item.statusCheckRollup ?? []),
                review: review(item.reviewDecision), mergeable: mergeable(item.mergeable),
                reviewRequestedFromMe: !mine, myVote: .none)
        }
    }

    static func ci(_ checks: [Item.Check]) -> PullRequest.CI {
        var failing = false, pending = false, passing = false
        for c in checks {
            if let state = c.state?.uppercased() {
                // StatusContext
                switch state {
                case "FAILURE", "ERROR": failing = true
                case "PENDING", "EXPECTED": pending = true
                case "SUCCESS": passing = true
                default: break
                }
                continue
            }
            let status = c.status?.uppercased() ?? ""
            if status != "COMPLETED" && !status.isEmpty {
                pending = true
                continue
            }
            switch c.conclusion?.uppercased() ?? "" {
            case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": failing = true
            case "SUCCESS": passing = true
            default: break // SKIPPED, NEUTRAL, STALE
            }
        }
        if failing { return .failing }
        if pending { return .pending }
        return passing ? .passing : .none
    }

    static func review(_ decision: String?) -> PullRequest.Review {
        switch decision?.uppercased() ?? "" {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .waiting
        default: return .none
        }
    }

    static func mergeable(_ value: String?) -> PullRequest.Mergeable {
        switch value?.uppercased() ?? "" {
        case "MERGEABLE": return .yes
        case "CONFLICTING": return .conflict
        default: return .unknown
        }
    }
}

/// `az repos pr list --org https://dev.azure.com/{org} --project {project} --repository {repo}
/// (--creator|--reviewer) <me> --status active -o json`, and `az repos pr policy list --id N -o json`.
public enum AzurePRParser {
    struct Identity: Decodable {
        var displayName: String?
        var uniqueName: String?
    }

    struct Reviewer: Decodable {
        var uniqueName: String?
        var vote: Int?
        var isRequired: Bool?
        var hasDeclined: Bool?
        var isContainer: Bool?
    }

    struct Item: Decodable {
        var pullRequestId: Int
        var title: String?
        var sourceRefName: String?
        var targetRefName: String?
        var isDraft: Bool?
        var mergeStatus: String?
        var creationDate: String?
        var createdBy: Identity?
        var reviewers: [Reviewer]?
        var status: String?
    }

    public static func parse(_ data: Data, org: String, project: String, repo: String, me: String,
                             reviewList: Bool) throws -> [PullRequest] {
        guard let items = try? JSONDecoder().decode([Item].self, from: data) else { throw PullRequestParseError.notJSON }
        let remote = RemoteRepo.azure(org: org, project: project, repo: repo)
        let meKey = me.lowercased()
        return items.filter { ($0.status ?? "active") == "active" }.map { item in
            let reviewers = item.reviewers ?? []
            let mine = !meKey.isEmpty && item.createdBy?.uniqueName?.lowercased() == meKey
            let myEntry = reviewers.first { !meKey.isEmpty && $0.uniqueName?.lowercased() == meKey }
            return PullRequest(
                id: "\(remote.key)#\(item.pullRequestId)", provider: .azure, number: item.pullRequestId,
                title: item.title ?? "",
                url: webURL(org: org, project: project, repo: repo, id: item.pullRequestId),
                repoKey: remote.key, repoLabel: remote.label,
                sourceBranch: branchName(item.sourceRefName), targetBranch: branchName(item.targetRefName),
                author: item.createdBy?.displayName ?? item.createdBy?.uniqueName ?? "", isMine: mine,
                isDraft: item.isDraft ?? false, createdAt: ISODate.parse(item.creationDate) ?? Date(timeIntervalSince1970: 0),
                updatedAt: nil, ci: .none, review: review(reviewers), mergeable: mergeable(item.mergeStatus),
                reviewRequestedFromMe: !mine && (reviewList || myEntry != nil),
                myVote: vote(myEntry?.vote))
        }
    }

    /// "refs/heads/feature/x" → "feature/x".
    public static func branchName(_ ref: String?) -> String {
        guard let ref else { return "" }
        return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }

    public static func webURL(org: String, project: String, repo: String, id: Int) -> String {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s }
        return "https://dev.azure.com/\(enc(org))/\(enc(project))/_git/\(enc(repo))/pullrequest/\(id)"
    }

    /// 10 approved, 5 approved with suggestions, 0 none, -5 waiting for author, -10 rejected.
    public static func vote(_ value: Int?) -> PullRequest.Vote {
        switch value ?? 0 {
        case 5...: return .approved
        case -5: return .waiting
        case ...(-6): return .rejected
        default: return .none
        }
    }

    /// The PR's overall review state from its reviewers' votes.
    static func review(_ reviewers: [Reviewer]) -> PullRequest.Review {
        let active = reviewers.filter { $0.hasDeclined != true }
        guard !active.isEmpty else { return .none }
        let votes = active.map { vote($0.vote) }
        if votes.contains(.rejected) || votes.contains(.waiting) { return .changesRequested }
        let requiredPending = active.contains { $0.isRequired == true && vote($0.vote) == .none }
        if votes.contains(.approved) && !requiredPending { return .approved }
        return .waiting
    }

    static func mergeable(_ status: String?) -> PullRequest.Mergeable {
        switch status ?? "" {
        case "succeeded": return .yes
        case "conflicts": return .conflict
        default: return .unknown
        }
    }

    struct Evaluation: Decodable {
        struct Configuration: Decodable {
            struct Kind: Decodable { var displayName: String? }
            var type: Kind?
        }
        var status: String?
        var configuration: Configuration?
    }

    /// CI from policy evaluations. Only build-like policies ("Build", "Status") count: others such as
    /// "Require a merge strategy" or reviewer minimums report `rejected` on PRs whose build is fine.
    public static func ci(fromPolicies data: Data) throws -> PullRequest.CI {
        guard let evals = try? JSONDecoder().decode([Evaluation].self, from: data) else { throw PullRequestParseError.notJSON }
        let builds = evals.filter {
            let kind = $0.configuration?.type?.displayName?.lowercased() ?? ""
            return kind == "build" || kind == "status"
        }
        var failing = false, pending = false, passing = false
        for e in builds {
            switch e.status?.lowercased() ?? "" {
            case "rejected", "broken": failing = true
            case "running", "queued": pending = true
            case "approved": passing = true
            default: break // notApplicable
            }
        }
        if failing { return .failing }
        if pending { return .pending }
        return passing ? .passing : .none
    }
}

/// Why a `gh` / `az` call failed, from its output. Only the category is kept; the text isn't shown raw.
public enum CLIFailureKind: Equatable, Sendable {
    case notLoggedIn
    case network
    case other

    public static func classify(_ output: String) -> CLIFailureKind {
        let s = output.lowercased()
        let auth = ["gh auth login", "not logged in", "not logged into", "az login", "please run 'az login'",
                    "aadsts", "authentication failed", "tf400813", "unauthorized", "bad credentials",
                    "token has expired", "refresh token"]
        if auth.contains(where: s.contains) { return .notLoggedIn }
        let network = ["could not resolve host", "connection refused", "network is unreachable", "timed out",
                       "timeout", "failed to establish a new connection", "error connecting to", "no such host",
                       "max retries exceeded", "temporary failure in name resolution", "connection reset"]
        if network.contains(where: s.contains) { return .network }
        return .other
    }
}
