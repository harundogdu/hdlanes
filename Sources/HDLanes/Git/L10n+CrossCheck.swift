import Foundation

// OWNER: git area. Strings of "Check with another account".
extension L {
    static var crossCheckButton: String { pick("Check with…", "Kontrol ettir…") }
    static var crossCheckHelp: String {
        pick("Another Claude account reads this diff once (claude -p, no tools, uses that account's quota) and adds its findings as notes you can edit and send.",
             "Başka bir Claude hesabı bu diff'i bir kez okur (claude -p, araçsız, o hesabın kotasını kullanır) ve bulduklarını düzenleyip gönderebileceğin notlar olarak ekler.")
    }
    static var crossCheckNoAccount: String {
        pick("Add a Claude account to check with", "Kontrol için bir Claude hesabı ekle")
    }
    static func crossCheckWith(_ label: String, own: Bool) -> String {
        own ? pick("\(label) (this session's account)", "\(label) (bu oturumun hesabı)") : label
    }
    static func crossCheckRunning(_ label: String) -> String {
        pick("\(label) is checking…", "\(label) kontrol ediyor…")
    }
    static func crossCheckDone(_ label: String, _ n: Int) -> String {
        n == 0 ? pick("\(label) found nothing to flag.", "\(label) işaretlenecek bir şey bulmadı.")
               : pick("\(label) added \(n) \(n == 1 ? "note" : "notes").", "\(label) \(n) not ekledi.")
    }
    static var crossCheckNoChanges: String { pick("No changes to check.", "Kontrol edilecek değişiklik yok.") }
    static var crossCheckFailed: String { pick("The check failed.", "Kontrol başarısız oldu.") }
    static var crossCheckUnreadable: String {
        pick("The reply couldn't be read as findings.", "Cevap bulgu olarak okunamadı.")
    }
}
