import Foundation

/// Wire format between `hdlanes-hook` and the app: one JSON object per line over the Unix socket
/// at `HDPaths.socketPath`.
///
/// hook → app:  HookMessage
/// app → hook:  HookReply   (only when `wait == true`, i.e. PermissionRequest)
public struct HookMessage: Codable, Sendable {
    public static let protocolVersion = 1

    public var v: Int
    /// hdlanes session id (from the HD_SESSION_ID env var the app sets when it launches the agent).
    public var session: String
    /// Claude hook event name (`PreToolUse`, `Stop`, …) or `StatusLine` for the status line wrapper.
    public var event: String
    /// true when the hook blocks waiting for a HookReply.
    public var wait: Bool
    /// The JSON Claude Code wrote to the hook's stdin, unchanged.
    public var payload: JSONValue

    public init(session: String, event: String, wait: Bool, payload: JSONValue) {
        self.v = Self.protocolVersion
        self.session = session
        self.event = event
        self.wait = wait
        self.payload = payload
    }
}

public struct HookReply: Codable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case allow, deny
        /// No decision from hdlanes: the hook exits without output and Claude shows its own prompt.
        case none
    }

    public var decision: Decision
    public var message: String?

    public init(decision: Decision, message: String? = nil) {
        self.decision = decision
        self.message = message
    }
}

/// Environment variable names shared by the app and the hook.
public enum HookEnv {
    public static let socket = "HD_SOCKET"
    public static let session = "HD_SESSION_ID"
    public static let account = "HD_ACCOUNT_ID"
    /// The user's own status line command for this account, chained by `hdlanes-hook statusline`.
    public static let statusLineChain = "HD_STATUSLINE_CHAIN"
}

/// Arbitrary JSON, so hook payloads pass through without a schema.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Follows a dotted path, e.g. `value.path("rate_limits.five_hour.used_percentage")`.
    public func path(_ dotted: String) -> JSONValue? {
        var cur: JSONValue? = self
        for part in dotted.split(separator: ".") { cur = cur?[String(part)] }
        return cur
    }
}
