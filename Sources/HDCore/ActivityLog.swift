import Foundation

// OWNER: tracking area.

/// One line of `~/.hdlanes/activity.jsonl`: something that happened to a session, a PR or a task.
/// Never holds secrets: `detail` is an agent's last message (trimmed) or a PR title.
public struct ActivityEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case sessionStarted, turnDone, needsYou, error, sessionClosed, prOpened, prMerged, reviewStarted, taskMoved
    }

    public static let detailLimit = 500
    public static let titleLimit = 200

    public var at: Date
    public var kind: Kind
    public var sessionID: UUID?
    public var projectID: UUID?
    public var title: String
    public var detail: String?
    public var prURL: String?

    public init(at: Date = Date(), kind: Kind, sessionID: UUID? = nil, projectID: UUID? = nil, title: String,
                detail: String? = nil, prURL: String? = nil) {
        self.at = at
        self.kind = kind
        self.sessionID = sessionID
        self.projectID = projectID
        self.title = Self.clip(title, limit: Self.titleLimit) ?? ""
        self.detail = Self.clip(detail, limit: Self.detailLimit)
        self.prURL = prURL
    }

    /// Control and format characters dropped, whitespace collapsed to single spaces, cut at `limit`
    /// characters (with "…"). nil when nothing is left.
    public static func clip(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control:
                if scalar == "\n" || scalar == "\t" || scalar == "\r" { out.append(" ") }
            case .format:
                continue
            default:
                out.append(scalar)
            }
        }
        let collapsed = String(out).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(0, limit - 1))) + "…"
    }
}

/// Lenient ISO 8601: with or without fractional seconds (any number of digits), `Z` or `±hh:mm`.
public enum ISODate {
    public static func parse(_ string: String?) -> Date? {
        guard var s = string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        // Fractions longer than milliseconds (Azure: ".667673", ".1234567") trip the formatter: cut to 3 digits.
        if let dot = s.firstIndex(of: "."), let t = s.firstIndex(of: "T"), dot > t {
            let digitsEnd = s[s.index(after: dot)...].firstIndex { !$0.isNumber } ?? s.endIndex
            let digits = s[s.index(after: dot)..<digitsEnd]
            let kept = digits.isEmpty ? "" : "." + String((digits + "000").prefix(3))
            s = String(s[..<dot]) + kept + String(s[digitsEnd...])
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    public static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

/// Reads and appends `activity.jsonl`. Reads only the last `tailBytes` of a file; the current file is
/// moved to `activity-YYYY-MM.jsonl` (month of the rotation) once it passes `rotateBytes`. Events of a
/// day that straddles a rotation are read from both files.
public struct ActivityLog: Sendable {
    public static let rotateBytes = 5 << 20
    public static let tailBytes = 2 << 20

    public let paths: HDPaths
    public var rotateBytes: Int
    public var tailBytes: Int

    public init(paths: HDPaths, rotateBytes: Int = ActivityLog.rotateBytes, tailBytes: Int = ActivityLog.tailBytes) {
        self.paths = paths
        self.rotateBytes = rotateBytes
        self.tailBytes = tailBytes
    }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISODate.string(date))
        }
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISODate.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date")
            }
            return date
        }
        return d
    }

    public func append(_ event: ActivityEvent, now: Date = Date(), calendar: Calendar = .current) throws {
        try HDPaths.ensurePrivateDir(paths.root)
        try rotateIfNeeded(now: now, calendar: calendar)
        var line = try Self.makeEncoder().encode(event)
        line.append(0x0A)
        let url = paths.activityFile
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Moves a current file over `rotateBytes` aside. A rotated file of the same month is appended to,
    /// never replaced.
    public func rotateIfNeeded(now: Date = Date(), calendar: Calendar = .current) throws {
        let url = paths.activityFile
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > rotateBytes else { return }
        let target = paths.rotatedActivityFile(Self.monthStamp(now, calendar: calendar))
        if fm.fileExists(atPath: target.path) {
            let data = try Data(contentsOf: url)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try fm.removeItem(at: url)
        } else {
            try fm.moveItem(at: url, to: target)
        }
    }

    /// `YYYY-MM` of `date` in `calendar`.
    public static func monthStamp(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    public func events(on day: Date, calendar: Calendar = .current) -> [ActivityEvent] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return events(from: start, to: end, calendar: calendar)
    }

    /// Events with `start <= at < end`, oldest first.
    public func events(from start: Date, to end: Date, calendar: Calendar = .current) -> [ActivityEvent] {
        let current = readTail(paths.activityFile)
        var all: [ActivityEvent] = []
        // The current file covers the range when it is read whole and starts before it.
        let covered = !current.truncated && (current.events.first.map { $0.at <= start } ?? false)
        if !covered {
            let first = Self.monthStamp(start, calendar: calendar)
            let lastDate = calendar.date(byAdding: .month, value: 1, to: end) ?? end
            let last = Self.monthStamp(lastDate, calendar: calendar)
            for url in rotatedFiles() {
                let stamp = String(url.deletingPathExtension().lastPathComponent.dropFirst("activity-".count))
                guard stamp >= first && stamp <= last else { continue }
                all += readTail(url).events
            }
        }
        all += current.events
        // Stable: events with the same timestamp keep file order.
        return all.enumerated().filter { $0.element.at >= start && $0.element.at < end }
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
    }

    func rotatedFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.root.path)) ?? []
        return names.filter { $0.hasPrefix("activity-") && $0.hasSuffix(".jsonl") }.sorted()
            .map { paths.root.appendingPathComponent($0) }
    }

    /// Decodable lines of the last `tailBytes` of `url`. A partial first line and bad lines are skipped.
    func readTail(_ url: URL) -> (events: [ActivityEvent], truncated: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], false) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return ([], false) }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return ([], false) }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        let decoder = Self.makeDecoder()
        let events = lines.compactMap { try? decoder.decode(ActivityEvent.self, from: Data($0)) }
        return (events, offset > 0)
    }
}

/// Drops an event identical (kind, title, detail) to the last one recorded for the same session (or PR)
/// within `window`. Status can flap (OSC 7501 and hooks both report a turn's end); one line is enough.
public struct ActivityDebouncer: Sendable {
    struct Last: Sendable {
        var key: String
        var at: Date
    }

    public var window: TimeInterval
    var last: [String: Last] = [:]

    public init(window: TimeInterval = 30 * 60) {
        self.window = window
    }

    public mutating func accepts(_ event: ActivityEvent) -> Bool {
        guard let subject = event.sessionID?.uuidString ?? event.prURL else { return true }
        let key = [event.kind.rawValue, event.title, event.detail ?? ""].joined(separator: "\u{1F}")
        if let prev = last[subject], prev.key == key, event.at.timeIntervalSince(prev.at) < window { return false }
        last[subject] = Last(key: key, at: event.at)
        return true
    }
}
