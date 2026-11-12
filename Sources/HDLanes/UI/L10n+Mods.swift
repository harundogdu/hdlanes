import Foundation
import HDCore

// OWNER: workspace area. Settings › Mods.
extension L {
    static var modsTab: String { pick("Mods", "Modlar") }
    static var modsAccount: String { pick("Account", "Hesap") }
    static var modsIntro: String {
        pick("Mods change Claude Code itself: panes, a band above the prompt, themes. They install into this account's own folder and load in its new sessions; in a running one, type /reload-plugins. Panes dock beside the chat in fullscreen mode (/tui fullscreen).",
             "Modlar Claude Code'un kendisini değiştirir: paneller, istemin üstünde bir şerit, temalar. Bu hesabın kendi klasörüne kurulur ve yeni oturumlarında yüklenir; çalışan bir oturumda /reload-plugins yaz. Paneller tam ekran modunda (/tui fullscreen) sohbetin yanına yerleşir.")
    }
    static var modsInstalled: String { pick("Installed", "Kurulu") }
    static var modsNoneInstalled: String { pick("No plugins in this account yet.", "Bu hesapta henüz eklenti yok.") }
    static var modsCatalog: String { pick("Catalog", "Katalog") }
    static var modsInstallByHand: String { pick("Install by Hand", "Elle Kur") }
    static var modsName: String { pick("Name", "Ad") }
    static var modsMarketplace: String { pick("Marketplace", "Marketplace") }
    static var modsInstall: String { pick("Install", "Kur") }
    static var modsInstalledBadge: String { pick("Installed", "Kurulu") }
    static var modsEnabled: String { pick("On", "Açık") }
    static var modsEnabledHelp: String { pick("Turn on or off for this account", "Bu hesap için aç ya da kapat") }
    static var modsRemove: String { pick("Uninstall from this account", "Bu hesaptan kaldır") }
    static var modsOpenPage: String { pick("Open the project page", "Proje sayfasını aç") }
    static var modsNoClaudeAccount: String { pick("Add a Claude account first; mods are a Claude Code feature.",
                                                  "Önce bir Claude hesabı ekle; modlar bir Claude Code özelliği.") }
    static var modsFooter: String {
        pick("A mod runs inside Claude Code with your permissions; it isn't sandboxed. L0 draws, L1 reads, L2 writes files or runs commands, L3 reaches the network — levels as graded by the awesome-claude-code-mods catalogue, not by Anthropic. Anthropic's samples are cloned into ~/.hdlanes/mods and load from there.",
             "Bir mod Claude Code içinde senin yetkilerinle çalışır; korumalı alanda değildir. L0 çizer, L1 okur, L2 dosya yazar ya da komut çalıştırır, L3 internete çıkar — seviyeler Anthropic'in değil, awesome-claude-code-mods kataloğunun derecelendirmesi. Anthropic'in örnekleri ~/.hdlanes/mods altına kopyalanır ve oradan yüklenir.")
    }
    static func modsConfirmTitle(_ name: String) -> String { pick("Install \(name)?", "\(name) kurulsun mu?") }
    static func modsConfirmBody(_ level: ModLevel?) -> String {
        let what: String
        switch level {
        case .network?: what = pick("It can reach the network.", "İnternete çıkabilir.")
        case .writes?: what = pick("It can write files, run commands or drive Claude.", "Dosya yazabilir, komut çalıştırabilir ya da Claude'u yönlendirebilir.")
        default: what = pick("Its level isn't known.", "Seviyesi bilinmiyor.")
        }
        return what + " " + pick("It runs inside Claude Code with your permissions in every session of this account. Install only mods you trust.",
                                 "Bu hesabın her oturumunda Claude Code içinde senin yetkilerinle çalışır. Yalnız güvendiğin modları kur.")
    }
    static var modsCommandTitle: String { pick("The marketplace runs a command", "Marketplace bir komut çalıştırıyor") }
    static func modsCommandBody(_ command: String) -> String {
        pick("Installing runs this command on your Mac:\n\n\(command)\n\nInstall only if you trust it.",
             "Kurulum Mac'inde şu komutu çalıştırır:\n\n\(command)\n\nYalnız güveniyorsan kur.")
    }
    static var modsGitMissing: String { pick("git isn't installed.", "git kurulu değil.") }
    static var modsCloneFailed: String { pick("Couldn't download Anthropic's sample mods.", "Anthropic'in örnek modları indirilemedi.") }
    static var modsListFailed: String { pick("Couldn't list this account's plugins.", "Bu hesabın eklentileri listelenemedi.") }
    static var modsTimedOut: String { pick("Claude Code didn't answer in time.", "Claude Code zamanında yanıt vermedi.") }
    static var modsCommandFailed: String { pick("The command failed.", "Komut başarısız oldu.") }

    static func modLevelHelp(_ level: ModLevel?) -> String {
        switch level {
        case .draws?: return pick("L0: only draws", "L0: yalnız çizer")
        case .reads?: return pick("L1: reads", "L1: okur")
        case .writes?: return pick("L2: writes or runs", "L2: yazar, çalıştırır")
        case .network?: return pick("L3: reaches the network", "L3: internete çıkar")
        case nil: return pick("Built into Claude Code; not graded", "Claude Code'a yerleşik; derecelendirilmemiş")
        }
    }

    static func modDisplayName(_ name: String) -> String {
        switch name {
        case "cc-plugin-you-should-know": return "You Should Know"
        case "token-weather": return "Token Weather"
        case "replay-theater": return "Replay Theater"
        case "blast-radius": return "Blast Radius"
        case "flightdeck": return "Flightdeck"
        case "filetree": return "Filetree"
        case "cache-tax": return "Cache Tax"
        case "savvy-progress": return "Savvy Progress"
        case "prismantis": return "Prismantis"
        case "reflect-mod": return "Reflect"
        case "recap": return "recap-tr"
        case "skins": return "Claude Skins"
        case "terminal-browser": return "Terminal Browser"
        default: return name
        }
    }

    static func modSummary(_ name: String) -> String {
        switch name {
        case "cc-plugin-you-should-know":
            return pick("A side agent posts \"Heads up\" notes above the prompt. Built in; its checks use this account's quota.",
                        "Yan bir ajan istemin üstüne \"Dikkat\" notları düşer. Yerleşik; kontrolleri bu hesabın kotasını kullanır.")
        case "token-weather":
            return pick("A live forecast of the context window above the prompt. Anthropic sample.",
                        "İstemin üstünde bağlam penceresinin canlı hava durumu. Anthropic örneği.")
        case "replay-theater":
            return pick("/replay steps through the last turn's file edits, one diff at a time. Anthropic sample.",
                        "/replay son turdaki dosya düzenlemelerini tek tek diff olarak oynatır. Anthropic örneği.")
        case "blast-radius":
            return pick("Holds risky shell commands and shows what they would change, with Proceed and Cancel. Anthropic sample.",
                        "Riskli kabuk komutlarını durdurur, neyi değiştireceklerini gösterir; Devam ya da İptal. Anthropic örneği.")
        case "flightdeck":
            return pick("A pane with agents, cost and pending permissions.", "Ajanlar, maliyet ve bekleyen izinler için bir panel.")
        case "filetree":
            return pick("A file tree pane with git status and the files Claude reads and edits.",
                        "Git durumu ve Claude'un okuyup düzenlediği dosyalarla bir dosya ağacı paneli.")
        case "cache-tax":
            return pick("Keeps the prompt cache warm and shows its cost in a band above the prompt.",
                        "İstem önbelleğini sıcak tutar, maliyetini istemin üstünde bir şeritte gösterir.")
        case "savvy-progress":
            return pick("A progress pane and band for the current task.", "Mevcut iş için ilerleme paneli ve şeridi.")
        case "prismantis":
            return pick("Themed tables, charts and code blocks in the transcript.", "Sohbette temalı tablolar, grafikler ve kod blokları.")
        case "reflect-mod":
            return pick("Captures your corrections and syncs them into CLAUDE.md.", "Düzeltmelerini yakalar ve CLAUDE.md'ye işler.")
        case "recap":
            return pick("A short spoken Turkish recap of what Claude did, with a local voice.",
                        "Claude'un yaptıklarının kısa, sesli Türkçe özeti; yerel ses kullanır.")
        case "skins":
            return pick("Restyles tool rows and messages; 15 themes.", "Araç satırlarını ve mesajları yeniden biçimlendirir; 15 tema.")
        case "terminal-browser":
            return pick("A web browser in a pane. Needs an extra app and kitty graphics.",
                        "Bir panelde web tarayıcısı. Ek bir uygulama ve kitty grafikleri ister.")
        default:
            return ""
        }
    }
}
