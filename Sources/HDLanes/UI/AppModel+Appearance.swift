import AppKit
import HDCore

// OWNER: workspace area. Window theme, terminal colors and font (Settings › Appearance).
extension AppModel {
    /// Switches the window colors and, with them, the terminal palette the theme was drawn with;
    /// a terminal theme picked afterwards stays. nil = Klasik.
    func setAppTheme(_ id: String?) {
        let theme = AppTheme.resolve(id)
        state.settings.appTheme = theme?.id
        appTheme = theme
        setTerminalTheme(theme?.terminalPalette ?? TerminalPalette.defaultID)
        applyAppAppearance()
    }

    /// The themes are dark: system controls, sheets and alerts (AppKit too) follow. Klasik follows the system.
    func applyAppAppearance() {
        NSApp.appearance = appTheme == nil ? nil : NSAppearance(named: .darkAqua)
    }

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
            // Hidden names never resolve as a theme id (see `TerminalPalette.resolve`).
            guard !url.lastPathComponent.hasPrefix("."), TerminalPalette.load(file: url) != nil else {
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
