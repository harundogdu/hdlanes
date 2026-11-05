import Foundation

// OWNER: git area (inspector File tab).
extension L {
    static var tabFile: String { pick("File", "Dosya") }
    static var fileEmptyTitle: String { pick("No file open", "Açık dosya yok") }
    static var fileEmptyDetail: String {
        pick("Click a file path in the terminal to read it here.", "Okumak için terminaldeki bir dosya yoluna tıkla.")
    }
    static func openIn(_ app: String) -> String { pick("Open in \(app)", "\(app) ile Aç") }
    static var openWithDefault: String { pick("Open", "Aç") }
    static var copyPath: String { pick("Copy Path", "Yolu Kopyala") }
    static var closeFile: String { pick("Close", "Kapat") }
    static var fileMissing: String { pick("The file no longer exists.", "Dosya artık yok.") }
    static var fileUnreadable: String { pick("The file can't be read.", "Dosya okunamıyor.") }
    static var fileSensitive: String {
        pick("Looks like a credential file; hdlanes doesn't show it.", "Kimlik bilgisi dosyası gibi görünüyor; hdlanes bunu göstermez.")
    }
    static var fileBinary: String { pick("Not a text file.", "Metin dosyası değil.") }
    static func fileTruncated(_ mb: Int) -> String {
        pick("Showing the first \(mb) MB.", "İlk \(mb) MB gösteriliyor.")
    }
}
