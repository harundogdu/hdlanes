import Foundation
import HDCore

/// User-facing strings, English and Turkish side by side. Each area keeps its strings in its own
/// extension file (`L10n+<Area>.swift`); views never hold literal UI text.
///
///     static var newSession: String { pick("New Session", "Yeni Oturum") }
enum L {
    /// Set from AppSettings.language at launch and when the setting changes.
    nonisolated(unsafe) static var language: AppLanguage = .system

    static var isTurkish: Bool {
        switch language {
        case .turkish: return true
        case .english: return false
        case .system: return Locale.preferredLanguages.first?.lowercased().hasPrefix("tr") ?? false
        }
    }

    static func pick(_ en: String, _ tr: String) -> String { isTurkish ? tr : en }

    // Shared, used by the app shell.
    static var appName: String { "hdlanes" }
    static var saveFailedTitle: String { pick("Couldn't save hdlanes state", "hdlanes durumu kaydedilemedi") }
    static func stateRecovered(_ backup: String) -> String {
        pick("The saved state could not be read. A copy was kept at \(backup); hdlanes started fresh.",
             "Kayıtlı durum okunamadı. Bir kopyası \(backup) konumunda saklandı; hdlanes boş başladı.")
    }
    static func stateUnreadable(path: String, backupFailed: Bool, error: String) -> String {
        backupFailed
            ? pick("The saved state at \(path) could not be read, and a copy of it could not be kept (\(error)). hdlanes started empty and won't save anything, so the file stays as it is. Free up space or fix the folder's permissions, then restart hdlanes.",
                   "\(path) konumundaki kayıtlı durum okunamadı ve bir kopyası saklanamadı (\(error)). hdlanes boş başladı ve hiçbir şey kaydetmeyecek; dosya olduğu gibi kalır. Yer açıp ya da klasörün izinlerini düzeltip hdlanes'i yeniden başlat.")
            : pick("The saved state at \(path) exists but could not be read (\(error)). hdlanes started empty and won't save anything, so the file stays as it is. Fix its permissions, then restart hdlanes.",
                   "\(path) konumundaki kayıtlı durum var ama okunamadı (\(error)). hdlanes boş başladı ve hiçbir şey kaydetmeyecek; dosya olduğu gibi kalır. İzinlerini düzeltip hdlanes'i yeniden başlat.")
    }
    static var ok: String { pick("OK", "Tamam") }
    static var cancel: String { pick("Cancel", "Vazgeç") }
    static var done: String { pick("Done", "Bitti") }
    static var remove: String { pick("Remove", "Kaldır") }
    static var save: String { pick("Save", "Kaydet") }
    static var add: String { pick("Add", "Ekle") }
    static var close: String { pick("Close", "Kapat") }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        // Timestamps a moment ahead of the view's clock would read "in 0 sec."
        if abs(now.timeIntervalSince(date)) < 10 { return pick("now", "şimdi") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: isTurkish ? "tr_TR" : "en_US")
        return f.localizedString(for: date, relativeTo: now)
    }

    static var locale: Locale { Locale(identifier: isTurkish ? "tr_TR" : "en_US") }
}
