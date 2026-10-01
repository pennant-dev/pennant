import PennantCore
import Foundation

extension SQLiteStore {
    // MARK: - Skills

    private func indexSkill(_ skill: Skill) throws {
        try db.execute("DELETE FROM skills_fts WHERE skill_id = ?", [.text(skill.id.rawValue)])
        try db.execute(
            "INSERT INTO skills_fts(skill_id, name, purpose, applicability) VALUES (?, ?, ?, ?)",
            [.text(skill.id.rawValue), .text(skill.name), .text(skill.purpose), .text(skill.applicability)]
        )
    }

    public func upsertSkill(_ skill: Skill) throws {
        try db.transaction {
            try db.execute(
                """
                INSERT INTO skills(id, name, status, version, updated_at, json) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name, status=excluded.status, version=excluded.version, updated_at=excluded.updated_at, json=excluded.json
                """,
                [.text(skill.id.rawValue), .text(skill.name), .text(skill.status.rawValue), .int(skill.version), .date(skill.updatedAt), .text(try Self.encode(skill))]
            )
            try indexSkill(skill)
        }
    }

    public func skill(_ id: SkillID) throws -> Skill? {
        try db.query("SELECT json FROM skills WHERE id = ?", [.text(id.rawValue)]) { Self.decode(Skill.self, $0.string(0), context: "skill \(id)") }.first ?? nil
    }

    public func listSkills(includeDisabled: Bool) throws -> [Skill] {
        let sql = includeDisabled
            ? "SELECT json FROM skills ORDER BY updated_at DESC"
            : "SELECT json FROM skills WHERE status != 'disabled' ORDER BY updated_at DESC"
        return try db.query(sql) { Self.decode(Skill.self, $0.string(0), context: "skill") }.compactMap { $0 }
    }

    public func searchSkills(text: String, limit: Int) throws -> [Skill] {
        try Self.withRecall(text: text, limit: limit, minimumPrecise: 1, id: { $0.id.rawValue }) { match, limit in
            try searchSkills(match: match, limit: limit).map { ($0, 0) }
        }.map(\.0)
    }

    private func searchSkills(match: String, limit: Int) throws -> [Skill] {
        return try db.query(
            """
            SELECT s.json FROM skills_fts f JOIN skills s ON s.id = f.skill_id
            WHERE skills_fts MATCH ? AND s.status != 'disabled' ORDER BY bm25(skills_fts) LIMIT ?
            """,
            [.text(match), .int(max(0, limit))]
        ) { Self.decode(Skill.self, $0.string(0), context: "skill") }.compactMap { $0 }
    }

    public func deleteSkill(_ id: SkillID) throws {
        try db.transaction {
            try db.execute("DELETE FROM skills WHERE id = ?", [.text(id.rawValue)])
            try db.execute("DELETE FROM skills_fts WHERE skill_id = ?", [.text(id.rawValue)])
            try db.execute("DELETE FROM embeddings WHERE kind = 'skill' AND item_id = ?", [.text(id.rawValue)])
        }
    }

    // MARK: - MCP servers

    public func upsertMCPServer(_ config: MCPServerConfig) throws {
        try db.execute(
            """
            INSERT INTO mcp_servers(id, name, created_at, json) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, json=excluded.json
            """,
            [.text(config.id.rawValue), .text(config.name), .date(config.createdAt), .text(try Self.encode(config))]
        )
    }

    public func listMCPServers() throws -> [MCPServerConfig] {
        try db.query("SELECT json FROM mcp_servers ORDER BY created_at") { Self.decode(MCPServerConfig.self, $0.string(0), context: "mcp server") }.compactMap { $0 }
    }

    public func removeMCPServer(_ id: MCPServerID) throws {
        try db.execute("DELETE FROM mcp_servers WHERE id = ?", [.text(id.rawValue)])
    }
}

// MARK: - Scheduled jobs

extension SQLiteStore {
    public func upsertSchedule(_ job: ScheduledJob) throws {
        try db.execute(
            """
            INSERT INTO schedules(id, agent_id, enabled, next_run_at, json) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET agent_id=excluded.agent_id, enabled=excluded.enabled, next_run_at=excluded.next_run_at, json=excluded.json
            """,
            [.text(job.id.rawValue), .text(job.agentID.rawValue), .int(job.enabled ? 1 : 0), job.nextRunAt.map { SQLiteValue.date($0) } ?? .null, .text(try Self.encode(job))]
        )
    }

    public func schedule(_ id: ScheduleID) throws -> ScheduledJob? {
        try db.query("SELECT json FROM schedules WHERE id = ?", [.text(id.rawValue)]) { Self.decode(ScheduledJob.self, $0.string(0), context: "schedule") }.first ?? nil
    }

    public func listSchedules() throws -> [ScheduledJob] {
        try db.query("SELECT json FROM schedules ORDER BY rowid", []) { Self.decode(ScheduledJob.self, $0.string(0), context: "schedule") }.compactMap { $0 }
    }

    public func deleteSchedule(_ id: ScheduleID) throws {
        try db.execute("DELETE FROM schedules WHERE id = ?", [.text(id.rawValue)])
    }

    public func dueSchedules(before date: Date) throws -> [ScheduledJob] {
        try db.query("SELECT json FROM schedules WHERE enabled = 1 AND next_run_at IS NOT NULL AND next_run_at <= ? ORDER BY next_run_at", [.date(date)]) { Self.decode(ScheduledJob.self, $0.string(0), context: "schedule") }.compactMap { $0 }
    }
}
