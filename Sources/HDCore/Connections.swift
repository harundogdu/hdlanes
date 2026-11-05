import Foundation

/// A token, MCP server or kubeconfig handed to agent sessions. Only metadata lives here (and in
/// state.json); the secret is in the macOS Keychain under the connection's id.
public struct Connection: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// The secret as an environment variable.
        case token
        /// A local MCP server started by Claude (`command args…`); the secret, if any, in its env.
        case mcpCommand
        /// A remote MCP server (`url`); the secret, if any, in a header.
        case mcpURL
        /// A kubeconfig file, as `KUBECONFIG`. Read-only access is up to the file's credentials.
        case kubeconfig
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Environment variable that carries the secret (or the kubeconfig path).
    public var variable: String
    public var command: String?
    public var arguments: [String]?
    public var url: String?
    /// Header that carries the secret for `mcpURL`, e.g. `Authorization`.
    public var headerName: String?
    /// Text before the secret in that header, e.g. `Bearer `.
    public var headerPrefix: String?
    public var filePath: String?
    /// Projects the connection is given to; nil or empty means every project.
    public var projectIDs: [UUID]?
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, kind: Kind, variable: String, command: String? = nil,
                arguments: [String]? = nil, url: String? = nil, headerName: String? = nil, headerPrefix: String? = nil,
                filePath: String? = nil, projectIDs: [UUID]? = nil, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.variable = variable
        self.command = command
        self.arguments = arguments
        self.url = url
        self.headerName = headerName
        self.headerPrefix = headerPrefix
        self.filePath = filePath
        self.projectIDs = projectIDs
        self.isEnabled = isEnabled
    }

    /// Whether the connection has a secret in the Keychain (a kubeconfig is only a path).
    public var hasSecret: Bool { kind != .kubeconfig }

    public func applies(to projectID: UUID?) -> Bool {
        guard isEnabled else { return false }
        guard let ids = projectIDs, !ids.isEmpty else { return true }
        return projectID.map(ids.contains) ?? false
    }
}

public enum ConnectionRules {
    public enum Problem: Equatable, Sendable {
        case emptyName
        case invalidVariable
        /// Would change which account or provider a session uses, or hdlanes' own wiring.
        case reservedVariable
        case duplicateVariable
        /// Another MCP connection would get the same server name.
        case duplicateServerName
        case missingCommand
        case invalidURL
        case missingFile
    }

    /// Names a connection may never set: credentials and dirs of the agents' own logins, provider
    /// switches, hdlanes' hook variables and the shell basics.
    public static func isReserved(_ name: String) -> Bool {
        let upper = name.uppercased()
        if EnvBuilder.droppedPrefixes.contains(where: { upper.hasPrefix($0) }) { return true }
        if upper.hasPrefix("HD_") { return true }
        if ["DYLD_", "LD_"].contains(where: { upper.hasPrefix($0) }) { return true }
        let fixed = Set(["NODE_OPTIONS", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"] + EnvBuilder.claudeStripVariables + EnvBuilder.claudeProviderSwitchVariables
                        + EnvBuilder.codexStripVariables + Array(EnvBuilder.allowedKeys)
                        + Array(EnvBuilder.terminalVariables.keys) + ["LC_ALL", "LC_CTYPE", "PWD", "OLDPWD"])
        return fixed.contains(upper) || upper.hasPrefix("LC_")
    }

    public static func problem(_ c: Connection, others: [Connection]) -> Problem? {
        if c.name.trimmingCharacters(in: .whitespaces).isEmpty { return .emptyName }
        let v = c.variable
        guard let first = v.unicodeScalars.first, v.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }),
              !CharacterSet.decimalDigits.contains(first) else { return .invalidVariable }
        if c.kind == .kubeconfig ? v != "KUBECONFIG" : isReserved(v) || v == "KUBECONFIG" { return .reservedVariable }
        // Two connections may share a variable only when no project gets both.
        if others.contains(where: { $0.id != c.id && $0.variable == v && overlaps($0, c) }) { return .duplicateVariable }
        if c.kind == .mcpCommand || c.kind == .mcpURL,
           others.contains(where: { $0.id != c.id && ($0.kind == .mcpCommand || $0.kind == .mcpURL)
                                    && serverName($0) == serverName(c) && overlaps($0, c) }) {
            return .duplicateServerName
        }
        switch c.kind {
        case .token: break
        case .mcpCommand:
            if (c.command ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return .missingCommand }
        case .mcpURL:
            guard let s = c.url, let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
                  u.host != nil else { return .invalidURL }
        case .kubeconfig:
            if (c.filePath ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return .missingFile }
        }
        return nil
    }

    /// Whether some project would get both connections.
    static func overlaps(_ a: Connection, _ b: Connection) -> Bool {
        guard let x = a.projectIDs, !x.isEmpty, let y = b.projectIDs, !y.isEmpty else { return true }
        return !Set(x).isDisjoint(with: y)
    }

    /// Variables a session in `projectID` gets: each applying connection's secret (or kubeconfig path)
    /// under its variable. A connection without a stored secret is skipped.
    public static func environment(_ connections: [Connection], projectID: UUID?,
                                   secret: (Connection) -> String?) -> [String: String] {
        var env: [String: String] = [:]
        for c in connections where c.applies(to: projectID) {
            switch c.kind {
            case .kubeconfig:
                if let path = c.filePath, !path.isEmpty { env["KUBECONFIG"] = path }
            default:
                // Checked again here: a hand-edited state file must not reroute a session's login.
                guard !isReserved(c.variable), c.variable != "KUBECONFIG" else { continue }
                if let value = secret(c), !value.isEmpty { env[c.variable] = value }
            }
        }
        return env
    }

    /// MCP server name Claude shows: lowercase letters, digits and `-` from the connection's name.
    public static func serverName(_ c: Connection) -> String {
        let slug = c.name.lowercased().unicodeScalars.map { s -> String in
            s.isASCII && CharacterSet.alphanumerics.contains(s) ? String(s) : "-"
        }.joined()
        let trimmed = slug.split(separator: "-").joined(separator: "-")
        return trimmed.isEmpty ? "connection-\(c.id.uuidString.prefix(8).lowercased())" : trimmed
    }

    /// `--mcp-config` file for a session: the applying MCP connections. Secrets are written as
    /// `${VAR}`, which Claude expands from the session's environment (claude 2.1.318 expands variables
    /// in `--mcp-config` files), so the file holds none. nil when there is no MCP connection.
    public static func mcpConfigJSON(_ connections: [Connection], projectID: UUID?,
                                     hasSecret: (Connection) -> Bool) -> Data? {
        var servers: [String: JSONValue] = [:]
        for c in connections where c.applies(to: projectID) {
            let name = serverName(c)
            let withSecret = hasSecret(c) && !isReserved(c.variable)
            switch c.kind {
            case .mcpCommand:
                guard let command = c.command, !command.isEmpty else { continue }
                var server: [String: JSONValue] = [
                    "type": .string("stdio"),
                    "command": .string(command),
                    "args": .array((c.arguments ?? []).map { .string($0) }),
                ]
                if withSecret { server["env"] = .object([c.variable: .string("${\(c.variable)}")]) }
                servers[name] = .object(server)
            case .mcpURL:
                guard let url = c.url, !url.isEmpty else { continue }
                var server: [String: JSONValue] = ["type": .string("http"), "url": .string(url)]
                if withSecret, let header = c.headerName, !header.isEmpty {
                    server["headers"] = .object([header: .string((c.headerPrefix ?? "") + "${\(c.variable)}")])
                }
                servers[name] = .object(server)
            case .token, .kubeconfig:
                continue
            }
        }
        guard !servers.isEmpty else { return nil }
        return ClaudePluginFiles.encode(.object(["mcpServers": .object(servers)]))
    }
}
