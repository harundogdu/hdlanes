import Darwin
import Foundation

/// Finds every process of a terminal's session. The shell is started with setsid, so its pid is the
/// session id; the agent (its own job / process group under job control) and helpers that shell init
/// files spawn all stay in that session. Signalling only the shell or one process group leaves the
/// rest running after the terminal is gone.
enum ProcessTree {
    /// Every live process whose session id is `sid`. Matches with getsid() over the full pid list:
    /// a KERN_PROC_SESSION query fails with ENOENT once the session leader (the shell) has exited,
    /// which is exactly when the leftovers need finding.
    static func sessionMembers(_ sid: pid_t) -> [pid_t] {
        guard sid > 0 else { return [] }
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let got = pids.withUnsafeMutableBytes { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count))
        }
        guard got > 0 else { return [] }
        let me = getpid()
        return pids.prefix(Int(got)).filter { $0 > 0 && $0 != me && getsid($0) == sid }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    /// Hangs up every process of the session (like closing a terminal tab).
    static func hangUp(session sid: pid_t) {
        for pid in sessionMembers(sid) { Darwin.kill(pid, SIGHUP) }
    }

    /// SIGKILLs whatever of the session is still alive.
    static func killAll(session sid: pid_t) {
        for pid in sessionMembers(sid) { Darwin.kill(pid, SIGKILL) }
    }

    /// Hang up all sessions, wait up to `timeout` for them to exit, then kill the rest.
    /// Used when the app quits, so no agent keeps running without its terminal.
    static func terminate(sessions: [pid_t], timeout: TimeInterval) {
        let sessions = sessions.filter { $0 > 0 }
        guard !sessions.isEmpty else { return }
        sessions.forEach { hangUp(session: $0) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sessions.allSatisfy({ sessionMembers($0).isEmpty }) { return }
            usleep(100_000)
        }
        // Whatever ignored the hangup (disowned shell-init helpers, stuck tools).
        sessions.forEach { killAll(session: $0) }
    }
}
