import Foundation
import Testing
@testable import HDCore

struct ActivityLogTests {
    private func tempPaths() -> HDPaths {
        HDPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("hdlanes-test-\(UUID().uuidString)"))
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ s: String) -> Date { ISODate.parse(s)! }

    @Test func appendAndReadDay() throws {
        let paths = tempPaths()
        let log = ActivityLog(paths: paths)
        let session = UUID()
        try log.append(ActivityEvent(at: date("2026-11-02T23:30:00Z"), kind: .turnDone, sessionID: session, title: "Yesterday"),
                       calendar: utc)
        try log.append(ActivityEvent(at: date("2026-11-03T09:00:00Z"), kind: .sessionStarted, sessionID: session, title: "A"),
                       calendar: utc)
        try log.append(ActivityEvent(at: date("2026-11-03T10:00:00Z"), kind: .prOpened, title: "PR", prURL: "https://x/pr/1"),
                       calendar: utc)
        let today = log.events(on: date("2026-11-03T12:00:00Z"), calendar: utc)
        #expect(today.map(\.title) == ["A", "PR"])
        #expect(today[1].prURL == "https://x/pr/1")
        #expect(today[0].sessionID == session)
        let attrs = try FileManager.default.attributesOfItem(atPath: paths.activityFile.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test func detailIsClippedAndFlattened() {
        let long = String(repeating: "a", count: 800)
        let e = ActivityEvent(kind: .turnDone, title: "t\n\tx", detail: "line one\nline two \u{202E}" + long)
        #expect(e.title == "t x")
        #expect(e.detail!.count == ActivityEvent.detailLimit)
        #expect(e.detail!.hasPrefix("line one line two aaa"))
        #expect(e.detail!.hasSuffix("…"))
        #expect(ActivityEvent(kind: .error, title: "x", detail: "  \n ").detail == nil)
    }

    @Test func skipsBadLinesAndReadsOnlyTail() throws {
        let paths = tempPaths()
        let log = ActivityLog(paths: paths, tailBytes: 400)
        for i in 0..<20 {
            try log.append(ActivityEvent(at: date("2026-11-03T10:00:00Z").addingTimeInterval(Double(i)), kind: .turnDone,
                                         title: "event \(i)"), calendar: utc)
        }
        let handle = try FileHandle(forWritingTo: paths.activityFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n{\"kind\":\"unknownKind\",\"at\":\"2026-11-03T11:00:00Z\",\"title\":\"x\"}\n".utf8))
        try handle.close()
        let events = log.events(on: date("2026-11-03T00:00:00Z"), calendar: utc)
        #expect(!events.isEmpty)
        #expect(events.count < 20)
        #expect(events.last?.title == "event 19")
        // Whole lines only: every event decoded fully.
        #expect(events.allSatisfy { $0.title.hasPrefix("event ") })
    }

    @Test func rotatesAndStillReadsTheDay() throws {
        let paths = tempPaths()
        let log = ActivityLog(paths: paths, rotateBytes: 300)
        let now = date("2026-11-03T10:00:00Z")
        for i in 0..<6 {
            try log.append(ActivityEvent(at: now.addingTimeInterval(Double(i)), kind: .turnDone, title: "e\(i)"),
                           now: now, calendar: utc)
        }
        let rotated = paths.rotatedActivityFile("2026-11")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        let titles = log.events(on: now, calendar: utc).map(\.title)
        #expect(titles == ["e0", "e1", "e2", "e3", "e4", "e5"])
    }

    @Test func rotationAppendsToAnExistingMonthFile() throws {
        let paths = tempPaths()
        try HDPaths.ensurePrivateDir(paths.root)
        let rotated = paths.rotatedActivityFile("2026-11")
        let old = ActivityEvent(at: date("2026-11-01T08:00:00Z"), kind: .turnDone, title: "old")
        var line = try ActivityLog.makeEncoder().encode(old)
        line.append(0x0A)
        try line.write(to: rotated)
        let log = ActivityLog(paths: paths, rotateBytes: 10)
        let now = date("2026-11-03T10:00:00Z")
        try log.append(ActivityEvent(at: now, kind: .turnDone, title: "a"), now: now, calendar: utc)
        try log.append(ActivityEvent(at: now, kind: .turnDone, title: "b"), now: now, calendar: utc)
        let content = try String(contentsOf: rotated, encoding: .utf8)
        #expect(content.contains("\"old\""))
        #expect(content.contains("\"a\""))
        let range = log.events(from: date("2026-11-01T00:00:00Z"), to: date("2026-11-04T00:00:00Z"), calendar: utc)
        #expect(range.map(\.title) == ["old", "a", "b"])
    }

    @Test func debouncesIdenticalConsecutiveEventsPerSession() {
        var d = ActivityDebouncer(window: 600)
        func ok(_ e: ActivityEvent) -> Bool { d.accepts(e) }
        let s1 = UUID(), s2 = UUID()
        let t0 = date("2026-11-03T10:00:00Z")
        #expect(ok(ActivityEvent(at: t0, kind: .turnDone, sessionID: s1, title: "A", detail: "x")))
        #expect(!ok(ActivityEvent(at: t0.addingTimeInterval(5), kind: .turnDone, sessionID: s1, title: "A", detail: "x")))
        // Another session is independent.
        #expect(ok(ActivityEvent(at: t0.addingTimeInterval(5), kind: .turnDone, sessionID: s2, title: "A", detail: "x")))
        // A different event in between breaks the run.
        #expect(ok(ActivityEvent(at: t0.addingTimeInterval(6), kind: .needsYou, sessionID: s1, title: "A")))
        #expect(ok(ActivityEvent(at: t0.addingTimeInterval(7), kind: .turnDone, sessionID: s1, title: "A", detail: "x")))
        // Past the window the same event counts again.
        #expect(ok(ActivityEvent(at: t0.addingTimeInterval(900), kind: .turnDone, sessionID: s1, title: "A", detail: "x")))
        // Events without a subject are never dropped.
        #expect(ok(ActivityEvent(at: t0, kind: .taskMoved, title: "T")))
        #expect(ok(ActivityEvent(at: t0, kind: .taskMoved, title: "T")))
    }

    @Test func parsesDatesWithLongFractions() {
        #expect(ISODate.parse("2026-10-30T08:12:34.667673+00:00") == ISODate.parse("2026-10-30T08:12:34.667Z"))
        #expect(ISODate.parse("2026-10-30T08:12:34.1234567Z") != nil)
        #expect(ISODate.parse("2026-10-30T08:12:34Z") == Date(timeIntervalSince1970: 1_793_347_954))
        #expect(ISODate.parse("garbage") == nil)
        #expect(ISODate.parse(nil) == nil)
    }
}
