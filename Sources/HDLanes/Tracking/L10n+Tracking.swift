import Foundation
import HDCore

// OWNER: tracking area.
extension L {
    static var tracking: String { pick("Tracking", "Takip") }
    static func trackingBadgeHelp(_ n: Int) -> String {
        pick("\(n) waiting for you (sessions and pull requests)", "Seni bekleyen \(n) şey (oturumlar ve PR'lar)")
    }
    static var tabToday: String { pick("Today", "Bugün") }
    static var tabPullRequests: String { pick("Pull Requests", "PR'lar") }
    static var tabDaySummary: String { pick("End of Day", "Gün sonu") }

    static var refreshing: String { pick("Refreshing…", "Yenileniyor…") }
    static func refreshedAt(_ when: String) -> String { pick("Updated \(when)", "Güncellendi: \(when)") }
    static var refreshHelp: String { pick("Read open pull requests again", "Açık PR'ları yeniden oku") }

    // Today
    static var sectionWaiting: String { pick("Waiting for you", "Seni bekleyen") }
    static var sectionWorking: String { pick("In progress", "Devam eden") }
    static var sectionFinishedToday: String { pick("Finished today", "Bugün biten") }
    static var sectionMyPullRequests: String { pick("Open pull requests", "Açık PR'lar") }
    static var sectionFlow: String { pick("Activity", "Akış") }
    static var emptyWaiting: String { pick("Nothing is waiting for you.", "Seni bekleyen bir şey yok.") }
    static var emptyWorking: String { pick("No agent is working right now.", "Şu an çalışan bir ajan yok.") }
    static var emptyFinished: String { pick("No turn has finished today yet.", "Bugün henüz biten bir tur yok.") }
    static var emptyMyPullRequests: String { pick("You have no open pull requests.", "Açık PR'ın yok.") }
    static var emptyReviewRequested: String { pick("No pull request is waiting for your review.", "Senden review bekleyen PR yok.") }
    static var emptyNoRemotes: String {
        pick("No project has a GitHub or Azure DevOps remote named origin.",
             "Hiçbir projede GitHub ya da Azure DevOps'a giden bir origin uzak deposu yok.")
    }
    static var emptyFlow: String { pick("Nothing recorded today yet.", "Bugün henüz kayıt yok.") }
    static func linkedSession(_ title: String) -> String { pick("session: \(title)", "oturum: \(title)") }

    static func activityKind(_ k: ActivityEvent.Kind) -> String {
        switch k {
        case .sessionStarted: return pick("Started", "Başladı")
        case .turnDone: return pick("Finished", "Bitti")
        case .needsYou: return pick("Needs you", "Seni bekliyor")
        case .error: return pick("Error", "Hata")
        case .sessionClosed: return pick("Closed", "Kapandı")
        case .prOpened: return pick("PR opened", "PR açıldı")
        case .prMerged: return pick("PR merged", "PR merge edildi")
        case .reviewStarted: return pick("Review started", "Review başladı")
        case .taskMoved: return pick("Task moved", "Görev taşındı")
        }
    }

    // Pull requests
    static var sectionMine: String { pick("Opened by me", "Benim açtıklarım") }
    static var sectionReviewRequested: String { pick("Waiting for my review", "Benden review bekleyen") }
    static var prDraft: String { pick("Draft", "Taslak") }
    static var prCI: String { "CI" }
    static var prCIPassing: String { pick("Checks passed", "Kontroller geçti") }
    static var prCIFailing: String { pick("Checks failed", "Kontroller başarısız") }
    static var prCIPending: String { pick("Checks running", "Kontroller sürüyor") }
    static var prApproved: String { pick("Approved", "Onaylandı") }
    static var prChangesRequested: String { pick("Changes requested", "Değişiklik istendi") }
    static var prReviewWaiting: String { pick("Awaiting review", "Review bekliyor") }
    static var prReviewRequested: String { pick("Your review", "Senin review'un") }
    static var prYouApproved: String { pick("You approved", "Onayladın") }
    static var prYouRejected: String { pick("You rejected", "Reddettin") }
    static var prConflict: String { pick("Conflict", "Çakışma") }
    static func prReason(_ r: PullRequest.Reason) -> String {
        switch r {
        case .ciFailing: return pick("checks failing", "kontroller başarısız")
        case .changesRequested: return pick("changes requested", "değişiklik istendi")
        case .conflict: return pick("merge conflict", "çakışma var")
        case .reviewRequested: return pick("your review", "review'un bekleniyor")
        }
    }
    static func branchArrow(_ source: String, _ target: String) -> String { "\(source) → \(target)" }
    static var openPR: String { pick("Open", "Aç") }
    static var openInBrowserHelp: String { pick("Open the pull request in the browser", "PR'ı tarayıcıda aç") }
    static var goToSession: String { pick("Go to Session", "Oturuma git") }
    static var reviewEllipsis: String { pick("Review…", "Review et…") }
    static var reviewHelp: String {
        pick("Check the branch out in a new worktree and start an agent that reviews it",
             "Dalı yeni bir worktree'de aç ve onu inceleyen bir ajan başlat")
    }
    static var reviewNoProject: String {
        pick("No project in hdlanes points at this repository", "hdlanes'te bu depoyu gösteren bir proje yok")
    }
    static var copyLink: String { pick("Copy Link", "Bağlantıyı Kopyala") }

    static func prIssue(_ issue: PRIssue) -> String {
        switch issue {
        case .cliMissing(let tool): return pick("\(tool) isn't installed; its pull requests can't be read.",
                                                "\(tool) kurulu değil; PR'ları okunamıyor.")
        case .notLoggedIn(let tool): return pick("\(tool) isn't logged in. Run `\(tool == "az" ? "az login" : "gh auth login")` in a terminal.",
                                                 "\(tool) giriş yapılmamış. Bir terminalde `\(tool == "az" ? "az login" : "gh auth login")` çalıştır.")
        case .network(let tool): return pick("\(tool) couldn't reach the server. Pull requests will be read again later.",
                                             "\(tool) sunucuya ulaşamadı. PR'lar sonra yeniden okunacak.")
        case .failed(let tool, let line):
            return line.isEmpty ? pick("\(tool) returned something unexpected.", "\(tool) beklenmedik bir yanıt verdi.")
                : pick("\(tool) failed: \(line)", "\(tool) hata verdi: \(line)")
        }
    }

    // End of day
    static var day: String { pick("Day", "Gün") }
    static var copy: String { pick("Copy", "Kopyala") }
    static var copyHelp: String { pick("Copy the report as Markdown", "Raporu Markdown olarak kopyala") }
    static var saveEllipsisReport: String { pick("Save", "Kaydet") }
    static var saveReportHelp: String {
        pick("Save to ~/.hdlanes/reports and show it in Finder", "~/.hdlanes/reports altına kaydet ve Finder'da göster")
    }
    static func saveReportFailed(_ e: String) -> String { pick("Couldn't save the report: \(e)", "Rapor kaydedilemedi: \(e)") }
    static var aiAccountHelp: String { pick("Claude account the summary runs on", "Özetin çalışacağı Claude hesabı") }
    static var aiNoAccount: String { pick("Add a Claude account first", "Önce bir Claude hesabı ekle") }
    static var tidyWithAI: String { pick("Summarize with AI", "AI ile toparla") }
    static var tidyWithAIHelp: String {
        pick("One short claude -p call (haiku) on the chosen account turns the report into a few bullet points",
             "Seçili hesapta tek bir kısa claude -p çağrısı (haiku) raporu birkaç maddeye çevirir")
    }
    static var aiSummary: String { pick("AI summary", "AI özeti") }
    static func daySummaryTitle(_ date: String) -> String { pick("End of day · \(date)", "Gün sonu · \(date)") }
    static var sumDone: String { pick("Done", "Bitenler") }
    static var sumPullRequests: String { pick("Pull requests opened and merged", "Açılan / merge edilen PR'lar") }
    static var sumOpened: String { pick("Opened", "Açıldı") }
    static var sumMerged: String { pick("Merged", "Merge edildi") }
    static var sumStillOpen: String { pick("Still open", "Açık kalanlar") }
    static var sumTomorrow: String { pick("For tomorrow", "Yarına") }
    static var sumNothing: String { pick("Nothing", "Yok") }

    // Review sheet
    static var pullRequest: String { pick("Pull request", "PR") }
    static var branches: String { pick("Branches", "Dallar") }
    static var sessionTitle: String { pick("Title", "Başlık") }
    static func reviewTitle(_ prTitle: String) -> String { "Review: \(prTitle)" }
    static var reviewFooter: String {
        pick("The branch is fetched and checked out detached in a new worktree. Nothing is pushed, commented or approved.",
             "Dal çekilir ve yeni bir worktree'de detached olarak açılır. Hiçbir şey push edilmez, yorumlanmaz ya da onaylanmaz.")
    }
    static var reviewPrompt: String { pick("First prompt", "İlk istem") }
    static var reviewPreparing: String { pick("Fetching the branch…", "Dal çekiliyor…") }
    static var reviewBranchUnusable: String {
        pick("This pull request's branch name can't be used here.", "Bu PR'ın dal adı burada kullanılamıyor.")
    }
    static var startReview: String { pick("Start Review", "Review'u Başlat") }
    static var reviewPromptTemplate: String { pick("Review prompt", "Review istemi") }
    static func reviewTemplateFooter(_ placeholders: String) -> String {
        pick("First prompt of review sessions started from Tracking. Empty uses the default. Placeholders: \(placeholders)",
             "Takip'ten başlatılan review oturumlarının ilk istemi. Boşsa varsayılan kullanılır. Yer tutucular: \(placeholders)")
    }
    static var loadingPullRequests: String { pick("Reading pull requests…", "PR'lar okunuyor…") }
}
