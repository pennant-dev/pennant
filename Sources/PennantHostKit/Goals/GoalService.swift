import PennantCore
import Foundation

/// Goals and their boards: keeps each active goal's two jobs (work sessions, weekly review) on the scheduler, writes
/// the session's instructions from the goal and its board when a job fires, holds a goal to its weekly budget, and
/// says how much a goal's work may do by itself.
public actor GoalService {
    private let store: SQLiteStore
    private let scheduler: Scheduler
    private let publish: @Sendable (EventPayload) async -> Void

    public init(store: SQLiteStore, scheduler: Scheduler, publish: @escaping @Sendable (EventPayload) async -> Void) {
        self.store = store
        self.scheduler = scheduler
        self.publish = publish
    }

    // MARK: Goals

    public func list() async throws -> [Goal] { try await store.listGoals() }

    /// Saves a goal: an active one gets its own conversation and its jobs; any other status has its jobs off.
    @discardableResult
    public func save(_ input: Goal) async throws -> Goal {
        var goal = input
        guard let owner = try await store.agent(goal.ownerAgentID), owner.status != .retired else { throw ToolError.failed("The goal's agent doesn't exist.") }
        _ = try CronSchedule.parse(goal.workSchedule, timeZone: .current)
        _ = try CronSchedule.parse(goal.reviewSchedule, timeZone: .current)
        var hasConversation = false
        if let id = goal.conversationID { hasConversation = try await store.conversation(id) != nil }
        if goal.status == .active, !hasConversation {
            let conversation = Conversation(agentID: owner.id, title: "🎯 \(goal.title)")
            try await store.upsertConversation(conversation)
            await publish(.conversationUpserted(conversation))
            goal.conversationID = conversation.id
        }
        goal.updatedAt = Date()
        try await store.upsertGoal(goal)
        await publish(.goalUpserted(goal))
        try await syncJobs(goal)
        return goal
    }

    public func setStatus(_ id: GoalID, _ status: Goal.Status) async throws -> Goal {
        guard var goal = try await store.goal(id) else { throw ToolError.failed("Goal not found") }
        goal.status = status
        return try await save(goal)
    }

    /// Deletes a goal, its board and its jobs. Its conversation stays with the owner's other threads.
    public func delete(_ id: GoalID) async throws {
        guard try await store.goal(id) != nil else { throw ToolError.failed("Goal not found") }
        for job in try await scheduler.list() where job.goalID == id { try await scheduler.delete(job.id) }
        try await store.deleteGoal(id)
        await publish(.goalRemoved(id))
    }

    /// Two jobs per goal, on while it's active.
    private func syncJobs(_ goal: Goal) async throws {
        let existing = try await scheduler.list().filter { $0.goalID == goal.id }
        for (run, schedule) in [("work", goal.workSchedule), ("review", goal.reviewSchedule)] {
            var job = existing.first { $0.goalRun == run }
                ?? ScheduledJob(name: "", agentID: goal.ownerAgentID, prompt: "", schedule: schedule)
            job.name = "🎯 \(goal.title) · \(run == "work" ? "work" : "weekly review")"
            job.agentID = goal.ownerAgentID
            job.prompt = run == "work" ? "A work session on the goal \"\(goal.title)\"." : "The weekly review of the goal \"\(goal.title)\"."
            job.schedule = schedule
            job.enabled = goal.status == .active
            job.conversationID = goal.conversationID
            job.goalID = goal.id
            job.goalRun = run
            job.skillID = goal.skillID
            _ = try await scheduler.upsert(job)
        }
    }

    // MARK: Board

    public func items(_ goalID: GoalID) async throws -> [GoalItem] { try await store.goalItems(goalID) }

    @discardableResult
    public func saveItem(_ input: GoalItem) async throws -> GoalItem {
        guard try await store.goal(input.goalID) != nil else { throw ToolError.failed("Goal not found") }
        var item = input
        item.updatedAt = Date()
        try await store.upsertGoalItem(item)
        await publish(.goalItemUpserted(item))
        return item
    }

    public func comment(_ id: GoalItemID, text: String, by: String) async throws -> GoalItem {
        guard var item = try await store.goalItem(id) else { throw ToolError.failed("Item not found") }
        item.notes.append(GoalItem.Note(text: text, by: by))
        return try await saveItem(item)
    }

    // MARK: Sessions

    /// What the agent is told when a goal's job fires, or why this run is skipped.
    public func runPrompt(_ goalID: GoalID, run: String) async throws -> (text: String?, skip: String?) {
        guard var goal = try await store.goal(goalID) else { return (nil, "the goal no longer exists") }
        guard goal.status == .active else { return (nil, "the goal is \(goal.status.rawValue)") }
        if let budget = goal.weeklyBudget, let conversation = goal.conversationID {
            let spent = try await store.spend(conversationID: conversation, since: Date().addingTimeInterval(-7 * 86400))
            if spent >= budget { return (nil, String(format: "over its weekly budget ($%.2f of $%.2f)", spent, budget)) }
        }
        let items = try await store.goalItems(goalID)
        let text = run == "review" ? Self.reviewPrompt(goal, items) : Self.workPrompt(goal, items)
        goal.lastWorkedAt = Date()
        try await store.upsertGoal(goal)
        await publish(.goalUpserted(goal))
        return (text, nil)
    }

    static func board(_ items: [GoalItem]) -> String {
        var out: [String] = []
        for state in [GoalItem.State.doing, .next, .waiting, .idea] {
            let list = items.filter { $0.state == state }.sorted { $0.rank < $1.rank }
            guard !list.isEmpty else { continue }
            out.append("\(state.title):")
            for item in list {
                out.append("- [\(item.id.rawValue.prefix(8))] \(item.title)\(item.detail.isEmpty ? "" : " — \(item.detail.prefix(160))")")
                if let last = item.notes.last { out.append("    last note (\(last.by), \(last.at.formatted(date: .abbreviated, time: .omitted))): \(last.text.prefix(200))") }
            }
        }
        let done = items.filter { $0.state == .done }.sorted { $0.updatedAt > $1.updatedAt }.prefix(5)
        if !done.isEmpty { out.append("Recently done:"); out += done.map { "- \($0.title)" } }
        return out.isEmpty ? "(empty: start by adding the first items)" : out.joined(separator: "\n")
    }

    static func ownerComments(_ goal: Goal, _ items: [GoalItem]) -> [String] {
        let since = goal.lastWorkedAt ?? .distantPast
        return items.flatMap { item in item.notes.filter { $0.by == "owner" && $0.at > since }.map { "- On \"\(item.title)\" [\(item.id.rawValue.prefix(8))]: \($0.text)" } }
    }

    static func freedomText(_ goal: Goal) -> String {
        switch goal.freedom {
        case .proposeOnly:
            return "Only propose: research and write, and put everything else to the owner with request_approval. Don't change anything yourself."
        case .workFreely:
            return "Work freely: research, analyse, build, ship, ask the coding agent for branches and pull requests. Only publishing or sending email, deleting, and spending wait on the owner's sign-off, and Pennant asks for those by itself when you do them."
        case .actWithinLimits:
            return "You may act within the goal's limits and budget, and report what you did."
        }
    }

    static func header(_ goal: Goal) -> String {
        """
        Goal: \(goal.title) (id \(goal.id.rawValue.prefix(8)))
        Outcome: \(goal.outcome)
        How we'll know: \(goal.measure.isEmpty ? "(not set: suggest a measure)" : goal.measure)
        Freedom: \(freedomText(goal))\(goal.limits.isEmpty ? "" : "\nLimits: \(goal.limits)")
        """
    }

    static func workPrompt(_ goal: Goal, _ items: [GoalItem]) -> String {
        let comments = ownerComments(goal, items)
        return """
        🎯 Work session.

        \(header(goal))

        Your board (keep it with goal_board and goal_update):
        \(board(items))
        \(comments.isEmpty ? "" : "\nThe owner's comments since your last session (act on these first):\n" + comments.joined(separator: "\n") + "\n")
        How to work:
        1. Pick the most valuable thing you can move forward now: something in Doing, else the top of Next. If Next is empty, turn the best idea into a next step, or add new ones. Skip what's waiting on the owner.
        2. Work it for real: research, analysis, a draft, a plan, a branch through the coding agent. Prefer finishing one thing to touching many.
        3. Keep the board true with goal_update: move what you worked on, add a note with what you did and found (with sources or numbers), add new ideas you came across, mark done what's done, drop what no longer makes sense. Keep open items under about 25.
        4. Anything for the owner to decide goes on a card (request_approval) and its item to "waiting".
        5. End with three short lines: what you did, what's next, what you need from the owner (or "nothing").
        """
    }

    static func reviewPrompt(_ goal: Goal, _ items: [GoalItem]) -> String {
        """
        🎯 Weekly review.

        \(header(goal))

        Your board:
        \(board(items))

        1. Check the measure: get the current number if you can, and compare with last week (search your memory for last week's review).
        2. Look at what got done this week, what's waiting on the owner, and what's stuck. Reorder Next by expected impact; drop what isn't worth it.
        3. Post the review with post_report: title "Goal: \(goal.title)", a one-line verdict, status good, watch or bad, stat tiles (the measure, done this week, waiting on you), and items for next week's plan and anything you need from the owner.
        4. memory_remember the measure's number and the week's key lesson, so next week's review can compare.
        """
    }

    // MARK: Freedom

    /// The freedom of the goal a task works for: its own conversation, or that of the task that asked for it.
    public func freedom(forTask taskID: TaskID) async -> Goal.Freedom? {
        guard let goals = try? await store.listGoals().filter({ $0.conversationID != nil }), !goals.isEmpty else { return nil }
        var next: TaskID? = taskID
        var hops = 0
        while let id = next, hops < 6, let task = try? await store.task(id) {
            if let goal = goals.first(where: { $0.conversationID == task.conversationID }) { return goal.freedom }
            next = task.requestedByTaskID ?? task.parentTaskID
            hops += 1
        }
        return nil
    }
}

extension SQLiteStore {
    /// What a conversation's model use cost since a date, in US dollars.
    public func spend(conversationID: ConversationID, since: Date) throws -> Double {
        try db.query("SELECT COALESCE(SUM(json_extract(json, '$.cost')), 0) FROM usage_events WHERE at >= ? AND json_extract(json, '$.conversationID') = ?",
                     [.date(since), .text(conversationID.rawValue)]) { $0.double(0) }.first ?? 0
    }
}
