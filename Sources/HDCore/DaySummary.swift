import Foundation

// OWNER: tracking area. End-of-day markdown, the review prompt template and `claude -p` output.

public enum DaySummary {
    /// Headings and fixed words, supplied by the app in the user's language.
    public struct Labels: Sendable {
        public var title: String
        public var done: String
        public var pullRequests: String
        public var opened: String
        public var merged: String
        public var stillOpen: String
        public var tomorrow: String
        public var nothing: String

        public init(title: String, done: String, pullRequests: String, opened: String, merged: String,
                    stillOpen: String, tomorrow: String, nothing: String) {
            self.title = title
            self.done = done
            self.pullRequests = pullRequests
            self.opened = opened
            self.merged = merged
            self.stillOpen = stillOpen
            self.tomorrow = tomorrow
            self.nothing = nothing
        }
    }

    /// A line under "still open" or "tomorrow".
    public struct Item: Equatable, Sendable {
        public var text: String
        public var detail: String?
        public var url: String?

        public init(text: String, detail: String? = nil, url: String? = nil) {
            self.text = text
            self.detail = detail
            self.url = url
        }
    }

    /// Builds the report. `events` are the day's activity events (any order); `projectNames` labels
    /// them; `time` formats a time of day. Finished turns are grouped per session (latest result wins).
    public static func markdown(events: [ActivityEvent], stillOpen: [Item], tomorrow: [Item],
                                projectNames: [UUID: String], labels: Labels, time: (Date) -> String) -> String {
        let sorted = events.sorted { $0.at < $1.at }
        var out = "# \(labels.title)\n"

        // Done: one line per session, its last finished turn.
        var order: [String] = []
        var lastDone: [String: ActivityEvent] = [:]
        var turns: [String: Int] = [:]
        for e in sorted where e.kind == .turnDone {
            let key = e.sessionID?.uuidString ?? e.title
            if lastDone[key] == nil { order.append(key) }
            lastDone[key] = e
            turns[key, default: 0] += 1
        }
        out += "\n## \(labels.done)\n\n"
        if order.isEmpty {
            out += "- \(labels.nothing)\n"
        } else {
            for key in order.sorted(by: { lastDone[$0]!.at < lastDone[$1]!.at }) {
                let e = lastDone[key]!
                var line = "- **\(inline(e.title))**"
                if let p = e.projectID.flatMap({ projectNames[$0] }) { line += " (\(inline(p)))" }
                if let n = turns[key], n > 1 { line += " ×\(n)" }
                line += " · \(time(e.at))"
                if let first = firstLine(e.detail) { line += "\n  \(inline(first))" }
                out += line + "\n"
            }
        }

        let opened = sorted.filter { $0.kind == .prOpened }
        let merged = sorted.filter { $0.kind == .prMerged }
        out += "\n## \(labels.pullRequests)\n\n"
        if opened.isEmpty && merged.isEmpty {
            out += "- \(labels.nothing)\n"
        } else {
            for e in opened { out += "- \(labels.opened): \(link(e.title, e.prURL))\n" }
            for e in merged { out += "- \(labels.merged): \(link(e.title, e.prURL))\n" }
        }

        out += "\n## \(labels.stillOpen)\n\n" + list(stillOpen, nothing: labels.nothing)
        out += "\n## \(labels.tomorrow)\n\n" + list(tomorrow, nothing: labels.nothing)
        return out
    }

    static func list(_ items: [Item], nothing: String) -> String {
        guard !items.isEmpty else { return "- \(nothing)\n" }
        return items.map { item in
            var line = "- " + link(item.text, item.url)
            if let d = firstLine(item.detail) { line += " — " + inline(d) }
            return line + "\n"
        }.joined()
    }

    static func link(_ text: String, _ url: String?) -> String {
        let t = inline(text)
        guard let url, !url.isEmpty else { return t }
        return "[\(t.replacingOccurrences(of: "]", with: "\\]"))](\(url))"
    }

    /// Single line, markdown-neutral enough for a list item.
    static func inline(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    /// Instruction for the optional "tidy with AI" button.
    public static func aiPrompt(markdown: String) -> String {
        "Aşağıdaki gün sonu notunu 5-8 maddelik, sade Türkçe bir özete çevir. Yalnız madde işaretli satırları yaz; "
            + "başlık, giriş ya da kapanış cümlesi ekleme. Olmayan bir şey uydurma.\n\n" + String(markdown.prefix(12_000))
    }
}

/// The prompt a review session starts with, from the project's template.
public enum ReviewPrompt {
    public static let defaultTemplate = "Review pull request {url} ({source} → {target}). Run `git diff origin/{target}...HEAD` to see the change. Use a code-review skill or command if one is available. List concrete findings with file:line and severity, most important first. Do not push, comment on the PR, approve or change anything; only report."

    public static let placeholders = ["{url}", "{number}", "{title}", "{source}", "{target}", "{repo}"]

    /// `template` (or the default when nil/blank) with the placeholders filled from `pr`.
    public static func render(_ template: String?, pr: PullRequest) -> String {
        let t = template?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (t?.isEmpty ?? true) ? defaultTemplate : t!
        let values: [String: String] = [
            "{url}": pr.url, "{number}": String(pr.number), "{title}": pr.title,
            "{source}": pr.sourceBranch, "{target}": pr.targetBranch, "{repo}": pr.repoLabel,
        ]
        // One pass, so a value that itself contains "{title}" isn't expanded again.
        var out = ""
        var rest = Substring(base)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            if let close = rest[open...].firstIndex(of: "}"), let v = values[String(rest[open...close])] {
                out += v
                rest = rest[rest.index(after: close)...]
            } else {
                out += "{"
                rest = rest[rest.index(after: open)...]
            }
        }
        return out + rest
    }
}

/// Output of `claude -p --output-format json`.
public enum ClaudePrintOutput {
    /// The `result` text, or nil when the call reported an error or the output isn't that JSON.
    public static func result(from output: String) -> String? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        if json["is_error"]?.bool == true { return nil }
        guard let text = json["result"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
