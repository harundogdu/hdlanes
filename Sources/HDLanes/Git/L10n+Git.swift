import Foundation
import HDCore

// OWNER: git area.
extension L {
    // MARK: Inspector tabs

    static var tabChanges: String { pick("Changes", "Değişiklikler") }
    static var tabAgents: String { pick("Agents", "Ajanlar") }
    static var tabBrowser: String { pick("Browser", "Tarayıcı") }
    static var inspectorSessionMissing: String { pick("Session not found", "Oturum bulunamadı") }
    static var inspectorSessionMissingDetail: String {
        pick("Select a session in the sidebar.", "Kenar çubuğundan bir oturum seç.")
    }

    // MARK: Changes

    static func filesCount(_ n: Int) -> String { pick(n == 1 ? "1 file" : "\(n) files", "\(n) dosya") }
    static func diffVersus(_ name: String) -> String { pick("vs \(name)", "\(name) tabanına göre") }
    static var diffVersusHead: String { pick("vs HEAD", "HEAD'e göre") }
    static func updatedAgo(_ relative: String) -> String { pick("Updated \(relative)", "\(relative) güncellendi") }
    static var updatedJustNow: String { pick("Updated just now", "Az önce güncellendi") }
    static var refresh: String { pick("Refresh", "Yenile") }
    static var refreshChangesHelp: String { pick("Reload the changes", "Değişiklikleri yeniden yükle") }
    static var loadingChanges: String { pick("Loading changes…", "Değişiklikler yükleniyor…") }
    static var noChangesTitle: String { pick("No changes yet", "Henüz değişiklik yok") }
    static var noChangesDetail: String {
        pick("Edits in this session's folder show up here.", "Bu oturumun klasöründeki düzenlemeler burada görünür.")
    }
    static var notRepositoryTitle: String { pick("Not a Git repository", "Git deposu değil") }
    static var notRepositoryDetail: String {
        pick("This session's folder isn't tracked by Git, so there is nothing to compare.",
             "Bu oturumun klasörü Git ile izlenmiyor, karşılaştırılacak bir şey yok.")
    }
    static var changesErrorTitle: String { pick("Couldn't load changes", "Değişiklikler yüklenemedi") }
    static var tryAgain: String { pick("Try Again", "Tekrar Dene") }
    static func untrackedSkipped(_ n: Int) -> String {
        pick("\(n) more untracked files not listed", "Listelenmeyen \(n) izlenmeyen dosya daha var")
    }
    static var diffTruncated: String {
        pick("The diff is very large; the end was cut off.", "Fark çok büyük, sonu kesildi.")
    }
    static var selectFile: String { pick("Select a file to see its changes.", "Değişikliklerini görmek için bir dosya seç.") }

    static func statusLetter(_ status: DiffFileStatus) -> String {
        switch status {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        case .binary: return "B"
        }
    }

    static func statusName(_ status: DiffFileStatus) -> String {
        switch status {
        case .modified: return pick("Modified", "Değişti")
        case .added: return pick("Added", "Eklendi")
        case .deleted: return pick("Deleted", "Silindi")
        case .renamed: return pick("Renamed", "Yeniden adlandırıldı")
        case .untracked: return pick("Untracked", "İzlenmiyor")
        case .binary: return pick("Binary", "İkili")
        }
    }

    // MARK: Diff view

    static var binaryFile: String { pick("Binary file. Contents aren't shown.", "İkili dosya, içeriği gösterilmiyor.") }
    static var fileTooLarge: String { pick("File is too large to show.", "Dosya gösterilemeyecek kadar büyük.") }
    static var nestedRepository: String {
        pick("Folder with its own repository. Contents aren't shown.", "Kendi deposu olan klasör, içeriği gösterilmiyor.")
    }
    static var noLineChanges: String { pick("No line changes.", "Satır değişikliği yok.") }
    static func modeChange(_ old: String, _ new: String) -> String {
        pick("File mode \(old) → \(new)", "Dosya izni \(old) → \(new)")
    }
    static func renamedFrom(_ old: String) -> String { pick("Renamed from \(old)", "Eski adı: \(old)") }
    static func showingFirstLines(_ shown: Int, _ total: Int) -> String {
        pick("Showing the first \(shown) of \(total) lines.", "\(total) satırın ilk \(shown) satırı gösteriliyor.")
    }
    static func showAllLines(_ total: Int) -> String { pick("Show All \(total) Lines", "\(total) Satırın Hepsini Göster") }
    static var addNote: String { pick("Add a note on this line", "Bu satıra not ekle") }
    static var notePlaceholder: String { pick("Note for the agent", "Ajana not") }
    static var addNoteButton: String { pick("Add Note", "Not Ekle") }
    static var removeNote: String { pick("Remove note", "Notu kaldır") }
    static var notesNotInDiff: String {
        pick("Notes on lines that are no longer in the diff", "Artık farkta olmayan satırlardaki notlar")
    }
    static func noteLocation(_ path: String, _ line: Int?) -> String {
        line.map { "\(path):\($0)" } ?? path
    }

    // MARK: Footer

    static func notesCount(_ n: Int) -> String { pick(n == 1 ? "1 note" : "\(n) notes", "\(n) not") }
    static func sendNotes(to provider: Provider) -> String {
        switch provider {
        case .claude: return pick("Send to Claude", "Claude'a Gönder")
        case .codex: return pick("Send to Codex", "Codex'e Gönder")
        case .shell: return pick("Send to Agent", "Ajana Gönder")
        }
    }
    static var sendNotesNoNotes: String { pick("Add notes on diff lines first.", "Önce fark satırlarına not ekle.") }
    static var sendNotesNotRunning: String { pick("Start the agent to send notes.", "Not göndermek için ajanı başlat.") }
    static var sendNotesNoAgent: String { pick("This session has no agent.", "Bu oturumda ajan yok.") }
    static var sendNotesStarting: String {
        pick("The agent is still starting. Send the notes once it's ready.", "Ajan hâlâ başlıyor. Hazır olunca notları gönder.")
    }
    static var sendNotesAwaitingAnswer: String {
        pick("The agent is waiting for an answer in the terminal. Answer it first.",
             "Ajan terminalde bir yanıt bekliyor. Önce onu yanıtla.")
    }
    static func describe(_ block: ReviewSendBlock) -> String {
        switch block {
        case .notRunning: return sendNotesNotRunning
        case .starting: return sendNotesStarting
        case .awaitingAnswer: return sendNotesAwaitingAnswer
        }
    }
    static var sendNotesHelp: String {
        pick("Paste all notes into the agent as one message", "Tüm notları ajana tek mesaj olarak yapıştır")
    }
    static var createPRButton: String { pick("Create PR…", "PR Oluştur…") }
    static var createPRHelp: String {
        pick("Push the branch and open a pull request with GitHub CLI", "Dalı gönder ve GitHub CLI ile PR aç")
    }
    static var openPullRequest: String { pick("Open Pull Request", "PR'ı Aç") }

    static func describe(_ problem: PullRequestInfo.Problem) -> String {
        switch problem {
        case .noSession: return inspectorSessionMissing
        case .notRepository: return pick("This session's folder isn't a Git repository.", "Bu oturumun klasörü bir Git deposu değil.")
        case .noBranch: return pick("This session has no branch to open a pull request from.",
                                    "Bu oturumun PR açılacak bir dalı yok.")
        case .sameAsBase: return pick("The branch is the same as the base branch.", "Dal, taban dalla aynı.")
        case .ghMissing: return pick("Install GitHub CLI (gh) to create pull requests.",
                                     "PR oluşturmak için GitHub CLI'yi (gh) kur.")
        }
    }

    // MARK: Pull request sheet

    static var prSheetTitle: String { pick("Create Pull Request", "PR Oluştur") }
    static var prTitleField: String { pick("Title", "Başlık") }
    static var prBodyField: String { pick("Description", "Açıklama") }
    static var prBranches: String { pick("Branches", "Dallar") }
    static var prDefaultBase: String { pick("default branch", "varsayılan dal") }
    static func prUncommitted(_ n: Int) -> String {
        pick(n == 1 ? "1 uncommitted change won't be in the pull request. Ask the agent to commit first."
                    : "\(n) uncommitted changes won't be in the pull request. Ask the agent to commit first.",
             "Commit edilmemiş \(n) değişiklik PR'a girmez. Önce ajandan commit etmesini iste.")
    }
    static var prCreate: String { pick("Create", "Oluştur") }
    static var prWorking: String { pick("Pushing the branch and creating the pull request…", "Dal gönderiliyor ve PR oluşturuluyor…") }
    static var prCreated: String { pick("Pull request created", "PR oluşturuldu") }
    static var prOpen: String { pick("Open", "Aç") }
    static var prChecking: String { pick("Checking the branch…", "Dal kontrol ediliyor…") }
    static var prTitleRequired: String { pick("Enter a title.", "Bir başlık yaz.") }

    // MARK: Review message (pasted into the agent)

    static var reviewMessageHeader: String {
        pick("Review notes on your changes:", "Değişikliklerine dair inceleme notları:")
    }
    static func reviewRemovedLine(_ n: Int) -> String { pick("removed line \(n)", "silinen satır \(n)") }

    // MARK: Agents panel

    static var subagentsSection: String { pick("Subagents", "Alt ajanlar") }
    static var activitySection: String { pick("Activity", "Etkinlik") }
    static var agentsEmptyTitle: String { pick("No agent activity yet", "Henüz ajan etkinliği yok") }
    static var agentsEmptyDetail: String {
        pick("Subagents and tool calls show up here while the agent works.",
             "Ajan çalışırken alt ajanlar ve araç çağrıları burada görünür.")
    }
    static var mainAgent: String { pick("main", "ana") }
    static var subagent: String { pick("subagent", "alt ajan") }
    static func toolCount(_ n: Int) -> String { pick(n == 1 ? "1 tool" : "\(n) tools", "\(n) araç") }
    static var lastMessage: String { pick("Last message", "Son mesaj") }
    static var noLastMessage: String { pick("No message.", "Mesaj yok.") }
    static var finished: String { pick("Finished", "Bitti") }
    static var failed: String { pick("Failed", "Başarısız") }
    static var running: String { pick("Running", "Çalışıyor") }
    static var noActivity: String { pick("No tool calls yet.", "Henüz araç çağrısı yok.") }
    static var noSubagents: String { pick("No subagents in this session.", "Bu oturumda alt ajan yok.") }

    // MARK: Browser

    static var addressPlaceholder: String { pick("Address or localhost:3000", "Adres ya da localhost:3000") }
    static var back: String { pick("Back", "Geri") }
    static var forward: String { pick("Forward", "İleri") }
    static var reload: String { pick("Reload", "Yeniden Yükle") }
    static var stopLoading: String { pick("Stop", "Durdur") }
    static var openInDefaultBrowser: String { pick("Open in Default Browser", "Varsayılan Tarayıcıda Aç") }
    static var browserEmptyTitle: String { pick("No page open", "Açık sayfa yok") }
    static var browserEmptyDetail: String {
        pick("Dev server addresses printed in the terminal appear here. You can also type one above.",
             "Terminalde yazılan geliştirme sunucusu adresleri burada görünür. Yukarıya adres de yazabilirsin.")
    }
    static var browserLoadFailed: String { pick("Couldn't load the page", "Sayfa yüklenemedi") }
    static var browserInvalidAddress: String { pick("That isn't a valid address.", "Bu geçerli bir adres değil.") }
    static var browserOnlyHTTP: String {
        pick("Only http and https addresses can be opened.", "Yalnız http ve https adresleri açılabilir.")
    }
    static var detectedURLsHelp: String { pick("Seen in the terminal output", "Terminal çıktısında görüldü") }

    // MARK: Removing a worktree

    static var worktreeRemoveConfirmTitle: String { pick("Remove the worktree anyway?", "Worktree yine de kaldırılsın mı?") }
    static var worktreeRemoveConfirmButton: String { pick("Remove Anyway", "Yine de Kaldır") }

    static func worktreeRemoveConfirmBody(path: String, risks: WorktreeRemovalRisks) -> String {
        var lines = [pick("Removing \(path) deletes these for good:", "\(path) kaldırılırsa bunlar kalıcı olarak silinir:")]
        lines += worktreeRiskLines(risks)
        lines.append("")
        lines.append(worktreeCommitsFate(risks))
        return lines.joined(separator: "\n")
    }

    static func worktreeRiskLines(_ r: WorktreeRemovalRisks) -> [String] {
        var out: [String] = []
        if !r.uncommitted.isEmpty {
            let n = r.uncommitted.count
            out.append("\u{2022} " + pick(n == 1 ? "1 uncommitted change: " : "\(n) uncommitted changes: ",
                                           "Commit edilmemiş \(n) değişiklik: ") + pathSample(r.uncommitted))
        }
        if !r.ignored.isEmpty {
            let n = r.ignored.count
            out.append("\u{2022} " + pick(n == 1 ? "1 gitignored file: " : "\(n) gitignored files: ",
                                           "Git'in yok saydığı \(n) dosya: ") + pathSample(r.ignored))
        }
        for op in r.operations { out.append("\u{2022} " + operationInProgress(op)) }
        return out
    }

    static func pathSample(_ paths: [String], limit: Int = 5) -> String {
        let shown = paths.prefix(limit).joined(separator: ", ")
        guard paths.count > limit else { return shown }
        let more = paths.count - limit
        return shown + pick(", and \(more) more", " ve \(more) tane daha")
    }

    static func operationInProgress(_ op: GitOperation) -> String {
        switch op {
        case .rebase: return pick("An unfinished rebase", "Yarım kalmış bir rebase")
        case .merge: return pick("An unfinished merge", "Yarım kalmış bir merge")
        case .cherryPick: return pick("An unfinished cherry-pick", "Yarım kalmış bir cherry-pick")
        case .revert: return pick("An unfinished revert", "Yarım kalmış bir revert")
        case .bisect: return pick("A bisect in progress", "Süren bir bisect")
        }
    }

    /// What happens to commits: kept on their branch, or saved to a rescue branch when HEAD is detached.
    static func worktreeCommitsFate(_ r: WorktreeRemovalRisks) -> String {
        guard let branch = r.rescueBranch else {
            return pick("Committed work stays in the repository.", "Commit edilmiş işler depoda kalır.")
        }
        let n = r.unreachableCommits
        return pick(n == 1 ? "HEAD is detached: its 1 commit that is on no branch is saved to the new branch \(branch) first."
                           : "HEAD is detached: its \(n) commits that are on no branch are saved to the new branch \(branch) first.",
                    "HEAD ayrık: hiçbir dalda olmayan \(n) commit önce yeni \(branch) dalına kaydedilir.")
    }

    static var worktreeRescuedTitle: String { pick("Commits saved to a new branch", "Commit'ler yeni bir dala kaydedildi") }
    static func worktreeRescuedMessage(branch: String, count: Int) -> String {
        pick(count == 1 ? "The removed worktree had 1 commit on no branch (detached HEAD). It is kept on the branch \(branch)."
                        : "The removed worktree had \(count) commits on no branch (detached HEAD). They are kept on the branch \(branch).",
             "Kaldırılan worktree'de hiçbir dalda olmayan \(count) commit vardı (ayrık HEAD). \(branch) dalında duruyorlar.")
    }

    // MARK: Branch names

    static func describe(_ problem: BranchNameProblem) -> String {
        switch problem {
        case .empty: return pick("Enter a branch name.", "Bir dal adı yaz.")
        case .controlCharacter: return pick("Branch names can't contain control characters.", "Dal adında kontrol karakteri olamaz.")
        case .containsSpace: return pick("Branch names can't contain spaces.", "Dal adında boşluk olamaz.")
        case .invalidCharacter(let c): return pick("Branch names can't contain “\(c)”.", "Dal adında “\(c)” olamaz.")
        case .doubleDot: return pick("Branch names can't contain “..”.", "Dal adında “..” olamaz.")
        case .atBrace: return pick("Branch names can't contain “@{”.", "Dal adında “@{” olamaz.")
        case .isAt: return pick("“@” isn't a valid branch name.", "“@” geçerli bir dal adı değil.")
        case .leadingDash: return pick("Branch names can't start with “-”.", "Dal adı “-” ile başlayamaz.")
        case .slash: return pick("Branch names can't start or end with “/” or contain “//”.",
                                 "Dal adı “/” ile başlayıp bitemez, “//” içeremez.")
        case .trailingDot: return pick("Branch names can't end with “.”.", "Dal adı “.” ile bitemez.")
        case .componentStartsWithDot: return pick("No part of a branch name can start with “.”.",
                                                  "Dal adının hiçbir parçası “.” ile başlayamaz.")
        case .lockSuffix: return pick("No part of a branch name can end with “.lock”.",
                                      "Dal adının hiçbir parçası “.lock” ile bitemez.")
        case .reserved: return pick("“HEAD” can't be used as a branch name.", "“HEAD” dal adı olarak kullanılamaz.")
        }
    }

    // MARK: Errors

    static func describe(_ error: GitError) -> String {
        switch error {
        case .toolMissing("gh"):
            return pick("GitHub CLI (gh) isn't installed.", "GitHub CLI (gh) kurulu değil.")
        case .toolMissing(let tool):
            return pick("\(tool) isn't installed. Install the Xcode Command Line Tools.",
                        "\(tool) kurulu değil. Xcode Command Line Tools'u kur.")
        case .launchFailed(let command, let reason):
            return pick("Couldn't start \(command): \(reason)", "\(command) başlatılamadı: \(reason)")
        case .failed(let command, let status, let stderr):
            if stderr.isEmpty {
                return pick("\(command) exited with code \(status).", "\(command) \(status) koduyla çıktı.")
            }
            return pick("\(command) failed: \(stderr)", "\(command) başarısız oldu: \(stderr)")
        case .timedOut(let command):
            return pick("\(command) took too long and was stopped.", "\(command) çok uzun sürdü, durduruldu.")
        case .folderMissing(let path):
            return pick("The folder \(path) doesn't exist.", "\(path) klasörü yok.")
        case .notRepository(let path):
            return pick("\(path) isn't inside a Git repository.", "\(path) bir Git deposunda değil.")
        case .invalidBranch(let name, let problem):
            return pick("“\(name)” isn't a valid branch name. ", "“\(name)” geçerli bir dal adı değil. ") + describe(problem)
        case .invalidBaseRef(let ref):
            return pick("Couldn't find the base “\(ref)” in this repository.", "Bu depoda “\(ref)” tabanı bulunamadı.")
        case .branchInUse(let branch, let path):
            return pick("Branch \(branch) is already checked out at \(path).", "\(branch) dalı zaten \(path) konumunda açık.")
        case .worktreeDirty(let path, let risks):
            return worktreeRemoveConfirmBody(path: path, risks: risks)
        case .sessionNotFound:
            return inspectorSessionMissing
        case .noBranch:
            return describe(PullRequestInfo.Problem.noBranch)
        case .sameAsBase(let branch):
            return pick("\(branch) is the base branch itself.", "\(branch) zaten taban dal.")
        case .noPullRequestURL(let output):
            return pick("gh didn't return a pull request address.", "gh bir PR adresi döndürmedi.")
                + (output.isEmpty ? "" : " " + output)
        }
    }
}
