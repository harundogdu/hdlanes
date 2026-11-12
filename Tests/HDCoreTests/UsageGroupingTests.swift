import Foundation
import Testing
@testable import HDCore

struct UsageGroupingTests {
    @Test func splitsGroupFromName() {
        #expect(AccountGrouping.split("Fimple - Claude") == ("Fimple", "Claude"))
        #expect(AccountGrouping.split("Kişisel – Codex") == ("Kişisel", "Codex"))
        #expect(AccountGrouping.split("Codex 2") == (nil, "Codex 2"))
        #expect(AccountGrouping.split(" - Claude") == (nil, " - Claude"))
    }

    @Test func aWindowThatEndedBeforeTheReadingIsUnknown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let updated = now.addingTimeInterval(-60)
        // Ended days before the reading and not reported since: unknown, not 0 %.
        let stale = AccountUsage(fiveHour: UsageWindow(usedPercent: 80, resetsAt: updated.addingTimeInterval(-86_400), windowMinutes: 300),
                                 week: UsageWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(86_400), windowMinutes: 10_080),
                                 plan: nil, updatedAt: updated)
        #expect(stale.percent(\.fiveHour, at: now) == nil)
        #expect(stale.percent(\.week, at: now) == 50)
        // Ended after the reading: really empty again.
        let reset = AccountUsage(fiveHour: UsageWindow(usedPercent: 80, resetsAt: now.addingTimeInterval(-10), windowMinutes: 300),
                                 week: nil, plan: nil, updatedAt: updated)
        #expect(reset.percent(\.fiveHour, at: now) == 0)
        #expect(reset.percent(\.week, at: now) == nil)
    }
}
