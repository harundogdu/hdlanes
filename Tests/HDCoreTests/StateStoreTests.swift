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
