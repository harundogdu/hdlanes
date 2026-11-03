import Foundation
import Testing
@testable import HDCore

struct StateStoreTests {
    private func tempPaths() -> HDPaths {
        HDPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("hdlanes-test-\(UUID().uuidString)"))
    }

    @Test func missingFileStartsFresh() {
        let store = StateStore(paths: tempPaths())
        guard case .fresh = store.load() else { Issue.record("expected fresh"); return }
    }

    @Test func roundTripKeepsData() throws {
        let paths = tempPaths()
        let store = StateStore(paths: paths)
        var state = AppState()
        let project = Project(name: "demo", path: "/tmp/demo")
        state.projects = [project]
        state.accounts = [Account(provider: .claude, label: "Work", colorIndex: 1, isSystemDefault: false,
                                  configDir: "/tmp/x", authMethod: .browser)]
        state.usage["abc"] = AccountUsage(fiveHour: UsageWindow(usedPercent: 12, resetsAt: nil, windowMinutes: 300),
                                         week: nil, plan: "max", updatedAt: Date(timeIntervalSince1970: 0))
        try store.save(state)
        let loaded = store.load().state
        #expect(loaded.projects == [project])
        #expect(loaded.accounts.first?.label == "Work")
        #expect(loaded.usage["abc"]?.fiveHour?.usedPercent == 12)
    }

    @Test func corruptFileIsBackedUpNotLost() throws {
        let paths = tempPaths()
        try HDPaths.ensurePrivateDir(paths.root)
        try Data("{not json".utf8).write(to: paths.stateFile)
        let result = StateStore(paths: paths).load()
        guard case .recoveredFromCorruption(_, let backup, _) = result else { Issue.record("expected recovery"); return }
        #expect(FileManager.default.fileExists(atPath: backup))
        #expect(try String(contentsOfFile: backup, encoding: .utf8) == "{not json")
    }

    @Test func missingFileInExistingFolderStartsFresh() throws {
        let paths = tempPaths()
        try HDPaths.ensurePrivateDir(paths.root)
        guard case .fresh = StateStore(paths: paths).load() else { Issue.record("expected fresh"); return }
    }

    /// A state file that exists but can't be read must not look like a first launch: the app would
    /// save an empty state over it.
    @Test(.enabled(if: geteuid() != 0, "root reads mode-000 files"))
    func unreadableFileIsNotTreatedAsFresh() throws {
        let paths = tempPaths()
        let store = StateStore(paths: paths)
        var state = AppState()
        state.projects = [Project(name: "demo", path: "/tmp/demo")]
        try store.save(state)
        let original = try Data(contentsOf: paths.stateFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.stateFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.stateFile.path) }

        let result = store.load()
        guard case .unreadable(let s, let reason, _) = result else { Issue.record("expected unreadable, got \(result)"); return }
        #expect(reason == .readFailed)
        #expect(s.projects.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.stateFile.path)
        #expect(try Data(contentsOf: paths.stateFile) == original)
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        #expect(names == ["state.json"])
    }

    @Test(.enabled(if: geteuid() != 0, "root ignores directory permissions"))
    func unreadableFolderIsNotTreatedAsFresh() throws {
        let paths = tempPaths()
        try StateStore(paths: paths).save(AppState())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.root.path) }
        let result = StateStore(paths: paths).load()
        guard case .unreadable(_, .readFailed, _) = result else { Issue.record("expected unreadable, got \(result)"); return }
    }

    /// A corrupt file whose backup copy fails must not be reported as backed up.
    @Test func failedBackupIsUnreadableNotRecovered() throws {
        let paths = tempPaths()
        try HDPaths.ensurePrivateDir(paths.root)
        try Data("{not json".utf8).write(to: paths.stateFile)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let taken = paths.root.appendingPathComponent("state.backup-\(stamp).json")
        try Data("older backup".utf8).write(to: taken)

        let result = StateStore(paths: paths).load(now: now)
        guard case .unreadable(_, .backupFailed, _) = result else { Issue.record("expected unreadable, got \(result)"); return }
        #expect(try String(contentsOf: paths.stateFile, encoding: .utf8) == "{not json")
        #expect(try String(contentsOf: taken, encoding: .utf8) == "older backup")
    }

    @Test func olderFileWithMissingCollectionsLoads() throws {
        let paths = tempPaths()
        try HDPaths.ensurePrivateDir(paths.root)
        try Data(#"{"version":1,"projects":[]}"#.utf8).write(to: paths.stateFile)
        guard case .loaded(let s) = StateStore(paths: paths).load() else { Issue.record("expected loaded"); return }
        #expect(s.accounts.isEmpty && s.tasks.isEmpty)
    }

    @Test func accountDirIsStableAndHasNoTrailingSlash() {
        let paths = HDPaths(root: URL(fileURLWithPath: "/Users/x/.hdlanes/"))
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let dir = paths.accountDir(provider: .claude, id: id)
        #expect(dir == "/Users/x/.hdlanes/accounts/claude/00000000-0000-0000-0000-000000000001")
        #expect(!dir.hasSuffix("/"))
    }
}

struct UsageWindowTests {
    @Test func windowPastItsResetReadsEmpty() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let w = UsageWindow(usedPercent: 100, resetsAt: now.addingTimeInterval(-60), windowMinutes: 300)
        #expect(w.percent(at: now) == 0)
        #expect(w.hasReset(at: now))
        let live = UsageWindow(usedPercent: 42, resetsAt: now.addingTimeInterval(600), windowMinutes: 300)
        #expect(live.percent(at: now) == 42)
        #expect(UsageWindow(usedPercent: 7, resetsAt: nil, windowMinutes: nil).percent(at: now) == 7)
    }
}

struct LegacyStateTests {
    /// A state.json written before lastResult / lastResultAt / reviewPullRequestURL / reviewPromptTemplate
    /// existed must still load, with those fields nil.
    @Test func stateWithoutTrackingFieldsLoads() throws {
        let json = #"""
        {"version":1,"accounts":[],"tasks":[],"usage":{},"settings":{},
         "projects":[{"id":"00000000-0000-0000-0000-0000000000AA","name":"p","path":"/tmp/p"}],
         "sessions":[{"id":"00000000-0000-0000-0000-0000000000BB","projectID":"00000000-0000-0000-0000-0000000000AA",
                      "title":"t","provider":"claude","cwd":"/tmp/p","createdAt":"2026-11-01T10:00:00Z"}]}
        """#
        let state = try StateStore.makeDecoder().decode(AppState.self, from: Data(json.utf8))
        #expect(state.sessions.first?.lastResult == nil)
        #expect(state.sessions.first?.lastResultAt == nil)
        #expect(state.projects.first?.reviewPromptTemplate == nil)
    }
}
