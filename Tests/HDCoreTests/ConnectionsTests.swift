import Foundation
import Testing
@testable import HDCore

struct ConnectionsTests {
    private let p1 = UUID()
    private let p2 = UUID()

    @Test func reservedNamesCantBeUsed() {
        for name in ["ANTHROPIC_API_KEY", "anthropic_base_url", "OPENAI_API_KEY", "CLAUDE_CONFIG_DIR", "CODEX_HOME",
                     "CLAUDE_CODE_USE_BEDROCK", "HD_SOCKET", "PATH", "HOME", "SHELL", "TERM", "LC_ALL", "LANG"] {
            #expect(ConnectionRules.isReserved(name), "\(name)")
        }
        for name in ["GITHUB_TOKEN", "AZURE_DEVOPS_EXT_PAT", "MY_TOKEN"] {
            #expect(!ConnectionRules.isReserved(name), "\(name)")
        }
    }

    @Test func validation() {
        func problem(_ c: Connection, _ others: [Connection] = []) -> ConnectionRules.Problem? {
            ConnectionRules.problem(c, others: others)
        }
        #expect(problem(Connection(name: " ", kind: .token, variable: "A")) == .emptyName)
        #expect(problem(Connection(name: "x", kind: .token, variable: "1A")) == .invalidVariable)
        #expect(problem(Connection(name: "x", kind: .token, variable: "A-B")) == .invalidVariable)
        #expect(problem(Connection(name: "x", kind: .token, variable: "")) == .invalidVariable)
        #expect(problem(Connection(name: "x", kind: .token, variable: "ANTHROPIC_API_KEY")) == .reservedVariable)
        #expect(problem(Connection(name: "x", kind: .token, variable: "KUBECONFIG")) == .reservedVariable)
        #expect(problem(Connection(name: "x", kind: .kubeconfig, variable: "KUBECONFIG")) == .missingFile)
        #expect(problem(Connection(name: "x", kind: .kubeconfig, variable: "KUBECONFIG", filePath: "/k")) == nil)
        #expect(problem(Connection(name: "x", kind: .mcpCommand, variable: "T")) == .missingCommand)
        #expect(problem(Connection(name: "x", kind: .mcpURL, variable: "T", url: "ftp://a")) == .invalidURL)
        #expect(problem(Connection(name: "x", kind: .mcpURL, variable: "T", url: "https://a.example/mcp")) == nil)
        let other = Connection(name: "o", kind: .token, variable: "T")
        #expect(problem(Connection(name: "x", kind: .token, variable: "T"), [other]) == .duplicateVariable)
        #expect(problem(other, [other]) == nil)
        let p1Only = Connection(name: "o1", kind: .token, variable: "T", projectIDs: [p1])
        #expect(problem(Connection(name: "x", kind: .token, variable: "T", projectIDs: [p2]), [p1Only]) == nil)
        #expect(problem(Connection(name: "x", kind: .token, variable: "T", projectIDs: [p1, p2]), [p1Only]) == .duplicateVariable)
        let jira = Connection(name: "Jira!", kind: .mcpURL, variable: "J1", url: "https://a.example/mcp")
        #expect(problem(Connection(name: "Jira?", kind: .mcpURL, variable: "J2", url: "https://b.example/mcp"), [jira]) == .duplicateServerName)
        #expect(ConnectionRules.isReserved("NODE_OPTIONS") && ConnectionRules.isReserved("DYLD_INSERT_LIBRARIES"))
    }

    @Test func environmentFollowsScopeAndSkipsMissingSecrets() {
        let all = Connection(name: "a", kind: .token, variable: "A_TOKEN")
        let only2 = Connection(name: "b", kind: .token, variable: "B_TOKEN", projectIDs: [p2])
        let off = Connection(name: "c", kind: .token, variable: "C_TOKEN", isEnabled: false)
        let noSecret = Connection(name: "d", kind: .token, variable: "D_TOKEN")
        let kube = Connection(name: "k", kind: .kubeconfig, variable: "KUBECONFIG", filePath: "/k/ro.yaml")
        let evil = Connection(name: "e", kind: .token, variable: "ANTHROPIC_API_KEY")
        let secrets: [UUID: String] = [all.id: "sa", only2.id: "sb", off.id: "sc", evil.id: "bad"]
        let env = ConnectionRules.environment([all, only2, off, noSecret, kube, evil], projectID: p1) { secrets[$0.id] }
        #expect(env == ["A_TOKEN": "sa", "KUBECONFIG": "/k/ro.yaml"])
        let env2 = ConnectionRules.environment([all, only2], projectID: p2) { secrets[$0.id] }
        #expect(env2 == ["A_TOKEN": "sa", "B_TOKEN": "sb"])
    }

    @Test func mcpConfigHoldsReferencesNotSecrets() throws {
        let cmd = Connection(name: "Issue Tracker", kind: .mcpCommand, variable: "TRACKER_TOKEN",
                             command: "npx", arguments: ["-y", "tracker-mcp"])
        let web = Connection(name: "Docs", kind: .mcpURL, variable: "DOCS_TOKEN", url: "https://docs.example/mcp",
                             headerName: "Authorization", headerPrefix: "Bearer ")
        let plain = Connection(name: "Public", kind: .mcpURL, variable: "PUB", url: "https://pub.example/mcp")
        let token = Connection(name: "t", kind: .token, variable: "T")
        let data = try #require(ConnectionRules.mcpConfigJSON([cmd, web, plain, token], projectID: nil,
                                                              hasSecret: { $0.id != plain.id }))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(json.path("mcpServers.issue-tracker.command")?.string == "npx")
        #expect(json.path("mcpServers.issue-tracker.args")?.array?.compactMap(\.string) == ["-y", "tracker-mcp"])
        #expect(json.path("mcpServers.issue-tracker.env.TRACKER_TOKEN")?.string == "${TRACKER_TOKEN}")
        #expect(json.path("mcpServers.docs.type")?.string == "http")
        #expect(json.path("mcpServers.docs.headers.Authorization")?.string == "Bearer ${DOCS_TOKEN}")
        #expect(json.path("mcpServers.public.headers") == nil)
        #expect(json.path("mcpServers.t") == nil)
        #expect(ConnectionRules.mcpConfigJSON([token], projectID: nil, hasSecret: { _ in true }) == nil)
    }

    @Test func launchPutsSecretsInTheEnvironmentNotTheCommandLine() {
        var launch = EnvBuilder.AgentLaunch(provider: .claude, account: nil, title: "t", agentSessionID: "s", resume: false)
        launch.mcpConfigPath = "/run/s/mcp.json"
        let vars = EnvBuilder.SessionVariables(socketPath: "/s", sessionID: UUID(), accountID: nil)
        let spec = EnvBuilder.launchSpec(launch, session: vars, cwd: "/w", processEnv: ["PATH": "/bin"],
                                         connections: ["MY_TOKEN": "secret-value", "ANTHROPIC_API_KEY": "x", "KUBECONFIG": "/k"])
        #expect(spec.environment["MY_TOKEN"] == "secret-value")
        #expect(spec.environment["KUBECONFIG"] == "/k")
        #expect(spec.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(!spec.args.joined(separator: " ").contains("secret-value"))
        #expect(spec.args.joined(separator: " ").contains("--mcp-config '/run/s/mcp.json'"))
        let shell = EnvBuilder.shellSpec(cwd: "/w", processEnv: ["PATH": "/bin"], connections: ["MY_TOKEN": "v"])
        #expect(shell.environment["MY_TOKEN"] == "v")
    }

    @Test func stateWithoutConnectionsDecodes() throws {
        let state = try JSONDecoder().decode(AppState.self, from: Data(#"{"version":1}"#.utf8))
        #expect(state.connections.isEmpty)
    }
}
