import Foundation
import UniformTypeIdentifiers

/// What the File tab can show for a path clicked in the terminal.
public enum FilePreview {
    public enum Content: Equatable, Sendable {
        case text(String, truncated: Bool)
        case image
        case binary
        case missing
        case unreadable
    }

    public static let maxTextBytes = 2_000_000

    public static func load(_ url: URL, maxBytes: Int = maxTextBytes) -> Content {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return .missing
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) { return .image }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1) ?? Data() else { return .unreadable }
        let truncated = data.count > maxBytes
        return text(from: truncated ? data.prefix(maxBytes) : data, truncated: truncated)
    }

    /// UTF-8 text, or `.binary` when the bytes have a NUL or don't decode. A cut at `maxBytes` may split a
    /// character, so up to three trailing bytes are dropped before giving up.
    public static func text(from data: Data, truncated: Bool) -> Content {
        if data.prefix(8192).contains(0) { return .binary }
        for drop in 0...(truncated ? 3 : 0) where drop < max(data.count, 1) {
            if let s = String(data: data.dropLast(drop), encoding: .utf8) { return .text(s, truncated: truncated) }
        }
        return .binary
    }

    /// Hosts the Browser tab opens instead of the default browser.
    public static func isLocalWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(host)
    }
}
