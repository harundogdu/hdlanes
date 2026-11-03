import Foundation

/// Loads and saves `state.json`. Never loses data: a file that fails to decode is copied aside
/// (`state.backup-<timestamp>.json`) before anything new is written, and the caller is told. A file
/// that exists but can't be read (or backed up) is reported as `.unreadable`; the caller must not save.
public struct StateStore: Sendable {
    public enum LoadResult: Sendable {
        case fresh(AppState)
        case loaded(AppState)
        /// The file existed but could not be decoded. It was preserved at `backupPath`.
        case recoveredFromCorruption(AppState, backupPath: String, error: String)
        /// The file exists but could not be read, or it could not be decoded and no backup could be
        /// written. The state is empty and the caller must not save, so the original stays untouched.
        case unreadable(AppState, reason: UnreadableReason, error: String)

        public var state: AppState {
            switch self {
            case .fresh(let s), .loaded(let s), .recoveredFromCorruption(let s, _, _), .unreadable(let s, _, _): return s
            }
        }
    }

    public enum UnreadableReason: Sendable, Equatable {
        /// Reading the file failed (permissions, a directory in its place, I/O).
        case readFailed
        /// The file didn't decode and the backup copy couldn't be written.
        case backupFailed
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
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Only a missing file is a first launch. Anything else (permissions, a directory in its
            // place, I/O) means the user's data may still be there.
            if Self.isFileMissing(error) { return .fresh(AppState()) }
            return .unreadable(AppState(), reason: .readFailed, error: error.localizedDescription)
        }
        let decodeError: Error
        do {
            return .loaded(try Self.makeDecoder().decode(AppState.self, from: data))
        } catch {
            decodeError = error
        }
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let backup = paths.root.appendingPathComponent("state.backup-\(stamp).json")
        do {
            try FileManager.default.copyItem(at: url, to: backup)
        } catch {
            return .unreadable(AppState(), reason: .backupFailed, error: error.localizedDescription)
        }
        return .recoveredFromCorruption(AppState(), backupPath: backup.path, error: String(describing: decodeError))
    }

    /// true when the read failed because nothing exists at the path (not for "exists but can't read").
    static func isFileMissing(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) { return true }
        return false
    }

    /// Atomic write (temp file + rename), file mode 0600.
    public func save(_ state: AppState) throws {
        try HDPaths.ensurePrivateDir(paths.root)
        let data = try Self.makeEncoder().encode(state)
        try data.write(to: paths.stateFile, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.stateFile.path)
    }
}
