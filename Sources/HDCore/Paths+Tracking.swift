import Foundation

// OWNER: tracking area.
extension HDPaths {
    /// Append-only activity log (one JSON object per line). Rotated to `activity-YYYY-MM.jsonl`.
    public var activityFile: URL { root.appendingPathComponent("activity.jsonl") }

    /// Rotated activity file for the month `stamp` (`YYYY-MM`).
    public func rotatedActivityFile(_ stamp: String) -> URL {
        root.appendingPathComponent("activity-\(stamp).jsonl")
    }

    /// Saved end-of-day reports (`YYYY-MM-DD.md`).
    public var reportsDir: URL { root.appendingPathComponent("reports", isDirectory: true) }
}
