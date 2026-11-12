import AppKit
import HDCore
import SwiftUI

/// Visual constants. Keep the UI quiet: system materials and fonts, one accent per meaning,
/// account colors only as small dots/bars so several accounts stay tellable apart.
enum Theme {
    /// Account colors, muted so they don't fight the status colors. Index stored on `Account.colorIndex`.
    static let accountColors: [Color] = [
        Color(red: 0.36, green: 0.42, blue: 0.86),  // indigo
        Color(red: 0.18, green: 0.62, blue: 0.56),  // teal
        Color(red: 0.85, green: 0.62, blue: 0.24),  // amber
        Color(red: 0.80, green: 0.38, blue: 0.45),  // rose
        Color(red: 0.33, green: 0.62, blue: 0.40),  // green
        Color(red: 0.60, green: 0.43, blue: 0.80),  // purple
        Color(red: 0.25, green: 0.55, blue: 0.85),  // blue
        Color(red: 0.84, green: 0.48, blue: 0.25),  // orange
    ]

    static func accountColor(_ index: Int) -> Color {
        accountColors[((index % accountColors.count) + accountColors.count) % accountColors.count]
    }

    static func color(for status: AgentStatus) -> Color {
        switch status {
        case .working, .starting: return .accentColor
        case .needsYou: return .orange
        case .done: return .green
        case .error: return .red
        case .ready: return .secondary
        case .notStarted, .exited: return Color.secondary.opacity(0.6)
        }
    }

    static let categoryColors: [String: Color] = [
        "bug": Color(red: 0.80, green: 0.38, blue: 0.45),
        "feature": Color(red: 0.36, green: 0.42, blue: 0.86),
        "refactor": Color(red: 0.60, green: 0.43, blue: 0.80),
        "test": Color(red: 0.18, green: 0.62, blue: 0.56),
        "docs": Color(red: 0.55, green: 0.55, blue: 0.58),
        "ui": Color(red: 0.85, green: 0.62, blue: 0.24),
        "chore": Color(red: 0.50, green: 0.55, blue: 0.60),
        "research": Color(red: 0.25, green: 0.55, blue: 0.85),
        "review": Color(red: 0.18, green: 0.52, blue: 0.62),
    ]

    static func categoryColor(_ id: String?) -> Color {
        id.flatMap { categoryColors[$0] } ?? .secondary
    }

    static func color(_ rgb: RGB, opacity: Double = 1) -> Color {
        Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: opacity)
    }

    static let mono = Font.system(.body, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
}

extension View {
    /// Fills the background with the app theme's `color`, or leaves the system look (Classic).
    @ViewBuilder
    func themeBackground(_ theme: AppTheme?, _ color: KeyPath<AppTheme, RGB>) -> some View {
        if let theme { background(Theme.color(theme[keyPath: color])) } else { self }
    }

    /// The theme's text color and accent for everything inside, dark controls included.
    @ViewBuilder
    func themeColors(_ theme: AppTheme?) -> some View {
        if let theme {
            // Dark controls come from `NSApp.appearance` (`applyAppAppearance`).
            foregroundStyle(Theme.color(theme.text))
                .tint(Theme.color(theme.accent))
        } else {
            self
        }
    }
}
