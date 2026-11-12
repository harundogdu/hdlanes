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

    /// A session that finished turns that day: its last result, how many turns, when.
    public struct Done: Equatable, Sendable, Identifiable {
        public var id: String
        public var sessionID: UUID?
        public var title: String
        public var project: String?
        public var turns: Int
        public var at: Date
        /// First line of the last result.
        public var result: String?
    }

    /// A pull request opened or merged that day.
    public struct PullRequestLine: Equatable, Sendable {
        public var title: String
        public var url: String?
    }

    /// The day's report as data, for the screen; `markdown` writes the same thing as text.
    public struct Report: Equatable, Sendable {
        public var done: [Done]
        public var opened: [PullRequestLine]
        public var merged: [PullRequestLine]
        public var stillOpen: [Item]
        public var tomorrow: [Item]
    }

    /// `events` are the day's activity events (any order); `projectNames` labels them. Finished turns
    /// are grouped per session (latest result wins), in order of their last turn.
    public static func report(events: [ActivityEvent], stillOpen: [Item], tomorrow: [Item],
                              projectNames: [UUID: String]) -> Report {
        let sorted = events.sorted { $0.at < $1.at }
        var order: [String] = []
        var lastDone: [String: ActivityEvent] = [:]
        var turns: [String: Int] = [:]
        for e in sorted where e.kind == .turnDone {
            let key = e.sessionID?.uuidString ?? e.title
            if lastDone[key] == nil { order.append(key) }
            lastDone[key] = e
            turns[key, default: 0] += 1
        }
        let done = order.compactMap { key -> Done? in
            guard let e = lastDone[key] else { return nil }
            return Done(id: key, sessionID: e.sessionID, title: inline(e.title),
                        project: e.projectID.flatMap { projectNames[$0] }.map(inline),
                        turns: turns[key] ?? 1, at: e.at, result: firstLine(e.detail).map(inline))
        }.sorted { $0.at < $1.at }
        return Report(done: done,
                      opened: sorted.filter { $0.kind == .prOpened }.map { PullRequestLine(title: $0.title, url: $0.prURL) },
                      merged: sorted.filter { $0.kind == .prMerged }.map { PullRequestLine(title: $0.title, url: $0.prURL) },
                      stillOpen: stillOpen, tomorrow: tomorrow)
    }

    /// The report as markdown, to copy or save. `time` formats a time of day.
    public static func markdown(events: [ActivityEvent], stillOpen: [Item], tomorrow: [Item],
                                projectNames: [UUID: String], labels: Labels, time: (Date) -> String) -> String {
        markdown(report(events: events, stillOpen: stillOpen, tomorrow: tomorrow, projectNames: projectNames),
                 labels: labels, time: time)
    }

    public static func markdown(_ r: Report, labels: Labels, time: (Date) -> String) -> String {
        var out = "# \(labels.title)\n"
        out += "\n## \(labels.done)\n\n"
        if r.done.isEmpty {
            out += "- \(labels.nothing)\n"
        } else {
            for d in r.done {
                var line = "- **\(d.title)**"
                if let p = d.project { line += " (\(p))" }
                if d.turns > 1 { line += " ×\(d.turns)" }
                line += " · \(time(d.at))"
                if let first = d.result { line += "\n  \(first)" }
                out += line + "\n"
            }
        }
        out += "\n## \(labels.pullRequests)\n\n"
        if r.opened.isEmpty && r.merged.isEmpty {
            out += "- \(labels.nothing)\n"
        } else {
            for e in r.opened { out += "- \(labels.opened): \(link(e.title, e.url))\n" }
            for e in r.merged { out += "- \(labels.merged): \(link(e.title, e.url))\n" }
        }
        out += "\n## \(labels.stillOpen)\n\n" + list(r.stillOpen, nothing: labels.nothing)
        out += "\n## \(labels.tomorrow)\n\n" + list(r.tomorrow, nothing: labels.nothing)
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

    /// The readable message of a failed call (`"type":"result","is_error":true,"result":"Invalid API key …"`),
    /// from either `--output-format json` (one object) or `stream-json` (one object per line). nil otherwise,
    /// so callers never show the raw JSON instead.
    public static func errorText(from output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                  json["type"]?.string == "result", json["is_error"]?.bool == true else { continue }
            // A line that says is_error always yields something: its text, its first error, or its subtype.
            let candidates = [json["result"]?.string, json["errors"]?.array?.first?.string, json["subtype"]?.string]
            for case let text? in candidates.map({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) where !text.isEmpty {
                return String(text.prefix(300))
            }
            return "error"
        }
        return nil
    }
}
