import Foundation

// OWNER: tracking area. Pure PR model and classification; the app fills it from `gh` / `az`.

/// Where a repository's pull requests live, parsed from its `origin` URL.
public enum RemoteRepo: Hashable, Sendable {
    case github(owner: String, repo: String)
    case azure(org: String, project: String, repo: String)

    /// Case-insensitive identity, for deduping projects that share a repository.
    public var key: String {
        switch self {
        case .github(let o, let r): return "github:\(o)/\(r)".lowercased()
        case .azure(let o, let p, let r): return "azure:\(o)/\(p)/\(r)".lowercased()
        }
    }

    /// Short label: `owner/repo` or `project/repo`.
    public var label: String {
        switch self {
        case .github(let o, let r): return "\(o)/\(r)"
        case .azure(_, let p, let r): return p == r ? r : "\(p)/\(r)"
        }
    }

    public var provider: PullRequest.Provider {
        switch self {
        case .github: return .github
        case .azure: return .azure
        }
    }

    /// Parses the forms git remotes take:
    /// `https://github.com/o/r(.git)`, `git@github.com:o/r.git`, `ssh://git@github.com/o/r.git`,
    /// `https://dev.azure.com/{org}/{project}/_git/{repo}`, `https://{user}@dev.azure.com/…`,
    /// `https://{org}.visualstudio.com/(DefaultCollection/){project}/_git/{repo}`,
    /// `git@ssh.dev.azure.com:v3/{org}/{project}/{repo}`. Percent-escapes (`%20`) are decoded.
    public static func parse(_ raw: String) -> RemoteRepo? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var host: String
        var path: String
        if let schemeEnd = s.range(of: "://") {
            var rest = String(s[schemeEnd.upperBound...])
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            var authority = String(rest[..<slash])
            rest = String(rest[slash...])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            if let colon = authority.firstIndex(of: ":") { authority = String(authority[..<colon]) }
            host = authority
            path = rest
        } else if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("/") {
            // scp-like: user@host:path
            var authority = String(s[..<colon])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            host = authority
            path = String(s[s.index(after: colon)...])
        } else {
            return nil
        }
        host = host.lowercased()
        var parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
            .filter { !$0.isEmpty }
        if let last = parts.last, last.lowercased().hasSuffix(".git") { parts[parts.count - 1] = String(last.dropLast(4)) }
        while parts.last?.isEmpty == true { parts.removeLast() }

        if host == "github.com" || host == "ssh.github.com" || host == "www.github.com" {
            guard parts.count >= 2 else { return nil }
            return .github(owner: parts[0], repo: parts[1])
        }
        if host == "ssh.dev.azure.com" || host == "vs-ssh.visualstudio.com" {
            // v3/{org}/{project}/{repo}
            guard parts.count >= 4, parts[0] == "v3" else { return nil }
            return .azure(org: parts[1], project: parts[2], repo: parts[3])
        }
        if host == "dev.azure.com" {
            guard parts.count >= 4, let git = parts.firstIndex(of: "_git"), git >= 2, git + 1 < parts.count else { return nil }
            return .azure(org: parts[0], project: parts[git - 1], repo: parts[git + 1])
        }
        if host.hasSuffix(".visualstudio.com") {
            let org = String(host.dropLast(".visualstudio.com".count))
            guard !org.isEmpty, let git = parts.firstIndex(of: "_git"), git >= 1, git + 1 < parts.count else { return nil }
            return .azure(org: org, project: parts[git - 1], repo: parts[git + 1])
        }
        return nil
    }
}

public struct PullRequest: Identifiable, Hashable, Sendable {
    public enum Provider: String, Hashable, Sendable { case github, azure }
    public enum CI: String, Hashable, Sendable { case passing, failing, pending, none }
    public enum Review: String, Hashable, Sendable { case approved, changesRequested, waiting, none }
    public enum Mergeable: String, Hashable, Sendable { case yes, conflict, unknown }
    /// My own vote on someone else's PR (Azure votes; GitHub "review requested" means none yet).
    public enum Vote: String, Hashable, Sendable { case none, waiting, approved, rejected }

    /// Provider-scoped: `github:owner/repo#12`, `azure:org/project/repo#345` (lowercased repo part).
    public var id: String
    public var provider: Provider
    public var number: Int
    public var title: String
    /// Web URL.
    public var url: String
    public var repoKey: String
    public var repoLabel: String
    public var sourceBranch: String
    public var targetBranch: String
    public var author: String
    public var isMine: Bool
    public var isDraft: Bool
    public var createdAt: Date
    public var updatedAt: Date?
    public var ci: CI
    public var review: Review
    public var mergeable: Mergeable
    public var reviewRequestedFromMe: Bool
    /// Only meaningful when `reviewRequestedFromMe`.
    public var myVote: Vote

    public init(id: String, provider: Provider, number: Int, title: String, url: String, repoKey: String,
                repoLabel: String, sourceBranch: String, targetBranch: String, author: String, isMine: Bool,
                isDraft: Bool, createdAt: Date, updatedAt: Date? = nil, ci: CI = .none, review: Review = .none,
                mergeable: Mergeable = .unknown, reviewRequestedFromMe: Bool = false, myVote: Vote = .none) {
        self.id = id
        self.provider = provider
        self.number = number
        self.title = title
        self.url = url
        self.repoKey = repoKey
        self.repoLabel = repoLabel
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.author = author
        self.isMine = isMine
        self.isDraft = isDraft
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ci = ci
        self.review = review
        self.mergeable = mergeable
        self.reviewRequestedFromMe = reviewRequestedFromMe
        self.myVote = myVote
    }

    /// Why a PR wants the user, most pressing first. Empty when it doesn't.
    public enum Reason: String, Hashable, Sendable { case ciFailing, changesRequested, conflict, reviewRequested }

    public var reasons: [Reason] {
        var out: [Reason] = []
        if isMine {
            if ci == .failing { out.append(.ciFailing) }
            if review == .changesRequested { out.append(.changesRequested) }
            if mergeable == .conflict { out.append(.conflict) }
        }
        if reviewRequestedFromMe && !isMine && (myVote == .none || myVote == .waiting) {
            out.append(.reviewRequested)
        }
        return out
    }

    public var needsMe: Bool { !reasons.isEmpty }

    public var lastActivity: Date { updatedAt ?? createdAt }

    /// No activity for `days` days.
    public func isStale(now: Date = Date(), days: Int) -> Bool {
        now.timeIntervalSince(lastActivity) > Double(days) * 86_400
    }

    /// Days without activity after which a PR leaves the lists (it stays one click away).
    public static let staleDays = 30

    /// Review requests the user still has to act on: not voted on yet and not stale.
    public static func openReviewRequests(_ prs: [PullRequest], now: Date = Date()) -> (shown: [PullRequest], hidden: [PullRequest]) {
        split(prs) { ($0.myVote == .none || $0.myVote == .waiting) && !$0.isStale(now: now, days: staleDays) }
    }

    /// The user's own PRs with activity in the last `staleDays` days.
    public static func activeMine(_ prs: [PullRequest], now: Date = Date()) -> (shown: [PullRequest], hidden: [PullRequest]) {
        split(prs) { !$0.isStale(now: now, days: staleDays) }
    }

    private static func split(_ prs: [PullRequest], _ keep: (PullRequest) -> Bool) -> (shown: [PullRequest], hidden: [PullRequest]) {
        var shown: [PullRequest] = [], hidden: [PullRequest] = []
        for pr in prs { if keep(pr) { shown.append(pr) } else { hidden.append(pr) } }
        return (shown, hidden)
    }

    /// Merges the same PR seen in two lists (mine and review-requested): flags are OR'ed.
    public func merged(with other: PullRequest) -> PullRequest {
        var m = self
        m.isMine = isMine || other.isMine
        m.reviewRequestedFromMe = reviewRequestedFromMe || other.reviewRequestedFromMe
        if m.myVote == .none { m.myVote = other.myVote }
        if m.ci == .none { m.ci = other.ci }
        return m
    }

    /// Dedupes by id, keeping first-seen order.
    public static func dedupe(_ prs: [PullRequest]) -> [PullRequest] {
        var order: [String] = []
        var byID: [String: PullRequest] = [:]
        for pr in prs {
            if let existing = byID[pr.id] {
                byID[pr.id] = existing.merged(with: pr)
            } else {
                byID[pr.id] = pr
                order.append(pr.id)
            }
        }
        return order.compactMap { byID[$0] }
    }
}
