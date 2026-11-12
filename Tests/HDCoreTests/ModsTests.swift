import Foundation
import Testing
@testable import HDCore

struct ModsTests {
    @Test func catalogIDsAreUniqueAndBuiltinIsYouShouldKnow() {
        let ids = ModCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains(ModCatalog.youShouldKnowID))
        #expect(ModCatalog.entries.filter { $0.source == .builtin }.map(\.id) == [ModCatalog.youShouldKnowID])
    }

    @Test func installArguments() throws {
        let flightdeck = try #require(ModCatalog.entries.first { $0.name == "flightdeck" })
        #expect(ModCatalog.installArguments(flightdeck, playgroundPath: nil)
            == ["plugin", "install", "flightdeck", "--marketplace", "scasella/claude-flightdeck", "--json"])
        let weather = try #require(ModCatalog.entries.first { $0.name == "token-weather" })
        #expect(ModCatalog.installArguments(weather, playgroundPath: nil) == nil)
        #expect(ModCatalog.installArguments(weather, playgroundPath: "/x/mods")?[4] == "/x/mods")
        let ysk = try #require(ModCatalog.entries.first { $0.source == .builtin })
        #expect(ModCatalog.installArguments(ysk, playgroundPath: "/x") == nil)
    }

    @Test func customInstallRejectsOptionsAndBlanks() {
        #expect(ModCatalog.customInstallArguments(name: " cache-tax ", source: "karanb192/claude-code-mods")
            == ["plugin", "install", "cache-tax", "--marketplace", "karanb192/claude-code-mods", "--json"])
        #expect(ModCatalog.customInstallArguments(name: "--yes", source: "a/b") == nil)
        #expect(ModCatalog.customInstallArguments(name: "a", source: "-y") == nil)
        #expect(ModCatalog.customInstallArguments(name: "a b", source: "a/b") == nil)
        #expect(ModCatalog.customInstallArguments(name: "", source: "a/b") == nil)
        #expect(ModCatalog.customInstallArguments(name: "a@npm", source: "a/b") == nil)
        #expect(ModCatalog.accepting("2", ["plugin", "install", "a", "--accept-command", "1", "--json"])
            == ["plugin", "install", "a", "--json", "--accept-command", "2"])
    }

    // List and ok/failed lines seen live from Claude Code 2.1.322; the shownCommand shape is read from
    // its binary (headers-helper case), not seen live.
    @Test func parsesListAndResults() throws {
        let list = #"[{"id": "token-weather@claude-code-playground-mods", "version": "0.1.0", "scope": "user", "enabled": true}, {"id": "x@y", "enabled": false}]"#
        let plugins = try #require(InstalledPlugin.parseList(Data(list.utf8)))
        #expect(plugins.map(\.name) == ["token-weather", "x"])
        #expect(plugins.map(\.enabled) == [true, false])
        #expect(InstalledPlugin.parseList(Data("nope".utf8)) == nil)

        #expect(PluginCommandResult.parse(#"{"command":"install","outcome":"ok","plugin":"a@b"}"#) == .ok)
        #expect(PluginCommandResult.parse(#"{"command":"install","outcome":"failed","message":"Plugin \"nope\" not found"}"#)
            == .failed("Plugin \"nope\" not found"))
        #expect(PluginCommandResult.parse(#"{"outcome":"failed","failureCode":"command_source_refused","message":"m","shownCommand":{"kind":"headersHelper","command":"curl x","archiveUrl":"https://a/b.zip","sha256":"ab"}}"#)
            == .needsCommand(command: "curl x", archiveURL: "https://a/b.zip", sha256: "ab"))
        // Fails closed when the command can't be shown.
        #expect(PluginCommandResult.parse(#"{"outcome":"failed","message":"m","shownCommand":{"command":["a"],"sha256":"ab"}}"#) == .failed("m"))
        #expect(PluginCommandResult.parse(#"{"outcome":"failed","message":"m","shownCommand":{"command":"  ","sha256":"ab"}}"#) == .failed("m"))
        #expect(PluginCommandResult.parse("✘ Failed") == nil)
    }

    @Test func builtinStateComesFromSettings() {
        let settings = Data(#"{"enabledPlugins": {"cc-plugin-you-should-know@builtin": true}}"#.utf8)
        #expect(InstalledPlugin.isEnabled(ModCatalog.youShouldKnowID, settings: settings))
        #expect(!InstalledPlugin.isEnabled(ModCatalog.youShouldKnowID, settings: Data("{}".utf8)))
        #expect(!InstalledPlugin.isEnabled(ModCatalog.youShouldKnowID, settings: nil))
    }
}
