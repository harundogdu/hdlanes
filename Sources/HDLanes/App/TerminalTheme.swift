import AppKit
import HDCore
import SwiftTerm

/// Applies a `TerminalPalette` and font to a terminal view. The default palette stays dark in both
/// appearances: agent TUIs (Claude Code, Codex) default to dark themes and look broken on white.
enum TerminalTheme {
    static func color(_ c: RGB) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }

    @MainActor
    static func apply(_ palette: TerminalPalette, to view: TerminalView) {
        let fg = color(palette.foreground)
        view.nativeBackgroundColor = color(palette.background)
        view.nativeForegroundColor = fg
        view.caretColor = palette.cursor.map(color) ?? fg
        // Themes without a selection color get a 30 % foreground-over-background mix.
        let b = palette.background, f = palette.foreground
        view.selectedTextBackgroundColor = color(palette.selection
            ?? RGB(b.r + (f.r - b.r) * 0.3, b.g + (f.g - b.g) * 0.3, b.b + (f.b - b.b) * 0.3))
        view.installColors(palette.ansi.map {
            SwiftTerm.Color(red: UInt16($0.r * 65535), green: UInt16($0.g * 65535), blue: UInt16($0.b * 65535))
        })
    }

    /// The chosen fixed-pitch family at `size`, or the system monospaced font when it is missing.
    static func font(family: String?, size: Double) -> NSFont {
        if let family, let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: CGFloat(size)) {
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    /// Installed fixed-pitch font families, sorted.
    static func monospacedFamilies() -> [String] {
        let fm = NSFontManager.shared
        let names = fm.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
            .filter { !$0.hasPrefix(".") }
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
