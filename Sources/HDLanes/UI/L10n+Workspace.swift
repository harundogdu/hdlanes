import Foundation
import HDCore

// OWNER: workspace area.
extension L {
    // MARK: Names

    static func providerName(_ p: Provider) -> String {
        switch p {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .shell: return pick("Shell", "Kabuk")
        }
    }

    static func categoryName(_ id: String) -> String {
        switch id {
        case "bug": return pick("Bug", "Hata")
        case "feature": return pick("Feature", "Özellik")
        case "refactor": return pick("Refactor", "Düzenleme")
        case "test": return pick("Test", "Test")
        case "docs": return pick("Docs", "Belge")
        case "ui": return pick("UI", "Arayüz")
        case "chore": return pick("Chore", "Bakım")
        case "research": return pick("Research", "Araştırma")
        case "review": return pick("Review", "İnceleme")
        default: return id
        }
    }

    static func taskStatusName(_ s: TaskStatus) -> String {
        switch s {
        case .backlog: return pick("Backlog", "Bekleyen")
        case .active: return pick("Active", "Sürüyor")
        case .review: return pick("Review", "İncelemede")
        case .done: return pick("Done", "Bitti")
        }
    }

    static func authMethodName(_ m: AuthMethod) -> String {
        switch m {
        case .browser: return pick("Browser login", "Tarayıcıyla giriş")
        case .token: return pick("Token", "Token")
        case .apiKey: return pick("API key", "API anahtarı")
        case .existing: return pick("Existing login", "Mevcut giriş")
        }
    }

    static func claudeAuthMethodName(_ raw: String?) -> String? {
        switch raw {
        case "claude.ai": return "claude.ai"
        case "oauth_token": return pick("Token", "Token")
        case "api_key_helper", "api_key": return pick("API key", "API anahtarı")
        case nil: return nil
        default: return raw
        }
    }

    static func codexAuthKindName(_ k: CodexLoginStatus.Kind) -> String {
        switch k {
        case .chatgpt: return "ChatGPT"
        case .apiKey: return pick("API key", "API anahtarı")
        case .accessToken: return pick("Access token", "Erişim token'ı")
        case .other: return pick("Logged in", "Giriş yapılmış")
        }
    }

    static func defaultSessionTitle(_ p: Provider, _ n: Int) -> String {
        switch p {
        case .claude: return pick("Claude \(n)", "Claude \(n)")
        case .codex: return pick("Codex \(n)", "Codex \(n)")
        case .shell: return pick("Shell \(n)", "Kabuk \(n)")
        }
    }

    static func defaultAccountLabel(_ p: Provider, _ n: Int) -> String { "\(providerName(p)) \(n)" }
    static var untitledTask: String { pick("Untitled task", "Adsız görev") }
    static var otherProjects: String { pick("Other", "Diğer") }

    // MARK: Errors

    static var createSessionFailed: String { pick("Couldn't start the session", "Oturum başlatılamadı") }
    static var removeWorktreeFailed: String { pick("Couldn't remove the worktree", "Worktree kaldırılamadı") }
    static var errProjectMissing: String { pick("The project no longer exists.", "Proje artık yok.") }
    static func errNoAccount(_ p: Provider) -> String {
        pick("There is no \(providerName(p)) account. Add one in Settings → Accounts.",
             "\(providerName(p)) hesabı yok. Ayarlar → Hesaplar'dan ekle.")
    }
    static var errSystemAccount: String {
        pick("This is your existing login; hdlanes doesn't remove it.",
             "Bu senin mevcut girişin; hdlanes onu kaldırmaz.")
    }
    static func errAccountInUse(_ n: Int) -> String {
        pick(n == 1 ? "1 open session uses this account. Close it first." : "\(n) open sessions use this account. Close them first.",
             "Bu hesabı \(n) açık oturum kullanıyor. Önce onları kapat.")
    }
    static var errNotManaged: String {
        pick("Only accounts added in hdlanes can store a token or key. For your existing login, sign in again with the browser.",
             "Token ya da anahtar yalnız hdlanes'ta eklenen hesaplara kaydedilir. Mevcut girişin için tarayıcıyla yeniden giriş yap.")
    }
    static var errEmptySecret: String { pick("Paste a value first.", "Önce bir değer yapıştır.") }
    static func cliMissing(_ p: Provider) -> String {
        let cmd = p == .codex ? "codex" : "claude"
        return pick("\(cmd) wasn't found on your PATH.", "\(cmd) PATH'te bulunamadı.")
    }
    static var errTimedOut: String { pick("The command didn't finish in time.", "Komut zamanında bitmedi.") }
    static var errAIDisabled: String {
        pick("AI categorization is off. Turn it on in Settings → Tasks.", "Yapay zekâyla kategori kapalı. Ayarlar → Görevler'den aç.")
    }
    static var errAIUnreadable: String {
        pick("The answer wasn't one of the categories.", "Gelen cevap kategorilerden biri değildi.")
    }
    static var errUnreadableStatus: String { pick("Couldn't read the login status.", "Giriş durumu okunamadı.") }
    static func errExitStatus(_ code: Int32) -> String { pick("The command failed (exit \(code)).", "Komut başarısız oldu (çıkış \(code)).") }
}

// MARK: Shared view strings
extension L {
    static func statusText(_ s: AgentStatus) -> String {
        switch s {
        case .notStarted: return pick("Not started", "Başlamadı")
        case .starting: return pick("Starting…", "Başlıyor…")
        case .ready: return pick("Ready", "Hazır")
        case .working: return pick("Working", "Çalışıyor")
        case .needsYou(let kind, _):
            switch kind {
            case .permission: return pick("Needs you · permission", "Seni bekliyor · izin")
            case .question: return pick("Needs you · question", "Seni bekliyor · soru")
            case .input: return pick("Needs you", "Seni bekliyor")
            case .auth: return pick("Needs you · login", "Seni bekliyor · giriş")
            }
        case .done: return pick("Done", "Bitti")
        case .error(let message): return message.isEmpty ? pick("Error", "Hata") : pick("Error: \(message)", "Hata: \(message)")
        case .exited(let code):
            if let code { return pick("Exited (\(code))", "Çıktı (\(code))") }
            return pick("Exited", "Çıktı")
        }
    }

    static var removedAccount: String { pick("Removed account", "Kaldırılmış hesap") }
    static func accountTooltip(_ a: Account) -> String {
        var parts = [a.label, authMethodName(a.authMethod)]
        if let email = a.email { parts.append(email) }
        if let plan = a.plan { parts.append(plan) }
        return parts.joined(separator: " · ")
    }
    static var addProjectMessage: String {
        pick("Choose a git repository or folder to work in.", "Çalışılacak bir git deposu ya da klasör seç.")
    }
}

// MARK: Window, sidebar, session
extension L {
    static var newSession: String { pick("New Session", "Yeni Oturum") }
    static var newSessionEllipsis: String { pick("New Session…", "Yeni Oturum…") }
    static var newSessionHelp: String { pick("New session (⌘N)", "Yeni oturum (⌘N)") }
    static func newSessionIn(_ project: String) -> String { pick("New session in \(project)", "\(project) içinde yeni oturum") }
    static var newTask: String { pick("New Task", "Yeni Görev") }
    static var newTaskEllipsis: String { pick("New Task…", "Yeni Görev…") }
    static var board: String { pick("Board", "Pano") }
    static var showBoard: String { pick("Show Board", "Panoyu Göster") }
    static var showBoardHelp: String { pick("Task board (⇧⌘B)", "Görev panosu (⇧⌘B)") }
    static var toggleInspector: String { pick("Toggle Inspector", "Denetçiyi Aç/Kapat") }
    static var toggleInspectorHelp: String { pick("Show or hide the inspector (⌥⌘I)", "Denetçiyi göster ya da gizle (⌥⌘I)") }
    static var sessionMenu: String { pick("Session", "Oturum") }
    static var nextNeedsYou: String { pick("Next Session Needing You", "Seni Bekleyen Sonraki Oturum") }
    static func selectSessionN(_ n: Int) -> String { pick("Select Session \(n)", "\(n). Oturumu Seç") }
    static var addProjectEllipsis: String { pick("Add Project…", "Proje Ekle…") }
    static var accounts: String { pick("Accounts", "Hesaplar") }
    static var dismiss: String { pick("Dismiss", "Kapat") }

    static var welcomeTitle: String { pick("Run agents side by side", "Ajanları yan yana çalıştır") }
    static var welcomeBody: String {
        pick("Each Claude Code or Codex session gets its own terminal, worktree and account.\nAdd a project to start.",
             "Her Claude Code ya da Codex oturumu kendi terminalini, worktree'sini ve hesabını alır.\nBaşlamak için bir proje ekle.")
    }
    static var noSessionSelected: String { pick("No session selected", "Seçili oturum yok") }
    static var noSessionSelectedBody: String {
        pick("Pick one in the sidebar or start a new one.", "Kenar çubuğundan birini seç ya da yenisini başlat.")
    }
    static var sessionMissing: String { pick("This session is gone", "Bu oturum artık yok") }

    static var filter: String { pick("Filter", "Süzgeç") }
    static func filterName(_ f: SidebarFilter) -> String {
        switch f {
        case .all: return pick("All", "Tümü")
        case .needsYou: return pick("Needs you", "Bekleyen")
        case .working: return pick("Working", "Çalışan")
        case .done: return pick("Done", "Biten")
        }
    }
    static func filterLabel(_ f: SidebarFilter, _ count: Int) -> String {
        count > 0 ? "\(filterName(f)) \(count)" : filterName(f)
    }
    static func filterEmpty(_ f: SidebarFilter) -> String {
        switch f {
        case .all: return pick("No sessions.", "Oturum yok.")
        case .needsYou: return pick("Nothing needs you.", "Seni bekleyen bir şey yok.")
        case .working: return pick("Nothing is running.", "Çalışan bir şey yok.")
        case .done: return pick("No finished sessions.", "Biten oturum yok.")
        }
    }
    static var showAll: String { pick("Show All", "Tümünü Göster") }
    static var groupBy: String { pick("Group By", "Grupla") }
    static var groupByProject: String { pick("Project", "Proje") }
    static var groupByCategory: String { pick("Category", "Kategori") }
    static func activeTasksHelp(_ n: Int) -> String {
        pick(n == 1 ? "1 active task" : "\(n) active tasks", "\(n) süren görev")
    }
    static var sidebarNoProjects: String {
        pick("No projects yet. Add a repository to start sessions in it.",
             "Henüz proje yok. Oturum başlatmak için bir depo ekle.")
    }

    static var projectSettingsEllipsis: String { pick("Project Settings…", "Proje Ayarları…") }
    static var revealInFinder: String { pick("Reveal in Finder", "Finder'da Göster") }
    static var removeProjectEllipsis: String { pick("Remove Project…", "Projeyi Kaldır…") }
    static func removeProjectTitle(_ name: String) -> String { pick("Remove “\(name)” from hdlanes?", "“\(name)” hdlanes'tan kaldırılsın mı?") }
    static func removeProjectMessage(_ sessions: Int) -> String {
        let en = sessions == 0 ? "" : (sessions == 1 ? "Its open session is closed and archived. " : "Its \(sessions) open sessions are closed and archived. ")
        let tr = sessions == 0 ? "" : "Açık \(sessions) oturumu kapatılıp arşivlenir. "
        return pick(en + "Files and worktrees on disk stay where they are.",
                    tr + "Diskteki dosyalar ve worktree'ler yerinde kalır.")
    }

    static var rename: String { pick("Rename", "Yeniden Adlandır") }
    static var renameEllipsis: String { pick("Rename…", "Yeniden Adlandır…") }
    static var renameSession: String { pick("Rename Session", "Oturumu Yeniden Adlandır") }
    static var renameHelp: String { pick("Double-click to rename", "Yeniden adlandırmak için çift tıkla") }
    static var sessionTitlePlaceholder: String { pick("Title", "Başlık") }
    static var stop: String { pick("Stop", "Durdur") }
    static var stopHelp: String { pick("Stop the process in this terminal", "Bu terminaldeki süreci durdur") }
    static var resume: String { pick("Resume", "Sürdür") }
    static var startShell: String { pick("Start Shell", "Kabuğu Başlat") }
    static var resumeHelp: String { pick("Continue the previous conversation", "Önceki konuşmayı sürdür") }
    static var startFreshHelp: String { pick("Start the agent again in this folder", "Ajanı bu klasörde yeniden başlat") }
    static var notRunning: String { pick("Not running", "Çalışmıyor") }
    static var closeEllipsis: String { pick("Close…", "Kapat…") }
    static var closeSession: String { pick("Close Session", "Oturumu Kapat") }
    static var closeAndRemoveWorktreeEllipsis: String { pick("Close and Remove Worktree…", "Kapat ve Worktree'yi Kaldır…") }
    static var closeAndRemoveWorktree: String { pick("Close and Remove Worktree", "Kapat ve Worktree'yi Kaldır") }
    static func closeSessionTitle(_ title: String) -> String { pick("Close “\(title)”?", "“\(title)” kapatılsın mı?") }
    static var closeSessionMessage: String {
        pick("The process in its terminal stops. The session is archived; its worktree and files stay.",
             "Terminalindeki süreç durur. Oturum arşivlenir; worktree'si ve dosyaları kalır.")
    }
    static func closeRemoveWorktreeMessage(_ path: String) -> String {
        pick("The worktree folder \(path) is removed. Uncommitted changes in it would be lost if forced, so hdlanes doesn't force: if git reports changes, nothing is deleted and the session stays.",
             "\(path) worktree klasörü kaldırılır. Zorlanırsa içindeki commit edilmemiş değişiklikler kaybolur; hdlanes zorlamaz: git değişiklik bildirirse hiçbir şey silinmez ve oturum kalır.")
    }
    static var copyBranchName: String { pick("Copy Branch Name", "Dal Adını Kopyala") }

    static func subagentLine(_ s: SubagentInfo) -> String {
        let activity = [s.currentTool, s.currentToolDetail].compactMap { $0?.nilIfBlank }.joined(separator: " ")
        let what = activity.nilIfBlank ?? s.description?.nilIfBlank
        return what.map { "\(s.type) · \($0)" } ?? s.type
    }
    static func moreSubagents(_ n: Int) -> String { pick("+\(n) more", "+\(n) daha") }
    static var allow: String { pick("Allow", "İzin Ver") }
    static var deny: String { pick("Deny", "Reddet") }
    static var denyEllipsis: String { pick("Deny…", "Reddet…") }
    static var denyMessageLabel: String { pick("Tell Claude why (optional)", "Claude'a nedenini yaz (isteğe bağlı)") }
    static var denyMessagePlaceholder: String { pick("e.g. use the test database instead", "ör. bunun yerine test veritabanını kullan") }

    // Usage
    static var usageHint: String { pick("Usage appears after the first reply.", "Kullanım ilk cevaptan sonra görünür.") }
    static var fiveHourShort: String { pick("5h", "5 sa") }
    static var weekShort: String { pick("Week", "Hafta") }
    static var noValue: String { "–" }
    static func percent(_ v: Double) -> String { isTurkish ? "%\(Int(v.rounded()))" : "\(Int(v.rounded()))%" }
    static func usageTooltip(account: Account, usage: AccountUsage?, now: Date) -> String {
        var lines = [account.label]
        if let u = usage {
            if let w = u.fiveHour { lines.append(windowLine(pick("5-hour", "5 saatlik"), w, now: now)) }
            if let w = u.week { lines.append(windowLine(pick("Week", "Haftalık"), w, now: now)) }
            if let plan = u.plan ?? account.plan { lines.append(pick("Plan: \(plan)", "Plan: \(plan)")) }
        }
        if let email = account.email { lines.append(email) }
        if let u = usage {
            lines.append(pick("Updated \(relative(u.updatedAt, now: now))", "Güncellendi: \(relative(u.updatedAt, now: now))"))
        } else {
            lines.append(pick("No usage yet", "Henüz kullanım yok"))
        }
        return lines.joined(separator: "\n")
    }
    private static func windowLine(_ name: String, _ w: UsageWindow, now: Date) -> String {
        let pct = percent(w.percent(at: now))
        guard let reset = w.resetsAt else { return "\(name): \(pct)" }
        if w.hasReset(at: now) { return pick("\(name): \(pct) · reset \(relative(reset, now: now))", "\(name): \(pct) · \(relative(reset, now: now)) sıfırlandı") }
        return pick("\(name): \(pct) · resets \(relative(reset, now: now))", "\(name): \(pct) · sıfırlanma \(relative(reset, now: now))")
    }
}

// MARK: Sheets: new session, tasks
extension L {
    static var project: String { pick("Project", "Proje") }
    static var chooseProject: String { pick("Choose…", "Seç…") }
    static var agent: String { pick("Agent", "Ajan") }
    static var account: String { pick("Account", "Hesap") }
    static func accountPickerLabel(_ a: Account) -> String {
        a.email.map { "\(a.label) — \($0)" } ?? a.label
    }
    static var titleLabel: String { pick("Title", "Başlık") }
    static var titlePlaceholder: String { pick("Optional, taken from the prompt", "İsteğe bağlı, istemden alınır") }
    static var firstPrompt: String { pick("First prompt", "İlk istem") }
    static var task: String { pick("Task", "Görev") }
    static var noTask: String { pick("None", "Yok") }
    static var useWorktree: String { pick("Work in a new worktree", "Yeni bir worktree'de çalış") }
    static var useWorktreeHelp: String {
        pick("Creates a branch and a separate folder so sessions don't touch each other's files.",
             "Bir dal ve ayrı bir klasör açar; oturumlar birbirinin dosyasına dokunmaz.")
    }
    static var notAGitRepo: String { pick("This folder isn't a git repository.", "Bu klasör bir git deposu değil.") }
    static var notAGitRepoFooter: String {
        pick("Not a git repository: the session runs in the project folder.", "Git deposu değil: oturum proje klasöründe çalışır.")
    }
    static var branch: String { pick("Branch", "Dal") }
    static var baseBranch: String { pick("Based on", "Kaynak dal") }
    static var currentHead: String { pick("Current HEAD", "Geçerli HEAD") }
    static var create: String { pick("Create", "Oluştur") }
    static var createHelp: String { pick("Create the session and start it", "Oturumu oluştur ve başlat") }
    static var createDisabledHelp: String { pick("Choose a project and an account first", "Önce bir proje ve hesap seç") }

    static func taskCount(_ n: Int) -> String { pick(n == 1 ? "1 task" : "\(n) tasks", "\(n) görev") }
    static var newTaskHelp: String { pick("New task (⌘T)", "Yeni görev (⌘T)") }
    static var noTasks: String { pick("No tasks yet", "Henüz görev yok") }
    static var noTasksBody: String {
        pick("Tasks group sessions by goal and move from backlog to done.",
             "Görevler oturumları amaca göre toplar ve bekleyenden bitene ilerler.")
    }
    static var dropTasksHere: String { pick("Drop tasks here", "Görevleri buraya bırak") }
    static var categorizedByAI: String { pick("Category suggested by AI", "Kategoriyi yapay zekâ önerdi") }
    static var categoryLabel: String { pick("Category", "Kategori") }
    static var openSession: String { pick("Open session", "Oturumu aç") }
    static var startSessionEllipsis: String { pick("Start Session…", "Oturum Başlat…") }
    static var editEllipsis: String { pick("Edit…", "Düzenle…") }
    static var suggestCategoryAI: String { pick("Suggest Category with AI", "Kategoriyi Yapay Zekâyla Öner") }
    static var moveTo: String { pick("Move To", "Taşı") }
    static var delete: String { pick("Delete", "Sil") }
    static var deleteEllipsis: String { pick("Delete…", "Sil…") }
    static func deleteTaskTitle(_ title: String) -> String { pick("Delete “\(title)”?", "“\(title)” silinsin mi?") }
    static func deleteTaskMessage(_ sessions: Int) -> String {
        sessions == 0 ? pick("This can't be undone.", "Bu geri alınamaz.")
            : pick("Its sessions stay; they just lose the link to this task.", "Oturumları kalır; yalnız bu görevle bağları kopar.")
    }
    static var aiCategorizeFailed: String { pick("Couldn't suggest a category", "Kategori önerilemedi") }
    static var notes: String { pick("Notes", "Notlar") }
    static var taskTitlePlaceholder: String { pick("What needs doing", "Yapılacak iş") }
    static var noProject: String { pick("None", "Yok") }
    static var suggestWithAI: String { pick("Suggest", "Öner") }
    static func suggestWithAIHelp(_ provider: AIProvider) -> String {
        switch provider {
        case .claude: return pick("Ask Claude for a category (one short claude -p call)", "Claude'dan kategori iste (kısa bir claude -p çağrısı)")
        case .jev: return pick("Ask Jev for a category (title and notes go to api.typesafe.ai)",
                               "Jev'den kategori iste (başlık ve notlar api.typesafe.ai'ye gider)")
        }
    }
    static var startSessionNow: String { pick("Start a session now", "Hemen bir oturum başlat") }
}

// MARK: Accounts
extension L {
    static func noAccounts(_ p: Provider) -> String { pick("No \(providerName(p)) accounts.", "\(providerName(p)) hesabı yok.") }
    static var accountsFooter: String {
        pick("Each account keeps its own login and history, so several can run at once.",
             "Her hesabın kendi girişi ve geçmişi var; birkaçı aynı anda çalışabilir.")
    }
    static var addAccount: String { pick("Add Account", "Hesap Ekle") }
    static var addAccountEllipsis: String { pick("Add Account…", "Hesap Ekle…") }
    static var accountLabel: String { pick("Label", "Ad") }
    static func accountDetailLine(_ a: Account) -> String {
        var parts = [authMethodName(a.authMethod)]
        if let email = a.email { parts.append(email) }
        if let plan = a.plan { parts.append(plan) }
        if let dir = a.configDir { parts.append((dir as NSString).abbreviatingWithTildeInPath) }
        else { parts.append(a.provider == .codex ? "~/.codex" : "~/.claude") }
        return parts.joined(separator: " · ")
    }
    static func systemAccountNote(_ p: Provider) -> String {
        let dir = p == .codex ? "~/.codex" : "~/.claude"
        return pick("Your existing \(dir) login, used as is. Signing in again here changes it for the terminal too.",
                    "Mevcut \(dir) girişin, olduğu gibi kullanılır. Burada yeniden giriş yaparsan terminalde de değişir.")
    }
    static var check: String { pick("Check", "Denetle") }
    static var checkHelp: String { pick("Ask the CLI whether this account is logged in", "Bu hesabın girişli olup olmadığını CLI'a sor") }
    static var checking: String { pick("Checking…", "Denetleniyor…") }
    static var loggedIn: String { pick("Logged in", "Giriş yapılmış") }
    static func loggedInVia(_ detail: String) -> String { pick("Logged in · \(detail)", "Giriş yapılmış · \(detail)") }
    static var notLoggedIn: String { pick("Not logged in", "Giriş yapılmamış") }
    static var notChecked: String { pick("Not checked yet", "Henüz denetlenmedi") }
    static var notInstalled: String { pick("CLI not found", "CLI bulunamadı") }
    static var logIn: String { pick("Log In…", "Giriş Yap…") }
    static var logInAgain: String { pick("Log In Again…", "Yeniden Giriş Yap…") }
    static var removeEllipsis: String { pick("Remove…", "Kaldır…") }
    static var removeAccountHelp: String { pick("Remove this account and move its folder to the Trash", "Bu hesabı kaldır, klasörünü Çöp'e taşı") }
    static func removeAccountTitle(_ label: String) -> String { pick("Remove “\(label)”?", "“\(label)” kaldırılsın mı?") }
    static func removeAccountMessage(_ dir: String) -> String {
        let shown = (dir as NSString).abbreviatingWithTildeInPath
        return pick("Its folder \(shown) goes to the Trash. It holds this account's login, transcripts and history.",
                    "\(shown) klasörü Çöp'e taşınır. Bu hesabın girişi, konuşma kayıtları ve geçmişi oradadır.")
    }
    static var moveToTrash: String { pick("Move to Trash", "Çöp'e Taşı") }
    static var changeColor: String { pick("Change color", "Rengi değiştir") }
    static func colorName(_ i: Int) -> String {
        let names: [(String, String)] = [("Indigo", "Çivit"), ("Teal", "Camgöbeği"), ("Amber", "Kehribar"), ("Rose", "Gül"),
                                         ("Green", "Yeşil"), ("Purple", "Mor"), ("Blue", "Mavi"), ("Orange", "Turuncu")]
        let n = names[((i % names.count) + names.count) % names.count]
        return pick(n.0, n.1)
    }
    static func usageSummary(_ u: AccountUsage) -> String {
        var parts: [String] = []
        let now = Date()
        if let w = u.fiveHour { parts.append(pick("5h \(percent(w.percent(at: now)))", "5 saat \(percent(w.percent(at: now)))")) }
        if let w = u.week { parts.append(pick("week \(percent(w.percent(at: now)))", "hafta \(percent(w.percent(at: now)))")) }
        parts.append(pick("updated \(relative(u.updatedAt))", "güncellendi \(relative(u.updatedAt))"))
        return parts.joined(separator: " · ")
    }

    static var provider: String { pick("Provider", "Sağlayıcı") }
    static var continueLabel: String { pick("Continue", "Devam") }
    static var addAccountFootnote: String {
        pick("hdlanes creates a separate folder for this account and runs the vendor's own login. It never sees your password.",
             "hdlanes bu hesap için ayrı bir klasör açar ve sağlayıcının kendi girişini çalıştırır. Parolanı hiç görmez.")
    }
    static func methodTitle(_ m: AuthMethod, _ p: Provider) -> String {
        switch m {
        case .browser: return pick("Browser login (email + password on the vendor's page)",
                                   "Tarayıcıyla giriş (sağlayıcının sayfasında e-posta + parola)")
        case .token: return p == .claude ? pick("Token", "Token") : pick("Access token", "Erişim token'ı")
        case .apiKey: return pick("API key", "API anahtarı")
        case .existing: return authMethodName(.existing)
        }
    }
    static func methodDetail(_ m: AuthMethod, _ p: Provider) -> String {
        switch (m, p) {
        case (.browser, _):
            return pick("Uses whichever account is signed in in your default browser. To pick another one, open the link in a private window or another browser profile.",
                        "Varsayılan tarayıcında o an açık olan hesabı kullanır. Başka bir hesap için bağlantıyı gizli pencerede ya da başka bir tarayıcı profilinde aç.")
        case (.token, .claude):
            return pick("Runs claude setup-token. Needs a Pro or Max plan; the token lasts a year.",
                        "claude setup-token çalıştırır. Pro ya da Max plan ister; token bir yıl geçerli.")
        case (.token, _):
            return pick("Paste a Codex access token.", "Bir Codex erişim token'ı yapıştır.")
        case (.apiKey, .claude):
            return pick("An Anthropic Console key. Usage is billed per token.", "Bir Anthropic Console anahtarı. Kullanım token başına ücretlenir.")
        case (.apiKey, _):
            return pick("An OpenAI API key. Usage is billed per token.", "Bir OpenAI API anahtarı. Kullanım token başına ücretlenir.")
        case (.existing, _):
            return ""
        }
    }

    static func loginTitle(_ a: Account) -> String { pick("Log in: \(a.label)", "Giriş: \(a.label)") }
    static func loginInstructions(account a: Account, method m: AuthMethod) -> String {
        if a.provider == .claude && m == .token {
            return pick("Approve in the browser. Claude then prints a long-lived token in the terminal below; paste it into the field and press Save. hdlanes stores it in this account's settings.json.",
                        "Tarayıcıda onayla. Claude aşağıdaki terminale uzun ömürlü bir token basar; onu alana yapıştırıp Kaydet'e bas. hdlanes onu bu hesabın settings.json dosyasına yazar.")
        }
        let site = a.provider == .codex ? "ChatGPT" : "claude.ai"
        return pick("Sign in on the page that opens in your browser. It uses whichever \(site) account is signed in there; for a different one, open the link in a private window or another browser profile. Press Done when the terminal says you're logged in.",
                    "Tarayıcıda açılan sayfada giriş yap. Orada açık olan \(site) hesabı kullanılır; başka bir hesap için bağlantıyı gizli pencerede ya da başka bir tarayıcı profilinde aç. Terminal girişin tamamlandığını söyleyince Bitti'ye bas.")
    }
    static var deviceCodeTitle: String { pick("Device code (sign in on any device)", "Cihaz kodu (herhangi bir cihazdan giriş)") }
    static var deviceCodeDetail: String {
        pick("Runs codex login --device-auth (beta): the terminal shows a link and a one-time code; enter the code in a browser on any device, signed in to the ChatGPT account you want. Nothing opens on this Mac.",
             "codex login --device-auth (beta) çalıştırır: terminal bir bağlantı ve tek kullanımlık kod gösterir; kodu herhangi bir cihazdaki tarayıcıda, istediğin ChatGPT hesabıyla giriş yapıp gir. Bu Mac'te hiçbir şey açılmaz.")
    }
    static var browserLoginHelp: String {
        pick("Runs codex login: signs in on the page that opens in this Mac's default browser.",
             "codex login çalıştırır: bu Mac'in varsayılan tarayıcısında açılan sayfada giriş yapılır.")
    }
    static var deviceCodeInstructions: String {
        pick("Open the link shown below in any browser, sign in to the ChatGPT account for this account and enter the code. If device code sign-in is off, turn it on in ChatGPT's security settings (personal account) or ask a workspace admin to allow it in the workspace permissions. Press Done when the terminal says you're logged in.",
             "Aşağıda görünen bağlantıyı herhangi bir tarayıcıda aç, bu hesabın ChatGPT hesabıyla giriş yap ve kodu gir. Cihaz koduyla giriş kapalıysa ChatGPT'nin güvenlik ayarlarından aç (kişisel hesap) ya da çalışma alanı yöneticisinden çalışma alanı izinlerinde açmasını iste. Terminal girişin tamamlandığını söyleyince Bitti'ye bas.")
    }
    static var useDeviceCode: String { pick("Use a Device Code", "Cihaz Kodu Kullan") }
    static var useBrowserLogin: String { pick("Use the Browser", "Tarayıcıyı Kullan") }
    static var pasteTokenPlaceholder: String { pick("Paste the token shown above", "Yukarıda görünen token'ı yapıştır") }
    static var saved: String { pick("Saved", "Kaydedildi") }
    static var runAgain: String { pick("Run Again", "Yeniden Çalıştır") }
    static var runAgainHelp: String { pick("Start the login command again", "Giriş komutunu yeniden başlat") }
    static func secretTitle(account a: Account, method m: AuthMethod) -> String {
        m == .apiKey ? pick("API key for \(a.label)", "\(a.label) için API anahtarı")
                     : pick("Access token for \(a.label)", "\(a.label) için erişim token'ı")
    }
    static func secretExplanation(provider p: Provider, method m: AuthMethod) -> String {
        switch (p, m) {
        case (.claude, _):
            return pick("Saved in this account's folder, readable only by you, and handed to Claude Code through apiKeyHelper. hdlanes doesn't keep a copy.",
                        "Bu hesabın klasörüne yalnız senin okuyabileceğin şekilde kaydedilir ve apiKeyHelper ile Claude Code'a verilir. hdlanes kopya tutmaz.")
        case (_, .apiKey):
            return pick("Passed to codex login --with-api-key on stdin; Codex stores it in this account's folder.",
                        "codex login --with-api-key komutuna stdin ile verilir; Codex onu bu hesabın klasöründe saklar.")
        default:
            return pick("Passed to codex login --with-access-token on stdin; Codex stores it in this account's folder.",
                        "codex login --with-access-token komutuna stdin ile verilir; Codex onu bu hesabın klasöründe saklar.")
        }
    }
    static func secretPlaceholder(_ m: AuthMethod) -> String {
        m == .apiKey ? pick("Paste the API key", "API anahtarını yapıştır") : pick("Paste the access token", "Erişim token'ını yapıştır")
    }
    static var later: String { pick("Later", "Sonra") }
    static var laterHelp: String {
        pick("Keep the account and add the key later from Accounts", "Hesabı tut, anahtarı sonra Hesaplar'dan ekle")
    }
}

// MARK: Settings
extension L {
    static var general: String { pick("General", "Genel") }
    static var tasksTab: String { pick("Tasks", "Görevler") }
    static var languageLabel: String { pick("Language", "Dil") }
    static var languageSystem: String { pick("System", "Sistem") }
    static var languageEnglish: String { "English" }
    static var languageTurkish: String { "Türkçe" }
    static var languageNote: String {
        pick("Windows switch right away; menus follow after a restart.", "Pencereler hemen değişir; menüler yeniden başlatınca değişir.")
    }
    static var notifications: String { pick("Notifications", "Bildirimler") }
    static var notifyNeedsYou: String { pick("When a session needs you", "Bir oturum seni beklediğinde") }
    static var notifyDone: String { pick("When a session finishes", "Bir oturum bittiğinde") }
    static var permissions: String { pick("Permissions", "İzinler") }
    static var permissionsInSidebar: String {
        pick("Answer Claude permission prompts in the sidebar", "Claude izin sorularını kenar çubuğunda cevapla")
    }
    static var permissionsInSidebarNote: String {
        pick("Shows Allow and Deny under the session; Claude's own prompt stays in the terminal too. Takes effect for new sessions.",
             "Oturumun altında İzin Ver ve Reddet gösterir; Claude'un kendi sorusu terminalde de durur. Yeni oturumlarda geçerli olur.")
    }
    static var terminal: String { pick("Terminal", "Terminal") }
    static func terminalFontSize(_ n: Int) -> String { pick("Font size: \(n) pt", "Yazı boyutu: \(n) pt") }
    static var categories: String { pick("Categories", "Kategoriler") }
    static var aiCategorization: String { pick("Suggest categories with AI", "Kategorileri yapay zekâyla öner") }
    static var aiAccount: String { pick("Claude account", "Claude hesabı") }
    static var noClaudeAccount: String { pick("No Claude account", "Claude hesabı yok") }
    static func aiCategorizationNote(_ label: String?) -> String {
        let who = label ?? pick("the chosen account", "seçili hesap")
        return pick("Runs claude -p with a small model on \(who) when you press Suggest, and uses that account's quota. Never runs on its own.",
                    "Öner'e bastığında \(who) üzerinde küçük bir modelle claude -p çalıştırır ve o hesabın kotasını kullanır. Kendiliğinden çalışmaz.")
    }
    static var rulesNote: String {
        pick("Without AI, categories come from keywords in the title and the branch name.",
             "Yapay zekâ olmadan kategori, başlıktaki ve dal adındaki anahtar kelimelerden gelir.")
    }

    // Project settings
    static var projectName: String { pick("Name", "Ad") }
    static var location: String { pick("Location", "Konum") }
    static var worktrees: String { pick("Worktrees", "Worktree'ler") }
    static var worktreeRoot: String { pick("Worktree folder", "Worktree klasörü") }
    static func worktreeRootDefault(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return "\(parent)/\(url.lastPathComponent)-worktrees"
    }
    static var worktreeRootMessage: String { pick("Choose where new worktrees go.", "Yeni worktree'lerin gideceği yeri seç.") }
    static var choose: String { pick("Choose", "Seç") }
    static var chooseEllipsis: String { pick("Choose…", "Seç…") }
    static var reset: String { pick("Reset", "Sıfırla") }
    static var setupCommand: String { pick("Setup command", "Kurulum komutu") }
    static var setupCommandPlaceholder: String { "npm ci" }
    static var copyFiles: String { pick("Copy into worktrees", "Worktree'lere kopyala") }
    static var worktreeFooter: String {
        pick("The setup command runs in each new worktree before the agent starts. Listed files (one per line, e.g. .env) are copied from the project.",
             "Kurulum komutu her yeni worktree'de ajandan önce çalışır. Listelenen dosyalar (satır başına bir tane, ör. .env) projeden kopyalanır.")
    }
    static var defaultAccounts: String { pick("Default accounts", "Varsayılan hesaplar") }
    static var firstAccount: String { pick("First account", "İlk hesap") }

    // Integration
    static var copyFilesFailedTitle: String { pick("Some files weren't copied into the worktree", "Bazı dosyalar worktree'ye kopyalanamadı") }

    // Agent exited in its shell
    static var agentExitedShellOpen: String { pick("The agent exited; its shell is still open", "Ajan çıktı; kabuğu hâlâ açık") }
    static var resumeShellBusyTitle: String { pick("Couldn't resume the agent", "Ajan sürdürülemedi") }
    static var resumeShellBusyBody: String {
        pick("Another program is running in this terminal. Quit it, then try again, or stop the session and resume it.",
             "Bu terminalde başka bir program çalışıyor. Onu kapatıp yeniden dene ya da oturumu durdurup sürdür.")
    }
}

// OWNER: workspace area. Settings › Terminal.
extension L {
    static var terminalSample: String { pick("~/git/hdlanes $ claude", "~/git/hdlanes $ claude") }
    static var terminalColors: String { pick("Colors", "Renkler") }
    static var terminalTheme: String { pick("Theme", "Tema") }
    static var importThemeEllipsis: String { pick("Import Theme…", "Tema İçe Aktar…") }
    static var showThemesFolder: String { pick("Themes Folder", "Temalar Klasörü") }
    static var importThemeNote: String {
        pick("Ghostty theme files and iTerm2 .itermcolors work. They are copied to ~/.hdlanes/themes; files you put there show up after Reload. Claude Code and Codex draw with these colors too.",
             "Ghostty tema dosyaları ve iTerm2 .itermcolors çalışır. ~/.hdlanes/themes klasörüne kopyalanır; oraya koyduğun dosyalar Yeniden Yükle'den sonra görünür. Claude Code ve Codex de bu renklerle çizer.")
    }
    static func themesRejected(_ names: [String]) -> String {
        pick("Not a theme: \(names.joined(separator: ", "))", "Tema değil: \(names.joined(separator: ", "))")
    }
    static var terminalFontSection: String { pick("Font", "Yazı Tipi") }
    static var terminalFontFamily: String { pick("Family", "Aile") }
    static var terminalSystemFont: String { pick("System (SF Mono)", "Sistem (SF Mono)") }
}

// OWNER: workspace area. Settings › Tasks: AI provider and TypeSafe Jev.
extension L {
    static var aiProviderLabel: String { pick("Model", "Model") }
    static var aiProviderClaude: String { pick("Claude account (claude -p)", "Claude hesabı (claude -p)") }
    static var aiProviderJev: String { pick("TypeSafe Jev (API key)", "TypeSafe Jev (API anahtarı)") }
    static var jevKeyLabel: String { pick("Jev API key", "Jev API anahtarı") }
    static var jevKeySaved: String { pick("Saved in the Keychain", "Keychain'de kayıtlı") }
    static var jevKeyPlaceholder: String { pick("Paste a key from console.typesafe.ai", "console.typesafe.ai'den aldığın anahtarı yapıştır") }
    static var jevRemoveKey: String { pick("Remove Key", "Anahtarı Sil") }
    static var jevNote: String {
        pick("Jev is a decision model: it picks one category from the task's title and notes, which are sent to api.typesafe.ai. It doesn't write text, so the end-of-day summary still uses a Claude account. Leave it off for work you can't send to a third party.",
             "Jev bir karar modeli: görevin başlığı ve notlarından bir kategori seçer; bunlar api.typesafe.ai'ye gönderilir. Metin yazmaz, bu yüzden gün sonu özeti yine Claude hesabıyla yapılır. Üçüncü tarafa gönderemeyeceğin işlerde kapalı tut.")
    }
    static var errAIUnsure: String {
        pick("The model wasn't sure; the category is unchanged.", "Model emin olamadı; kategori değişmedi.")
    }
    static var errJevKeyMissing: String {
        pick("Add a Jev API key in Settings › Tasks.", "Ayarlar › Görevler'de bir Jev API anahtarı ekle.")
    }
    static func jevHTTPError(_ status: Int, _ detail: String?) -> String {
        // No server text for auth failures: it is the one reply that could echo the key back.
        if status == 401 || status == 403 { return pick("Jev rejected the API key", "Jev API anahtarını reddetti") }
        let base = pick("Jev answered with HTTP \(status)", "Jev HTTP \(status) ile cevap verdi")
        return detail.map { "\(base): \($0)" } ?? base
    }
}
