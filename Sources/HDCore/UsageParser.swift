import Foundation

/// Rate-limit readings from Claude's status line JSON and Codex's `rate_limits` objects.
public enum UsageParser {
    public static let fiveHourMinutes = 300
    public static let weekMinutes = 10_080

    // MARK: Claude

    /// `rate_limits.five_hour` / `rate_limits.seven_day` of a status line payload. nil when neither
    /// window is present (API-key accounts, or before the first API response of a session).
    public static func claudeUsage(fromStatusLine json: JSONValue, now: Date) -> AccountUsage? {
        let limits = json["rate_limits"]
        let five = window(limits?["five_hour"], minutes: fiveHourMinutes)
        let week = window(limits?["seven_day"], minutes: weekMinutes)
        guard five != nil || week != nil else { return nil }
        return AccountUsage(fiveHour: five, week: week, plan: nil, updatedAt: now)
    }

    /// `context_window.used_percentage` (or 100 − `remaining_percentage`).
    public static func contextPercent(fromStatusLine json: JSONValue) -> Double? {
        let context = json["context_window"]
        if let used = percent(context, keys: ["used_percentage", "used_percent"]) { return clamp(used) }
        if let remaining = percent(context, keys: ["remaining_percentage", "remaining_percent"]) { return clamp(100 - remaining) }
        return nil
    }

    // MARK: Codex

    /// A Codex `rate_limits` object (rollout `token_count`, snake_case) or app-server `rateLimits`
    /// (camelCase). Windows are placed by length: up to a day → five-hour slot, longer → week.
    public static func codexUsage(fromRateLimits json: JSONValue, now: Date) -> AccountUsage? {
        var five: UsageWindow?
        var week: UsageWindow?
        for (key, fallbackMinutes) in [("primary", fiveHourMinutes), ("secondary", weekMinutes)] {
            let raw = json[key]
            let minutes = (raw?["window_minutes"] ?? raw?["windowDurationMins"])?.double.map { Int($0) }
            guard let w = window(raw, minutes: minutes ?? fallbackMinutes) else { continue }
            if (minutes ?? fallbackMinutes) <= 1440 {
                if five == nil { five = w }
            } else if week == nil {
                week = w
            }
        }
        guard five != nil || week != nil else { return nil }
        let plan = (json["plan_type"] ?? json["planType"])?.string.flatMap { $0.isEmpty ? nil : $0 }
        return AccountUsage(fiveHour: five, week: week, plan: plan, updatedAt: now)
    }

    // MARK: Merge

    /// A new reading replaces the old one window by window; a window missing from the new reading
    /// keeps its old value, and a plan the new reading doesn't name is kept.
    public static func merge(_ old: AccountUsage?, _ new: AccountUsage) -> AccountUsage {
        guard let old else { return new }
        return AccountUsage(fiveHour: new.fiveHour ?? old.fiveHour, week: new.week ?? old.week,
                            plan: new.plan ?? old.plan, updatedAt: max(old.updatedAt, new.updatedAt))
    }

    /// true when two readings show the same numbers (ignores `updatedAt`), to skip needless saves.
    public static func sameReading(_ a: AccountUsage?, _ b: AccountUsage?) -> Bool {
        a?.fiveHour == b?.fiveHour && a?.week == b?.week && a?.plan == b?.plan
    }

    // MARK: Helpers

    static func window(_ raw: JSONValue?, minutes: Int) -> UsageWindow? {
        guard let raw, let used = percent(raw, keys: ["used_percentage", "used_percent", "usedPercent"]) else {
            return nil
        }
        let resets = (raw["resets_at"] ?? raw["resetsAt"]).flatMap(date)
        return UsageWindow(usedPercent: clamp(used), resetsAt: resets, windowMinutes: minutes)
    }

    static func percent(_ raw: JSONValue?, keys: [String]) -> Double? {
        for key in keys {
            if let v = raw?[key]?.double, v.isFinite { return v }
        }
        return nil
    }

    /// Epoch seconds (or milliseconds, if implausibly large), numeric string, or ISO 8601.
    static func date(_ value: JSONValue) -> Date? {
        if let n = value.double, n > 0 {
            return Date(timeIntervalSince1970: n > 100_000_000_000 ? n / 1000 : n)
        }
        if let s = value.string { return CodexRollout.parseDate(s) }
        return nil
    }

    static func clamp(_ v: Double) -> Double { min(100, max(0, v)) }
}
