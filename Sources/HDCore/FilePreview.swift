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
        /// Credential files (auth.json, SSH keys, …): never read into the app.
        case sensitive
    }

    public static let maxTextBytes = 2_000_000

    public static func load(_ url: URL, maxBytes: Int = maxTextBytes) -> Content {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return .missing
        }
        if isSensitive(url) { return .sensitive }
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

    /// Agent and SSH credential files the File tab refuses to show.
    public static func isSensitive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if ["auth.json", ".credentials.json", "credentials.json", ".netrc", ".env"].contains(name) { return true }
        if ["pem", "key", "p12", "pfx"].contains(url.pathExtension.lowercased()) { return true }
        if name.hasPrefix("id_") && !name.hasSuffix(".pub") { return true }
        return url.pathComponents.contains(".ssh") && !name.hasSuffix(".pub")
    }

    /// Re-checks a file before handing it to Launch Services later (it may have changed since the click):
    /// a regular file that isn't executable, a script or an app.
    public static func isSafeToOpen(_ url: URL) -> Bool {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let v = try? canonical.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey, .contentTypeKey]),
              v.isRegularFile == true, v.isExecutable != true else { return false }
        if let type = v.contentType ?? UTType(filenameExtension: canonical.pathExtension),
           [UTType.script, .executable, .application, .applicationBundle, .shellScript].contains(where: { type.conforms(to: $0) }) {
            return false
        }
        return true
    }

    /// `0.0.0.0` is where servers listen, not an address to browse; the Browser tab uses localhost.
    public static func normalizedLocalWebURL(_ url: URL) -> URL {
        guard url.host == "0.0.0.0" else { return url }
        return URL(string: url.absoluteString.replacingOccurrences(of: "://0.0.0.0", with: "://localhost")) ?? url
    }

    /// Hosts the Browser tab opens instead of the default browser.
    public static func isLocalWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(host)
    }
}
