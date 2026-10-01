import PennantCore
import Foundation

/// Tools that let the agent read and write memory explicitly. Writes carry provenance to the current task.
public struct MemorySearchTool: Tool {
    let memory: MemoryService
    public init(memory: MemoryService) { self.memory = memory }
    public var spec: ToolSpec {
        ToolSpec(name: "memory_search", description: "Search long-term memory: people, projects, documents, deadlines, instructions, and earlier conversations. Use before asking the user something they may have told you before.", inputSchema: JSONSchema.object([
            "query": JSONSchema.string("Words or a name to search for."),
            "limit": JSONSchema.integer("Maximum results (default 12)."),
        ], required: ["query"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let q = try arguments.requireString("query")
        let agent = try await context.store.agent(context.agentID)
        // Not the conversation being worked on: the agent already has it.
        let hits = try await memory.retrieve(MemoryQuery(text: q, limit: arguments.int("limit") ?? 12), agent: agent, excludingConversation: context.conversationID,
                                            includeInstructions: false)
        let text = hits.isEmpty ? "No memories matched." : MemoryService.render(hits)
        return .text(ToolCallID("pending"), name: spec.name, text)
    }
}

public struct MemoryRememberTool: Tool {
    let memory: MemoryService
    public init(memory: MemoryService) { self.memory = memory }
    public var spec: ToolSpec {
        ToolSpec(name: "memory_remember", description: "Store a durable fact about a person, project, document, application, deadline, or other entity, with optional relationships. Use `asserted` only when the user stated it or you read it directly from a source; use `inferred` for your own conclusions.", inputSchema: JSONSchema.object([
            "kind": JSONSchema.string("Entity kind.", enumValues: MemoryEntityKind.allCases.map(\.rawValue)),
            "name": JSONSchema.string("Canonical name, e.g. 'Invoice 042' or 'Project Atlas'."),
            "summary": JSONSchema.string("One sentence describing the entity."),
            "attributes": ["type": "object", "description": "Key facts such as email, path, due_date, amount.", "additionalProperties": true],
            "status": JSONSchema.string("asserted or inferred.", enumValues: ["asserted", "inferred"]),
            "shared": JSONSchema.boolean("True (the default) so every agent can use it; false only for something private to you."),
            "relations": JSONSchema.array(of: JSONSchema.object([
                "relation": JSONSchema.string("Relationship label, e.g. belongs_to, owned_by, due_for."),
                "target_name": JSONSchema.string("Name of the related entity."),
                "target_kind": JSONSchema.string("Kind of the related entity.", enumValues: MemoryEntityKind.allCases.map(\.rawValue)),
            ], required: ["relation", "target_name", "target_kind"]), "Relationships from this entity to others."),
        ], required: ["kind", "name"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let kind = MemoryEntityKind(rawValue: arguments.string("kind") ?? "fact") ?? .fact
        let name = try arguments.requireString("name")
        let status: MemoryStatus = (arguments.string("status") ?? "inferred") == "asserted" ? .asserted : .inferred
        let agent = try await context.store.agent(context.agentID)
        // Facts are shared by default: what one agent learns, the others can use.
        let scope = (arguments.bool("shared") ?? true) ? "shared" : (agent?.memoryScope.label ?? "shared")
        let provenance = Provenance(sourceType: status == .asserted ? .userMessage : .inference, sourceID: context.taskID.rawValue, agentID: context.agentID, note: "memory_remember during task")
        let entity = try await memory.assertEntity(kind: kind, name: name, attributes: arguments["attributes"] ?? .object([:]), summary: arguments.string("summary") ?? "", scope: scope, status: status, provenance: provenance)
        var lines = ["Remembered \(entity.kind.rawValue) '\(entity.name)' as \(entity.status.rawValue) (v\(entity.version))."]
        if entity.status == .contradicted { lines.append("Note: this conflicts with a fact the user asserted earlier; the asserted fact remains current. Ask the user if it matters.") }
        for rel in arguments["relations"]?.arrayValue ?? [] {
            guard let relation = rel.string("relation"), let target = rel.string("target_name") else { continue }
            let targetKind = MemoryEntityKind(rawValue: rel.string("target_kind") ?? "other") ?? .other
            let r = try await memory.relate(fromName: entity.name, fromKind: entity.kind, relation: relation, toName: target, toKind: targetKind, scope: scope, status: status, provenance: provenance)
            lines.append("Linked \(entity.name) —\(r.relation)→ \(target).")
        }
        return .text(ToolCallID("pending"), name: spec.name, lines.joined(separator: "\n"))
    }
}

public struct MemoryPreferenceTool: Tool {
    let memory: MemoryService
    public init(memory: MemoryService) { self.memory = memory }
    public var spec: ToolSpec {
        ToolSpec(name: "remember_instruction", description: "Record an explicit standing instruction or preference the user just gave that should govern future work (e.g. 'always file invoices under Finance/2026'). Quote the user's intent faithfully. Do not use for guesses.", inputSchema: JSONSchema.object([
            "instruction": JSONSchema.string("The instruction in one or two sentences."),
            "shared": JSONSchema.boolean("True if it applies to every agent (default true)."),
        ], required: ["instruction"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let text = try arguments.requireString("instruction")
        let agent = try await context.store.agent(context.agentID)
        let shared = arguments.bool("shared") ?? true
        let scope = shared ? "shared" : (agent?.memoryScope.label ?? "shared")
        let pref = try await memory.addPreference(text: text, scope: scope, provenance: Provenance(sourceType: .userMessage, sourceID: context.taskID.rawValue, agentID: context.agentID, note: "remember_instruction during task"))
        return .text(ToolCallID("pending"), name: spec.name, "Recorded instruction v\(pref.version): \"\(pref.text)\"")
    }
}
