import Foundation
import HDCore

// OWNER: runtime area.
extension L {
    // Claude plugin (shown in Claude Code's plugin list).
    static var pluginDescription: String {
        pick("Reports session status to hdlanes.", "Oturum durumunu hdlanes'e bildirir.")
    }

    // Startup problems
    static var hookMissingTitle: String { pick("Status tracking is off", "Durum takibi kapalı") }
    static var hookMissingBody: String {
        pick("hdlanes-hook wasn't found next to the app, so Claude sessions run without live status, permission cards or usage. Reinstall hdlanes to fix this.",
             "hdlanes-hook uygulamanın yanında bulunamadı; Claude oturumları canlı durum, izin kartı ve kullanım bilgisi olmadan çalışacak. Düzeltmek için hdlanes'i yeniden kur.")
    }
    static var pluginInstallFailedTitle: String { pick("Couldn't set up the Claude plugin", "Claude eklentisi kurulamadı") }
    static var hookServerFailedTitle: String { pick("Couldn't start status tracking", "Durum takibi başlatılamadı") }
    static func hookSocketPathTooLong(_ path: String) -> String {
        pick("The socket path is too long for macOS: \(path). Use a shorter HDLANES_HOME.",
             "Soket yolu macOS için fazla uzun: \(path). Daha kısa bir HDLANES_HOME kullan.")
    }
    static func hookSocketPathTaken(_ path: String) -> String {
        pick("\(path) exists and isn't a socket. hdlanes left it alone; move it away and restart.",
             "\(path) var ama soket değil. hdlanes ona dokunmadı; dosyayı taşıyıp yeniden başlat.")
    }

    // Launching
    static var launchFailedTitle: String { pick("Couldn't start the session", "Oturum başlatılamadı") }
    static var launchAccountMissing: String {
        pick("This session's account no longer exists. Pick another account for it.",
             "Bu oturumun hesabı artık yok. Oturum için başka bir hesap seç.")
    }
    static var launchAccountDirMissing: String {
        pick("This account has no folder set, so it can't be used. Remove it and add it again.",
             "Bu hesabın klasörü tanımlı değil, kullanılamaz. Hesabı kaldırıp yeniden ekle.")
    }
    static func launchFolderMissing(_ path: String) -> String {
        pick("The session's folder is gone: \(path)", "Oturumun klasörü yok: \(path)")
    }
    /// Printed in the terminal when the project's setup command fails (its exit code follows in
    /// parentheses); the agent starts anyway.
    static var setupCommandFailed: String {
        pick("hdlanes: the setup command failed, starting the agent anyway",
             "hdlanes: kurulum komutu başarısız oldu, ajan yine de başlatılıyor")
    }
    /// Printed in the login terminal when the vendor's login command ends.
    static var loginFinished: String {
        pick("hdlanes: login command finished. You can close this window.",
             "hdlanes: giriş komutu bitti. Bu pencereyi kapatabilirsin.")
    }

    // Agent errors (StopFailure codes)
    static func agentError(_ code: String) -> String {
        switch code {
        case "rate_limit": return pick("Usage limit reached", "Kullanım limiti doldu")
        case "authentication_failed": return pick("Signed out, log in again", "Oturum kapandı, yeniden giriş yap")
        case "overloaded": return pick("Service overloaded, try again", "Servis yoğun, tekrar dene")
        case "billing_error": return pick("Billing problem on this account", "Bu hesapta ödeme sorunu var")
        case "unknown", "error", "": return pick("Stopped with an error", "Bir hatayla durdu")
        default: return pick("Stopped with an error (\(code))", "Bir hatayla durdu (\(code))")
        }
    }

    // Notifications
    static func notifyNeedsYou(_ kind: NeedsYouKind) -> String {
        switch kind {
        case .permission: return pick("Wants permission", "İzin istiyor")
        case .question: return pick("Has a question", "Bir sorusu var")
        case .input: return pick("Waiting for you", "Seni bekliyor")
        case .auth: return pick("Needs you to log in again", "Yeniden giriş yapman gerekiyor")
        }
    }
    static var notifyDoneBody: String { pick("Finished", "Bitti") }
}
