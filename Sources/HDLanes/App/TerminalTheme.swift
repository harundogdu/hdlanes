import AppKit
import SwiftTerm

/// The terminal stays dark in both appearances: agent TUIs (Claude Code, Codex) default to dark
/// themes and look broken on white.
enum TerminalTheme {
    static let background = NSColor(srgbRed: 0.098, green: 0.102, blue: 0.114, alpha: 1)
    static let foreground = NSColor(srgbRed: 0.886, green: 0.890, blue: 0.902, alpha: 1)

    // 16 ANSI colors, tuned for contrast on `background`.
    private static let ansi: [(UInt16, UInt16, UInt16)] = [
        (0x1d, 0x1f, 0x23), (0xe0, 0x6c, 0x75), (0x8f, 0xc2, 0x7a), (0xe5, 0xc0, 0x7b),
        (0x61, 0xaf, 0xef), (0xc6, 0x78, 0xdd), (0x56, 0xb6, 0xc2), (0xc8, 0xcc, 0xd4),
        (0x5c, 0x63, 0x70), (0xef, 0x83, 0x8b), (0xa5, 0xd6, 0x8f), (0xf0, 0xd0, 0x8f),
        (0x7d, 0xc1, 0xf7), (0xd6, 0x92, 0xe9), (0x6f, 0xcf, 0xda), (0xec, 0xee, 0xf2),
    ]

    @MainActor
    static func apply(to view: TerminalView) {
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = foreground
        view.installColors(ansi.map { SwiftTerm.Color(red: $0.0 * 257, green: $0.1 * 257, blue: $0.2 * 257) })
    }
}
