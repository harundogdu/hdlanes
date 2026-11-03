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
        return pick("`\(cmd)` wasn't found on your PATH.", "`\(cmd)` PATH'te bulunamadı.")
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
