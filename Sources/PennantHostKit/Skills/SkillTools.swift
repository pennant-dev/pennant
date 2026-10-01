import PennantCore
import Foundation

/// Learn, find, and use skills. Learning never grants access; a skill is just a recorded procedure.
public struct LearnSkillTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "learn_skill", description: "Save a verified, repeatable procedure as a skill (or a new version of an existing skill with the same name). Call it only after the procedure actually succeeded in this task. Include the checks that proved each step worked.", inputSchema: JSONSchema.object([
            "name": JSONSchema.string("Short imperative name, e.g. 'File a supplier invoice in Finance'."),
            "purpose": JSONSchema.string("What the skill accomplishes."),
            "applicability": JSONSchema.string("When to use it and when not to."),
            "prerequisites": JSONSchema.array(of: JSONSchema.string("A prerequisite."), "Apps, permissions, files, or state that must exist."),
            "inputs": JSONSchema.array(of: JSONSchema.string("An input name and meaning."), "Inputs the skill needs."),
            "steps": JSONSchema.array(of: JSONSchema.object([
                "instruction": JSONSchema.string("What to do."),
                "tool": JSONSchema.string("Preferred tool name, if any."),
                "arguments": ["type": "object", "description": "Template arguments; use {{input}} placeholders.", "additionalProperties": true],
                "check": JSONSchema.string("How to verify the step worked."),
            ], required: ["instruction"]), "Ordered steps."),
            "expected_result": JSONSchema.string("What success looks like."),
            "failure_conditions": JSONSchema.array(of: JSONSchema.string("A known failure condition."), "Known ways it fails."),
            "scripts": ["type": "object", "description": "Optional supporting scripts keyed by file name.", "additionalProperties": ["type": "string"]],
        ], required: ["name", "purpose", "steps"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("Skill learning is unavailable in this context") }
        let steps = (arguments["steps"]?.arrayValue ?? []).compactMap { s -> SkillStep? in
            guard let instruction = s.string("instruction") else { return nil }
            return SkillStep(instruction: instruction, tool: s.string("tool"), arguments: s["arguments"], check: s.string("check") ?? "")
        }
        guard !steps.isEmpty else { throw ToolError.invalidArguments("steps must not be empty") }
        var scripts: [String: String] = [:]
        if case .object(let o) = arguments["scripts"] ?? .null { for (k, v) in o { if let s = v.stringValue { scripts[k] = s } } }
        let skill = Skill(name: try arguments.requireString("name"), purpose: try arguments.requireString("purpose"), applicability: arguments.string("applicability") ?? "", prerequisites: arguments.stringArray("prerequisites") ?? [], inputs: arguments.stringArray("inputs") ?? [], steps: steps, expectedResult: arguments.string("expected_result") ?? "", failureConditions: arguments.stringArray("failure_conditions") ?? [], scripts: scripts, status: .provisional, evidenceTaskIDs: [context.taskID], createdByAgentID: context.agentID)
        let saved = try await hooks.learnSkill(context.taskID, skill)
        return .text(ToolCallID("pending"), name: spec.name, "Saved skill '\(saved.name)' v\(saved.version) as \(saved.status.rawValue) with \(saved.steps.count) steps. It will be offered for similar tasks.")
    }
}

public struct FindSkillTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "find_skill", description: "Search learned skills by purpose or name and return their full steps.", inputSchema: JSONSchema.object([
            "query": JSONSchema.string("What you are trying to do."),
        ], required: ["query"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let q = try arguments.requireString("query")
        let skills = try await context.store.searchSkills(text: q, limit: 3).filter { $0.status != .disabled }
        guard !skills.isEmpty else { return .text(ToolCallID("pending"), name: spec.name, "No matching skills.") }
        var out = ""
        for sk in skills {
            out += "## \(sk.name) v\(sk.version) [\(sk.status.rawValue)] id=\(sk.id.rawValue)\n\(sk.purpose)\n"
            if !sk.applicability.isEmpty { out += "When: \(sk.applicability)\n" }
            if !sk.prerequisites.isEmpty { out += "Prerequisites: \(sk.prerequisites.joined(separator: "; "))\n" }
            for (n, st) in sk.steps.enumerated() {
                out += "\(n + 1). \(st.instruction)"
                if let t = st.tool { out += " [\(t)" + (st.arguments.map { " \($0.compactText.prefix(120))" } ?? "") + "]" }
                if !st.check.isEmpty { out += " — check: \(st.check)" }
                if st.uncertain { out += " (uncertain)" }
                out += "\n"
            }
            if !sk.expectedResult.isEmpty { out += "Expected: \(sk.expectedResult)\n" }
            if !sk.failureConditions.isEmpty { out += "Fails when: \(sk.failureConditions.joined(separator: "; "))\n" }
            if !sk.body.isEmpty { out += "Instructions:\n\(sk.body.prefix(6000))\n" }
            for (name, body) in sk.scripts.sorted(by: { $0.key < $1.key }).prefix(6) { out += "File \(name):\n\(body.prefix(1500))\n" }
            out += "\n"
        }
        return .text(ToolCallID("pending"), name: spec.name, out)
    }
}

/// Records which skills a task used so outcomes can be attributed on completion.
public actor SkillUsageTracker {
    private var used: [TaskID: Set<SkillID>] = [:]
    public init() {}
    public func markUsed(_ skill: SkillID, in task: TaskID) { used[task, default: []].insert(skill) }
    public func usedSkills(in task: TaskID) -> Set<SkillID> { used[task] ?? [] }
    public func clear(_ task: TaskID) { used[task] = nil }
}

public struct UseSkillTool: Tool {
    let tracker: SkillUsageTracker
    public init(tracker: SkillUsageTracker) { self.tracker = tracker }
    public var spec: ToolSpec {
        ToolSpec(name: "use_skill", description: "Declare that you are following a skill for this task so its outcome can be recorded. Returns the skill steps.", inputSchema: JSONSchema.object([
            "skill_id": JSONSchema.string("The skill's id or its name (e.g. \"sre-ops\")."),
        ], required: ["skill_id"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let id = SkillID(try arguments.requireString("skill_id"))
        // Agents name skills by name as often as by id: accept either.
        var found = try await context.store.skill(id)
        if found == nil {
            let wanted = id.rawValue.trimmingCharacters(in: .whitespaces).lowercased()
            found = try await context.store.listSkills(includeDisabled: false).filter { $0.name.lowercased() == wanted }.max { $0.version < $1.version }
        }
        guard let asked = found, asked.status != .disabled else {
            let names = (try? await context.store.listSkills(includeDisabled: false).map(\.name)).map { Array(Set($0)).sorted().joined(separator: ", ") } ?? ""
            throw ToolError.failed("No skill with the id or name \"\(id.rawValue)\". Skills: \(names)")
        }
        // An id from memory or an old schedule may name an older version: follow the newest enabled one.
        let skill = (try? await context.store.listSkills(includeDisabled: false).filter { $0.name == asked.name }.max { $0.version < $1.version }) ?? asked
        await tracker.markUsed(skill.id, in: context.taskID)
        let steps = skill.steps.enumerated().map { "\($0.offset + 1). \($0.element.instruction)\($0.element.check.isEmpty ? "" : " — check: \($0.element.check)")" }.joined(separator: "\n")
        var text = "Following '\(skill.name)' v\(skill.version) (\(skill.status.rawValue))\(skill.id != asked.id ? " — the newest version; the id you used is v\(asked.version)" : "").\n\(steps)"
        // Where the skill's own files are, so instructions can refer to its scripts wherever it was installed.
        let folder = skill.folder
        if let folder { text += "\n\nSkill folder: \(folder)" }
        if let outputs = skill.outputs, !outputs.isEmpty { text += "\n\n" + outputs.guide }
        if !skill.body.isEmpty { text += "\n\nInstructions:\n\(skill.expandingFolder(skill.body).prefix(12000))" }
        if !skill.scripts.isEmpty { text += "\n\nFiles: \(skill.scripts.keys.sorted().joined(separator: ", ")) (contents available through find_skill)" }
        return .text(ToolCallID("pending"), name: spec.name, text)
    }
}
