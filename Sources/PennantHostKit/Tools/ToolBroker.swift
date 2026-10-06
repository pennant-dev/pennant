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

    /// The tool a model meant by `name`: its exact name, or a connection's tool written the ways models write one
    /// ("mcp:<server>:<tool>", "<server>/<tool>", the server by its name or its id, in any case), when exactly one
    /// tool matches.
    public func resolve(_ name: String) -> (any Tool)? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = tools[name] { return exact }
        guard let (server, tool) = Self.splitConnectionName(name) else { return nil }
        let prefix = Self.connectionPrefix(server)
        if let named = tools["\(prefix)__\(tool)"] { return named }
        // The server written by its id ("mcp:microsoft-365:…") rather than its name.
        let byID = tools.values.filter {
            $0.spec.source.hasPrefix("mcp:") && Self.connectionPrefix(String($0.spec.source.dropFirst(4))) == prefix && $0.spec.name.hasSuffix("__" + tool)
        }
        return byID.count == 1 ? byID[0] : nil
    }

    /// Why `name` names no tool, in words an agent can act on: the closest real names, or that its connection isn't
    /// connected right now.
    public func whyMissing(_ name: String) -> String {
        let split = Self.splitConnectionName(name)
        let tail = split?.tool ?? name
        let close = tools.keys.filter { $0 == tail || $0.hasSuffix("__" + tail) }.sorted()
        if !close.isEmpty {
            return "There's no tool named \(name). Did you mean \(close.prefix(3).joined(separator: " or "))? Name a tool exactly as you call it."
        }
        if let split, !tools.keys.contains(where: { $0.hasPrefix(Self.connectionPrefix(split.server) + "__") }) {
            return "There's no tool named \(name): no connection called \(split.server) is connected right now. Check it in Connections."
        }
        return "There's no tool named \(name). Name a tool exactly as you call it; a connection's tools look like <connection>__<tool>."
    }

    /// How a connection's name prefixes its tools' names: lower case, with anything but letters and digits as "_".
    public static func connectionPrefix(_ server: String) -> String {
        server.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
    }

    /// "mcp:<server>:<tool>", "<server>:<tool>", "<server>/<tool>" or "<server>__<tool>", as its two halves.
    static func splitConnectionName(_ name: String) -> (server: String, tool: String)? {
        var rest = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.lowercased().hasPrefix("mcp:") { rest = String(rest.dropFirst(4)) }
        guard let cut = rest.range(of: "__") ?? rest.range(of: ":", options: .backwards) ?? rest.range(of: "/", options: .backwards) else { return nil }
        let server = String(rest[..<cut.lowerBound]), tool = String(rest[cut.upperBound...])
        return server.isEmpty || tool.isEmpty ? nil : (server, tool)
    }

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
