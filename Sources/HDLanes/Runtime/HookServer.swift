import Darwin
import Foundation
import HDCore

/// Unix socket server `hdlanes-hook` talks to: newline-delimited `HookMessage` JSON in, one
/// `HookReply` line out for a waiting (PermissionRequest) connection.
///
/// All socket work happens on a private serial queue; messages reach the main actor in arrival order.
/// Garbage lines are ignored, oversized or idle connections are closed.
final class HookServer: @unchecked Sendable {
    typealias ConnectionID = Int

    enum StartError: LocalizedError {
        case pathTooLong(String)
        case notASocket(String)
        case system(String, Int32)

        var errorDescription: String? {
            switch self {
            case .pathTooLong(let path): return L.hookSocketPathTooLong(path)
            case .notASocket(let path): return L.hookSocketPathTaken(path)
            case .system(let call, let code): return "\(call): \(String(cString: strerror(code)))"
            }
        }
    }

    private final class Connection {
        let id: ConnectionID
        let fd: Int32
        let source: DispatchSourceRead
        let openedAt = Date()
        var splitter = JSONLineSplitter(maxLineLength: HookServer.maxBytesPerConnection)
        var received = 0
        var waiting = false

        init(id: ConnectionID, fd: Int32, source: DispatchSourceRead) {
            self.id = id
            self.fd = fd
            self.source = source
        }
    }

    static let maxBytesPerConnection = 8 << 20
    /// A reporting hook writes one line and closes; anything slower is stuck.
    static let idleTimeout: TimeInterval = 15
    /// Claude gives the PermissionRequest hook 600 s; the hook gives up at 590 s.
    static let waitingTimeout: TimeInterval = 610

    let path: String
    private let queue = DispatchQueue(label: "hdlanes.hook-server")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var sweepTimer: DispatchSourceTimer?
    private var connections: [ConnectionID: Connection] = [:]
    private var nextID = 0

    private let onMessage: @MainActor (HookMessage, ConnectionID?) -> Void
    private let onWaitingClosed: @MainActor (ConnectionID) -> Void

    /// `onMessage` gets the connection id only for `wait == true` messages; answer those with `reply`.
    /// `onWaitingClosed` fires when such a connection goes away before it was answered.
    init(path: String, onMessage: @escaping @MainActor (HookMessage, ConnectionID?) -> Void,
         onWaitingClosed: @escaping @MainActor (ConnectionID) -> Void) {
        self.path = path
        self.onMessage = onMessage
        self.onWaitingClosed = onWaitingClosed
    }

    // MARK: Lifecycle

    func start() throws {
        try queue.sync { try startLocked() }
    }

    private func startLocked() throws {
        guard listenFD < 0 else { return }
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw StartError.pathTooLong(path) }

        // A socket left by a previous run is ours to replace; any other file at that path is not.
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw StartError.notASocket(path) }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.system("socket", errno) }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw StartError.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 128) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw StartError.system("listen", code)
        }
        Self.configure(fd)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.sweep() }
        timer.resume()
        sweepTimer = timer
    }

    /// Closes every connection and removes the socket file. Waiting hooks exit without an answer, so
    /// Claude falls back to its own prompt. Call from outside the server's queue (the main actor).
    func stop() {
        queue.sync {
            guard listenFD >= 0 else { return }
            sweepTimer?.cancel()
            sweepTimer = nil
            acceptSource?.cancel()
            acceptSource = nil
            listenFD = -1
            for connection in connections.values { connection.source.cancel() }
            connections.removeAll()
            unlink(path)
        }
    }

    /// Answers a waiting hook and closes its connection. A no-op when it is already gone.
    func reply(_ id: ConnectionID, _ reply: HookReply) {
        queue.async { [weak self] in
            guard let self, let connection = self.connections[id], connection.waiting else { return }
            if var data = try? JSONEncoder().encode(reply) {
                data.append(UInt8(ascii: "\n"))
                Self.writeAll(connection.fd, data)
            }
            self.drop(connection)
        }
    }

    // MARK: Socket work (on `queue`)

    private static func configure(_ fd: Int32) {
        // Children (the PTY shells) must not inherit our sockets.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private func acceptPending() {
        while listenFD >= 0 {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return   // EAGAIN, or out of descriptors: try again on the next event
            }
            Self.configure(fd)
            nextID += 1
            let id = nextID
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let connection = Connection(id: id, fd: fd, source: source)
            source.setEventHandler { [weak self] in self?.readAvailable(id) }
            source.setCancelHandler { close(fd) }
            connections[id] = connection
            source.resume()
        }
    }

    private func readAvailable(_ id: ConnectionID) {
        guard let connection = connections[id] else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(connection.fd, &buffer, buffer.count)
            if n > 0 {
                connection.received += n
                guard connection.received <= Self.maxBytesPerConnection else {
                    closeConnection(connection)
                    return
                }
                for line in connection.splitter.append(Data(buffer[0..<n])) { handle(line, on: connection) }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            closeConnection(connection)   // EOF or error
            return
        }
    }

    private func handle(_ line: Data, on connection: Connection) {
        guard let message = try? JSONDecoder().decode(HookMessage.self, from: line),
              message.v <= HookMessage.protocolVersion else { return }
        let waitingID: ConnectionID?
        if message.wait && !connection.waiting {
            connection.waiting = true
            waitingID = connection.id
        } else {
            waitingID = nil
        }
        let deliver = onMessage
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(message, waitingID) } }
    }

    /// The peer went away (or broke a limit). A waiting connection reports it so the card stops
    /// offering Allow/Deny.
    private func closeConnection(_ connection: Connection) {
        let wasWaiting = connection.waiting
        drop(connection)
        guard wasWaiting else { return }
        let id = connection.id
        let closed = onWaitingClosed
        DispatchQueue.main.async { MainActor.assumeIsolated { closed(id) } }
    }

    private func drop(_ connection: Connection) {
        guard connections.removeValue(forKey: connection.id) != nil else { return }
        connection.source.cancel()
    }

    private func sweep() {
        let now = Date()
        for connection in Array(connections.values) {
            let limit = connection.waiting ? Self.waitingTimeout : Self.idleTimeout
            if now.timeIntervalSince(connection.openedAt) > limit { closeConnection(connection) }
        }
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            var spins = 0
            while left > 0 {
                let n = write(fd, p, left)
                if n > 0 {
                    p += n
                    left -= n
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                // A reply is a few dozen bytes; a full buffer means the peer isn't reading.
                if n < 0 && errno == EAGAIN && spins < 50 {
                    spins += 1
                    usleep(2_000)
                    continue
                }
                return false
            }
            return true
        }
    }
}
