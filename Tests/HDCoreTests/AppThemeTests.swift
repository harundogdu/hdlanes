import Foundation
import Testing
@testable import HDCore

struct AppThemeTests {
    @Test func builtInsResolveAndNameRealTerminalPalettes() {
        #expect(Set(AppTheme.builtIn.map(\.id)).count == AppTheme.builtIn.count)
        for theme in AppTheme.builtIn {
            #expect(AppTheme.resolve(theme.id) == theme)
            // Each theme's terminal palette is a built-in, so picking the theme never falls back.
            #expect(TerminalPalette.builtIn.contains { $0.id == theme.terminalPalette })
            #expect(theme.window.luminance < 0.05 && theme.text.luminance > 0.5)
            #expect(theme.navTints.count == 3)
        }
        #expect(AppTheme.resolve(nil) == nil)
        #expect(AppTheme.resolve("nope") == nil)
    }
}
