import PennantCore
import Foundation

/// What Pennant did over a period, for the health review: tasks and how they ended, tool calls that went
/// wrong, how long replies took, what the models cost, and the warnings the runtime raised.
public struct RecentActivity: Sendable {
    public struct Reply: Sendable {
        public var agentID: AgentID
        /// Seconds from sending the request to the last token.
        public var seconds: Double
    }
    public struct Spend: Sendable {
        public var agentID: AgentID
        public var cost: Double
        /// Spent by a coding CLI (a coding run) rather than the agent's own model.
        public var coding: Bool = false
    }
    public var tasks: [TaskRecord]
    /// Tool calls that failed, were refused, or ended with an unknown outcome.
    public var badToolCalls: [ToolRecord]
    /// All tool calls by name, to put the bad ones in proportion.
    public var toolCallCounts: [String: Int]
    public var replies: [Reply]
    public var spend: [Spend]
    /// Warning and error notices (model retries, fallbacks, failures), newest first.
    public var warnings: [(agentID: AgentID?, text: String, at: Date)]
    /// Tasks that posted a report card: the task that asked gets only their final words, not their cards.
    public var tasksWithReports: Set<TaskID>
}

extension SQLiteStore {
    public func recentActivity(since: Date) throws -> RecentActivity {
        let at = SQLiteValue.date(since)
        let tasks = try db.query("SELECT json FROM tasks WHERE created_at >= ? ORDER BY created_at DESC", [at]) {
            Self.decode(TaskRecord.self, $0.string(0), context: "task")
        }.compactMap { $0 }
        let bad = try db.query("SELECT json FROM tool_records WHERE started_at >= ? AND status IN ('failed', 'denied', 'uncertain') ORDER BY started_at DESC", [at]) {
            Self.decode(ToolRecord.self, $0.string(0), context: "tool record")
        }.compactMap { $0 }
        var counts: [String: Int] = [:]
        for (name, n) in try db.query("SELECT json_extract(json, '$.call.name'), COUNT(*) FROM tool_records WHERE started_at >= ? GROUP BY 1", [at], { ($0.string(0) ?? "?", Int($0.int(1))) }) {
            counts[name] = n
        }
        let replies = try db.query(
            """
            SELECT agent_id, json_extract(json, '$.stats.seconds'), json_extract(json, '$.stats.firstTokenSeconds')
            FROM messages WHERE role = 'assistant' AND created_at >= ? AND json_extract(json, '$.stats') IS NOT NULL
            """, [at]) { row in
            RecentActivity.Reply(agentID: AgentID(row.string(0) ?? ""), seconds: row.double(1) + (row.isNull(2) ? 0 : row.double(2)))
        }
        let spend = try db.query(
            """
            SELECT agent_id, SUM(COALESCE(json_extract(json, '$.cost'), 0)),
                   COALESCE(json_extract(json, '$.provider'), '') = 'claude-code' AS coding
            FROM usage_events WHERE at >= ? GROUP BY agent_id, coding
            """, [at]) { row in
            RecentActivity.Spend(agentID: AgentID(row.string(0) ?? ""), cost: row.double(1), coding: row.int(2) == 1)
        }
        let warnings = try db.query(
            """
            SELECT json_extract(payload, '$.notice.agentID'), json_extract(payload, '$.notice.text'), at FROM events
            WHERE kind = 'notice' AND at >= ? AND json_extract(payload, '$.notice.level') IN ('warning', 'error') ORDER BY seq DESC LIMIT 500
            """, [at]) { row in
            (agentID: row.string(0).map { AgentID($0) }, text: row.string(1) ?? "", at: Date(timeIntervalSince1970: row.double(2)))
        }
        let reported = try db.query(
            """
            SELECT DISTINCT m.task_id FROM messages m, json_each(json_extract(m.json, '$.parts')) p
            WHERE m.created_at >= ? AND m.task_id IS NOT NULL AND json_extract(p.value, '$.type') = 'report'
            """, [at]) { $0.string(0) }.compactMap { $0.map { TaskID($0) } }
        return RecentActivity(tasks: tasks, badToolCalls: bad, toolCallCounts: counts, replies: replies, spend: spend, warnings: warnings, tasksWithReports: Set(reported))
    }
}
