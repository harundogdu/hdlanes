import Foundation

/// Loads and saves `state.json`. Never loses data: a file that fails to decode is copied aside
/// (`state.backup-<timestamp>.json`) before anything new is written, and the caller is told.
public struct StateStore: Sendable {
    public enum LoadResult: Sendable {
        case fresh(AppState)
        case loaded(AppState)
        /// The file existed but could not be decoded. It was preserved at `backupPath`.
        case recoveredFromCorruption(AppState, backupPath: String, error: String)

        public var state: AppState {
            switch self {
            case .fresh(let s), .loaded(let s), .recoveredFromCorruption(let s, _, _): return s
            }
        }
    }

    public let paths: HDPaths

    public init(paths: HDPaths) {
        self.paths = paths
    }

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func load(now: Date = Date()) -> LoadResult {
        let url = paths.stateFile
        guard let data = try? Data(contentsOf: url) else { return .fresh(AppState()) }
        do {
            return .loaded(try Self.makeDecoder().decode(AppState.self, from: data))
        } catch {
            let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
            let backup = paths.root.appendingPathComponent("state.backup-\(stamp).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            return .recoveredFromCorruption(AppState(), backupPath: backup.path, error: String(describing: error))
        }
    }

    /// Atomic write (temp file + rename), file mode 0600.
    public func save(_ state: AppState) throws {
        try HDPaths.ensurePrivateDir(paths.root)
        let data = try Self.makeEncoder().encode(state)
        try data.write(to: paths.stateFile, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.stateFile.path)
    }
}
