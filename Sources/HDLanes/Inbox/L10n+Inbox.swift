import Foundation

// OWNER: inbox area.
extension L {
    static var inbox: String { pick("Inbox", "Gelen Kutusu") }
    static var inboxRefresh: String { pick("Refresh", "Yenile") }
    static var inboxRefreshHelp: String {
        pick("Reads your messages once through the chosen account's connectors (claude -p, uses its quota).",
             "Mesajlarını seçili hesabın bağlayıcılarıyla bir kez okur (claude -p, o hesabın kotasını kullanır).")
    }
    static var inboxSetUpEllipsis: String { pick("Set Up…", "Kur…") }
    static var inboxNotSetUp: String {
        pick("Pick a Claude account with mail or chat connectors and the tools it may use to read.",
             "Posta veya sohbet bağlayıcısı olan bir Claude hesabı ve okumak için kullanabileceği araçları seç.")
    }
    static var inboxEmpty: String { pick("Nothing needs you right now.", "Şu an seni bekleyen bir şey yok.") }
    static var inboxNotLoaded: String { pick("Refresh to look for messages that need you.", "Seni bekleyen mesajlar için Yenile'ye bas.") }
    static var inboxReading: String { pick("Reading messages…", "Mesajlar okunuyor…") }
    static func inboxUpdated(_ when: String) -> String { pick("Updated \(when)", "Güncellendi: \(when)") }
    static var inboxFailed: String { pick("Reading messages failed.", "Mesajlar okunamadı.") }
    static var inboxUnreadable: String { pick("The reply couldn't be read as messages.", "Cevap mesaj listesi olarak okunamadı.") }
    static var inboxNoTools: String {
        pick("This account has no MCP tools. Connect mail or chat in claude.ai (Settings › Connectors) or add an MCP server, then load again.",
             "Bu hesabın MCP aracı yok. claude.ai'de (Ayarlar › Bağlayıcılar) posta veya sohbet bağla ya da bir MCP sunucusu ekle, sonra yeniden yükle.")
    }
    static var inboxReply: String { pick("Reply", "Cevap") }
    static var inboxSendEllipsis: String { pick("Send…", "Gönder…") }
    static var inboxSendHelp: String { pick("Asks before sending", "Göndermeden önce sorar") }
    static var inboxNoSendTool: String { pick("Pick a send tool in Set Up to send from here", "Buradan göndermek için Kur'da bir gönderme aracı seç") }
    static var inboxOpen: String { pick("Open", "Aç") }
    static var inboxDismiss: String { pick("Dismiss", "Gizle") }
    static var inboxSending: String { pick("Sending…", "Gönderiliyor…") }
    static var inboxSendTimedOut: String {
        pick("No answer in time; the reply may have been sent. Check in the app before sending again.",
             "Zamanında cevap gelmedi; cevap gönderilmiş olabilir. Yeniden göndermeden önce uygulamada kontrol et.")
    }
    static var inboxSendFailed: String { pick("Sending failed.", "Gönderilemedi.") }
    static func inboxConfirmTitle(_ to: String) -> String { pick("Send this reply to \(to)?", "Bu cevap \(to) kişisine gönderilsin mi?") }
    static var inboxSend: String { pick("Send", "Gönder") }

    // Setup
    static var inboxSetupTitle: String { pick("Inbox Setup", "Gelen Kutusu Kurulumu") }
    static var inboxSetupNote: String {
        pick("hdlanes has no mail or chat login of its own. It asks Claude, on the account below, to read with its connectors (Microsoft 365, Gmail, Slack, … in claude.ai, or MCP servers). A refresh may use only the tools ticked as Read; a reply only the Send tool, after you confirm the text. Nothing runs on its own and messages are kept in memory only.",
             "hdlanes'in kendi posta veya sohbet girişi yok. Aşağıdaki hesapta Claude'dan bağlayıcılarıyla (claude.ai'deki Microsoft 365, Gmail, Slack… ya da MCP sunucuları) okumasını ister. Yenileme yalnızca Okuma olarak işaretlenen araçları, cevap ise metni onayladıktan sonra yalnızca Gönderme aracını kullanabilir. Hiçbir şey kendiliğinden çalışmaz ve mesajlar yalnızca bellekte tutulur.")
    }
    static var inboxAccountLabel: String { pick("Account", "Hesap") }
    static var inboxChooseAccount: String { pick("Choose…", "Seç…") }
    static var inboxLoadTools: String { pick("Load Tools", "Araçları Yükle") }
    static var inboxLoadToolsHelp: String {
        pick("Starts Claude on the account once to list its tools; no tool is used.",
             "Araçlarını listelemek için hesapta Claude'u bir kez başlatır; hiçbir araç kullanılmaz.")
    }
    static var inboxLoadingTools: String { pick("Loading tools…", "Araçlar yükleniyor…") }
    static func inboxServersUnavailable(_ names: [String]) -> String {
        pick("Not connected, so their tools are missing: \(names.joined(separator: ", ")). Sign in to them in a Claude session on this account (/mcp) or in claude.ai, then load again.",
             "Bağlı değil, bu yüzden araçları yok: \(names.joined(separator: ", ")). Bu hesaptaki bir Claude oturumunda (/mcp) ya da claude.ai'de giriş yap, sonra yeniden yükle.")
    }
    static var inboxRead: String { pick("Read", "Okuma") }
    static var inboxSendRole: String { pick("Send", "Gönderme") }
    static var inboxToolUnused: String { pick("Not used", "Kullanılmaz") }
    static var inboxToolSearch: String { pick("Find a tool", "Araç bul") }
    static var inboxToolSearchPrompt: String { pick("e.g. mail, search, teams", "ör. mail, search, teams") }
    static func inboxGroupSummary(total: Int, read: Int, send: Bool) -> String {
        var parts = [pick("\(total) tools", "\(total) araç")]
        if read > 0 { parts.append(pick("\(read) read", "\(read) okuma")) }
        if send { parts.append(pick("sends", "gönderme var")) }
        return parts.joined(separator: " · ")
    }
    static var inboxSelectReadTools: String { pick("Select readers", "Okuyanları seç") }
    static var inboxSelectReadToolsHelp: String {
        pick("Marks every tool here whose name says it only reads (search, list, get…) as Read.",
             "Buradaki, adına göre yalnız okuyan (search, list, get…) bütün araçları Okuma yapar.")
    }
    static var inboxClearTools: String { pick("Clear", "Temizle") }
    static func inboxChangeTools(_ n: Int) -> String { pick("Tools that change things (\(n))", "Değişiklik yapan araçlar (\(n))") }
    static var inboxChangeToolsHelp: String {
        pick("Delete, edit, create, move… Not needed to read the inbox.",
             "Silme, düzenleme, oluşturma, taşıma… Gelen kutusunu okumak için gerekmez.")
    }
    static var inboxFocusLabel: String { pick("What matters to you (optional)", "Senin için önemli olan (isteğe bağlı)") }
    static var inboxFocusPrompt: String {
        pick("e.g. review requests, questions from my team, my projects", "ör. review istekleri, ekibimden sorular, projelerim")
    }
    static var inboxHoursLabel: String { pick("Look back", "Geriye bak") }
    static func inboxHours(_ h: Int) -> String { pick("\(h) hours", "\(h) saat") }
}
