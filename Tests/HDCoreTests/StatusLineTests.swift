import Foundation
import Testing
@testable import HDCore

struct StatusLineTests {
    private func payload(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test func plainLine() throws {
        let p = try payload(#"{"model":{"display_name":"Opus"},"context_window":{"used_percentage":41.6},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":2000000000},"seven_day":{"used_percentage":12}}}"#)
        #expect(StatusLine.render(p, accountLabel: "İş", color: false) == "İş · Opus · ctx 42% · 5h 30% · 7d 12%")
        #expect(StatusLine.render(try payload("{}"), accountLabel: nil, color: false) == "")
    }

    @Test func colorsAndResetNearTheLimit() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = Int(now.timeIntervalSince1970) + 3600
        let p = try payload(#"{"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":\#(reset)}}}"#)
        let utc = TimeZone(identifier: "UTC")!
        let plain = StatusLine.render(p, accountLabel: nil, now: now, color: false, timeZone: utc)
        #expect(plain == "5h 90% ↻09:00")
        let colored = StatusLine.render(p, accountLabel: nil, now: now, color: true, timeZone: utc)
        #expect(colored.contains("\u{1b}[31m90%"))
    }

    @Test func labelsCantInjectEscapes() {
        #expect(StatusLine.cleanLabel("Work\u{1b}]0;x\u{07}") == "Work]0;x")
        #expect(StatusLine.cleanLabel(String(repeating: "a", count: 40)).count == 24)
        let vars = EnvBuilder.SessionVariables(socketPath: "/s", sessionID: UUID(), accountID: nil, accountLabel: "Kişisel\n")
        #expect(vars.environment[HookEnv.accountLabel] == "Kişisel")
        #expect(EnvBuilder.SessionVariables(socketPath: "/s", sessionID: UUID(), accountID: nil).environment[HookEnv.accountLabel] == nil)
    }
}
