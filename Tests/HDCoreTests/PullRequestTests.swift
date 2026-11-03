import Foundation
import Testing
@testable import HDCore

struct RemoteRepoTests {
    @Test(arguments: [
        ("https://github.com/acme/widgets", RemoteRepo.github(owner: "acme", repo: "widgets")),
        ("https://github.com/acme/widgets.git", .github(owner: "acme", repo: "widgets")),
        ("https://user@github.com/acme/widgets.git/", .github(owner: "acme", repo: "widgets")),
        ("git@github.com:acme/widgets.git", .github(owner: "acme", repo: "widgets")),
        ("ssh://git@github.com/acme/widgets.git", .github(owner: "acme", repo: "widgets")),
        ("https://dev.azure.com/contoso/Web%20Apps/_git/Fi.Web", .azure(org: "contoso", project: "Web Apps", repo: "Fi.Web")),
        ("https://contoso@dev.azure.com/contoso/Fi/_git/Fi.Web", .azure(org: "contoso", project: "Fi", repo: "Fi.Web")),
        ("https://contoso.visualstudio.com/Fi/_git/Fi.Web", .azure(org: "contoso", project: "Fi", repo: "Fi.Web")),
        ("https://contoso.visualstudio.com/DefaultCollection/Fi/_git/Fi.Web", .azure(org: "contoso", project: "Fi", repo: "Fi.Web")),
        ("git@ssh.dev.azure.com:v3/contoso/My%20Project/my-repo", .azure(org: "contoso", project: "My Project", repo: "my-repo")),
    ])
    func parsesRemotes(url: String, expected: RemoteRepo) {
        #expect(RemoteRepo.parse(url) == expected)
    }

    @Test func rejectsOtherHostsAndJunk() {
        #expect(RemoteRepo.parse("https://gitlab.com/a/b.git") == nil)
        #expect(RemoteRepo.parse("/Users/me/repo") == nil)
        #expect(RemoteRepo.parse("") == nil)
        #expect(RemoteRepo.parse("https://github.com/onlyowner") == nil)
        #expect(RemoteRepo.parse("https://dev.azure.com/org/project") == nil)
    }

    @Test func keyIsCaseInsensitive() {
        #expect(RemoteRepo.parse("https://github.com/Acme/Widgets")?.key == RemoteRepo.parse("git@github.com:acme/widgets.git")?.key)
        #expect(RemoteRepo.azure(org: "o", project: "Fi", repo: "Fi.Web").label == "Fi/Fi.Web")
        #expect(RemoteRepo.azure(org: "o", project: "Same", repo: "Same").label == "Same")
    }
}

struct GitHubPRParserTests {
    static let repo = RemoteRepo.github(owner: "acme", repo: "widgets")

    // Same keys `gh pr list --json <jsonFields>` returns (gh 2.x).
    static let mine = """
    [
      {"author":{"id":"U_1","is_bot":false,"login":"me","name":"Me"},"baseRefName":"main","createdAt":"2026-11-01T11:48:55Z",
       "headRefName":"feat/a","isDraft":false,"mergeable":"MERGEABLE","number":12,"reviewDecision":"APPROVED",
       "statusCheckRollup":[{"__typename":"CheckRun","completedAt":"2026-11-01T12:00:00Z","conclusion":"SUCCESS","detailsUrl":"https://x","name":"build","startedAt":"2026-11-01T11:50:00Z","status":"COMPLETED","workflowName":"CI"},
                            {"__typename":"CheckRun","conclusion":"SKIPPED","name":"deploy","status":"COMPLETED","workflowName":"CI"}],
       "title":"Add widgets","updatedAt":"2026-11-02T09:00:00Z","url":"https://github.com/acme/widgets/pull/12"},
      {"author":{"login":"me"},"baseRefName":"main","createdAt":"2026-11-02T08:00:00Z","headRefName":"fix/b","isDraft":true,
       "mergeable":"CONFLICTING","number":13,"reviewDecision":"CHANGES_REQUESTED",
       "statusCheckRollup":[{"__typename":"CheckRun","conclusion":"FAILURE","status":"COMPLETED","name":"test"},
                            {"__typename":"CheckRun","conclusion":null,"status":"IN_PROGRESS","name":"lint"}],
       "title":"Fix b","updatedAt":"2026-11-02T08:30:00Z","url":"https://github.com/acme/widgets/pull/13"},
      {"author":{"login":"me"},"baseRefName":"main","createdAt":"2026-11-02T08:00:00Z","headRefName":"c","isDraft":false,
       "mergeable":"UNKNOWN","number":14,"reviewDecision":"","statusCheckRollup":[{"__typename":"StatusContext","state":"PENDING","context":"ci/x"}],
       "title":"C","updatedAt":"2026-11-02T08:30:00Z","url":"https://github.com/acme/widgets/pull/14"}
    ]
    """

    @Test func parsesMyPullRequests() throws {
        let prs = try GitHubPRParser.parse(Data(Self.mine.utf8), repo: Self.repo, mine: true)
        #expect(prs.count == 3)
        let a = prs[0]
        #expect(a.id == "github:acme/widgets#12")
        #expect(a.number == 12 && a.title == "Add widgets" && a.sourceBranch == "feat/a" && a.targetBranch == "main")
        #expect(a.isMine && !a.reviewRequestedFromMe && !a.isDraft)
        #expect(a.ci == .passing && a.review == .approved && a.mergeable == .yes)
        #expect(a.author == "me" && a.repoLabel == "acme/widgets")
        #expect(a.createdAt == ISODate.parse("2026-11-01T11:48:55Z"))
        #expect(!a.needsMe)

        let b = prs[1]
        #expect(b.isDraft && b.ci == .failing && b.review == .changesRequested && b.mergeable == .conflict)
        #expect(b.reasons == [.ciFailing, .changesRequested, .conflict])

        let c = prs[2]
        #expect(c.ci == .pending && c.review == .none && c.mergeable == .unknown)
        #expect(!c.needsMe)
    }

    @Test func reviewRequestedListAndDedupe() throws {
        let json = """
        [{"author":{"login":"teammate"},"baseRefName":"main","createdAt":"2026-11-02T08:00:00Z","headRefName":"x","isDraft":false,
          "mergeable":"MERGEABLE","number":20,"reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[],"title":"X",
          "updatedAt":"2026-11-02T08:00:00Z","url":"https://github.com/acme/widgets/pull/20"}]
        """
        let review = try GitHubPRParser.parse(Data(json.utf8), repo: Self.repo, mine: false)
        #expect(review[0].reviewRequestedFromMe && !review[0].isMine)
        #expect(review[0].review == .waiting && review[0].ci == .none)
        #expect(review[0].reasons == [.reviewRequested])

        let mine = try GitHubPRParser.parse(Data(Self.mine.utf8), repo: Self.repo, mine: true)
        var dup = review[0]
        dup.id = mine[0].id
        let merged = PullRequest.dedupe(mine + [dup])
        #expect(merged.count == 3)
        #expect(merged[0].isMine && merged[0].reviewRequestedFromMe)
        // Own PR: a review request on it is not a reason.
        #expect(!merged[0].reasons.contains(.reviewRequested))
    }

    @Test func badJSONThrows() {
        #expect(throws: PullRequestParseError.notJSON) {
            try GitHubPRParser.parse(Data("gh: not logged in".utf8), repo: Self.repo, mine: true)
        }
    }
}

struct AzurePRParserTests {
    static let me = "Me@Contoso.com"

    // Mirrors the keys `az repos pr list -o json` returns (azure-devops extension), names made up.
    static func pr(id: Int, creator: String, reviewers: String, merge: String = "succeeded", draft: Bool = false) -> String {
        """
        {"artifactId":"vstfs:///Git/PullRequestId/x","autoCompleteSetBy":null,"closedBy":null,"closedDate":null,"codeReviewId":\(id),
         "commits":null,"completionOptions":null,"completionQueueTime":null,
         "createdBy":{"descriptor":"aad.x","directoryAlias":null,"displayName":"\(creator) Name","id":"1","imageUrl":"https://x",
                      "inactive":null,"isAadIdentity":null,"isContainer":null,"isDeletedInOrigin":null,"profileUrl":null,
                      "uniqueName":"\(creator)","url":"https://x"},
         "creationDate":"2026-10-30T08:12:34.667673+00:00","description":"secret-free text","forkSource":null,"isDraft":\(draft),
         "labels":null,"lastMergeCommit":{},"lastMergeSourceCommit":{},"lastMergeTargetCommit":{},"mergeFailureMessage":null,
         "mergeFailureType":null,"mergeId":"m","mergeOptions":null,"mergeStatus":"\(merge)","pullRequestId":\(id),
         "remoteUrl":null,"repository":{"defaultBranch":null,"id":"r","isFork":null,"name":"Fi.Web","parentRepository":null,
         "project":{"id":"p","name":"Fi"},"remoteUrl":null,"size":null,"sshUrl":null,"url":"https://x","validRemoteUrls":null},
         "reviewers":[\(reviewers)],"sourceRefName":"refs/heads/feature/\(id)","status":"active","supportsIterations":true,
         "targetRefName":"refs/heads/master","title":"PR \(id)","url":"https://x","workItemRefs":null}
        """
    }

    static func reviewer(_ name: String, vote: Int, required: Bool = false, container: Bool = false) -> String {
        """
        {"descriptor":"d","directoryAlias":null,"displayName":"\(name)","hasDeclined":false,"id":"i","imageUrl":"https://x",
         "inactive":null,"isAadIdentity":null,"isContainer":\(container),"isDeletedInOrigin":null,"isFlagged":false,
         "isRequired":\(required),"profileUrl":null,"reviewerUrl":"https://x","uniqueName":"\(name)","url":"https://x",
         "vote":\(vote),"votedFor":null}
        """
    }

    @Test func parsesMineWithVotesAndMergeStatus() throws {
        let json = "[" + [
            Self.pr(id: 1, creator: "me@contoso.com", reviewers: [Self.reviewer("a@c.com", vote: 10), Self.reviewer("b@c.com", vote: 5)].joined(separator: ",")),
            Self.pr(id: 2, creator: "me@contoso.com", reviewers: Self.reviewer("a@c.com", vote: -10), merge: "conflicts", draft: true),
            Self.pr(id: 3, creator: "me@contoso.com", reviewers: [Self.reviewer("a@c.com", vote: 10), Self.reviewer("lead@c.com", vote: 0, required: true)].joined(separator: ",")),
            Self.pr(id: 4, creator: "me@contoso.com", reviewers: Self.reviewer("a@c.com", vote: -5), merge: "queued"),
            Self.pr(id: 5, creator: "me@contoso.com", reviewers: ""),
        ].joined(separator: ",") + "]"
        let prs = try AzurePRParser.parse(Data(json.utf8), org: "contoso", project: "Fi", repo: "Fi.Web", me: Self.me, reviewList: false)
        #expect(prs.count == 5)
        #expect(prs.allSatisfy { $0.isMine && !$0.reviewRequestedFromMe })
        #expect(prs[0].id == "azure:contoso/fi/fi.web#1")
        #expect(prs[0].url == "https://dev.azure.com/contoso/Fi/_git/Fi.Web/pullrequest/1")
        #expect(prs[0].sourceBranch == "feature/1" && prs[0].targetBranch == "master")
        #expect(prs[0].review == .approved && prs[0].mergeable == .yes)
        #expect(prs[0].createdAt == ISODate.parse("2026-10-30T08:12:34.667Z"))
        #expect(prs[1].review == .changesRequested && prs[1].mergeable == .conflict && prs[1].isDraft)
        #expect(prs[1].reasons == [.changesRequested, .conflict])
        #expect(prs[2].review == .waiting)
        #expect(prs[3].review == .changesRequested && prs[3].mergeable == .unknown)
        #expect(prs[4].review == .none)
    }

    @Test func reviewListUsesMyVote() throws {
        let json = "[" + [
            Self.pr(id: 7, creator: "teammate@c.com", reviewers: Self.reviewer("ME@contoso.com", vote: 0)),
            Self.pr(id: 8, creator: "teammate@c.com", reviewers: Self.reviewer("me@contoso.com", vote: 10)),
            Self.pr(id: 9, creator: "teammate@c.com", reviewers: Self.reviewer("me@contoso.com", vote: -5)),
            // Only through a group: I have no entry of my own.
            Self.pr(id: 10, creator: "teammate@c.com", reviewers: Self.reviewer("[Fi]\\\\Team", vote: 0, container: true)),
            Self.pr(id: 11, creator: "me@contoso.com", reviewers: Self.reviewer("me@contoso.com", vote: 0)),
        ].joined(separator: ",") + "]"
        let prs = try AzurePRParser.parse(Data(json.utf8), org: "contoso", project: "Fi", repo: "Fi.Web", me: Self.me, reviewList: true)
        #expect(prs[0].reviewRequestedFromMe && prs[0].myVote == .none && prs[0].needsMe)
        #expect(prs[1].myVote == .approved && !prs[1].needsMe)
        #expect(prs[2].myVote == .waiting && prs[2].needsMe)
        #expect(prs[3].reviewRequestedFromMe && prs[3].myVote == .none && prs[3].needsMe)
        #expect(prs[4].isMine && !prs[4].reviewRequestedFromMe && !prs[4].needsMe)
        #expect(prs[0].author == "teammate@c.com Name")
    }

    @Test func voteMapping() {
        #expect(AzurePRParser.vote(10) == .approved)
        #expect(AzurePRParser.vote(5) == .approved)
        #expect(AzurePRParser.vote(0) == .none)
        #expect(AzurePRParser.vote(nil) == .none)
        #expect(AzurePRParser.vote(-5) == .waiting)
        #expect(AzurePRParser.vote(-10) == .rejected)
    }

    @Test func webURLEscapesSpaces() {
        #expect(AzurePRParser.webURL(org: "o", project: "My Project", repo: "r", id: 3) == "https://dev.azure.com/o/My%20Project/_git/r/pullrequest/3")
    }

    static func evaluation(_ type: String, _ status: String) -> String {
        """
        {"artifactId":"a","completedDate":null,"configuration":{"isBlocking":true,"isEnabled":true,"type":{"displayName":"\(type)","id":"t"}},
         "context":null,"evaluationId":"e","startedDate":"2026-11-01T10:00:00.1234567Z","status":"\(status)"}
        """
    }

    @Test func policyEvaluationsToCI() throws {
        func ci(_ evals: [String]) throws -> PullRequest.CI {
            try AzurePRParser.ci(fromPolicies: Data(("[" + evals.joined(separator: ",") + "]").utf8))
        }
        // A rejected non-build policy (merge strategy) doesn't make CI fail.
        #expect(try ci([Self.evaluation("Minimum number of reviewers", "approved"), Self.evaluation("Require a merge strategy", "rejected"),
                        Self.evaluation("Build", "approved")]) == .passing)
        #expect(try ci([Self.evaluation("Build", "queued")]) == .pending)
        #expect(try ci([Self.evaluation("Build", "running"), Self.evaluation("Build", "approved")]) == .pending)
        #expect(try ci([Self.evaluation("Build", "rejected"), Self.evaluation("Build", "running")]) == .failing)
        #expect(try ci([Self.evaluation("Status", "approved")]) == .passing)
        #expect(try ci([Self.evaluation("Build", "notApplicable")]) == .none)
        #expect(try ci([Self.evaluation("Work item linking", "rejected")]) == .none)
        #expect(try ci([]) == .none)
    }

    @Test func cliFailureKinds() {
        #expect(CLIFailureKind.classify("ERROR: Please run 'az login' to setup account.") == .notLoggedIn)
        #expect(CLIFailureKind.classify("To get started with GitHub CLI, please run:  gh auth login") == .notLoggedIn)
        #expect(CLIFailureKind.classify("AADSTS700082: The refresh token has expired") == .notLoggedIn)
        #expect(CLIFailureKind.classify("error connecting to api.github.com") == .network)
        #expect(CLIFailureKind.classify("Failed to establish a new connection: [Errno 8] nodename nor servname provided") == .network)
        #expect(CLIFailureKind.classify("TF401019: The Git repository does not exist") == .other)
    }
}

struct DaySummaryTests {
    static let labels = DaySummary.Labels(title: "Day 2026-11-03", done: "Done", pullRequests: "Pull requests",
                                          opened: "Opened", merged: "Merged", stillOpen: "Still open",
                                          tomorrow: "Tomorrow", nothing: "Nothing")

    @Test func buildsMarkdown() {
        let s1 = UUID(), s2 = UUID(), p = UUID()
        let t = ISODate.parse("2026-11-03T09:00:00Z")!
        let events = [
            ActivityEvent(at: t.addingTimeInterval(600), kind: .turnDone, sessionID: s1, projectID: p, title: "Login fix",
                          detail: "Fixed the token refresh.\nAlso added a test."),
            ActivityEvent(at: t, kind: .turnDone, sessionID: s1, projectID: p, title: "Login fix", detail: "first pass"),
            ActivityEvent(at: t.addingTimeInterval(300), kind: .turnDone, sessionID: s2, title: "Docs", detail: nil),
            ActivityEvent(at: t.addingTimeInterval(700), kind: .prOpened, title: "Fix [login]", prURL: "https://x/1"),
            ActivityEvent(at: t.addingTimeInterval(800), kind: .prMerged, title: "Old PR", prURL: "https://x/0"),
            ActivityEvent(at: t.addingTimeInterval(900), kind: .needsYou, sessionID: s2, title: "Docs"),
        ]
        let md = DaySummary.markdown(
            events: events,
            stillOpen: [DaySummary.Item(text: "Big refactor", detail: "Needs you: permission\nmore"),
                        DaySummary.Item(text: "PR 7", detail: "CI failing", url: "https://x/7")],
            tomorrow: [],
            projectNames: [p: "app"], labels: Self.labels,
            time: { d in d == t.addingTimeInterval(600) ? "09:10" : "09:05" })
        let expected = """
        # Day 2026-11-03

        ## Done

        - **Docs** · 09:05
        - **Login fix** (app) ×2 · 09:10
          Fixed the token refresh. Also added a test.

        ## Pull requests

        - Opened: [Fix [login\\]](https://x/1)
        - Merged: [Old PR](https://x/0)

        ## Still open

        - Big refactor — Needs you: permission
        - [PR 7](https://x/7) — CI failing

        ## Tomorrow

        - Nothing

        """
        #expect(md == expected)
    }

    @Test func emptyDay() {
        let md = DaySummary.markdown(events: [], stillOpen: [], tomorrow: [], projectNames: [:], labels: Self.labels, time: { _ in "" })
        #expect(md.components(separatedBy: "- Nothing").count - 1 == 4)
    }

    @Test func aiOutput() {
        #expect(ClaudePrintOutput.result(from: #"{"type":"result","is_error":false,"result":"- a\n- b"}"#) == "- a\n- b")
        #expect(ClaudePrintOutput.result(from: #"{"type":"result","is_error":true,"result":"Credit balance too low"}"#) == nil)
        #expect(ClaudePrintOutput.result(from: "plain") == nil)
        #expect(DaySummary.aiPrompt(markdown: "# x").hasSuffix("# x"))
    }
}

struct ReviewPromptTests {
    static let pr = PullRequest(id: "github:a/b#5", provider: .github, number: 5, title: "Add {title} support",
                                url: "https://github.com/a/b/pull/5", repoKey: "github:a/b", repoLabel: "a/b",
                                sourceBranch: "feat/x", targetBranch: "main", author: "t", isMine: false, isDraft: false,
                                createdAt: Date(timeIntervalSince1970: 0))

    @Test func rendersDefaultTemplate() {
        let text = ReviewPrompt.render(nil, pr: Self.pr)
        #expect(text.hasPrefix("Review pull request https://github.com/a/b/pull/5 (feat/x → main)."))
        #expect(text.contains("`git diff origin/main...HEAD`"))
        #expect(!text.contains("{"))
        #expect(ReviewPrompt.render("   ", pr: Self.pr) == text)
    }

    @Test func rendersCustomTemplateOnce() {
        let t = "#{number} {title} in {repo}: {source}->{target} {url} {unknown} {"
        #expect(ReviewPrompt.render(t, pr: Self.pr)
                == "#5 Add {title} support in a/b: feat/x->main https://github.com/a/b/pull/5 {unknown} {")
    }
}
