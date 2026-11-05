import AppKit
import HDCore

// OWNER: workspace area. Terminal colors and font (Settings › Terminal).
extension AppModel {
    var terminalFont: NSFont {
        TerminalTheme.font(family: state.settings.terminalFont, size: state.settings.terminalFontSize ?? 13)
    }

    func availableTerminalThemes() -> [TerminalPalette] {
        TerminalPalette.available(themesDir: paths.themesDir)
    }

    func setTerminalTheme(_ id: String) {
        state.settings.terminalTheme = id == TerminalPalette.defaultID ? nil : id
        terminalPalette = TerminalPalette.resolve(state.settings.terminalTheme, themesDir: paths.themesDir)
        terminals.applyAppearance(font: terminalFont, palette: terminalPalette)
    }

    func setTerminalFont(family: String?) {
        state.settings.terminalFont = family
        terminals.applyAppearance(font: terminalFont, palette: terminalPalette)
    }

    func setTerminalFontSize(_ size: Double) {
        state.settings.terminalFontSize = size
        terminals.applyAppearance(font: terminalFont, palette: terminalPalette)
    }

    /// Copies readable theme files into `themes/` and switches to the last one. Returns the names of
    /// files that aren't Ghostty or iTerm2 themes.
    @discardableResult
    func importTerminalThemes(_ urls: [URL]) -> [String] {
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.themesDir, withIntermediateDirectories: true)
        var rejected: [String] = []
        var last: String?
        for url in urls {
            guard TerminalPalette.load(file: url) != nil else {
                rejected.append(url.lastPathComponent)
                continue
            }
            let dest = paths.themesDir.appendingPathComponent(url.lastPathComponent)
            if dest.standardizedFileURL != url.standardizedFileURL {
                try? fm.removeItem(at: dest)
                guard (try? fm.copyItem(at: url, to: dest)) != nil else {
                    rejected.append(url.lastPathComponent)
                    continue
                }
            }
            last = TerminalPalette.filePrefix + dest.lastPathComponent
        }
        if let last { setTerminalTheme(last) }
        return rejected
    }

    func revealThemesFolder() {
        try? FileManager.default.createDirectory(at: paths.themesDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(paths.themesDir)
    }
}
