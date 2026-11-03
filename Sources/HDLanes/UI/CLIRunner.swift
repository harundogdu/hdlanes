import Foundation
import HDCore

// OWNER: workspace area.

struct CLIResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
    var launchFailed = false

    var combined: String { stdout + "\n" + stderr }

    /// First non-empty stderr (else stdout) line, shortened: safe to show in an alert.
    func firstErrorLine(redacting secret: String? = nil) -> String? {
        let source = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
        guard var line = source.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        if let secret, !secret.isEmpty { line = line.replacingOccurrences(of: secret, with: "•••") }
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}

/// Runs short-lived vendor CLI commands (status checks, key login, `claude -p`) off the main thread.
/// Output is returned to the caller and never logged.
enum CLIRunner {
    static func run(executable: String, arguments: [String], environment: [String: String],
                    currentDirectory: String? = nil, stdin: Data? = nil, timeout: TimeInterval) async -> CLIResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable: executable, arguments: arguments,
                                                           environment: environment, currentDirectory: currentDirectory,
                                                           stdin: stdin, timeout: timeout))
            }
        }
    }

    /// `/bin/zsh -l -c '<line>'` with `environment`. Callers build `line` with `AccountCLI.commandLine`
    /// so credentials exported by the user's shell init are unset again before the CLI runs.
    static func runShell(_ line: String, environment: [String: String], currentDirectory: String? = nil,
                         stdin: Data? = nil, timeout: TimeInterval) async -> CLIResult {
        await run(executable: "/bin/zsh", arguments: ["-l", "-c", line], environment: environment,
                  currentDirectory: currentDirectory, stdin: stdin, timeout: timeout)
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private(set) var timedOut = false

        func append(_ data: Data, toErr: Bool) {
            lock.lock(); defer { lock.unlock() }
            if toErr { err.append(data) } else { out.append(data) }
        }

        func markTimedOut() {
            lock.lock(); timedOut = true; lock.unlock()
        }

        func snapshot() -> (Data, Data, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (out, err, timedOut)
        }
    }

    private static func runBlocking(executable: String, arguments: [String], environment: [String: String],
                                    currentDirectory: String?, stdin: Data?, timeout: TimeInterval) -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = stdin == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let collector = Collector()
        // Read as data arrives so a chatty child can't fill the pipe and block.
        outPipe.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, toErr: false) }
        errPipe.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, toErr: true) }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return CLIResult(status: -1, stdout: "", stderr: error.localizedDescription, launchFailed: true)
        }

        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        let pid = process.processIdentifier
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            collector.markTimedOut()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()

        // A grandchild may still hold the pipes open; take what arrived and stop reading.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? outPipe.fileHandleForReading.drainNonBlocking() { collector.append(rest, toErr: false) }
        if let rest = try? errPipe.fileHandleForReading.drainNonBlocking() { collector.append(rest, toErr: true) }

        let (out, err, timedOut) = collector.snapshot()
        return CLIResult(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self),
                         stderr: String(decoding: err, as: UTF8.self), timedOut: timedOut)
    }
}

private extension FileHandle {
    /// Reads what is buffered without blocking on a writer that never closes.
    func drainNonBlocking() throws -> Data? {
        let flags = fcntl(fileDescriptor, F_GETFL)
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if n <= 0 { break }
            result.append(contentsOf: buffer[0..<n])
        }
        return result
    }
}

/// The user's interactive login PATH. Apps started from Finder get a minimal PATH, and on many setups
/// (nvm, ~/.local/bin) the CLIs are only added in `.zshrc`, which `zsh -l -c` doesn't read. Resolved
/// once per run via `$SHELL -l -i -c` with sentinels around the value (shell init noise is ignored).
@MainActor
enum ShellPath {
    private static var cached: String?
    private static var inflight: Task<String, Never>?

    static func resolved(base: [String: String]) async -> String {
        if let cached { return cached }
        if let inflight { return await inflight.value }
        let task = Task<String, Never> {
            let shell = base["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
            let begin = "__HDLANES_PATH_BEGIN__", end = "__HDLANES_PATH_END__"
            var env = AccountCLI.environment(base: base, provider: .shell, configDir: nil)
            env["TERM"] = "dumb"
            let result = await CLIRunner.run(executable: shell, arguments: ["-l", "-i", "-c", "printf '\(begin)%s\(end)' \"$PATH\""],
                                             environment: env, timeout: 10)
            if let path = AccountCLI.extract(between: begin, and: end, in: result.stdout), !path.isEmpty {
                return path
            }
            return fallback(base: base)
        }
        inflight = task
        let value = await task.value
        cached = value
        inflight = nil
        return value
    }

    private static func fallback(base: [String: String]) -> String {
        let home = NSHomeDirectory()
        var dirs = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            extra += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.prefix(1).map { "\(nvm)/\($0)/bin" }
        }
        for d in extra where !dirs.contains(d) { dirs.append(d) }
        return dirs.joined(separator: ":")
    }
}
