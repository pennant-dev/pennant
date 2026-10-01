import PennantClientKit
import PennantCore
import Foundation

// Scheduled jobs and goals.

@MainActor
func goalsCommand(_ options: CLIOptions) async throws {
    // pennant goals: every goal. pennant goals <title|id>: its board.
    // pennant goals edit <title|id> [--work "<when>"] [--review "<when>"] [--status proposed|active|paused|achieved|dropped]
    // pennant goals delete <title|id>: the goal, its board and its jobs (its conversation stays).
    let session = try await connect(options)
    if options.args.first == "delete" {
        let key = options.args.dropFirst().joined(separator: " ").lowercased()
        guard !key.isEmpty, let goal = session.state.goals.first(where: { $0.id.rawValue.lowercased().hasPrefix(key) || $0.title.lowercased() == key }) else { await session.disconnect(); fail("No goal \(key)") }
        let r = try await session.send(.deleteGoal(goal.id), timeout: 60)
        await session.disconnect()
        guard case .ok = r else { fail(replyError(r)) }
        out("Deleted \(goal.title), its board and its jobs. Its conversation stays.")
        return
    }
    if options.args.first == "edit" {
        var rest = Array(options.args.dropFirst())
        func take(_ flag: String) -> String? {
            guard let i = rest.firstIndex(of: flag), i + 1 < rest.count else { return nil }
            let v = rest[i + 1]; rest.removeSubrange(i...(i + 1)); return v
        }
        let work = take("--work"), review = take("--review"), status = take("--status")
        let key = rest.joined(separator: " ").lowercased()
        guard var goal = session.state.goals.first(where: { $0.id.rawValue.lowercased().hasPrefix(key) || $0.title.lowercased() == key }) else { await session.disconnect(); fail("No goal \(key)") }
        if let work { goal.workSchedule = work }
        if let review { goal.reviewSchedule = review }
        if let status { guard let s = Goal.Status(rawValue: status) else { await session.disconnect(); fail("Unknown status \(status)") }; goal.status = s }
        let r = try await session.send(.upsertGoal(goal), timeout: 60)
        await session.disconnect()
        guard case .goal(let saved) = r else { fail(replyError(r)) }
        out("\(saved.title): \(saved.status.rawValue), works \(saved.workSchedule), reviews \(saved.reviewSchedule)")
        return
    }
    let goals = session.state.goals
    let name: (AgentID) -> String = { id in session.state.agents.first { $0.id == id }?.name ?? "?" }
    if let key = options.args.first?.lowercased() {
        guard let goal = goals.first(where: { $0.id.rawValue.lowercased().hasPrefix(key) || $0.title.lowercased() == key }) else { await session.disconnect(); fail("No goal \(key)") }
        let r = try await session.send(.listGoalItems(goal.id), timeout: 30)
        await session.disconnect()
        guard case .goalItems(let items) = r else { fail(replyError(r)) }
        out("\(goal.title) — \(name(goal.ownerAgentID)), \(goal.status.rawValue), \(goal.freedom.title)")
        out("Outcome: \(goal.outcome)")
        if !goal.measure.isEmpty { out("Measure: \(goal.measure)") }
        for state in GoalItem.State.allCases {
            let list = items.filter { $0.state == state }.sorted { $0.rank < $1.rank }
            guard !list.isEmpty else { continue }
            out("\n\(state.title)")
            for item in list { out("  [\(shortID(item.id.rawValue))] \(item.title)\(item.notes.last.map { " — \($0.by): \($0.text.prefix(100))" } ?? "")") }
        }
        return
    }
    await session.disconnect()
    if goals.isEmpty { out("No goals yet."); return }
    for g in goals {
        let next = session.state.schedules.first { $0.goalID == g.id && $0.goalRun == "work" }?.nextRunAt.map { ISO8601.format($0) } ?? "-"
        out("\(g.status == .active ? "●" : "○") \(g.title) [\(shortID(g.id.rawValue))] \(name(g.ownerAgentID)) · \(g.status.rawValue) · next session \(next)")
    }
}

@MainActor
func schedulesCommand(_ options: CLIOptions) async throws {
    let session = try await connect(options)
    if options.args.first == "delete", options.args.count > 1 {
        let key = options.args.dropFirst().joined(separator: " ").lowercased()
        guard let job = session.state.schedules.first(where: { $0.id.rawValue.lowercased().hasPrefix(key) || $0.name.lowercased() == key }) else { fail("No job \(key)") }
        let r = try await session.send(.deleteSchedule(job.id), timeout: 60)
        if case .ok = r { out("Deleted '\(job.name)'.") } else { fail(replyError(r)) }
    }
    if options.args.first == "run", options.args.count > 1 {
        // The short id the listing shows, or the job's name.
        let key = options.args.dropFirst().joined(separator: " ").lowercased()
        let job = session.state.schedules.first { $0.id.rawValue.lowercased().hasPrefix(key) || $0.name.lowercased() == key }
        let r = try await session.send(.runScheduleNow(job?.id ?? ScheduleID(options.args[1])), timeout: 120)
        if case .schedule(let job) = r { out("Ran '\(job.name)'; task \(job.lastTaskID?.rawValue ?? "-")") }
    }
    // pennant schedules pin <id|name> <skill>: the skill a run always follows ("none" to unpin).
    if options.args.first == "pin", options.args.count > 2 {
        let key = options.args[1].lowercased(), skillName = options.args[2]
        guard var job = session.state.schedules.first(where: { $0.id.rawValue.lowercased().hasPrefix(key) || $0.name.lowercased() == key }) else { await session.disconnect(); fail("No job \(key)") }
        if skillName == "none" {
            job.skillID = nil
        } else {
            try await session.loadSkills()
            guard let skill = session.state.skills.filter({ $0.name == skillName }).max(by: { $0.version < $1.version }) else { await session.disconnect(); fail("No skill named \(skillName)") }
            job.skillID = skill.id
        }
        let saved = try await session.upsertSchedule(job)
        out("'\(saved.name)' \(skillName == "none" ? "has no pinned skill" : "follows \(skillName)").")
    }
    // pennant schedules edit <id|name> [--name <name>] [--prompt <prompt>]: rename a job or change what it's told.
    if options.args.first == "edit", options.args.count > 1 {
        var rest = Array(options.args.dropFirst(2))
        func take(_ flag: String) -> String? {
            guard let i = rest.firstIndex(of: flag), i + 1 < rest.count else { return nil }
            let v = rest[i + 1]
            rest.removeSubrange(i ... i + 1)
            return v
        }
        let key = options.args[1].lowercased()
        guard var job = session.state.schedules.first(where: { $0.id.rawValue.lowercased().hasPrefix(key) || $0.name.lowercased() == key }) else { await session.disconnect(); fail("No job \(key)") }
        let newName = take("--name"), newPrompt = take("--prompt")
        guard newName != nil || newPrompt != nil else { await session.disconnect(); fail("Usage: pennant schedules edit <id|name> [--name <name>] [--prompt <prompt>]") }
        if let newName { job.name = newName }
        if let newPrompt { job.prompt = newPrompt }
        let saved = try await session.upsertSchedule(job)
        out("Saved '\(saved.name)'.")
    }
    // pennant schedules add "<when>" <prompt…> [--skill <name>] [--name <name>]
    if options.args.first == "add" {
        var rest = Array(options.args.dropFirst())
        func take(_ flag: String) -> String? {
            guard let i = rest.firstIndex(of: flag), i + 1 < rest.count else { return nil }
            let v = rest[i + 1]
            rest.removeSubrange(i ... i + 1)
            return v
        }
        let skillName = take("--skill"), jobName = take("--name")
        guard rest.count >= 2 else { await session.disconnect(); fail("Usage: pennant schedules add \"<when>\" <prompt…> [--skill <name>] [--name <name>]") }
        guard let agent = session.state.leadAgent else { await session.disconnect(); fail("There's no agent yet.") }
        var skillID: SkillID?
        if let skillName {
            try await session.loadSkills()
            guard let skill = session.state.skills.first(where: { $0.name == skillName }) else { await session.disconnect(); fail("No skill named \(skillName)") }
            skillID = skill.id
        }
        let prompt = rest.dropFirst().joined(separator: " ")
        let job = try await session.upsertSchedule(ScheduledJob(name: jobName ?? String(prompt.prefix(40)), agentID: agent.id, skillID: skillID, prompt: prompt, schedule: rest[0]))
        out("Scheduled '\(job.name)' · \(job.schedule) · next \(job.nextRunAt.map { ISO8601.format($0) } ?? "-")")
    }
    let r = try await session.send(.listSchedules)
    guard case .schedules(let jobs) = r else { await session.disconnect(); fail("Unexpected reply") }
    if jobs.isEmpty { out("No scheduled jobs.") }
    for job in jobs {
        let agent = session.state.agents.first { $0.id == job.agentID }?.name ?? "?"
        out("\(job.enabled ? "●" : "○") \(job.name) [\(job.id.rawValue.prefix(8))] \(agent) · \(job.schedule) · next \(job.nextRunAt.map { ISO8601.format($0) } ?? "-") · runs \(job.runCount)\(job.lastOutcome.map { " · \($0.prefix(60))" } ?? "")")
    }
    await session.disconnect()
}
