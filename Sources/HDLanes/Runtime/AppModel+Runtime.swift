import AppKit
import Foundation
import HDCore
import SwiftTerm

/// Long-lived runtime objects (hook socket server, Codex rollout watchers, timers).
/// OWNER: runtime area. Add stored properties here freely.
@MainActor
final class RuntimeServices {
    var started = false
    var hookServer: HookServer?
    /// Absolute path of `hdlanes-hook`; nil when it wasn't found (agents then run without hooks).
    var hookPath: String?
    var pluginInstalled = false
    var warnedAboutHook = false
    /// Per Claude session: the reducer's bookkeeping next to `SessionRuntime.snapshot`.
    var reducers: [UUID: ClaudeEventReducer] = [:]
    /// Session → the PermissionRequest hook connection waiting for our answer and the card it created
    /// (at most one per session).
    var permissionConnections: [UUID: PermissionWait] = [:]
    var watchers: [UUID: RolloutWatcher] = [:]
    let rolloutClaims = RolloutClaims()
    /// Throttles `AgentSession.lastActivityAt` writes (each one saves state.json).
    var activitySavedAt: [UUID: Date] = [:]
    /// Login shell PATH, for one-off CLI calls from a Finder-launched app.
    var loginPath: String?
    var notifier: RuntimeNotifier?
    var observers: [NSObjectProtocol] = []
    var monitorTimer: Timer?
    /// Sessions whose agent was seen in the terminal's foreground since launch.
    var agentSeenInForeground: Set<UUID> = []
    /// Consecutive monitor ticks that found the shell back in the foreground.
    var shellForegroundTicks: [UUID: Int] = [:]
}

/// A PermissionRequest hook waiting for our answer, and the id of the card it created.
struct PermissionWait: Equatable {
    var connection: HookServer.ConnectionID
    var permissionID: String
}

// OWNER: runtime area. Signatures are a contract used by the UI and Git areas; keep them.
extension AppModel {
    /// Installs the Claude plugin, starts the hook socket server and usage seeding.
    func startRuntimeServices() {
        let services = runtimeServices
        guard !services.started else { return }
        services.started = true
        do {
            try HDPaths.ensurePrivateDir(paths.root)
            try HDPaths.ensurePrivateDir(paths.runDir)
        } catch {
            show(error: error, title: L.hookServerFailedTitle)
        }
        refreshClaudePlugin()
        startHookServer()
        seedCodexUsage()
        captureLoginPath()
        if RuntimeNotifier.isAvailable {
            let notifier = RuntimeNotifier()
            notifier.onOpen = { [weak self] id in
                guard let self, self.session(id) != nil else { return }
                self.selection = .session(id)
                self.markSeen(id)
            }
            services.notifier = notifier
        }
        let active = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.selectedSessionID else { return }
                self.markSeen(id)
            }
        }
        services.observers.append(active)
        services.monitorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitorForegroundProcesses() }
        }
    }

    func stopRuntimeServices() {
        let services = runtimeServices
        services.monitorTimer?.invalidate()
        services.monitorTimer = nil
        services.observers.forEach { NotificationCenter.default.removeObserver($0) }
        services.observers.removeAll()
        services.watchers.values.forEach { $0.stop() }
        services.watchers.removeAll()
        services.permissionConnections.removeAll()
        services.hookServer?.stop()
        services.hookServer = nil
        services.started = false
    }

    /// Rewrites the Claude plugin for the current hook path and settings. New Claude sessions pick it
    /// up; running ones keep what they loaded. Call again after `permissionsInSidebar` changes.
    func refreshClaudePlugin() {
        let services = runtimeServices
        services.hookPath = PluginInstaller.locateHookBinary()
        guard let hook = services.hookPath else {
            services.pluginInstalled = false
            if !services.warnedAboutHook {
                services.warnedAboutHook = true
                alert = AppAlert(title: L.hookMissingTitle, message: L.hookMissingBody)
            }
            return
        }
        do {
            try PluginInstaller.install(paths: paths, hookPath: hook,
                                        includePermissionRequest: state.settings.permissionsInSidebar != false)
            services.pluginInstalled = true
        } catch {
            services.pluginInstalled = false
            show(error: error, title: L.pluginInstallFailedTitle)
        }
    }

    /// Starts (or resumes) the agent of a session in its terminal.
    func launch(_ sessionID: UUID, resume: Bool) {
        guard let session = session(sessionID) else { return }
        let rt = runtime(for: sessionID)
        let shellAlive = terminals.isRunning(sessionID)
        if shellAlive {
            // Restart only in a shell whose agent has ended; never type a command into a running agent.
            guard case .exited = rt.status, foregroundIsShell(sessionID) == true else { return }
        }
        guard FileManager.default.fileExists(atPath: session.cwd) else {
            alert = AppAlert(title: L.launchFailedTitle, message: L.launchFolderMissing(session.cwd))
            return
        }
        let processEnv = ProcessInfo.processInfo.environment

        guard session.provider.isAgent else {
            guard !shellAlive else { return }
            rt.snapshot = AgentRuntimeSnapshot(status: .notStarted)
            terminals.start(sessionID, spec: EnvBuilder.shellSpec(cwd: session.cwd, processEnv: processEnv))
            return
        }

        let account = account(session.accountID)
        if session.accountID != nil && account == nil {
            alert = AppAlert(title: L.launchFailedTitle, message: L.launchAccountMissing)
            return
        }
        if let account, !account.isSystemDefault {
            guard let dir = account.configDir, !dir.isEmpty else {
                alert = AppAlert(title: L.launchFailedTitle, message: L.launchAccountDirMissing)
                return
            }
            // CODEX_HOME must exist; creating a missing Claude dir only means "logged out".
            prepareAccountDir(dir)
        }

        // Initial prompt and setup command belong to the very first launch only.
        let firstLaunch = !resume && rt.startedAt == nil && session.lastActivityAt == nil
        var resumeAgent = resume
        var agentSessionID: String?
        switch session.provider {
        case .claude:
            if resume, let existing = session.agentSessionID, !existing.isEmpty {
                agentSessionID = existing
            } else {
                // `--session-id` refuses an id that already has a conversation.
                resumeAgent = false
                agentSessionID = (firstLaunch ? session.agentSessionID : nil) ?? UUID().uuidString.lowercased()
            }
        case .codex:
            if resume, let thread = session.agentSessionID, !thread.isEmpty {
                agentSessionID = thread
            } else {
                resumeAgent = false
            }
        case .shell:
            break
        }

        var setup: String?
        if firstLaunch, session.worktreePath != nil,
           let command = project(session.projectID)?.setupCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            setup = command
        }

        var pluginDir: String?
        var settingsPath: String?
        var chain: String?
        let services = runtimeServices
        if session.provider == .claude, services.pluginInstalled, let hook = services.hookPath {
            pluginDir = HDPaths.normalizedDirString(paths.claudePluginDir.path)
            settingsPath = try? PluginInstaller.writeSessionSettings(paths: paths, sessionID: sessionID, hookPath: hook)
            if settingsPath != nil {
                chain = PluginInstaller.userStatusLineCommand(for: account, homeDirectory: homeDirectory)
            }
        }

        let agentLaunch = EnvBuilder.AgentLaunch(
            provider: session.provider, account: account, title: session.title, agentSessionID: agentSessionID,
            resume: resumeAgent, initialPrompt: firstLaunch ? session.initialPrompt : nil, pluginDir: pluginDir,
            settingsPath: settingsPath, setupCommand: setup, setupFailedNotice: L.setupCommandFailed)

        resetLiveState(sessionID, agentSessionID: agentSessionID)
        if shellAlive {
            // The agent exited and left its shell: start it there.
            // Ctrl-U first: whatever the user left half-typed at the prompt must not be glued in front
            // of the agent command and run with it.
            terminals.sendRaw(sessionID, "\u{15}")
            terminals.paste(sessionID, EnvBuilder.agentCommand(agentLaunch), submit: true)
            rt.startedAt = Date()
        } else {
            let vars = EnvBuilder.SessionVariables(socketPath: paths.socketPath, sessionID: sessionID,
                                                   accountID: account?.id, statusLineChain: chain)
            terminals.start(sessionID, spec: EnvBuilder.launchSpec(agentLaunch, session: vars, cwd: session.cwd,
                                                                   processEnv: processEnv))
        }
        if session.provider == .claude, let agentSessionID, session.agentSessionID != agentSessionID {
            updateSession(sessionID) { $0.agentSessionID = agentSessionID }
        }
        // Also marks the session as launched, so a later fresh start won't repeat the prompt or setup.
        touchActivity(sessionID, now: Date())
        if firstLaunch { recordActivity(.sessionStarted, sessionID: sessionID) }
        if session.provider == .codex {
            startRolloutWatcher(sessionID, account: account, cwd: session.cwd,
                                resumeThreadID: resumeAgent ? agentSessionID : nil)
        }
        updateDockBadge()
    }

    /// Stops the agent process of a session (the terminal view stays).
    func stop(_ sessionID: UUID) {
        guard let process = terminals.existingView(for: sessionID)?.process, process.running else { return }
        let shell = process.shellPid
        // An interactive shell ignores SIGTERM, and the agent runs in its own process group: hang up
        // the whole terminal session, like closing a tab.
        ProcessTree.hangUp(session: shell)
        terminals.terminate(sessionID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, let p = self.terminals.existingView(for: sessionID)?.process, p.running, p.shellPid == shell else { return }
            ProcessTree.killAll(session: shell)
        }
    }

    /// Ends every session's processes before the app quits; nothing keeps running without its terminal.
    func terminateAllSessionsForQuit() {
        ProcessTree.terminate(sessions: terminals.runningShellPids(), timeout: 1.5)
    }

    /// Pastes text into the session's agent; `submit` presses Return.
    func sendText(_ text: String, to sessionID: UUID, submit: Bool) {
        terminals.paste(sessionID, text, submit: submit)
    }

    /// Answers the pending Claude permission request `permissionID` from the sidebar. Does nothing when
    /// another request has replaced that card meanwhile, so a decision never lands on a request the
    /// user didn't read.
    func respondToPermission(sessionID: UUID, permissionID: String, allow: Bool, message: String?) {
        guard let rt = runtimes[sessionID], let pending = rt.snapshot.pendingPermission,
              pending.id == permissionID else { return }
        let services = runtimeServices
        var snapshot = rt.snapshot
        var reducer = services.reducers[sessionID] ?? ClaudeEventReducer()
        if pending.canAnswer, let wait = services.permissionConnections[sessionID] {
            // canAnswer is only set together with the connection that created this card.
            guard wait.permissionID == permissionID else { return }
            services.permissionConnections[sessionID] = nil
            let note = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            services.hookServer?.reply(wait.connection, HookReply(decision: allow ? .allow : .deny,
                                                                  message: allow || note?.isEmpty != false ? nil : note))
            reducer.resolvePermission(in: &snapshot)
        } else {
            // The hook is gone: only Claude's own prompt in the terminal can answer now.
            snapshot.pendingPermission = nil
        }
        commit(sessionID, snapshot: snapshot, reducer: reducer)
    }

    /// Answers whichever card is pending now. Prefer `respondToPermission(sessionID:permissionID:…)`.
    func respondToPermission(sessionID: UUID, allow: Bool, message: String?) {
        guard let id = runtimes[sessionID]?.snapshot.pendingPermission?.id else { return }
        respondToPermission(sessionID: sessionID, permissionID: id, allow: allow, message: message)
    }

    /// Ends the runtime side of a session: its rollout watcher (which releases its file claim), a hook
    /// still waiting for an answer, the reducer's bookkeeping and the foreground monitor's state. The
    /// snapshot stays. Every way a session's agent goes away (exit, quit in its shell, relaunch,
    /// archive) runs this; a watcher left running would claim a later session's rollout file.
    func endRuntime(_ id: UUID) {
        let services = runtimeServices
        services.watchers.removeValue(forKey: id)?.stop()
        if let wait = services.permissionConnections.removeValue(forKey: id) {
            services.hookServer?.reply(wait.connection, HookReply(decision: .none))
        }
        services.reducers[id] = nil
        services.agentSeenInForeground.remove(id)
        services.shellForegroundTicks[id] = nil
    }

    /// Clears the unread mark (called when the user selects the session).
    func markSeen(_ sessionID: UUID) {
        guard let rt = runtimes[sessionID] else { return }
        if rt.unread { rt.unread = false }
        runtimeServices.notifier?.removeDelivered(sessionID: sessionID)
    }

    /// Environment for running a vendor CLI as `account` (login, status checks): allowlisted base env,
    /// credential variables stripped, CLAUDE_CONFIG_DIR / CODEX_HOME set for managed accounts only.
    func environment(for account: Account?) -> [String: String] {
        EnvBuilder.cliEnvironment(account: account, processEnv: ProcessInfo.processInfo.environment,
                                  loginPath: runtimeServices.loginPath)
    }

    /// Command for the login sheet's terminal: vendor login for `account` with `method`.
    func loginSpec(account: Account, method: AuthMethod, cwd: String) -> LaunchSpec {
        let flow: EnvBuilder.LoginFlow?
        switch method {
        case .browser: flow = .browser
        case .token: flow = account.provider == .claude ? .token : nil
        case .apiKey, .existing: flow = nil
        }
        if let flow { return loginSpec(account: account, flow: flow, cwd: cwd) }
        // Nothing to run for this method: an interactive shell already set up as the account.
        let env = ProcessInfo.processInfo.environment
        return LaunchSpec(executable: EnvBuilder.userShell(env), args: ["-l", "-i"], environment: environment(for: account), cwd: cwd)
    }

    /// Like `loginSpec(account:method:cwd:)`, for flows that aren't an `AuthMethod` (Codex device code).
    func loginSpec(account: Account, flow: EnvBuilder.LoginFlow, cwd: String) -> LaunchSpec {
        let env = ProcessInfo.processInfo.environment
        if !account.isSystemDefault, let dir = account.configDir, !dir.isEmpty {
            prepareAccountDir(dir)
        }
        if let spec = EnvBuilder.loginSpec(provider: account.provider, flow: flow, account: account,
                                           doneNotice: L.loginFinished, cwd: cwd, processEnv: env) {
            return spec
        }
        return LaunchSpec(executable: EnvBuilder.userShell(env), args: ["-l", "-i"], environment: environment(for: account), cwd: cwd)
    }

    /// Creates (0700) a folder hdlanes owns. An imported folder the user also uses from the terminal or
    /// an editor is never chmod'ed or recreated.
    func prepareAccountDir(_ dir: String) {
        guard isInsideAccountsDir(dir) else { return }
        try? HDPaths.ensurePrivateDir(URL(fileURLWithPath: dir, isDirectory: true))
    }

    func usage(for accountID: UUID) -> AccountUsage? { state.usage[accountID.uuidString] }

    // Terminal callbacks (from TerminalRegistry).
    func handleTerminalTitle(sessionID: UUID, title: String) {
        // An archived session's terminal may still be draining; it reports nothing anymore.
        guard let session = session(sessionID), session.provider == .codex, session.isArchived != true else { return }
        let rt = runtime(for: sessionID)
        switch rt.snapshot.status {
        case .notStarted, .exited: return
        default: break
        }
        var snapshot = rt.snapshot
        let lower = title.lowercased()
        if lower.contains("action required") || lower.contains("approval") {
            snapshot.status = .needsYou(.permission, detail: Self.displayText(title))
        } else if let first = title.unicodeScalars.first, (0x2800...0x28FF).contains(first.value) {
            snapshot.status = .working
        } else {
            return
        }
        commit(sessionID, snapshot: snapshot, reducer: nil)
    }

    func handleProgramStatus(sessionID: UUID, records: [TerminalProgramStatus]) {
        guard let session = session(sessionID), session.provider.isAgent, session.isArchived != true,
              let root = records.first(where: { $0.id.isEmpty }) else { return }
        let rt = runtime(for: sessionID)
        var snapshot = rt.snapshot
        var reducer = runtimeServices.reducers[sessionID] ?? ClaudeEventReducer()
        let authoritative = session.provider == .codex || !reducer.hasReceivedEvents
        let message = (root.message ?? root.title).map(Self.displayText)
        reducer.applyProgramStatus(state: root.state.rawValue, kind: root.kind?.rawValue, message: message,
                                   to: &snapshot, now: Date(), authoritative: authoritative)
        commit(sessionID, snapshot: snapshot, reducer: reducer)
    }

    func handleProcessExit(sessionID: UUID, exitCode: Int32?) {
        endRuntime(sessionID)
        let rt = runtime(for: sessionID)
        var snapshot = rt.snapshot
        snapshot.pendingPermission = nil
        snapshot.status = .exited(exitCode)
        for i in snapshot.subagents.indices where snapshot.subagents[i].isRunning {
            snapshot.subagents[i].isRunning = false
            snapshot.subagents[i].endedAt = Date()
        }
        for i in snapshot.activity.indices where snapshot.activity[i].isRunning { snapshot.activity[i].isRunning = false }
        commit(sessionID, snapshot: snapshot, reducer: ClaudeEventReducer())
    }
}
