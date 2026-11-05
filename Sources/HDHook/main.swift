import Foundation
import HDCore

// `hdlanes-hook <EventName>`  — a Claude Code hook: forwards its stdin JSON to the app's socket.
//                              PermissionRequest waits for the answer and prints Claude's decision JSON.
// `hdlanes-hook statusline`   — the status line: forwards the JSON, then prints the account's own status
//                              line (HD_STATUSLINE_CHAIN) or hdlanes' own line (HDCore/StatusLine).
//
// Never fails loudly: every path exits 0, and without HD_SOCKET / HD_SESSION_ID (or without the app)
// it does nothing beyond the status line text.

let stdinLimit = 4 << 20
let connectTimeoutMs: Int32 = 300
let permissionTimeoutMs: Int32 = 590_000
let chainTimeout: TimeInterval = 1.5

signal(SIGPIPE, SIG_IGN)

/// Reads all of stdin, keeping at most `limit` bytes (the rest is drained so the writer never blocks).
func readStandardInput(limit: Int) -> Data {
    if isatty(STDIN_FILENO) != 0 { return Data() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = read(STDIN_FILENO, &buffer, buffer.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { break }
        if data.count < limit { data.append(contentsOf: buffer[0..<min(n, limit - data.count)]) }
    }
    return data
}

func decodePayload(_ data: Data) -> JSONValue {
    (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
}

/// Connects to the app's Unix socket, giving up after `timeoutMs`.
func connectSocket(path: String, timeoutMs: Int32) -> Int32? {
    var addr = sockaddr_un()
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if result != 0 {
        guard errno == EINPROGRESS || errno == EAGAIN, wait(fd, for: Int16(POLLOUT), timeoutMs: timeoutMs) else {
            close(fd)
            return nil
        }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
            close(fd)
            return nil
        }
    }
    _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    var timeout = timeval(tv_sec: 0, tv_usec: suseconds_t(connectTimeoutMs) * 1000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

/// poll() for one event with EINTR retry; false on timeout or error.
func wait(_ fd: Int32, for events: Int16, timeoutMs: Int32) -> Bool {
    var pfd = pollfd(fd: fd, events: events, revents: 0)
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while true {
        let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        let r = poll(&pfd, 1, remaining)
        if r < 0 && errno == EINTR { continue }
        return r > 0
    }
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard var p = raw.baseAddress else { return true }
        var left = raw.count
        while left > 0 {
            let n = write(fd, p, left)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            p += n
            left -= n
        }
        return true
    }
}

/// Reads one newline-terminated line, waiting up to `timeoutMs` in total.
func readLine(_ fd: Int32, timeoutMs: Int32, limit: Int = 64 * 1024) -> Data? {
    var line = Data()
    var byte = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while line.count < limit {
        let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        guard remaining > 0, wait(fd, for: Int16(POLLIN), timeoutMs: remaining) else { return nil }
        let n = read(fd, &byte, byte.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return nil }
        let chunk = byte[0..<n]
        if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
            line.append(contentsOf: chunk[chunk.startIndex..<newline])
            return line
        }
        line.append(contentsOf: chunk)
    }
    return nil
}

/// Sends one message; returns the still-open socket when `keepOpen`.
func send(_ message: HookMessage, socketPath: String, keepOpen: Bool) -> Int32? {
    guard var data = try? JSONEncoder().encode(message), let fd = connectSocket(path: socketPath, timeoutMs: connectTimeoutMs) else {
        return nil
    }
    data.append(UInt8(ascii: "\n"))
    guard writeAll(fd, data), keepOpen else {
        close(fd)
        return nil
    }
    return fd
}

func printOut(_ data: Data) {
    try? FileHandle.standardOutput.write(contentsOf: data)
}

// MARK: Permission answer

struct PermissionOutput: Encodable {
    struct Decision: Encodable {
        var behavior: String
        var message: String?
    }

    struct Specific: Encodable {
        var hookEventName = "PermissionRequest"
        var decision: Decision
    }

    var hookSpecificOutput: Specific
}

func permissionOutput(for reply: HookReply) -> Data? {
    let decision: PermissionOutput.Decision
    switch reply.decision {
    case .allow: decision = .init(behavior: "allow")
    case .deny: decision = .init(behavior: "deny", message: reply.message.flatMap { $0.isEmpty ? nil : $0 })
    case .none: return nil
    }
    guard var data = try? JSONEncoder().encode(PermissionOutput(hookSpecificOutput: .init(decision: decision))) else { return nil }
    data.append(UInt8(ascii: "\n"))
    return data
}

// MARK: Status line

final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Runs the account's own status line command with the same stdin; returns what it printed in time.
func runChain(_ command: String, input: Data, environment: [String: String]) -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    var env = environment
    // The chained command must not recurse into hdlanes.
    for key in [HookEnv.statusLineChain, HookEnv.socket, HookEnv.session, HookEnv.account] { env.removeValue(forKey: key) }
    process.environment = env
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return Data() }

    let writer = stdinPipe.fileHandleForWriting
    DispatchQueue.global().async {
        try? writer.write(contentsOf: input)
        try? writer.close()
    }
    let box = OutputBox()
    let reader = stdoutPipe.fileHandleForReading
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            box.append(chunk)
        }
        group.leave()
    }
    if group.wait(timeout: .now() + chainTimeout) == .timedOut {
        let pid = process.processIdentifier
        process.terminate()
        if pid > 0 { kill(pid, SIGKILL) }
    }
    return box.value
}

func defaultStatusLine(_ payload: JSONValue, accountLabel: String?) -> Data {
    let line = StatusLine.render(payload, accountLabel: accountLabel)
    return line.isEmpty ? Data() : Data((line + "\n").utf8)
}

// MARK: Main

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { exit(0) }
let event = arguments[1]
let environment = ProcessInfo.processInfo.environment
let startedAt = Date().timeIntervalSince1970 * 1000
let input = readStandardInput(limit: stdinLimit)
let socketPath = environment[HookEnv.socket].flatMap { $0.isEmpty ? nil : $0 }
let sessionID = environment[HookEnv.session].flatMap { $0.isEmpty ? nil : $0 }

if event == "statusline" {
    let payload = decodePayload(input)
    if let socketPath, let sessionID {
        _ = send(HookMessage(session: sessionID, event: "StatusLine", wait: false, payload: payload),
                 socketPath: socketPath, keepOpen: false)
    }
    if let chain = environment[HookEnv.statusLineChain], !chain.trimmingCharacters(in: .whitespaces).isEmpty {
        printOut(runChain(chain, input: input, environment: environment))
    } else {
        printOut(defaultStatusLine(payload, accountLabel: environment[HookEnv.accountLabel]))
    }
    exit(0)
}

guard let socketPath, let sessionID else { exit(0) }
let payload = ClaudeHookPayload.slim(decodePayload(input), stamp: startedAt)
let waits = event == ClaudePluginFiles.permissionEvent
let message = HookMessage(session: sessionID, event: event, wait: waits, payload: payload)
if let fd = send(message, socketPath: socketPath, keepOpen: waits) {
    if let line = readLine(fd, timeoutMs: permissionTimeoutMs),
       let reply = try? JSONDecoder().decode(HookReply.self, from: line),
       let output = permissionOutput(for: reply) {
        printOut(output)
    }
    close(fd)
}
exit(0)
