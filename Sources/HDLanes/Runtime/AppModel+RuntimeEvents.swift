import AppKit
import Foundation
import HDCore
import SwiftTerm

/// Event intake and status post-processing: hook messages, Codex rollout lines, the foreground-process
/// monitor, unread marks, notifications and the Dock badge.
/// OWNER: runtime area.
extension AppModel {
    var homeDirectory: String { FileManager.default.homeDirectoryForCurrentUser.path }

    // MARK: Hook server

    func startHookServer() {
        let services = runtimeServices
        guard services.hookServer == nil else { return }
        let server = HookServer(path: paths.socketPath, onMessage: { [weak self] message, connection in
            self?.handleHook(message, connection: connection)
        }, onWaitingClosed: { [weak self] connection in
            self?.handleHookConnectionClosed(connection)
        })
        do {
            try server.start()
            services.hookServer = server
        } catch {
            show(error: error, title: L.hookServerFailedTitle)
        }
    }

    /// One message from `hdlanes-hook`. `connection` is set for a PermissionRequest waiting for an answer.
    func handleHook(_ message: HookMessage, connection: HookServer.ConnectionID?) {
        let services = runtimeServices
        guard let id = UUID(uuidString: message.session), let session = session(id), session.provider == .claude else {
            if let connection { services.hookServer?.reply(connection, HookReply(decision: .none)) }
            return
        }
        let now = Date()
        if message.event == "StatusLine" {
            handleStatusLine(message.payload, session: session, now: now)
            return
        }
        let rt = runtime(for: id)
        var snapshot = rt.snapshot
        var reducer = services.reducers[id] ?? ClaudeEventReducer()
        reducer.apply(event: message.event, payload: message.payload, to: &snapshot, now: now)

        if message.event == ClaudePluginFiles.permissionEvent, let connection {
            if snapshot.pendingPermission != nil, state.settings.permissionsInSidebar != false {
                if let previous = services.permissionConnections[id], previous != connection {
                    services.hookServer?.reply(previous, HookReply(decision: .none))
                }
                services.permissionConnections[id] = connection
                snapshot.pendingPermission?.canAnswer = true
            } else {
                // Not answerable here (a question, or the setting is off): Claude shows its own prompt.
                services.hookServer?.reply(connection, HookReply(decision: .none))
            }
        }
        if message.event == "StopFailure" {
            switch snapshot.status {
            case .error(let code): snapshot.status = .error(L.agentError(code))
            case .needsYou(.auth, let code?): snapshot.status = .needsYou(.auth, detail: L.agentError(code))
            default: break
            }
        }
        if let agentID = snapshot.agentSessionID, !agentID.isEmpty, agentID != session.agentSessionID {
            updateSession(id) { $0.agentSessionID = agentID }
        }
        touchActivity(id, now: now)
        commit(id, snapshot: snapshot, reducer: reducer)
    }

    func handleHookConnectionClosed(_ connection: HookServer.ConnectionID) {
        let services = runtimeServices
        guard let id = services.permissionConnections.first(where: { $0.value == connection })?.key else { return }
        services.permissionConnections[id] = nil
        let rt = runtime(for: id)
        var snapshot = rt.snapshot
        let reducer = services.reducers[id] ?? ClaudeEventReducer()
        reducer.permissionConnectionClosed(in: &snapshot)
        commit(id, snapshot: snapshot, reducer: reducer)
    }

    private func handleStatusLine(_ payload: JSONValue, session: AgentSession, now: Date) {
        let rt = runtime(for: session.id)
        if let percent = UsageParser.contextPercent(fromStatusLine: payload), rt.snapshot.contextUsedPercent != percent {
            rt.snapshot.contextUsedPercent = percent
        }
        if let accountID = session.accountID, let usage = UsageParser.claudeUsage(fromStatusLine: payload, now: now) {
            storeUsage(usage, for: accountID)
        }
    }

    /// Keeps the newest reading per account; skips saves when nothing changed (status lines are frequent).
    func storeUsage(_ usage: AccountUsage, for accountID: UUID) {
        let key = accountID.uuidString
        let old = state.usage[key]
        if let old, old.updatedAt > usage.updatedAt { return }
        let merged = UsageParser.merge(old, usage)
        if let old, UsageParser.sameReading(old, merged), merged.updatedAt.timeIntervalSince(old.updatedAt) < 60 { return }
        state.usage[key] = merged
    }

    // MARK: Codex

    func startRolloutWatcher(_ id: UUID, account: Account?, cwd: String, resumeThreadID: String?) {
        let services = runtimeServices
        services.watchers.removeValue(forKey: id)?.stop()
        let watcher = RolloutWatcher(sessionID: id, codexHome: CodexRollout.codexHome(for: account, homeDirectory: homeDirectory),
                                     cwd: cwd, launchedAt: Date(), resumeThreadID: resumeThreadID,
                                     claims: services.rolloutClaims) { [weak self] watcher, lines in
            self?.handleRolloutLines(from: watcher, lines)
        }
        services.watchers[id] = watcher
        watcher.start()
    }

    func handleRolloutLines(from watcher: RolloutWatcher, _ lines: [CodexRolloutLine]) {
        let id = watcher.sessionID
        // A batch from a watcher replaced by a relaunch belongs to the previous run.
        guard runtimeServices.watchers[id] === watcher, let session = session(id) else { return }
        let rt = runtime(for: id)
        var snapshot = rt.snapshot
        let now = Date()
        for line in lines {
            CodexRollout.apply(line.record, to: &snapshot, now: now)
            if case .tokenCount(let limits?, _) = line.record, let accountID = session.accountID,
               let usage = UsageParser.codexUsage(fromRateLimits: limits, now: line.timestamp ?? now) {
                storeUsage(usage, for: accountID)
            }
        }
        if let thread = snapshot.agentSessionID, !thread.isEmpty, thread != session.agentSessionID {
            updateSession(id) { $0.agentSessionID = thread }
        }
        touchActivity(id, now: now)
        commit(id, snapshot: snapshot, reducer: nil)
    }

    /// Fills every Codex account's meter from its newest rollout files (read-only, no tokens spent).
    func seedCodexUsage() {
        let home = homeDirectory
        for account in accounts(for: .codex) {
            let codexHome = CodexRollout.codexHome(for: account, homeDirectory: home)
            let accountID = account.id
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let found = CodexRollout.latestRateLimits(codexHome: codexHome),
                      let usage = UsageParser.codexUsage(fromRateLimits: found.rateLimits,
                                                         now: found.at ?? Date(timeIntervalSince1970: 0)) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.storeUsage(usage, for: accountID) } }
            }
        }
    }

    // MARK: Login shell PATH

    /// Reads the login shell's PATH once, in the background, for `environment(for:)`.
    func captureLoginPath() {
        let processEnv = ProcessInfo.processInfo.environment
        let shell = EnvBuilder.commandShell(processEnv)
        let env = EnvBuilder.baseEnvironment(processEnv)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let path = Self.readLoginPath(shell: shell, environment: env)
            DispatchQueue.main.async { MainActor.assumeIsolated { if let path { self?.runtimeServices.loginPath = path } } }
        }
    }

    nonisolated static func readLoginPath(shell: String, environment: [String: String]) -> String? {
        let marker = "__HDLANES_PATH__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '\\n\(marker)%s\(marker)\\n' \"$PATH\""]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let reader = pipe.fileHandleForReading
        let lock = NSLock()
        var output = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                lock.lock()
                output.append(chunk)
                lock.unlock()
            }
            group.leave()
        }
        if group.wait(timeout: .now() + 5) == .timedOut { process.terminate() }
        lock.lock()
        let text = String(decoding: output, as: UTF8.self)
        lock.unlock()
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // MARK: Foreground process monitor

    /// true when the session's shell (not the agent or another job) owns the terminal; nil when unknown.
    func foregroundIsShell(_ id: UUID) -> Bool? {
        guard let process = terminals.existingView(for: id)?.process, process.running else { return nil }
        let fd = process.childfd
        let shell = process.shellPid
        guard fd >= 0, shell > 0 else { return nil }
        let foreground = tcgetpgrp(fd)
        guard foreground > 0 else { return nil }
        return foreground == getpgid(shell)
    }

    /// Every 2 s: notices an agent that quit inside its shell (Codex has no exit event; Claude's
    /// SessionEnd can be missed) and moves a session out of "starting" once its agent is running.
    func monitorForegroundProcesses() {
        let services = runtimeServices
        let now = Date()
        for (id, rt) in runtimes {
            guard rt.isProcessRunning, let session = session(id), session.provider.isAgent,
                  let shellInFront = foregroundIsShell(id) else { continue }
            if !shellInFront {
                services.agentSeenInForeground.insert(id)
                services.shellForegroundTicks[id] = 0
                if rt.snapshot.status == .starting, let started = rt.startedAt, now.timeIntervalSince(started) > 4 {
                    var snapshot = rt.snapshot
                    snapshot.status = .ready
                    commit(id, snapshot: snapshot, reducer: nil)
                }
            } else if services.agentSeenInForeground.contains(id) {
                // Two ticks in a row, so the gap between a setup command and the agent doesn't count.
                let ticks = (services.shellForegroundTicks[id] ?? 0) + 1
                services.shellForegroundTicks[id] = ticks
                if ticks >= 2 { agentExitedInShell(id) }
            }
        }
    }

    private func agentExitedInShell(_ id: UUID) {
        let services = runtimeServices
        services.agentSeenInForeground.remove(id)
        services.shellForegroundTicks[id] = nil
        services.watchers.removeValue(forKey: id)?.stop()
        let rt = runtime(for: id)
        if case .exited = rt.snapshot.status { return }
        var snapshot = rt.snapshot
        snapshot.status = .exited(nil)
        snapshot.pendingPermission = nil
        for i in snapshot.subagents.indices where snapshot.subagents[i].isRunning {
            snapshot.subagents[i].isRunning = false
            snapshot.subagents[i].endedAt = Date()
        }
        for i in snapshot.activity.indices where snapshot.activity[i].isRunning { snapshot.activity[i].isRunning = false }
        commit(id, snapshot: snapshot, reducer: ClaudeEventReducer())
    }

    // MARK: Status post-processing

    /// Fresh live state for a (re)launch; the persisted session is untouched.
    func resetLiveState(_ id: UUID, agentSessionID: String?) {
        let services = runtimeServices
        if let connection = services.permissionConnections.removeValue(forKey: id) {
            services.hookServer?.reply(connection, HookReply(decision: .none))
        }
        services.watchers.removeValue(forKey: id)?.stop()
        services.reducers[id] = ClaudeEventReducer()
        services.agentSeenInForeground.remove(id)
        services.shellForegroundTicks[id] = nil
        let rt = runtime(for: id)
        var snapshot = AgentRuntimeSnapshot(status: .starting)
        snapshot.agentSessionID = agentSessionID
        rt.snapshot = snapshot
        rt.unread = false
    }

    /// Stores a new snapshot and reacts to the status change.
    func commit(_ id: UUID, snapshot: AgentRuntimeSnapshot, reducer: ClaudeEventReducer?) {
        let services = runtimeServices
        if let reducer { services.reducers[id] = reducer }
        // The card is gone (tool ran, turn ended…): let a still-waiting hook exit so Claude carries on.
        if snapshot.pendingPermission == nil, let connection = services.permissionConnections.removeValue(forKey: id) {
            services.hookServer?.reply(connection, HookReply(decision: .none))
        }
        let rt = runtime(for: id)
        let old = rt.snapshot.status
        if rt.snapshot != snapshot { rt.snapshot = snapshot }
        statusChanged(id, from: old, to: snapshot.status)
    }

    private func statusChanged(_ id: UUID, from old: AgentStatus, to new: AgentStatus) {
        guard old != new else { return }
        let becameDone = new == .done
        var becameNeedsYou = false
        if case .needsYou(let kind, _) = new {
            if case .needsYou(let oldKind, _) = old { becameNeedsYou = kind != oldKind } else { becameNeedsYou = true }
        }
        if becameDone || becameNeedsYou {
            let looking = NSApp.isActive && selectedSessionID == id
            if !looking {
                runtime(for: id).unread = true
                notify(id, status: new)
            }
        }
        updateDockBadge()
    }

    private func notify(_ id: UUID, status: AgentStatus) {
        guard let notifier = runtimeServices.notifier, let session = session(id) else { return }
        let body: String
        let sound: Bool
        switch status {
        case .needsYou(let kind, let detail):
            guard state.settings.notifyNeedsYou != false else { return }
            body = [L.notifyNeedsYou(kind), detail.map(Self.displayText)].compactMap { $0 }.joined(separator: "\n")
            sound = true
        case .done:
            guard state.settings.notifyDone != false else { return }
            let last = runtime(for: id).snapshot.lastAssistantMessage.map { String(Self.displayText($0).prefix(200)) }
            body = last.flatMap { $0.isEmpty ? nil : $0 } ?? L.notifyDone
            sound = false
        default:
            return
        }
        let title = session.title.isEmpty ? (project(session.projectID)?.name ?? L.appName) : session.title
        notifier.post(sessionID: id, title: title, body: body, sound: sound)
    }

    func updateDockBadge() {
        let count = visibleSessions.filter { runtimes[$0.id]?.status.needsUser == true }.count
        let label = count > 0 ? String(count) : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// Saves `lastActivityAt` at most every 30 s per session (each write saves state.json).
    func touchActivity(_ id: UUID, now: Date) {
        let services = runtimeServices
        if let last = services.activitySavedAt[id], now.timeIntervalSince(last) < 30 { return }
        services.activitySavedAt[id] = now
        updateSession(id) { $0.lastActivityAt = now }
    }

    /// Text from the terminal (OSC 7501, title) or the agent, made safe to show outside the grid:
    /// control, bidi-override and invisible format characters removed, whitespace collapsed.
    nonisolated static func displayText(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control:
                if scalar == "\n" || scalar == "\t" { out.append(" ") }
            case .format:
                continue
            default:
                out.append(scalar)
            }
        }
        return String(out).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
