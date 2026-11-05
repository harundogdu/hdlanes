import Foundation
import Testing
@testable import HDCore

struct FilePreviewTests {
    private func temp(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func textBinaryImageMissing() throws {
        let md = try temp("a.md", Data("# Başlık\nmetin".utf8))
        #expect(FilePreview.load(md) == .text("# Başlık\nmetin", truncated: false))
        #expect(FilePreview.load(try temp("b.bin", Data([0x41, 0, 0x42]))) == .binary)
        #expect(FilePreview.load(try temp("c.png", Data([1, 2, 3]))) == .image)
        #expect(FilePreview.load(md.deletingLastPathComponent()) == .missing)
        #expect(FilePreview.load(md.appendingPathExtension("nope")) == .missing)
    }

    @Test func truncationKeepsWholeCharacters() throws {
        // "ş" is two bytes; a 3-byte cut splits the second one.
        let url = try temp("t.txt", Data("şşşş".utf8))
        #expect(FilePreview.load(url, maxBytes: 3) == .text("ş", truncated: true))
        #expect(FilePreview.load(url, maxBytes: 8) == .text("şşşş", truncated: false))
        #expect(FilePreview.text(from: Data([0xFF, 0xFE, 0x41]), truncated: false) == .binary)
    }

    @Test func credentialsAndRunnablesStayOut() throws {
        #expect(FilePreview.load(try temp("auth.json", Data("{}".utf8))) == .sensitive)
        #expect(FilePreview.isSensitive(URL(fileURLWithPath: "/Users/x/.ssh/config")))
        #expect(FilePreview.isSensitive(URL(fileURLWithPath: "/tmp/id_ed25519")))
        #expect(!FilePreview.isSensitive(URL(fileURLWithPath: "/tmp/id_ed25519.pub")))
        #expect(!FilePreview.isSensitive(URL(fileURLWithPath: "/tmp/README.md")))
        #expect(!FilePreview.isSensitive(URL(fileURLWithPath: "/repo/id_utils.py")))
        #expect(FilePreview.isSensitive(URL(fileURLWithPath: "/repo/.env.local")))
        #expect(FilePreview.isSensitive(URL(fileURLWithPath: "/Users/x/.kube/config")))
        let md = try temp("a.md", Data("x".utf8))
        #expect(FilePreview.isSafeToOpen(md))
        let sh = try temp("run.sh", Data("echo".utf8))
        #expect(!FilePreview.isSafeToOpen(sh))
        let plain = try temp("tool", Data("x".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plain.path)
        #expect(!FilePreview.isSafeToOpen(plain))
        #expect(!FilePreview.isSafeToOpen(md.deletingLastPathComponent()))
    }

    @Test func localWebURLs() {
        #expect(FilePreview.normalizedLocalWebURL(URL(string: "http://0.0.0.0:8080/a")!).absoluteString == "http://localhost:8080/a")
        #expect(FilePreview.isLocalWebURL(URL(string: "http://localhost:3000/x")!))
        #expect(FilePreview.isLocalWebURL(URL(string: "https://127.0.0.1")!))
        #expect(!FilePreview.isLocalWebURL(URL(string: "https://github.com")!))
        #expect(!FilePreview.isLocalWebURL(URL(string: "file:///tmp/a")!))
    }
}
