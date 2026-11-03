import Foundation
import HDCore

// OWNER: workspace area. Strings of the import sheet and its entry points.
extension L {
    // MARK: Entry points

    static var importEllipsis: String { pick("Import…", "İçe Aktar…") }
    static var importTitle: String { pick("Import", "İçe Aktar") }
    static var importExistingAccountEllipsis: String { pick("Import Existing Account…", "Mevcut Hesabı İçe Aktar…") }
    static var importPastSessionsEllipsis: String { pick("Import Past Sessions…", "Geçmiş Oturumları İçe Aktar…") }
    static var importHelp: String {
        pick("Bring in account folders and past Claude and Codex sessions you already have",
             "Zaten sahip olduğun hesap klasörlerini ve geçmiş Claude ve Codex oturumlarını getir")
    }

    static func importTabName(_ tab: ImportTab) -> String {
        switch tab {
        case .accounts: return pick("Accounts", "Hesaplar")
        case .sessions: return pick("Sessions", "Oturumlar")
        }
    }

    // MARK: Accounts tab

    static var scanningAccounts: String { pick("Looking for account folders…", "Hesap klasörleri aranıyor…") }
    static var noAccountCandidates: String {
        pick("No other Claude or Codex account folders found.", "Başka Claude veya Codex hesap klasörü bulunamadı.")
    }
    static var chooseFolderEllipsis: String { pick("Choose Folder…", "Klasör Seç…") }
    static var chooseAccountFolderMessage: String {
        pick("Choose a Claude config folder (CLAUDE_CONFIG_DIR) or a Codex home (CODEX_HOME).",
             "Bir Claude yapılandırma klasörü (CLAUDE_CONFIG_DIR) ya da Codex ana klasörü (CODEX_HOME) seç.")
    }
    static func addCount(_ n: Int) -> String { pick("Add (\(n))", "Ekle (\(n))") }
    static var hasHistory: String { pick("has history", "geçmişi var") }
    static var hasHistoryHelp: String {
        pick("Past conversations are in this folder; import them on the Sessions tab after adding it.",
             "Bu klasörde geçmiş konuşmalar var; ekledikten sonra Oturumlar sekmesinden içe aktarabilirsin.")
    }
    static func whichProvider(_ path: String) -> String {
        pick("Which account is \(path)?", "\(path) hangi hesabın klasörü?")
    }
    static func importedAccountLabel(_ p: Provider, _ suffix: String) -> String { "\(providerName(p)) \(suffix)" }
    static func accountsAdded(_ n: Int) -> String {
        pick(n == 1 ? "1 account added." : "\(n) accounts added.", "\(n) hesap eklendi.")
    }
    static var goToSessions: String { pick("Import Their Sessions", "Oturumlarını İçe Aktar") }
    static var importAccountsFootnote: String {
        pick("An imported account keeps its folder and its login; nothing is copied or moved and you don't sign in again.",
             "İçe aktarılan hesap klasörünü ve girişini korur; hiçbir şey kopyalanmaz ya da taşınmaz, yeniden giriş yapmazsın.")
    }
    static var desktopAppNote: String {
        pick("The Claude desktop app keeps its own login, which can't be imported. To use that account here, add it with Add Account… and sign in in the browser.",
             "Claude masaüstü uygulamasının girişi kendine ait ve içe aktarılamaz. O hesabı burada kullanmak için Hesap Ekle… ile ekleyip tarayıcıdan giriş yap.")
    }

    static func importSourceName(_ s: AccountCandidate.Source) -> String {
        switch s {
        case .vscodeSettings(let app):
            switch app {
            case "Code": return "VS Code"
            case "Code - Insiders": return "VS Code Insiders"
            default: return app
            }
        case .shellProfile(let file): return file
        case .homeFolder: return pick("Home folder", "Ana klasör")
        case .chosenFolder: return pick("Chosen", "Seçildi")
        }
    }

    static func importSourceHelp(_ s: AccountCandidate.Source) -> String {
        switch s {
        case .vscodeSettings: return pick("Set in \(importSourceName(s)) settings", "\(importSourceName(s)) ayarlarında tanımlı")
        case .shellProfile(let file): return pick("Named in ~/\(file)", "~/\(file) içinde geçiyor")
        case .homeFolder: return pick("Found in your home folder", "Ana klasöründe bulundu")
        case .chosenFolder: return pick("You chose this folder", "Bu klasörü sen seçtin")
        }
    }

    static func folderExclusion(_ reason: ImportScanner.Exclusion) -> String {
        switch reason {
        case .missing: return pick("That folder doesn't exist.", "Bu klasör yok.")
        case .systemDefault:
            return pick("That's your default login; hdlanes already uses it.", "Bu varsayılan girişin; hdlanes onu zaten kullanıyor.")
        case .managedByHDLanes: return pick("hdlanes already manages that folder.", "Bu klasörü hdlanes zaten yönetiyor.")
        case .alreadyAdded: return pick("That folder is already an account.", "Bu klasör zaten bir hesap.")
        }
    }

    // MARK: Sessions tab

    static func lastNDays(_ n: Int) -> String { pick("Last \(n) days", "Son \(n) gün") }
    static var timeWindow: String { pick("Time window", "Zaman aralığı") }
    static var allAccounts: String { pick("All accounts", "Tüm hesaplar") }
    static var accountFilter: String { pick("Account", "Hesap") }
    static var searchSessionsPrompt: String { pick("Search title or folder", "Başlık veya klasör ara") }
    static var includeHeadless: String { pick("Also show headless (-p) runs", "Başsız (-p) çalıştırmaları da göster") }
    static var includeHeadlessHelp: String {
        pick("Runs started by scripts and tools with claude -p or codex exec. Hidden by default.",
             "Betiklerin ve araçların claude -p ya da codex exec ile başlattığı çalıştırmalar. Varsayılan olarak gizli.")
    }
    static var scanningSessions: String { pick("Reading past sessions…", "Geçmiş oturumlar okunuyor…") }
    static func noSessions(_ days: Int) -> String {
        pick("No Claude or Codex sessions in the last \(days) days.", "Son \(days) günde Claude veya Codex oturumu yok.")
    }
    static var showLast90Days: String { pick("Show Last 90 Days", "Son 90 Günü Göster") }
    static var importAnAccount: String { pick("Import an Account…", "Hesap İçe Aktar…") }
    static var noSessionMatches: String { pick("No sessions match the filters.", "Filtrelerle eşleşen oturum yok.") }
    static var clearFilters: String { pick("Clear Filters", "Filtreleri Temizle") }
    static var selectAll: String { pick("Select all", "Tümünü seç") }
    static func importCount(_ n: Int) -> String { pick("Import (\(n))", "İçe Aktar (\(n))") }
    static var importSessionsHelp: String {
        pick("Imported sessions appear in the sidebar, not running. Resume continues each conversation with its own account.",
             "İçe aktarılan oturumlar kenar çubuğunda çalışmıyor olarak görünür. Sürdür, her konuşmaya kendi hesabıyla devam eder.")
    }
    static var alreadyImported: String { pick("Added", "Eklendi") }
    static var alreadyImportedHelp: String { pick("Already in the sidebar", "Kenar çubuğunda zaten var") }
    static var closedEarlier: String { pick("Closed", "Kapatılmış") }
    static var closedEarlierHelp: String {
        pick("You closed this session in hdlanes; importing it brings it back.",
             "Bu oturumu hdlanes'te kapatmıştın; içe aktarınca geri gelir.")
    }
    static func hiddenMissingFolders(_ n: Int) -> String {
        pick(n == 1 ? "1 hidden: folder gone" : "\(n) hidden: folder gone", "\(n) gizli: klasörü yok")
    }
    static var hiddenMissingFoldersHelp: String {
        pick("These sessions ran in folders that no longer exist (usually removed worktrees), so they can't be resumed in place.",
             "Bu oturumlar artık olmayan klasörlerde çalıştı (çoğunlukla silinmiş worktree'ler); olduğu yerde sürdürülemezler.")
    }

    static func originName(_ o: SessionOrigin) -> String {
        switch o {
        case .desktop: return pick("Desktop", "Masaüstü")
        case .vscode: return "VS Code"
        case .terminal: return "Terminal"
        case .headless: return pick("Headless", "Başsız")
        case .other: return pick("Other", "Diğer")
        }
    }

    static func originHelp(_ o: SessionOrigin, raw: String?) -> String {
        let base: String
        switch o {
        case .desktop: base = pick("Started in a desktop app", "Bir masaüstü uygulamasında başlatıldı")
        case .vscode: base = pick("Started in a VS Code-family editor", "VS Code ailesinden bir düzenleyicide başlatıldı")
        case .terminal: base = pick("Started in a terminal", "Bir terminalde başlatıldı")
        case .headless: base = pick("A non-interactive run", "Etkileşimsiz bir çalıştırma")
        case .other: base = pick("Started elsewhere", "Başka bir yerde başlatıldı")
        }
        return raw.map { "\(base) (\($0))" } ?? base
    }

    // MARK: Removing an imported account

    static var forgetAccountHelp: String {
        pick("Remove this account from hdlanes; its folder stays where it is",
             "Bu hesabı hdlanes'ten kaldır; klasörü olduğu yerde kalır")
    }
    static func forgetAccountMessage(_ dir: String) -> String {
        let shown = (dir as NSString).abbreviatingWithTildeInPath
        return pick("hdlanes forgets this account. Its folder \(shown) stays where it is, with its login and history.",
                    "hdlanes bu hesabı unutur. \(shown) klasörü girişi ve geçmişiyle olduğu yerde kalır.")
    }
}
