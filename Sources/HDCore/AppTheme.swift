import Foundation

/// The app's chrome colors: window, sidebar, panels, text and accents. All built-ins are dark; nil in
/// settings (Klasik) keeps the system look. Each theme names the terminal palette it was drawn with.
public struct AppTheme: Hashable, Sendable, Identifiable {
    public var id: String
    /// Window and the space around the terminal card.
    public var window: RGB
    /// Sidebar, toolbar and session header.
    public var sidebar: RGB
    /// Inspector.
    public var panel: RGB
    /// Cards inside panels (subagents).
    public var card: RGB
    /// Wells: track of a progress bar, segmented backgrounds.
    public var well: RGB
    /// Hairlines between areas.
    public var edge: RGB
    public var edgeOpacity: Double
    /// Terminal card border; nil → the account's color.
    public var cardEdge: RGB?
    /// Terminal card shadow.
    public var cardShadow: Bool
    public var text: RGB
    public var muted: RGB
    public var accent: RGB
    public var accent2: RGB
    /// Selected sidebar row: filled with the accent, or a soft accent wash.
    public var solidSelection: Bool
    /// Tile colors of the sidebar's Tracking, Inbox and Board icons.
    public var navTints: [RGB]
    /// `TerminalPalette.id` the theme was drawn with; picked together with the theme.
    public var terminalPalette: String

    public static let navyID = "navy"
    public static let graphiteID = "graphite"
    public static let warmID = "warm"

    private static func hex(_ s: String) -> RGB { RGB(hex: s)! }

    public static let navy = AppTheme(
        id: navyID, window: hex("0f111a"), sidebar: hex("13151f"), panel: hex("141722"), card: hex("1a1b26"),
        well: hex("1d2030"), edge: hex("7aa2f7"), edgeOpacity: 0.12, cardEdge: hex("2a3150"), cardShadow: false,
        text: hex("c8d0f5"), muted: hex("7d86ad"), accent: hex("7aa2f7"), accent2: hex("7dcfff"),
        solidSelection: false, navTints: [hex("bb9af7"), hex("7aa2f7"), hex("2ac3de")], terminalPalette: "builtin:tokyo-night")

    public static let graphite = AppTheme(
        id: graphiteID, window: hex("1c1c1f"), sidebar: hex("2a2a2e"), panel: hex("202023"), card: hex("2a2a2e"),
        well: hex("25252a"), edge: hex("ffffff"), edgeOpacity: 0.07, cardEdge: nil, cardShadow: true,
        text: hex("ececf0"), muted: hex("9c9ca6"), accent: hex("7c86f2"), accent2: hex("4cc2b3"),
        solidSelection: true, navTints: [hex("f0a24a"), hex("3b82f6"), hex("8b5cf6")], terminalPalette: "builtin:graphite")

    public static let warm = AppTheme(
        id: warmID, window: hex("161311"), sidebar: hex("1c1815"), panel: hex("1a1613"), card: hex("211c18"),
        well: hex("262019"), edge: hex("d97757"), edgeOpacity: 0.12, cardEdge: hex("3d2e24"), cardShadow: false,
        text: hex("efe6dc"), muted: hex("a6978a"), accent: hex("d97757"), accent2: hex("e2b86b"),
        solidSelection: false, navTints: [hex("d97757"), hex("c49a5a"), hex("8e9f6c")], terminalPalette: "builtin:warm-charcoal")

    public static let builtIn: [AppTheme] = [navy, graphite, warm]

    /// The theme for a stored id; nil (Klasik) for nil or an unknown id.
    public static func resolve(_ id: String?) -> AppTheme? {
        guard let id else { return nil }
        return builtIn.first { $0.id == id }
    }
}
