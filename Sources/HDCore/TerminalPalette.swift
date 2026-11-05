import Foundation

/// An sRGB color, 0…1 per channel.
public struct RGB: Hashable, Sendable {
    public var r: Double, g: Double, b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// `#rrggbb` or `rrggbb`.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let v = UInt32(s, radix: 16) else { return nil }
        self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// Relative luminance (WCAG).
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

/// Terminal colors: background, foreground, cursor, selection and the 16 ANSI colors.
/// Built-ins live here; imported Ghostty / iTerm2 themes are files in `~/.hdlanes/themes/`.
public struct TerminalPalette: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var background: RGB
    public var foreground: RGB
    public var cursor: RGB?
    public var selection: RGB?
    /// Always 16 entries.
    public var ansi: [RGB]

    public init(id: String, name: String, background: RGB, foreground: RGB, cursor: RGB? = nil,
                selection: RGB? = nil, ansi: [RGB]) {
        self.id = id
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi.count >= 16 ? Array(ansi.prefix(16)) : ansi + Self.standard.ansi.dropFirst(ansi.count)
    }

    public var isDark: Bool { background.luminance < 0.4 }

    public static let defaultID = "builtin:hdlanes"
    public static let filePrefix = "file:"

    // MARK: Built-ins

    private static func make(_ id: String, _ name: String, bg: String, fg: String, _ hex: [String]) -> TerminalPalette {
        TerminalPalette(id: "builtin:\(id)", name: name, background: RGB(hex: bg)!, foreground: RGB(hex: fg)!,
                        ansi: hex.map { RGB(hex: $0)! })
    }

    /// hdlanes' own dark palette, tuned for contrast; also fills colors an imported theme leaves out.
    public static let standard = make("hdlanes", "hdlanes", bg: "191a1d", fg: "e2e3e6", [
        "1d1f23", "e06c75", "8fc27a", "e5c07b", "61afef", "c678dd", "56b6c2", "c8ccd4",
        "5c6370", "ef838b", "a5d68f", "f0d08f", "7dc1f7", "d692e9", "6fcfda", "eceef2",
    ])

    public static let builtIn: [TerminalPalette] = [
        standard,
        make("dracula", "Dracula", bg: "282a36", fg: "f8f8f2", [
            "21222c", "ff5555", "50fa7b", "f1fa8c", "bd93f9", "ff79c6", "8be9fd", "f8f8f2",
            "6272a4", "ff6e6e", "69ff94", "ffffa5", "d6acff", "ff92df", "a4ffff", "ffffff",
        ]),
        make("nord", "Nord", bg: "2e3440", fg: "d8dee9", [
            "3b4252", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "88c0d0", "e5e9f0",
            "4c566a", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "8fbcbb", "eceff4",
        ]),
        make("gruvbox-dark", "Gruvbox Dark", bg: "282828", fg: "ebdbb2", [
            "282828", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
            "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2",
        ]),
        make("solarized-dark", "Solarized Dark", bg: "002b36", fg: "839496", [
            "073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
            "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3",
        ]),
        make("tokyo-night", "Tokyo Night", bg: "1a1b26", fg: "c0caf5", [
            "15161e", "f7768e", "9ece6a", "e0af68", "7aa2f7", "bb9af7", "7dcfff", "a9b1d6",
            "414868", "f7768e", "9ece6a", "e0af68", "7aa2f7", "bb9af7", "7dcfff", "c0caf5",
        ]),
    ]

    // MARK: Imported themes

    /// Ghostty theme file: `background = #282a36`, `foreground = …`, `cursor-color = …`,
    /// `selection-background = …`, `palette = 0=#21222c`. Comments start with `#` at line start.
    public static func parseGhostty(_ text: String, id: String, name: String) -> TerminalPalette? {
        var values: [String: RGB] = [:]
        var ansi = standard.ansi
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "palette" {
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let i = Int(parts[0]), (0..<16).contains(i), let c = RGB(hex: parts[1]) else { continue }
                ansi[i] = c
            } else if let c = RGB(hex: value) {
                values[key] = c
            }
        }
        guard let bg = values["background"], let fg = values["foreground"] else { return nil }
        return TerminalPalette(id: id, name: name, background: bg, foreground: fg,
                               cursor: values["cursor-color"], selection: values["selection-background"], ansi: ansi)
    }

    /// iTerm2 `.itermcolors` (a property list of `"Ansi 0 Color"` … with Red/Green/Blue Component reals).
    public static func parseITerm(_ data: Data, id: String, name: String) -> TerminalPalette? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        func color(_ key: String) -> RGB? {
            guard let d = plist[key] as? [String: Any],
                  let r = (d["Red Component"] as? NSNumber)?.doubleValue,
                  let g = (d["Green Component"] as? NSNumber)?.doubleValue,
                  let b = (d["Blue Component"] as? NSNumber)?.doubleValue else { return nil }
            return RGB(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
        }
        guard let bg = color("Background Color"), let fg = color("Foreground Color") else { return nil }
        let ansi = (0..<16).map { color("Ansi \($0) Color") ?? standard.ansi[$0] }
        return TerminalPalette(id: id, name: name, background: bg, foreground: fg,
                               cursor: color("Cursor Color"), selection: color("Selection Color"), ansi: ansi)
    }

    /// Theme files hdlanes reads: `.itermcolors` as a property list, anything else as a Ghostty theme.
    public static func load(file url: URL) -> TerminalPalette? {
        guard let data = try? Data(contentsOf: url), data.count < 256_000 else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let id = filePrefix + url.lastPathComponent
        // iTerm2 themes are property lists, sometimes shipped as .plist.
        if url.pathExtension.lowercased() == "itermcolors" || data.starts(with: Data("<?xml".utf8))
            || data.starts(with: Data("bplist".utf8)) {
            return parseITerm(data, id: id, name: name)
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseGhostty(text, id: id, name: name)
    }

    /// Built-ins followed by the readable files in `dir`, sorted by name.
    public static func available(themesDir dir: URL) -> [TerminalPalette] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let imported = files
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap(load(file:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return builtIn + imported
    }

    /// The palette for a stored id; unknown or unreadable ids fall back to `standard`.
    public static func resolve(_ id: String?, themesDir: URL) -> TerminalPalette {
        guard let id else { return standard }
        if let b = builtIn.first(where: { $0.id == id }) { return b }
        if id.hasPrefix(filePrefix) {
            let file = String(id.dropFirst(filePrefix.count))
            guard !file.contains("/"), !file.hasPrefix(".") else { return standard }
            return load(file: themesDir.appendingPathComponent(file)) ?? standard
        }
        return standard
    }

}
