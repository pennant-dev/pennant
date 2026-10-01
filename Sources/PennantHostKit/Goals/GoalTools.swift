import PennantCore
import Foundation

/// The agents' side of goals: read a goal and its board, keep the board, and propose new goals for the owner to approve.
public enum GoalTools {
    public static func all(goals: GoalService, store: SQLiteStore) -> [any Tool] {
        [ListGoalsTool(goals: goals, store: store), GoalBoardTool(goals: goals, store: store), GoalUpdateTool(goals: goals, store: store), UpdateGoalTool(goals: goals),
         ProposeGoalTool(goals: goals), ActivateGoalTool(goals: goals), ApplyGoalChangeTool(goals: goals)]
    }

    /// Every goal, one line each: who works on it, its state, when it works next, and its board in numbers.
    static func overview(goals: GoalService, store: SQLiteStore) async throws -> String {
        let all = try await goals.list()
        guard !all.isEmpty else { return "There are no goals yet. propose_goal drafts one for the owner to approve." }
        let agents = try await store.listAgents(includeRetired: true)
        var lines = ["\(all.count) goal\(all.count == 1 ? "" : "s"):"]
        for g in all.sorted(by: { $0.title < $1.title }) {
            let items = try await goals.items(g.id)
            func n(_ s: GoalItem.State) -> Int { items.filter { $0.state == s }.count }
            let owner = agents.first { $0.id == g.ownerAgentID }?.name ?? "?"
            lines.append("- \(g.title) [\(g.id.rawValue.prefix(8))] — \(owner), \(g.status.rawValue), works \(g.workSchedule), reviews \(g.reviewSchedule)\(g.weeklyBudget.map { String(format: ", $%.0f/week", $0) } ?? ""). Board: \(n(.doing)) doing, \(n(.next)) next, \(n(.waiting)) waiting on the owner, \(n(.idea)) ideas, \(n(.done)) done.")
        }
        return lines.joined(separator: "\n")
    }

    /// The goal meant: named (title or id prefix), else the one whose conversation this is, else the agent's only goal.
    static func resolve(_ key: String?, context: ToolContext, goals: GoalService) async throws -> Goal {
        let all = try await goals.list().filter { $0.status != .dropped }
        if let key, !key.isEmpty {
            let k = key.lowercased()
            if let g = all.first(where: { $0.id.rawValue.lowercased().hasPrefix(k) || $0.title.lowercased() == k }) { return g }
            throw ToolError.invalidArguments("No goal \"\(key)\". Goals: \(all.map(\.title).joined(separator: "; "))")
        }
        if let g = all.first(where: { $0.conversationID == context.conversationID }) { return g }
        let mine = all.filter { $0.ownerAgentID == context.agentID }
        if mine.count == 1 { return mine[0] }
        throw ToolError.invalidArguments(mine.isEmpty ? "You have no goals." : "Which goal? Yours: \(mine.map(\.title).joined(separator: "; "))")
    }
}

struct GoalBoardTool: Tool {
    let goals: GoalService
    let store: SQLiteStore
    var spec: ToolSpec {
        ToolSpec(name: "goal_board", description: "A goal you work toward and its board: ideas, next steps, what's in progress, what waits on the owner, what's done, with notes and the owner's comments. Without a goal: the one this conversation is for, or your goals.", inputSchema: JSONSchema.object([
            "goal": JSONSchema.string("The goal's title or id (optional)."),
        ]))
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        if arguments.string("goal") == nil {
            // Not asking about one goal in particular (and not in a goal's own conversation): all of them.
            let all = try await goals.list()
            let here = all.first { $0.conversationID == context.conversationID }
            let mine = all.filter { $0.ownerAgentID == context.agentID && $0.status != .dropped }
            if here == nil, mine.count != 1 {
                return .text(ToolCallID("pending"), name: spec.name, try await GoalTools.overview(goals: goals, store: store) + "\n\nCall goal_board with a goal's title for its board.")
            }
        }
        let goal = try await GoalTools.resolve(arguments.string("goal"), context: context, goals: goals)
        let items = try await goals.items(goal.id)
        var out = [GoalService.header(goal), "Status: \(goal.status.rawValue)", "", "Board:", GoalService.board(items)]
        let comments = items.flatMap { item in item.notes.filter { $0.by == "owner" }.suffix(2).map { "- On \"\(item.title)\": \($0.text)" } }
        if !comments.isEmpty { out += ["", "The owner's latest comments:"] + comments }
        return .text(ToolCallID("pending"), name: spec.name, out.joined(separator: "\n"))
    }
}

struct GoalUpdateTool: Tool {
    let goals: GoalService
    let store: SQLiteStore
    var spec: ToolSpec {
        ToolSpec(name: "goal_update", description: "Keep a goal's board: add an item, move it (idea, next, doing, waiting, done, dropped), add a note with what you did or found, or edit it. Only the goal's own agent keeps its board.", inputSchema: JSONSchema.object([
            "goal": JSONSchema.string("The goal's title or id (optional: this conversation's goal)."),
            "action": JSONSchema.string("add, move, note, or edit."),
            "item": JSONSchema.string("The item's id (the 8 characters shown on the board); not for add."),
            "title": JSONSchema.string("For add or edit: what it is, as a short action."),
            "detail": JSONSchema.string("For add or edit: why it matters, what done looks like."),
            "state": JSONSchema.string("For add or move: idea, next, doing, waiting, done or dropped."),
            "note": JSONSchema.string("What you did or found (sources, numbers); for any action."),
            "position": JSONSchema.string("For add or move: \"top\" or \"bottom\" of its column (default bottom)."),
        ], required: ["action"]))
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let goal = try await GoalTools.resolve(arguments.string("goal"), context: context, goals: goals)
        guard goal.ownerAgentID == context.agentID || goal.conversationID == context.conversationID else { throw ToolError.failed("Only \(goal.title)'s own agent keeps its board.") }
        let action = try arguments.requireString("action").lowercased()
        let items = try await goals.items(goal.id)
        let state = try arguments.string("state").map { raw -> GoalItem.State in
            guard let s = GoalItem.State(rawValue: raw.lowercased()) else { throw ToolError.invalidArguments("state must be idea, next, doing, waiting, done or dropped") }
            return s
        }
        let author = (try? await store.agent(context.agentID))?.name ?? "agent"
        func rank(in state: GoalItem.State) -> Int {
            let column = items.filter { $0.state == state }.map(\.rank)
            return arguments.string("position") == "top" ? (column.min() ?? 0) - 1 : (column.max() ?? 0) + 1
        }
        var item: GoalItem
        if action == "add" {
            let s = state ?? .next
            item = GoalItem(goalID: goal.id, title: try arguments.requireString("title"), detail: arguments.string("detail") ?? "", state: s, rank: rank(in: s))
        } else {
            let key = try arguments.requireString("item").lowercased()
            guard let found = items.first(where: { $0.id.rawValue.lowercased().hasPrefix(key) }) else { throw ToolError.invalidArguments("No item \(key) on this board.") }
            item = found
            switch action {
            case "move":
                guard let s = state else { throw ToolError.invalidArguments("move needs a state") }
                item.state = s
                item.rank = rank(in: s)
            case "edit":
                if let t = arguments.string("title") { item.title = t }
                if let d = arguments.string("detail") { item.detail = d }
            case "note": break
            default: throw ToolError.invalidArguments("action must be add, move, note or edit")
            }
        }
        if let note = arguments.string("note"), !note.isEmpty { item.notes.append(GoalItem.Note(text: note, by: author)) }
        let saved = try await goals.saveItem(item)
        return .text(ToolCallID("pending"), name: spec.name, "\(action == "add" ? "Added" : "Updated") [\(saved.id.rawValue.prefix(8))] \(saved.title) — \(saved.state.title).")
    }
}

struct ListGoalsTool: Tool {
    let goals: GoalService
    let store: SQLiteStore
    var spec: ToolSpec {
        ToolSpec(name: "list_goals", description: "Every goal on this host, whichever agent works on it: owner, status, schedules, budget, and how its board stands. Use it before saying how many goals there are or that one doesn't exist.", inputSchema: JSONSchema.object([:]))
    }
    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        .text(ToolCallID("pending"), name: spec.name, try await GoalTools.overview(goals: goals, store: store))
    }
}

/// Changes to a goal. Its schedules, state (pause, resume, achieved, dropped), title and measure change at once;
/// what the agent may do and aims at (outcome, freedom, limits, budget) goes to the owner as a card.
struct UpdateGoalTool: Tool {
    let goals: GoalService
    var spec: ToolSpec {
        ToolSpec(name: "update_goal", description: "Change a goal: when it works (work_schedule, e.g. \"daily at 09:00\") and reviews (review_schedule), its status (active, paused, achieved, dropped), title or measure take effect at once. Changes to its outcome, freedom, limits or weekly budget go to the owner as an approval card. Never delete or recreate a goal's jobs with the schedule tools; use this.", inputSchema: JSONSchema.object([
            "goal": JSONSchema.string("The goal's title or id."),
            "work_schedule": JSONSchema.string("When it works, e.g. \"daily at 09:00\", \"every 4h\", \"weekdays at 08:30\"."),
            "review_schedule": JSONSchema.string("When it reviews, e.g. \"weekly on fri at 16:00\"."),
            "status": JSONSchema.string("active, paused, achieved or dropped."),
            "title": JSONSchema.string("A new title."),
            "measure": JSONSchema.string("A new measure."),
            "outcome": JSONSchema.string("A new outcome (the owner approves it)."),
            "freedom": JSONSchema.string("proposeOnly, workFreely or actWithinLimits (the owner approves it)."),
            "limits": JSONSchema.string("New limits (the owner approves them)."),
            "weekly_budget": JSONSchema.number("A new weekly budget in US dollars (the owner approves it)."),
            "why": JSONSchema.string("Why, for changes the owner approves."),
        ], required: ["goal"]), isConsequential: true)
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        var goal = try await GoalTools.resolve(arguments.string("goal"), context: context, goals: goals)
        var changed: [String] = []
        if let w = arguments.string("work_schedule"), !w.isEmpty, w != goal.workSchedule { goal.workSchedule = w; changed.append("works \(w)") }
        if let r = arguments.string("review_schedule"), !r.isEmpty, r != goal.reviewSchedule { goal.reviewSchedule = r; changed.append("reviews \(r)") }
        if let raw = arguments.string("status") {
            guard let s = Goal.Status(rawValue: raw.lowercased()), s != .proposed else { throw ToolError.invalidArguments("status must be active, paused, achieved or dropped") }
            if s == .active, goal.status == .proposed { throw ToolError.failed("The owner starts a proposed goal by approving its card.") }
            if s != goal.status { goal.status = s; changed.append(s.rawValue) }
        }
        if let t = arguments.string("title"), !t.isEmpty, t != goal.title { goal.title = t; changed.append("title \"\(t)\"") }
        if let m = arguments.string("measure"), m != goal.measure { goal.measure = m; changed.append("measure") }
        var applied = ""
        if !changed.isEmpty {
            let saved = try await goals.save(goal)
            applied = "Changed \"\(saved.title)\": \(changed.joined(separator: ", ")). Its jobs follow."
        }

        // What the agent may do, and what it aims at: the owner's call.
        var sensitive: [String: JSONValue] = [:]
        var lines: [String] = []
        if let o = arguments.string("outcome"), !o.isEmpty, o != goal.outcome { sensitive["outcome"] = .string(o); lines.append("Outcome: \(o)") }
        if let f = arguments.string("freedom") {
            guard let fr = Goal.Freedom(rawValue: f) else { throw ToolError.invalidArguments("freedom must be proposeOnly, workFreely or actWithinLimits") }
            if fr != goal.freedom { sensitive["freedom"] = .string(fr.rawValue); lines.append("Freedom: \(fr.title) (now \(goal.freedom.title))") }
        }
        if let l = arguments.string("limits"), l != goal.limits { sensitive["limits"] = .string(l); lines.append("Limits: \(l)") }
        if let b = arguments["weekly_budget"]?.doubleValue, b != goal.weeklyBudget { sensitive["weekly_budget"] = .number(b); lines.append(String(format: "Budget: $%.0f a week", b)) }
        if !sensitive.isEmpty {
            guard let hooks = context.runtimeHooks else { throw ToolError.failed("Proposals are unavailable in this context") }
            sensitive["goal_id"] = .string(goal.id.rawValue)
            var card = ApprovalRequest(taskID: context.taskID, title: "Change the goal: \(goal.title)", destination: "Goal", text: lines.joined(separator: "\n"),
                                       notes: arguments.string("why").map { "Why: \($0)" } ?? "")
            card.approveLabel = "Approve change"
            card.action = ApprovalAction(tool: ApplyGoalChangeTool.name, arguments: .object(sensitive), textField: "summary", label: "Approve change")
            try await hooks.postProposal(context.taskID, card)
            applied += (applied.isEmpty ? "" : " ") + "The rest (\(sensitive.keys.filter { $0 != "goal_id" }.sorted().joined(separator: ", "))) is on a card for the owner."
        }
        return .text(ToolCallID("pending"), name: spec.name, applied.isEmpty ? "Nothing to change." : applied)
    }
}

struct ApplyGoalChangeTool: Tool {
    static let name = "apply_goal_change"
    let goals: GoalService
    var spec: ToolSpec {
        ToolSpec(name: Self.name, description: "Applies an approved change to a goal. Runs only from an approved card.", inputSchema: JSONSchema.object([
            "goal_id": JSONSchema.string("The goal."),
        ], required: ["goal_id"]), isConsequential: true, access: .approvalOnly)
    }
    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard var goal = try await goals.list().first(where: { $0.id.rawValue == (arguments.string("goal_id") ?? "") }) else { throw ToolError.failed("That goal no longer exists.") }
        if let o = arguments.string("outcome") { goal.outcome = o }
        if let f = arguments.string("freedom").flatMap(Goal.Freedom.init(rawValue:)) { goal.freedom = f }
        if let l = arguments.string("limits") { goal.limits = l }
        if let b = arguments["weekly_budget"]?.doubleValue { goal.weeklyBudget = b }
        let saved = try await goals.save(goal)
        return .text(ToolCallID("pending"), name: spec.name, "Changed \"\(saved.title)\".")
    }
}

struct ProposeGoalTool: Tool {
    let goals: GoalService
    var spec: ToolSpec {
        ToolSpec(name: "propose_goal", description: "Propose a goal to work toward on your own (weeks, not one task), as an approval card. Once the owner approves (they can edit the outcome), you work on it on its schedule, keep its board, and review progress weekly.", inputSchema: JSONSchema.object([
            "title": JSONSchema.string("Short name, e.g. \"Grow the company LinkedIn page\"."),
            "outcome": JSONSchema.string("What success looks like, concretely."),
            "measure": JSONSchema.string("How progress is judged: the number to watch and where it comes from."),
            "freedom": JSONSchema.string("proposeOnly, workFreely (default) or actWithinLimits."),
            "limits": JSONSchema.string("What it must never do, or only within bounds."),
            "work_schedule": JSONSchema.string("When it works on it (default \"weekdays at 09:00\")."),
            "review_schedule": JSONSchema.string("When it reviews progress (default \"weekly on fri at 16:00\")."),
            "weekly_budget": JSONSchema.number("Most its work may cost in model use over 7 days, in US dollars (optional)."),
            "first_steps": JSONSchema.array(of: JSONSchema.string("A first thing to do."), "The first items for its board."),
        ], required: ["title", "outcome"]))
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let hooks = context.runtimeHooks else { throw ToolError.failed("Proposals are unavailable in this context") }
        var goal = Goal(title: try arguments.requireString("title"), outcome: try arguments.requireString("outcome"), measure: arguments.string("measure") ?? "", ownerAgentID: context.agentID,
                        freedom: arguments.string("freedom").flatMap(Goal.Freedom.init(rawValue:)) ?? .workFreely, limits: arguments.string("limits") ?? "",
                        weeklyBudget: arguments["weekly_budget"]?.doubleValue)
        if let w = arguments.string("work_schedule"), !w.isEmpty { goal.workSchedule = w }
        if let r = arguments.string("review_schedule"), !r.isEmpty { goal.reviewSchedule = r }
        let saved = try await goals.save(goal)
        let steps = arguments.stringArray("first_steps") ?? []
        for (i, step) in steps.enumerated() { try await goals.saveItem(GoalItem(goalID: saved.id, title: step, state: .next, rank: i)) }
        var details = [ApprovalDetail(label: "Freedom", value: saved.freedom.title),
                       ApprovalDetail(label: "Works", value: saved.workSchedule), ApprovalDetail(label: "Reviews", value: saved.reviewSchedule)]
        if !saved.measure.isEmpty { details.insert(ApprovalDetail(label: "How we'll know", value: saved.measure), at: 1) }
        if let b = saved.weeklyBudget { details.append(ApprovalDetail(label: "Budget", value: String(format: "$%.0f a week", b))) }
        var notes: [String] = []
        if !saved.limits.isEmpty { notes.append("Limits: \(saved.limits)") }
        if !steps.isEmpty { notes.append("First steps:\n" + steps.map { "- \($0)" }.joined(separator: "\n")) }
        var card = ApprovalRequest(taskID: context.taskID, title: "Goal: \(saved.title)", destination: "Goal", text: saved.outcome, details: details, notes: notes.joined(separator: "\n\n"))
        card.approveLabel = "Approve & start"
        card.action = ApprovalAction(tool: ActivateGoalTool.name, arguments: .object(["goal_id": .string(saved.id.rawValue)]), textField: "text", label: "Approve & start")
        try await hooks.postProposal(context.taskID, card)
        return .text(ToolCallID("pending"), name: spec.name, "Proposed the goal \"\(saved.title)\" (card \(card.id)). It starts when the owner approves.")
    }
}

struct ActivateGoalTool: Tool {
    static let name = "activate_goal"
    let goals: GoalService
    var spec: ToolSpec {
        ToolSpec(name: Self.name, description: "Starts an approved goal. Runs only from an approved goal card.", inputSchema: JSONSchema.object([
            "goal_id": JSONSchema.string("The goal."),
            "text": JSONSchema.string("The approved outcome."),
        ], required: ["goal_id", "text"]), isConsequential: true, access: .approvalOnly)
    }

    func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard var goal = try await goals.list().first(where: { $0.id.rawValue == (arguments.string("goal_id") ?? "") }) else { throw ToolError.failed("That goal no longer exists.") }
        // Started from the Goals page while its card waited: the owner's edits there stand.
        guard goal.status == .proposed else { return .text(ToolCallID("pending"), name: spec.name, "\"\(goal.title)\" is already \(goal.status == .active ? "under way" : goal.status.rawValue).") }
        goal.outcome = try arguments.requireString("text")
        goal.status = .active
        let saved = try await goals.save(goal)
        return .text(ToolCallID("pending"), name: spec.name, "Started \"\(saved.title)\": \(saved.workSchedule), reviews \(saved.reviewSchedule).")
    }
}
