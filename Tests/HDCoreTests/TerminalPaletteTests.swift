import Foundation
import Testing
@testable import HDCore

struct TerminalPaletteTests {
    @Test func builtInsAreComplete() {
        #expect(Set(TerminalPalette.builtIn.map(\.id)).count == TerminalPalette.builtIn.count)
        for p in TerminalPalette.builtIn {
            #expect(p.ansi.count == 16)
            #expect(p.isDark)
        }
        #expect(TerminalPalette.builtIn.first?.id == TerminalPalette.defaultID)
        #expect(RGB(hex: "#ff0000") == RGB(1, 0, 0))
        #expect(RGB(hex: "zz0000") == nil)
        #expect(RGB(hex: "fff") == nil)
    }

    @Test func ghosttyTheme() throws {
        let text = """
        # Dracula-ish
        background = #282a36
        foreground = f8f8f2
        cursor-color = #ffffff
        palette = 1=#ff5555
        palette = 15 = #fefefe
        palette = 99=#000000
        font-family = JetBrains Mono
        """
        let p = try #require(TerminalPalette.parseGhostty(text, id: "file:x", name: "x"))
        #expect(p.background == RGB(hex: "282a36"))
        #expect(p.cursor == RGB(1, 1, 1))
        #expect(p.ansi[1] == RGB(hex: "ff5555"))
        #expect(p.ansi[15] == RGB(hex: "fefefe"))
        #expect(p.ansi[2] == TerminalPalette.standard.ansi[2])
        #expect(p.ansi.count == 16)
        #expect(TerminalPalette.parseGhostty("palette = 0=#000000", id: "x", name: "x") == nil)
    }

    @Test func itermTheme() throws {
        func c(_ r: Double, _ g: Double, _ b: Double) -> [String: Any] {
            ["Red Component": r, "Green Component": g, "Blue Component": b, "Color Space": "sRGB"]
        }
        let plist: [String: Any] = ["Background Color": c(0, 0, 0), "Foreground Color": c(1, 1, 1),
                                    "Ansi 4 Color": c(0, 0, 1), "Selection Color": c(0.5, 0.5, 0.5)]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let p = try #require(TerminalPalette.parseITerm(data, id: "file:y", name: "y"))
        #expect(p.ansi[4] == RGB(0, 0, 1))
        #expect(p.ansi[0] == TerminalPalette.standard.ansi[0])
        #expect(p.selection == RGB(0.5, 0.5, 0.5))
        #expect(TerminalPalette.parseITerm(Data("nope".utf8), id: "", name: "") == nil)
    }

    @Test func filesAndResolve() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "background = #101010\nforeground = #eeeeee\n".write(to: dir.appendingPathComponent("Mine"), atomically: true, encoding: .utf8)
        try "not a theme".write(to: dir.appendingPathComponent("Broken"), atomically: true, encoding: .utf8)
        let all = TerminalPalette.available(themesDir: dir)
        #expect(all.map(\.id).suffix(1) == ["file:Mine"])
        #expect(all.count == TerminalPalette.builtIn.count + 1)
        #expect(TerminalPalette.resolve("file:Mine", themesDir: dir).background == RGB(hex: "101010"))
        #expect(TerminalPalette.resolve("file:../etc", themesDir: dir) == TerminalPalette.standard)
        #expect(TerminalPalette.resolve("builtin:nord", themesDir: dir).name == "Nord")
        #expect(TerminalPalette.resolve(nil, themesDir: dir) == TerminalPalette.standard)
        #expect(TerminalPalette.resolve("file:Gone", themesDir: dir) == TerminalPalette.standard)
    }
}
