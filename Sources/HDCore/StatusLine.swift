import Foundation

/// The status line `hdlanes-hook statusline` prints under Claude Code when the account has none of its
/// own: account · model · context · 5-hour and weekly limits, colored by how full each one is.
public enum StatusLine {
    /// Account labels come from the user, but they end up in a terminal: no control characters, short.
    public static func cleanLabel(_ label: String) -> String {
        let scalars = label.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.value != 0x7F }
        let s = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return s.count > 24 ? String(s.prefix(23)) + "…" : s
    }

    public static func render(_ payload: JSONValue, accountLabel: String?, now: Date = Date(),
                              color: Bool = true, timeZone: TimeZone = .current) -> String {
        func paint(_ text: String, _ code: String) -> String { color ? "\u{1b}[\(code)m\(text)\u{1b}[0m" : text }
        func level(_ p: Double) -> String { p >= 85 ? "31" : p >= 60 ? "33" : "32" }   // red / yellow / green

        var parts: [String] = []
        if let label = accountLabel.map(cleanLabel), !label.isEmpty { parts.append(paint(label, "1")) }
        if let model = payload.path("model.display_name")?.string, !model.isEmpty { parts.append(cleanLabel(model)) }
        if let ctx = UsageParser.contextPercent(fromStatusLine: payload) {
            parts.append("ctx " + paint("\(Int(ctx.rounded()))%", level(ctx)))
        }
        if let usage = UsageParser.claudeUsage(fromStatusLine: payload, now: now) {
            for (name, window) in [("5h", usage.fiveHour), ("7d", usage.week)] {
                guard let window else { continue }
                var text = "\(name) " + paint("\(Int(window.usedPercent.rounded()))%", level(window.usedPercent))
                // Near the limit, say when it resets.
                if window.usedPercent >= 80, let reset = window.resetsAt, reset > now {
                    text += " ↻" + resetText(reset, now: now, timeZone: timeZone)
                }
                parts.append(text)
            }
        }
        return parts.joined(separator: paint(" · ", "2"))
    }

    /// `14:20` today, `Mon 09:00` within a week, else the date.
    static func resetText(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        if cal.isDate(date, inSameDayAs: now) {
            f.dateFormat = "HH:mm"
        } else if date.timeIntervalSince(now) < 6 * 86_400 {
            f.dateFormat = "EEE HH:mm"
        } else {
            f.dateFormat = "d MMM"
        }
        return f.string(from: date)
    }
}
