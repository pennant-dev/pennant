import PennantCore
import Foundation

extension SQLiteStore {
    public func upsertGoal(_ goal: Goal) throws {
        try db.execute(
            """
            INSERT INTO goals(id, status, owner_agent_id, updated_at, json) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET status=excluded.status, owner_agent_id=excluded.owner_agent_id, updated_at=excluded.updated_at, json=excluded.json
            """,
            [.text(goal.id.rawValue), .text(goal.status.rawValue), .text(goal.ownerAgentID.rawValue), .date(goal.updatedAt), .text(try Self.encode(goal))]
        )
    }

    public func goal(_ id: GoalID) throws -> Goal? {
        try db.query("SELECT json FROM goals WHERE id = ?", [.text(id.rawValue)]) { Self.decode(Goal.self, $0.string(0), context: "goal") }.first ?? nil
    }

    public func listGoals() throws -> [Goal] {
        try db.query("SELECT json FROM goals ORDER BY updated_at DESC", []) { Self.decode(Goal.self, $0.string(0), context: "goal") }.compactMap { $0 }
    }

    /// A goal and its board.
    public func deleteGoal(_ id: GoalID) throws {
        try db.execute("DELETE FROM goal_items WHERE goal_id = ?", [.text(id.rawValue)])
        try db.execute("DELETE FROM goals WHERE id = ?", [.text(id.rawValue)])
    }

    public func upsertGoalItem(_ item: GoalItem) throws {
        try db.execute(
            """
            INSERT INTO goal_items(id, goal_id, state, rank, updated_at, json) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET goal_id=excluded.goal_id, state=excluded.state, rank=excluded.rank, updated_at=excluded.updated_at, json=excluded.json
            """,
            [.text(item.id.rawValue), .text(item.goalID.rawValue), .text(item.state.rawValue), .int(item.rank), .date(item.updatedAt), .text(try Self.encode(item))]
        )
    }

    public func goalItem(_ id: GoalItemID) throws -> GoalItem? {
        try db.query("SELECT json FROM goal_items WHERE id = ?", [.text(id.rawValue)]) { Self.decode(GoalItem.self, $0.string(0), context: "goal item") }.first ?? nil
    }

    public func goalItems(_ goalID: GoalID) throws -> [GoalItem] {
        try db.query("SELECT json FROM goal_items WHERE goal_id = ? ORDER BY rank, updated_at", [.text(goalID.rawValue)]) { Self.decode(GoalItem.self, $0.string(0), context: "goal item") }.compactMap { $0 }
    }
}
