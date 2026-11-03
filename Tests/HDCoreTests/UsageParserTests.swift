import Foundation
import Testing
@testable import HDCore

struct UsageParserTests {
    private func j(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }

    let now = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func claudeStatusLine() throws {
        let line = j(#"""
        {"session_id":"s","model":{"id":"claude-opus","display_name":"Opus"},
         "context_window":{"used_percentage":42.5,"context_window_size":200000},
         "cost":{"total_cost_usd":1.25},
         "rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":1793707612},
                        "seven_day":{"used_percentage":61,"resets_at":1794000000}}}
        """#)
        let usage = try #require(UsageParser.claudeUsage(fromStatusLine: line, now: now))
        #expect(usage.fiveHour == UsageWindow(usedPercent: 12.5, resetsAt: Date(timeIntervalSince1970: 1_793_707_612), windowMinutes: 300))
        #expect(usage.week == UsageWindow(usedPercent: 61, resetsAt: Date(timeIntervalSince1970: 1_794_000_000), windowMinutes: 10_080))
        #expect(usage.updatedAt == now)
        #expect(usage.plan == nil)
        #expect(UsageParser.contextPercent(fromStatusLine: line) == 42.5)
    }

    @Test func claudeStatusLineTolerance() {
        // API-key accounts: no rate_limits.
        #expect(UsageParser.claudeUsage(fromStatusLine: j(#"{"model":{"display_name":"Opus"}}"#), now: now) == nil)
        #expect(UsageParser.claudeUsage(fromStatusLine: j(#"{"rate_limits":{}}"#), now: now) == nil)
        let onlyWeek = UsageParser.claudeUsage(fromStatusLine: j(#"{"rate_limits":{"seven_day":{"used_percent":"30"}}}"#), now: now)
        #expect(onlyWeek?.fiveHour == nil)
        #expect(onlyWeek?.week?.usedPercent == 30)
        #expect(onlyWeek?.week?.resetsAt == nil)
        let iso = UsageParser.claudeUsage(fromStatusLine: j(#"{"rate_limits":{"five_hour":{"used_percentage":150,"resets_at":"2026-11-02T10:00:00Z"}}}"#), now: now)
        #expect(iso?.fiveHour?.usedPercent == 100)
        #expect(iso?.fiveHour?.resetsAt == CodexRollout.parseDate("2026-11-02T10:00:00Z"))
        let millis = UsageParser.claudeUsage(fromStatusLine: j(#"{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":1793707612000}}}"#), now: now)
        #expect(millis?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_793_707_612))
        #expect(UsageParser.contextPercent(fromStatusLine: j(#"{"context_window":{"remaining_percentage":70}}"#)) == 30)
        #expect(UsageParser.contextPercent(fromStatusLine: j("{}")) == nil)
    }

    @Test func codexRateLimitsByWindowLength() throws {
        let limits = j(#"{"limit_id":"codex","primary":{"used_percent":100.0,"window_minutes":300,"resets_at":1793707612},"secondary":{"used_percent":25.0,"window_minutes":10080,"resets_at":1794000000},"credits":{"has_credits":false},"plan_type":"plus"}"#)
        let usage = try #require(UsageParser.codexUsage(fromRateLimits: limits, now: now))
        #expect(usage.fiveHour?.usedPercent == 100)
        #expect(usage.fiveHour?.windowMinutes == 300)
        #expect(usage.week?.usedPercent == 25)
        #expect(usage.week?.resetsAt == Date(timeIntervalSince1970: 1_794_000_000))
        #expect(usage.plan == "plus")
    }

    @Test func codexWindowsArePlacedByLengthNotSlot() {
        let weekOnly = UsageParser.codexUsage(fromRateLimits: j(#"{"primary":{"used_percent":5,"window_minutes":10080},"secondary":null}"#), now: now)
        #expect(weekOnly?.fiveHour == nil)
        #expect(weekOnly?.week?.usedPercent == 5)
        let camel = UsageParser.codexUsage(fromRateLimits: j(#"{"primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":1793707612},"planType":"pro"}"#), now: now)
        #expect(camel?.fiveHour?.usedPercent == 7)
        #expect(camel?.plan == "pro")
        let noWindow = UsageParser.codexUsage(fromRateLimits: j(#"{"primary":{"used_percent":9}}"#), now: now)
        #expect(noWindow?.fiveHour?.usedPercent == 9)
        #expect(UsageParser.codexUsage(fromRateLimits: j(#"{"primary":null,"secondary":null}"#), now: now) == nil)
        #expect(UsageParser.codexUsage(fromRateLimits: .null, now: now) == nil)
    }

    @Test func mergeKeepsWindowsTheNewReadingLacks() {
        let old = AccountUsage(fiveHour: UsageWindow(usedPercent: 10, resetsAt: nil, windowMinutes: 300),
                               week: UsageWindow(usedPercent: 50, resetsAt: nil, windowMinutes: 10_080), plan: "max",
                               updatedAt: Date(timeIntervalSince1970: 1))
        let new = AccountUsage(fiveHour: UsageWindow(usedPercent: 20, resetsAt: nil, windowMinutes: 300), week: nil,
                               plan: nil, updatedAt: Date(timeIntervalSince1970: 2))
        let merged = UsageParser.merge(old, new)
        #expect(merged.fiveHour?.usedPercent == 20)
        #expect(merged.week?.usedPercent == 50)
        #expect(merged.plan == "max")
        #expect(merged.updatedAt == Date(timeIntervalSince1970: 2))
        #expect(UsageParser.merge(nil, new) == new)
        #expect(UsageParser.sameReading(merged, merged))
        #expect(!UsageParser.sameReading(old, merged))
    }
}
