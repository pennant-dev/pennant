import PennantCore
import Foundation

/// How Pennant reviews its own health and proposes fixes (the health review, `HealthReview`). Reading is free; every
/// change is a proposal the owner approves on a card, and only then does `apply_proposed_change` (which no agent can
/// call) make it. These tools are `granted`: only an agent the owner gave them to sees them.
public struct HealthTools: Sendable {
    public var store: SQLiteStore
    public var logURL: URL
    public var schedules: @Sendable () async throws -> [ScheduledJob]
    /// Replaces the agent's profile (keeping its status), and tells the apps.
    public var updateAgent: @Sendable (AgentProfile) async throws -> AgentProfile
    public var setSkillStatus: @Sendable (SkillID, SkillStatus) async throws -> Skill

    public init(store: SQLiteStore, logURL: URL, schedules: @escaping @Sendable () async throws -> [ScheduledJob], updateAgent: @escaping @Sendable (AgentProfile) async throws -> AgentProfile,
                setSkillStatus: @escaping @Sendable (SkillID, SkillStatus) async throws -> Skill) {
        self.store = store; self.logURL = logURL; self.schedules = schedules; self.updateAgent = updateAgent; self.setSkillStatus = setSkillStatus
    }

    /// The tools, for the broker.
    public var tools: [any Tool] {
        [HealthReportTool(health: self), RecentFailuresTool(health: self), SkillStatsTool(health: self), AgentDetailsTool(health: self),
         ProposeAgentChangeTool(health: self), ProposeSkillChangeTool(health: self), ProposeCodeChangeTool(), ApplyProposedChangeTool(health: self)]
    }

    /// The newest version of each skill, by name.
    func newestSkills() async throws -> [Skill] {
        var newest: [String: Skill] = [:]
        for s in try await store.listSkills(includeDisabled: true) {
            let key = s.name.lowercased()
            if let seen = newest[key], seen.version >= s.version { continue }
            newest[key] = s
        }
        return newest.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// What the coding run is told when a code change is approved: the approved brief, and how to work so nothing of
    /// the owner's is touched and nothing ships without their review.
    static func codeBrief(_ text: String, branch: String) -> String {
        """
        An approved code change from Pennant's health review (how its runs, skills and jobs are doing). The owner approved this brief:

        \(text)

        How to work:
        - Make your own git worktree on a new branch so the owner's working copy and any uncommitted changes stay untouched: `git worktree add ../$(basename "$PWD")-\(branch.replacingOccurrences(of: "/", with: "-")) -b \(branch)`, and work there.
        - Find the cause first. Fix it with the smallest change that does it, and add or update a test that fails without the fix.
        - Run the project's test suite in the worktree. Commit on \(branch) only when it passes, with a message that says what was wrong and why the fix works.
        - Don't push, merge, deploy or release anything. The owner reviews the branch.
        - Reply with: the branch, what was wrong, what you changed, the test results, and anything you weren't sure about.
        """
    }

    func skill(named name: String) async throws -> Skill {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let s = try await newestSkills().first(where: { $0.name.lowercased() == key || $0.id.rawValue.lowercased().hasPrefix(key) }) else {
            throw ToolError.invalidArguments("No skill called \"\(name)\". Call skill_stats for the list.")
        }
        return s
    }

    /// Warnings and errors from the host's log since a date, alike lines counted together.
    func logProblems(since: Date, limit: Int = 8) -> [(line: String, count: Int)] {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var counts: [String: Int] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n") where line.contains(" WARN ") || line.contains(" ERROR ") {
            guard let stamp = line.split(separator: " ").first, let at = iso.date(from: String(stamp)), at >= since else { continue }
            let message = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? String(line)
            let key = Self.shape(message)
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        let problems: [(line: String, count: Int)] = order.map { (line: $0, count: counts[$0] ?? 0) }
        return Array(problems.sorted { $0.count > $1.count }.prefix(limit))
    }

    /// A message with its ids, numbers and quoted specifics blanked, so alike problems count together.
    static func shape(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\b\\d+(\\.\\d+)?\\b", with: "#", options: .regularExpression)
        return String(s.prefix(160))
    }

    static func rate(_ s: Skill) -> Double { s.successRate ?? 0 }

    /// An answer that refers to something other than itself ("the report above", "see the card").
    static func pointsElsewhere(_ answer: String) -> Bool {
        let a = answer.lowercased()
        return ["report above", "in the report", "see the report", "the card above", "see the card", "above report", "attached report", "posted report", "in my report"].contains { a.contains($0) }
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    static func seconds(_ s: Double?) -> String {
        guard let s else { return "–" }
        return s < 60 ? String(format: "%.1fs", s) : String(format: "%.1fmin", s / 60)
    }
}

// MARK: Reading

struct HealthReportTool: Tool {
    let health: HealthTools
    var spec: ToolSpec {
        ToolSpec(name: "health_report", description: "How Pennant has been doing over the last days: tasks finished, failed and cancelled, reply times (median and slow end) and cost, for its own work, its helpers and its coding runs; the commonest failure reasons; tool calls that failed or were refused; model warnings (retries, fallbacks); weak skills; and warnings in the host's log. Read-only.", inputSchema: JSONSchema.object([
            "days": JSONSchema.integer("How many days back (default 7, at most 30)."),
        ]), access: .granted)
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let days = min(max(arguments.int("days") ?? 7, 1), 30)
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        let activity = try await health.store.recentActivity(since: since)
        let agents = try await health.store.listAgents(includeRetired: true)
        let workers = Set(agents.filter { $0.kind == .worker }.map(\.id))
        let codingThreads = Set(try await health.store.listConversations(agentID: context.agentID).filter(\.isCodingRun).map(\.id))
        let me = agents.first { $0.id == context.agentID }?.name ?? "Pennant"
        // Everything that isn't a helper's or a coding run's is Pennant's own, including work from before the rename.
        func who(_ id: AgentID?) -> String { id.map(workers.contains) == true ? "Helpers" : me }
        func bucket(_ t: TaskRecord) -> String { codingThreads.contains(t.conversationID) ? "Coding runs" : who(t.agentID) }
        var out = ["\(me) health, last \(days) day\(days == 1 ? "" : "s") (since \(since.formatted(date: .abbreviated, time: .shortened)))."]

        out.append("\n## Work\nwho | tasks | done | failed | cancelled | median reply | slowest 10% | cost")
        let byBucket = Dictionary(grouping: activity.tasks, by: bucket)
        let replies = Dictionary(grouping: activity.replies) { who($0.agentID) }
        var spend: [String: Double] = [:]
        for s in activity.spend { spend[s.coding ? "Coding runs" : who(s.agentID), default: 0] += s.cost }
        let rows = Set(byBucket.keys).union(replies.keys).union(spend.keys)
        for row in rows.sorted(by: { (byBucket[$0]?.count ?? 0) > (byBucket[$1]?.count ?? 0) }) {
            let t = byBucket[row] ?? []
            let r = (replies[row] ?? []).map(\.seconds)
            out.append("\(row) | \(t.count) | \(t.filter { $0.state == .completed }.count) | \(t.filter { $0.state == .failed }.count) | \(t.filter { $0.state == .cancelled }.count) | \(HealthTools.seconds(HealthTools.percentile(r, 0.5))) | \(HealthTools.seconds(HealthTools.percentile(r, 0.9))) | $\(String(format: "%.2f", spend[row] ?? 0))")
        }

        let failures = activity.tasks.filter { $0.state == .failed }
        if !failures.isEmpty {
            out.append("\n## Commonest failure reasons")
            let grouped = Dictionary(grouping: failures) { HealthTools.shape($0.stateReason.isEmpty ? "(no reason given)" : $0.stateReason) }
            for (reason, list) in grouped.sorted(by: { $0.value.count > $1.value.count }).prefix(8) {
                out.append("- \(list.count)× \(reason) — \(Set(list.map(bucket)).sorted().joined(separator: ", "))")
            }
        }

        if !activity.badToolCalls.isEmpty {
            out.append("\n## Tool calls that went wrong (failed / refused / unknown outcome, of all calls)")
            let grouped = Dictionary(grouping: activity.badToolCalls, by: \.call.name)
            for (tool, list) in grouped.sorted(by: { $0.value.count > $1.value.count }).prefix(10) {
                let f = list.filter { $0.status == .failed }.count, d = list.filter { $0.status == .denied }.count, u = list.filter { $0.status == .uncertain }.count
                let sample = list.first.map { HealthTools.shape($0.resultSummary) } ?? ""
                out.append("- \(tool): \(f) failed, \(d) refused, \(u) unknown of \(activity.toolCallCounts[tool] ?? list.count). e.g. \(sample)")
            }
        }

        if !activity.warnings.isEmpty {
            out.append("\n## Model and runtime warnings")
            let grouped = Dictionary(grouping: activity.warnings) { HealthTools.shape($0.text) }
            for (text, list) in grouped.sorted(by: { $0.value.count > $1.value.count }).prefix(8) {
                out.append("- \(list.count)× \(text)")
            }
        }

        // Hand-offs: the task that asked gets only the answer's final words. An answer that points at a card or "the
        // report above" didn't reach it; asking again in one task is the sign.
        let asked = activity.tasks.filter { $0.requestedByTaskID != nil }
        let unseen = asked.filter { t in activity.tasksWithReports.contains(t.id) || HealthTools.pointsElsewhere(t.resultSummary ?? "") }
        let reasked = Dictionary(grouping: asked) { $0.requestedByTaskID!.rawValue }.values.filter { $0.count > 1 }
        if !unseen.isEmpty || !reasked.isEmpty {
            out.append("\n## Hand-offs to coding runs (\(asked.count))")
            if !unseen.isEmpty {
                out.append("- \(unseen.count)× an answer the asking task couldn't read (it pointed at a report card or \"above\"; the asker only gets the final words). e.g.:")
                for t in unseen.prefix(3) {
                    out.append("    \"\(t.title.prefix(70))\" → \"\((t.resultSummary ?? "").prefix(140))\"\(activity.tasksWithReports.contains(t.id) ? " (posted a report card)" : "")")
                }
            }
            if !reasked.isEmpty {
                out.append("- \(reasked.count)× a task asked again (the first answer didn't do):")
                for group in reasked.prefix(3) { out.append("    \(group.count) asks, e.g. \"\(group.last!.title.prefix(90))\"") }
            }
        }

        let weak = try await health.newestSkills().filter { $0.status != .disabled && $0.outcomes.count >= 3 && HealthTools.rate($0) < 0.6 }
        if !weak.isEmpty {
            out.append("\n## Skills that often fail")
            for s in weak { out.append("- \(s.name) v\(s.version): \(Int(HealthTools.rate(s) * 100))% of \(s.outcomes.count) uses") }
        }

        let log = health.logProblems(since: since)
        if !log.isEmpty {
            out.append("\n## Host log warnings and errors")
            for p in log { out.append("- \(p.count)× \(p.line)") }
        }
        return .text(ToolCallID("pending"), name: spec.name, out.joined(separator: "\n"))
    }
}

struct RecentFailuresTool: Tool {
    let health: HealthTools
    var spec: ToolSpec {
        ToolSpec(name: "recent_failures", description: "The latest failed tasks (title, who, reason, when, conversation) and tool calls that failed or were refused (with their arguments), to find out what went wrong. Read-only.", inputSchema: JSONSchema.object([
            "days": JSONSchema.integer("How many days back (default 2, at most 30)."),
            "limit": JSONSchema.integer("How many of each (default 15, at most 50)."),
        ]), access: .granted)
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let days = min(max(arguments.int("days") ?? 2, 1), 30)
        let limit = min(max(arguments.int("limit") ?? 15, 1), 50)
        let activity = try await health.store.recentActivity(since: Date().addingTimeInterval(-Double(days) * 86400))
        let agents = try await health.store.listAgents(includeRetired: true)
        func name(_ id: AgentID) -> String { agents.first { $0.id == id }?.name ?? "?" }
        var out: [String] = []
        let failed = activity.tasks.filter { $0.state == .failed }.prefix(limit)
        out.append("## Failed tasks (\(failed.count))")
        for t in failed {
            out.append("- \(t.updatedAt.formatted(date: .abbreviated, time: .shortened)) · \(name(t.agentID)) · \"\(t.title.prefix(80))\" — \(t.stateReason.prefix(240)) (task \(t.id.rawValue.prefix(8)), conversation \(t.conversationID.rawValue.prefix(8)))")
        }
        let bad = activity.badToolCalls.prefix(limit)
        out.append("\n## Tool calls that went wrong (\(bad.count))")
        for r in bad {
            let args = (try? String(data: JSONEncoder().encode(r.call.arguments), encoding: .utf8)) ?? ""
            out.append("- \(r.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(name(r.agentID)) · \(r.call.name) [\(r.status.rawValue)] args \(args.prefix(200)) → \(r.resultSummary.prefix(200))")
        }
        return .text(ToolCallID("pending"), name: spec.name, out.joined(separator: "\n"))
    }
}

struct SkillStatsTool: Tool {
    let health: HealthTools
    var spec: ToolSpec {
        ToolSpec(name: "skill_stats", description: "Skills with their version, status, how often they were used and how often that worked, and recent failure notes. With a name: that skill in full (its instructions, steps and outcomes). Read-only.", inputSchema: JSONSchema.object([
            "name": JSONSchema.string("A skill's name, for the full skill."),
        ]), access: .granted)
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        if let name = arguments.string("name"), !name.isEmpty {
            let s = try await health.skill(named: name)
            var out = ["\(s.name) v\(s.version) (\(s.status.rawValue), \(s.origin)) — \(s.purpose)"]
            if !s.applicability.isEmpty { out.append("When: \(s.applicability)") }
            out.append("Used \(s.outcomes.count)×, \(s.outcomes.isEmpty ? "no outcomes yet" : "\(Int(HealthTools.rate(s) * 100))% worked")")
            for o in s.outcomes.suffix(8) where !o.succeeded { out.append("- failed \(o.at.formatted(date: .abbreviated, time: .omitted)): \(o.note.prefix(200))") }
            if !s.steps.isEmpty { out.append("Steps:"); for (i, step) in s.steps.enumerated() { out.append("\(i + 1). \(step.instruction)\(step.check.isEmpty ? "" : " (check: \(step.check))")") } }
            if !s.body.isEmpty { out.append("Instructions:\n\(s.body)") }
            return .text(ToolCallID("pending"), name: spec.name, out.joined(separator: "\n"))
        }
        let skills = try await health.newestSkills()
        var out = ["skill | version | status | uses | worked | last failure"]
        for s in skills.sorted(by: { $0.outcomes.count > $1.outcomes.count }) {
            let lastFail = s.outcomes.last { !$0.succeeded }.map { "\($0.at.formatted(date: .abbreviated, time: .omitted)): \($0.note.prefix(80))" } ?? ""
            out.append("\(s.name) | v\(s.version) | \(s.status.rawValue) | \(s.outcomes.count) | \(s.outcomes.isEmpty ? "–" : "\(Int(HealthTools.rate(s) * 100))%") | \(lastFail)")
        }
        return .text(ToolCallID("pending"), name: spec.name, out.joined(separator: "\n"))
    }
}

struct AgentDetailsTool: Tool {
    let health: HealthTools
    var spec: ToolSpec {
        ToolSpec(name: "agent_details", description: "Your own setup: role, style, your full instructions, model, tools, preferred skills, scheduled jobs, and how your tasks went this week. Read-only.", inputSchema: JSONSchema.object([:]), access: .granted)
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let a = try await health.store.agent(context.agentID) else { throw ToolError.failed("Agent not found") }
        var out = ["\(a.name) — \(a.role)", "Style: \(a.style.isEmpty ? "–" : a.style)"]
        out.append("Model profile: \(a.modelProfileID ?? "the host's default")\(a.reasoningEffort.map { ", reasoning \($0)" } ?? "")")
        out.append("Tools: \(a.toolAllowlist.isEmpty ? "the default set" : a.toolAllowlist.joined(separator: ", "))\(a.grantedTools?.isEmpty == false ? "; granted: \(a.grantedTools!.joined(separator: ", "))" : "")")
        if !a.skillIDs.isEmpty { out.append("Preferred skills: \(a.skillIDs.map(\.rawValue).joined(separator: ", "))") }
        let jobs = try await health.schedules().filter { $0.agentID == a.id }
        for j in jobs { out.append("Job \"\(j.name)\" \(j.schedule)\(j.lastOutcome.map { " — last: \($0.prefix(120))" } ?? "")") }
        let week = try await health.store.recentActivity(since: Date().addingTimeInterval(-7 * 86400))
        let tasks = week.tasks.filter { $0.agentID == a.id }
        out.append("This week: \(tasks.count) tasks, \(tasks.filter { $0.state == .failed }.count) failed, \(tasks.filter { $0.state == .cancelled }.count) cancelled.")
        out.append("Instructions:\n\(a.instructions.isEmpty ? "(none)" : a.instructions)")
        return .text(ToolCallID("pending"), name: spec.name, out.joined(separator: "\n"))
    }
}

// MARK: Proposing

struct ProposeAgentChangeTool: Tool {
    let health: HealthTools
    var spec: ToolSpec {
        ToolSpec(name: "propose_agent_change", description: "Propose a change to your own instructions, role or style, shown to the owner as an approval card with your reasons. Nothing changes until they approve (they can edit the text first). It returns at once; you'll hear if they ask for changes.", inputSchema: JSONSchema.object([
            "change": JSONSchema.string("instructions, role, or style."),
            "text": JSONSchema.string("The new instructions, role or style in full (it replaces the old)."),
            "why": JSONSchema.string("What you saw that calls for this (failures, slow replies, repeated corrections), with numbers and examples."),
        ], required: ["change", "text", "why"]), access: .granted)
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("Proposals are unavailable in this context") }
        let change = try arguments.requireString("change").lowercased()
        let text = try arguments.requireString("text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError.invalidArguments("text is empty") }
        guard ["instructions", "role", "style"].contains(change) else { throw ToolError.invalidArguments("change must be instructions, role or style") }
        guard let a = try await health.store.agent(context.agentID) else { throw ToolError.failed("Agent not found") }
        let current = change == "instructions" ? a.instructions : change == "role" ? a.role : a.style
        let title = "Change \(a.name)'s \(change)"
        var card = ApprovalRequest(taskID: context.taskID, title: title, destination: "\(a.name) · agent", text: text,
                                   details: [ApprovalDetail(label: "Change", value: change)],
                                   notes: "Why: \(try arguments.requireString("why"))\n\nCurrent \(change):\n\(current.isEmpty ? "(none)" : current)")
        card.approveLabel = "Approve change"
        card.action = ApprovalAction(tool: ApplyProposedChangeTool.name, arguments: .object(["kind": .string(change), "agent_id": .string(a.id.rawValue)]), textField: "text", label: "Approve change")
        try await hooks.postProposal(context.taskID, card)
        return .text(ToolCallID("pending"), name: spec.name, "Proposed: \(title) (card \(card.id)). It applies when the owner approves; a change request comes back to you as a message.")
    }
}

struct ProposeSkillChangeTool: Tool {
    let health: HealthTools
    var spec: ToolSpec {
        ToolSpec(name: "propose_skill_change", description: "Propose a better version of a skill (its full new instructions in Markdown), or disabling a skill that keeps failing, as an approval card with your reasons. Nothing changes until the user approves. It returns at once.", inputSchema: JSONSchema.object([
            "change": JSONSchema.string("new_version or disable."),
            "skill": JSONSchema.string("The skill's name."),
            "text": JSONSchema.string("For new_version: the complete new instructions (they replace the old steps and instructions). For disable: why."),
            "purpose": JSONSchema.string("For new_version: a new one-line purpose, if it changes."),
            "why": JSONSchema.string("What went wrong with the current version, with numbers and examples."),
        ], required: ["change", "skill", "text", "why"]), access: .granted)
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("Proposals are unavailable in this context") }
        let change = try arguments.requireString("change").lowercased()
        let skill = try await health.skill(named: try arguments.requireString("skill"))
        let text = try arguments.requireString("text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError.invalidArguments("text is empty") }
        var args: [String: JSONValue] = ["kind": .string(change == "disable" ? "disable_skill" : "skill_version"), "skill_id": .string(skill.id.rawValue)]
        if let purpose = arguments.string("purpose"), !purpose.isEmpty { args["purpose"] = .string(purpose) }
        let record = "Used \(skill.outcomes.count)×, \(skill.outcomes.isEmpty ? "no outcomes yet" : "\(Int(HealthTools.rate(skill) * 100))% worked")"
        let title: String
        switch change {
        case "new_version": title = "New version of the skill \(skill.name) (v\(skill.version + 1))"
        case "disable": title = "Disable the skill \(skill.name)"
        default: throw ToolError.invalidArguments("change must be new_version or disable")
        }
        var card = ApprovalRequest(taskID: context.taskID, title: title, destination: "Skill · \(skill.name)", text: text,
                                   details: [ApprovalDetail(label: "Current version", value: "v\(skill.version), \(skill.status.rawValue)"), ApprovalDetail(label: "Record", value: record)],
                                   notes: "Why: \(try arguments.requireString("why"))")
        card.approveLabel = change == "disable" ? "Approve & disable" : "Approve change"
        card.action = ApprovalAction(tool: ApplyProposedChangeTool.name, arguments: .object(args), textField: "text", label: card.approveLabel ?? "Approve change")
        try await hooks.postProposal(context.taskID, card)
        return .text(ToolCallID("pending"), name: spec.name, "Proposed: \(title) (card \(card.id)). It applies when the user approves.")
    }
}

struct ProposeCodeChangeTool: Tool {
    var spec: ToolSpec {
        ToolSpec(name: "propose_code_change", description: "Propose a fix in Pennant's own code (a bug or limit in Pennant itself, not something instructions or a skill can fix), as an approval card. If the owner approves, a coding run makes it on a separate branch with a test, runs the tests and commits; nothing is pushed or deployed until the owner reviews it. It returns at once.", inputSchema: JSONSchema.object([
            "title": JSONSchema.string("The fix in a few words, e.g. \"Keep an agent's tools under the model's 128 limit\"."),
            "problem": JSONSchema.string("What goes wrong, for whom, and how often, with one or two concrete examples (error text, task titles, dates)."),
            "approach": JSONSchema.string("What you think the fix is, as a suggestion for the coding agent (it finds the cause itself)."),
            "evidence": JSONSchema.string("The numbers behind it (from health_report / recent_failures)."),
        ], required: ["title", "problem", "approach", "evidence"]), access: .granted)
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("Proposals are unavailable in this context") }
        let title = try arguments.requireString("title").trimmingCharacters(in: .whitespaces)
        let slug = title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40)
        let branch = "pennant/\(slug.isEmpty ? "fix" : String(slug))"
        let brief = "\(title)\n\nProblem: \(try arguments.requireString("problem"))\n\nSuggested approach: \(try arguments.requireString("approach"))"
        var card = ApprovalRequest(taskID: context.taskID, title: "Code change: \(title)", destination: "Coding · the default project", text: brief,
                                   details: [ApprovalDetail(label: "Done by", value: "A coding run"), ApprovalDetail(label: "Branch", value: branch), ApprovalDetail(label: "Ships", value: "No: a branch for your review")],
                                   notes: "Evidence: \(try arguments.requireString("evidence"))")
        card.approveLabel = "Approve & start the fix"
        card.action = ApprovalAction(tool: ApplyProposedChangeTool.name, arguments: .object(["kind": .string("code"), "branch": .string(branch)]), textField: "text", label: "Approve & start the fix")
        try await hooks.postProposal(context.taskID, card)
        return .text(ToolCallID("pending"), name: spec.name, "Proposed: Code change: \(title) (card \(card.id)). If approved, a coding run works on it on \(branch) and reports back.")
    }
}

// MARK: Applying (approved cards only)

struct ApplyProposedChangeTool: Tool {
    static let name = "apply_proposed_change"
    let health: HealthTools
    var spec: ToolSpec {
        ToolSpec(name: Self.name, description: "Applies an approved change to the agent, a skill or the code. Runs only from an approved proposal card.", inputSchema: JSONSchema.object([
            "kind": JSONSchema.string("What changes."),
            "text": JSONSchema.string("The approved text."),
        ], required: ["kind", "text"]), isConsequential: true, access: .approvalOnly)
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let kind = try arguments.requireString("kind")
        let text = try arguments.requireString("text")
        func done(_ s: String) -> ToolResult { .text(ToolCallID("pending"), name: spec.name, s) }
        switch kind {
        case "instructions", "role", "style":
            guard let id = arguments.string("agent_id"), var agent = try await health.store.agent(AgentID(id)) else { throw ToolError.failed("That agent no longer exists.") }
            // Only the words change: never tools, grants, model or memory.
            switch kind {
            case "instructions": agent.instructions = text
            case "role": agent.role = text
            default: agent.style = text
            }
            let saved = try await health.updateAgent(agent)
            return done("Updated \(saved.name)'s \(kind).")
        case "skill_version":
            guard let hooks = context.runtimeHooks, let id = arguments.string("skill_id"), let old = try await health.store.skill(SkillID(id)) else { throw ToolError.failed("That skill no longer exists.") }
            // The approved instructions are the procedure now; the old steps would contradict them.
            let next = Skill(name: old.name, purpose: arguments.string("purpose") ?? old.purpose, applicability: old.applicability, prerequisites: old.prerequisites, inputs: old.inputs,
                             steps: [], expectedResult: old.expectedResult, failureConditions: old.failureConditions, scripts: old.scripts, status: .provisional,
                             evidenceTaskIDs: [context.taskID], createdByAgentID: context.agentID, origin: old.origin, body: text, sourcePath: old.sourcePath, outputs: old.outputs)
            let saved = try await hooks.learnSkill(context.taskID, next)
            return done("Saved \(saved.name) v\(saved.version).")
        case "code":
            guard let hooks = context.runtimeHooks else { throw ToolError.failed("Coding is unavailable in this context") }
            let branch = arguments.string("branch") ?? "pennant/fix"
            let (task, _) = try await hooks.startCoding(HealthTools.codeBrief(text, branch: branch), nil, nil, nil)
            return done("Started a coding run (task \(task.rawValue.prefix(8))): it works on \(branch) and reports back. Nothing ships until you review it.")
        case "disable_skill":
            guard let id = arguments.string("skill_id") else { throw ToolError.failed("The proposal is missing the skill.") }
            let skill = try await health.setSkillStatus(SkillID(id), .disabled)
            return done("Disabled \(skill.name) v\(skill.version).")
        default:
            throw ToolError.invalidArguments("Unknown change \(kind)")
        }
    }
}
