import PennantCore
import Foundation

/// Registry of tools available to the model. Built-in tools are always present; MCP tools are
/// registered as their servers connect. Descriptions can be filtered per agent to keep context small.
public actor ToolBroker {
    private var tools: [String: any Tool] = [:]
    /// Tool names grouped by MCP server so they can be unloaded when a server disconnects.
    private var mcpToolNames: [MCPServerID: [String]] = [:]

    public init() {}

    public func register(_ tool: any Tool) {
        tools[tool.spec.name] = tool
    }

    public func register(_ list: [any Tool]) {
        for t in list { register(t) }
    }

    public func registerMCPTools(_ list: [any Tool], server: MCPServerID) {
        unregisterMCPTools(server: server)
        for t in list { tools[t.spec.name] = t }
        mcpToolNames[server] = list.map(\.spec.name)
    }

    public func unregisterMCPTools(server: MCPServerID) {
        for name in mcpToolNames[server] ?? [] { tools[name] = nil }
        mcpToolNames[server] = nil
    }

    public func tool(named name: String) -> (any Tool)? { tools[name] }

    public var allSpecs: [ToolSpec] { tools.values.map(\.spec).sorted { $0.name < $1.name } }

    /// Specs visible to an agent. Empty allowlist means every builtin tool plus MCP tools. Granted tools only for the
    /// agents given them; approval-only tools for nobody.
    public func specs(for agent: AgentProfile, mcpServersEnabled: Bool = true) -> [ToolSpec] {
        var out = allSpecs.filter { Self.mayUse($0, agent) }
        if !mcpServersEnabled { out = out.filter { $0.source == "builtin" } }
        if !agent.toolAllowlist.isEmpty {
            let allow = Set(agent.toolAllowlist)
            out = out.filter { allow.contains($0.name) || allow.contains($0.source) }
        }
        return out
    }

    /// Whether an agent may call a tool itself, by its access (the allowlist is checked separately).
    public static func mayUse(_ spec: ToolSpec, _ agent: AgentProfile) -> Bool {
        switch spec.access {
        case nil: return true
        case .granted: return agent.grantedTools?.contains(spec.name) == true
        case .approvalOnly: return false
        }
    }

}
