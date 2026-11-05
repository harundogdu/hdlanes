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

    @Test func localWebURLs() {
        #expect(FilePreview.isLocalWebURL(URL(string: "http://localhost:3000/x")!))
        #expect(FilePreview.isLocalWebURL(URL(string: "https://127.0.0.1")!))
        #expect(!FilePreview.isLocalWebURL(URL(string: "https://github.com")!))
        #expect(!FilePreview.isLocalWebURL(URL(string: "file:///tmp/a")!))
    }
}
