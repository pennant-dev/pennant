import PennantCore
import Foundation

/// Writes code: hands a change to the coding engine set in Settings › Pennant › Coding, which works in one of the
/// project folders on this Mac and acts on GitHub as the host's own App. Its steps show in a thread under the one that
/// asked.
public struct CodeTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "code", description: "Make a code change: the coding engine the owner set up works in one of the coding projects on this Mac, runs tests, and commits, pushes and opens pull requests as your own GitHub App (never as the owner). Its steps show in a thread under this one. Returns the task id: call await_task with it for the result. Use it for anything that edits a repository; read code yourself with the shell for a quick answer.", inputSchema: JSONSchema.object([
            "request": JSONSchema.string("A self-contained request: what to change and why, where (repository, files, branch), how to check it, and what to hand back (a PR link, a summary)."),
            "folder": JSONSchema.string("Which coding project to work in, by name (listed in your instructions), or a folder path on this Mac. Default: the first project. Ignored when continuing a thread."),
            "mode": JSONSchema.string("How it asks before acting (default: the owner's setting): \"edit\" (only publishing, email, deleting and spending ask), \"plan\" (writes a plan for the owner to approve first), \"ask\" (every step asks)."),
            "thread": JSONSchema.string("Continue one of your earlier coding threads (its conversation id) instead of starting fresh: a follow-up with the context it already has."),
        ], required: ["request"]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("Coding unavailable") }
        let mode: CodingMode?
        switch arguments.string("mode")?.lowercased() {
        case nil, "", "edit", "edits": mode = nil
        case "plan": mode = .plan
        case "ask", "manual": mode = .manual
        case let other?: throw ToolError.invalidArguments("mode is edit, plan or ask, not \(other)")
        }
        let thread = arguments.string("thread")?.nilIfEmpty.map { ConversationID($0) }
        let (taskID, conversationID) = try await hooks.startCoding(try arguments.requireString("request"), arguments.string("folder")?.nilIfEmpty, mode, thread)
        return .text(ToolCallID("pending"), name: spec.name, "Coding run started (task \(taskID.rawValue), thread \(conversationID.rawValue)). Call await_task with the task id for the result; pass the thread id to follow up.")
    }
}

public struct ScheduleJobTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "schedule_job", description: "Create a scheduled job that runs a prompt (optionally following a skill) on a schedule. Expressions: 'every 15m', 'every 2h', 'hourly', 'daily at 09:00', 'weekdays at 08:30', 'weekly on mon,thu at 18:00', 'monthly on 1 at 07:00', 'once at 2026-10-01 09:00', or 5-field cron. The prompt must be self-contained.", inputSchema: JSONSchema.object([
            "name": JSONSchema.string("Short job name."),
            "schedule": JSONSchema.string("Schedule expression."),
            "prompt": JSONSchema.string("What to do on each run."),
            "skill_id": JSONSchema.string("Optional skill id to follow."),
        ], required: ["name", "schedule", "prompt"]), isConsequential: true)
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("Scheduling unavailable") }
        let job = try await hooks.scheduleJob(try arguments.requireString("name"), try arguments.requireString("schedule"), try arguments.requireString("prompt"), arguments.string("skill_id").map { SkillID($0) })
        let next = job.nextRunAt.map { ISO8601.format($0) } ?? "never"
        return .text(ToolCallID("pending"), name: spec.name, "Scheduled '\(job.name)' (id \(job.id.rawValue)) \(job.schedule); next run \(next). Runs appear in the conversation named ⏰ \(job.name).")
    }
}

public struct ListSchedulesTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "list_schedules", description: "List scheduled jobs with their next run, last outcome, and ids.", inputSchema: JSONSchema.object([:]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let jobs = try await context.store.listSchedules()
        let agents = try await context.store.listAgents(includeRetired: true)
        let lines = jobs.map { job -> String in
            let agent = agents.first { $0.id == job.agentID }?.name ?? "?"
            return "- \(job.name) (id \(job.id.rawValue)) for \(agent): \(job.schedule) · \(job.enabled ? "next \(job.nextRunAt.map { ISO8601.format($0) } ?? "-")" : "disabled") · runs \(job.runCount)\(job.lastOutcome.map { " · last: \($0.prefix(80))" } ?? "")"
        }
        return .text(ToolCallID("pending"), name: spec.name, lines.isEmpty ? "No scheduled jobs." : lines.joined(separator: "\n"))
    }
}

public struct CancelScheduleTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "cancel_schedule", description: "Delete a scheduled job by id (from list_schedules).", inputSchema: JSONSchema.object([
            "schedule_id": JSONSchema.string("The job id."),
        ], required: ["schedule_id"]), isConsequential: true)
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("Scheduling unavailable") }
        let id = ScheduleID(try arguments.requireString("schedule_id"))
        try await hooks.deleteSchedule(id)
        return .text(ToolCallID("pending"), name: spec.name, "Deleted schedule \(id.rawValue).")
    }
}

public struct ImportSkillsTool: Tool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "import_skills", description: "Import SKILL.md skills (Claude Code, Codex, Agent Skills format) from a folder into Pennant. Without a path, lists known skill folders on this Mac.", inputSchema: JSONSchema.object([
            "path": JSONSchema.string("Folder (or SKILL.md) to import. Omit to list known locations."),
        ]))
    }
    public func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("Import unavailable") }
        guard let path = arguments.string("path"), !path.isEmpty else {
            let locations = SkillImporter.knownLocations(workingDirectory: context.config.workingDirectory)
            let lines = locations.map { "- \($0.path) (\($0.harness), \($0.skillCount) skills)" }
            return .text(ToolCallID("pending"), name: spec.name, lines.isEmpty ? "No known skill folders found. Ask the user for a path." : "Known skill folders:\n" + lines.joined(separator: "\n") + "\nCall import_skills with one of these paths to import it.")
        }
        let (skills, warnings) = try await hooks.importSkills(path)
        var text = skills.isEmpty ? "Nothing imported." : "Imported \(skills.count) skill(s):\n" + skills.map { "- \($0.name) v\($0.version) (id \($0.id.rawValue))" }.joined(separator: "\n")
        if !warnings.isEmpty { text += "\nWarnings:\n" + warnings.map { "- \($0)" }.joined(separator: "\n") }
        return .text(ToolCallID("pending"), name: spec.name, text)
    }
}
