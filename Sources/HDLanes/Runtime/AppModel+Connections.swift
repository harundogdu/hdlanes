import Foundation
import HDCore

// OWNER: runtime area. Connections: tokens as environment variables, MCP servers for Claude and a
// kubeconfig, handed to sessions at launch (see ARCHITECTURE "Connections").
extension AppModel {
    var connectionSecrets: ConnectionSecrets { ConnectionSecrets(paths: paths) }

    func connectionProblem(_ c: Connection) -> ConnectionRules.Problem? {
        ConnectionRules.problem(c, others: state.connections)
    }

    /// Adds or replaces `c`. `secret` nil keeps the stored one; empty removes it.
    func saveConnection(_ c: Connection, secret: String?) throws {
        if let problem = connectionProblem(c) { throw WorkspaceError.connection(problem) }
        if c.hasSecret, let secret {
            if secret.isEmpty { connectionSecrets.delete(c.id) } else { try connectionSecrets.write(secret, for: c.id) }
        }
        if !c.hasSecret { connectionSecrets.delete(c.id) }
        if let i = state.connections.firstIndex(where: { $0.id == c.id }) {
            state.connections[i] = c
        } else {
            state.connections.append(c)
        }
    }

    func removeConnection(_ id: UUID) {
        connectionSecrets.delete(id)
        state.connections.removeAll { $0.id == id }
    }

    func connectionHasSecret(_ c: Connection) -> Bool {
        c.hasSecret && connectionSecrets.exists(c.id)
    }

    /// Variables for a session's terminal (tokens, KUBECONFIG).
    func connectionEnvironment(for session: AgentSession) -> [String: String] {
        let secrets = connectionSecrets
        return ConnectionRules.environment(state.connections, projectID: session.projectID) { secrets.read($0.id) }
    }

    func existingMCPConfig(for session: AgentSession) -> String? {
        let path = paths.sessionRunDir(session.id).appendingPathComponent("mcp.json").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Writes `run/sessions/<id>/mcp.json` (no secrets, `${VAR}` references) and returns its path, or
    /// removes a stale one and returns nil when the session gets no MCP connection.
    func writeMCPConfig(for session: AgentSession) -> String? {
        let dir = paths.sessionRunDir(session.id)
        let file = dir.appendingPathComponent("mcp.json")
        let secrets = connectionSecrets
        guard let data = ConnectionRules.mcpConfigJSON(state.connections, projectID: session.projectID,
                                                       hasSecret: { $0.hasSecret && secrets.exists($0.id) }) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        do {
            try HDPaths.ensurePrivateDir(dir)
            try data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file.path
        } catch {
            return nil
        }
    }
}
