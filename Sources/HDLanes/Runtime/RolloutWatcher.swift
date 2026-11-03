import Foundation
import HDCore

/// Rollout files already followed by a session, so two Codex sessions in one folder don't both pick
/// the same file. Shared by all watchers; thread-safe.
final class RolloutClaims: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()

    var snapshot: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    func claim(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.insert(path).inserted
    }

    func release(_ path: String) {
        lock.lock()
        paths.remove(path)
        lock.unlock()
    }
}

/// Follows the rollout file of one Codex session: finds it (by thread id when resuming, else by cwd and
/// launch time), then reads complete new lines every second and hands parsed records to the main actor.
final class RolloutWatcher: @unchecked Sendable {
    let sessionID: UUID
    private let codexHome: String
    private let cwd: String
    private let launchedAt: Date
    private let resumeThreadID: String?
    private let claims: RolloutClaims
    private let onLines: @MainActor (RolloutWatcher, [CodexRolloutLine]) -> Void

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var fileURL: URL?
    private var offset: UInt64 = 0
    private var splitter = JSONLineSplitter()
    private var lastSearch = Date.distantPast
    private var stopped = false

    /// Search every second for the first two minutes, then every 5 s (Codex may create the file only
    /// when the first prompt is sent).
    static let fastSearchWindow: TimeInterval = 120
    static let slowSearchInterval: TimeInterval = 5
    /// Upper bound per read so one huge append can't stall the queue.
    static let maxReadPerTick = 8 << 20

    init(sessionID: UUID, codexHome: String, cwd: String, launchedAt: Date, resumeThreadID: String?,
         claims: RolloutClaims, onLines: @escaping @MainActor (RolloutWatcher, [CodexRolloutLine]) -> Void) {
        self.sessionID = sessionID
        self.codexHome = codexHome
        self.cwd = cwd
        self.launchedAt = launchedAt
        self.resumeThreadID = resumeThreadID
        self.claims = claims
        self.onLines = onLines
        self.queue = DispatchQueue(label: "hdlanes.rollout.\(sessionID.uuidString)", qos: .utility)
    }

    func start() {
        queue.async { [self] in
            guard timer == nil, !stopped else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            timer?.cancel()
            timer = nil
            if let url = fileURL { claims.release(url.path) }
            fileURL = nil
        }
    }

    // MARK: On `queue`

    private func tick() {
        guard !stopped else { return }
        if fileURL == nil { locate() }
        if fileURL != nil { readNewLines() }
    }

    private func locate() {
        let now = Date()
        if now.timeIntervalSince(launchedAt) > Self.fastSearchWindow,
           now.timeIntervalSince(lastSearch) < Self.slowSearchInterval { return }
        lastSearch = now

        if let thread = resumeThreadID,
           let url = CodexRollout.findRolloutFile(codexHome: codexHome, threadID: thread),
           claims.claim(url.path) {
            // Resuming appends to the thread's file: skip its history, follow what comes next.
            fileURL = url
            offset = Self.size(of: url) ?? 0
            return
        }
        guard let url = CodexRollout.findRolloutFile(codexHome: codexHome, cwd: cwd, launchedAt: launchedAt, now: now,
                                                     excluding: claims.snapshot),
              claims.claim(url.path) else { return }
        fileURL = url
        offset = 0
    }

    private func readNewLines() {
        guard let url = fileURL, let size = Self.size(of: url) else { return }
        if size < offset {
            // Rewritten or truncated: start over.
            offset = 0
            splitter = JSONLineSplitter()
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let count = Int(min(UInt64(Self.maxReadPerTick), size - offset))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else { return }
            offset += UInt64(data.count)
            let lines = splitter.append(data).compactMap(CodexRollout.parse(line:))
            guard !lines.isEmpty else { return }
            let deliver = onLines
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(self, lines) } }
        } catch {
            return
        }
    }

    private static func size(of url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }
}
