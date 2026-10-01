import PennantCore
import Foundation

extension SQLiteStore {
    // MARK: - Tasks

    public func upsertTask(_ task: TaskRecord) throws {
        try db.execute(
            """
            INSERT INTO tasks(id, agent_id, conversation_id, parent_task_id, state, created_at, updated_at, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET agent_id=excluded.agent_id, conversation_id=excluded.conversation_id, parent_task_id=excluded.parent_task_id,
                state=excluded.state, updated_at=excluded.updated_at, json=excluded.json
            """,
            [.text(task.id.rawValue), .text(task.agentID.rawValue), .text(task.conversationID.rawValue), .optional(task.parentTaskID?.rawValue),
             .text(task.state.rawValue), .date(task.createdAt), .date(task.updatedAt), .text(try Self.encode(task))]
        )
    }

    public func task(_ id: TaskID) throws -> TaskRecord? {
        try db.query("SELECT json FROM tasks WHERE id = ?", [.text(id.rawValue)]) { Self.decode(TaskRecord.self, $0.string(0), context: "task \(id)") }.first ?? nil
    }

    public func listTasks(agentID: AgentID?, includeFinished: Bool) throws -> [TaskRecord] {
        var clauses: [String] = []
        var params: [SQLiteValue] = []
        if let agentID {
            clauses.append("agent_id = ?")
            params.append(.text(agentID.rawValue))
        }
        if !includeFinished {
            clauses.append("state NOT IN ('completed', 'failed', 'cancelled')")
        }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        return try db.query("SELECT json FROM tasks" + whereSQL + " ORDER BY updated_at DESC", params) { Self.decode(TaskRecord.self, $0.string(0), context: "task") }.compactMap { $0 }
    }

    public func recordTransition(_ transition: TaskTransition) throws {
        try db.execute(
            "INSERT INTO task_transitions(task_id, from_state, to_state, reason, at) VALUES (?, ?, ?, ?, ?)",
            [.text(transition.taskID.rawValue), .text(transition.from.rawValue), .text(transition.to.rawValue), .text(transition.reason), .date(transition.at)]
        )
    }

    public func transitions(taskID: TaskID) throws -> [TaskTransition] {
        try db.query("SELECT task_id, from_state, to_state, reason, at FROM task_transitions WHERE task_id = ? ORDER BY id", [.text(taskID.rawValue)]) { row -> TaskTransition? in
            guard let from = TaskState(rawValue: row.string(1) ?? ""), let to = TaskState(rawValue: row.string(2) ?? "") else {
                log.warn("Skipping transition with unknown state for task \(taskID)", category: "store")
                return nil
            }
            return TaskTransition(taskID: TaskID(row.string(0) ?? ""), from: from, to: to, reason: row.string(3) ?? "", at: Date(timeIntervalSince1970: row.double(4)))
        }.compactMap { $0 }
    }

    public func childTasks(parentTaskID: TaskID) throws -> [TaskRecord] {
        try db.query("SELECT json FROM tasks WHERE parent_task_id = ? ORDER BY created_at", [.text(parentTaskID.rawValue)]) { Self.decode(TaskRecord.self, $0.string(0), context: "task") }.compactMap { $0 }
    }

    // MARK: - Tool records

    public func upsertToolRecord(_ record: ToolRecord) throws {
        try db.execute(
            """
            INSERT INTO tool_records(id, task_id, agent_id, status, started_at, json) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET task_id=excluded.task_id, agent_id=excluded.agent_id, status=excluded.status, started_at=excluded.started_at, json=excluded.json
            """,
            [.text(record.id.rawValue), .text(record.taskID.rawValue), .text(record.agentID.rawValue), .text(record.status.rawValue), .date(record.startedAt), .text(try Self.encode(record))]
        )
    }

    public func toolRecord(_ id: ToolRecordID) throws -> ToolRecord? {
        try db.query("SELECT json FROM tool_records WHERE id = ?", [.text(id.rawValue)]) { Self.decode(ToolRecord.self, $0.string(0), context: "tool record \(id)") }.first ?? nil
    }

    public func toolRecords(taskID: TaskID) throws -> [ToolRecord] {
        try db.query("SELECT json FROM tool_records WHERE task_id = ? ORDER BY started_at, rowid", [.text(taskID.rawValue)]) { Self.decode(ToolRecord.self, $0.string(0), context: "tool record") }.compactMap { $0 }
    }

    public func unresolvedToolRecords() throws -> [ToolRecord] {
        try db.query("SELECT json FROM tool_records WHERE status IN ('intended', 'running', 'uncertain') ORDER BY started_at, rowid") { Self.decode(ToolRecord.self, $0.string(0), context: "tool record") }.compactMap { $0 }
    }

    public func recentToolRecords(limit: Int) throws -> [ToolRecord] {
        try db.query("SELECT json FROM tool_records ORDER BY started_at DESC, rowid DESC LIMIT ?", [.int(max(0, limit))]) { Self.decode(ToolRecord.self, $0.string(0), context: "tool record") }.compactMap { $0 }
    }

    // MARK: - Checkpoints

    public func saveCheckpoint(_ checkpoint: Checkpoint) throws {
        try db.execute(
            """
            INSERT INTO checkpoints(id, task_id, conversation_id, created_at, json) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET task_id=excluded.task_id, conversation_id=excluded.conversation_id, created_at=excluded.created_at, json=excluded.json
            """,
            [.text(checkpoint.id.rawValue), .text(checkpoint.taskID.rawValue), checkpoint.conversationID.map { SQLiteValue.text($0.rawValue) } ?? .null, .date(checkpoint.createdAt), .text(try Self.encode(checkpoint))]
        )
    }

    public func latestCheckpoint(conversationID: ConversationID) throws -> Checkpoint? {
        try db.query("SELECT json FROM checkpoints WHERE conversation_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1", [.text(conversationID.rawValue)]) { Self.decode(Checkpoint.self, $0.string(0), context: "checkpoint") }.first ?? nil
    }

    public func checkpoints(conversationID: ConversationID) throws -> [Checkpoint] {
        try db.query("SELECT json FROM checkpoints WHERE conversation_id = ? ORDER BY created_at, rowid", [.text(conversationID.rawValue)]) { Self.decode(Checkpoint.self, $0.string(0), context: "checkpoint") }.compactMap { $0 }
    }

    public func latestCheckpoint(taskID: TaskID) throws -> Checkpoint? {
        try db.query("SELECT json FROM checkpoints WHERE task_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1", [.text(taskID.rawValue)]) { Self.decode(Checkpoint.self, $0.string(0), context: "checkpoint") }.first ?? nil
    }

    public func checkpoints(taskID: TaskID) throws -> [Checkpoint] {
        try db.query("SELECT json FROM checkpoints WHERE task_id = ? ORDER BY created_at, rowid", [.text(taskID.rawValue)]) { Self.decode(Checkpoint.self, $0.string(0), context: "checkpoint") }.compactMap { $0 }
    }

    // MARK: - Artifacts

    nonisolated private func artifactFileURL(_ id: ArtifactID) -> URL {
        paths.artifactsURL.appendingPathComponent(id.rawValue)
    }

    public func putArtifact(_ record: ArtifactRecord, data: Data) throws {
        try FileManager.default.createDirectory(at: paths.artifactsURL, withIntermediateDirectories: true)
        try data.write(to: artifactFileURL(record.id), options: .atomic)
        var stored = record
        stored.byteCount = data.count
        try db.execute(
            """
            INSERT INTO artifacts(id, kind, mime_type, byte_count, task_id, agent_id, created_at, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, mime_type=excluded.mime_type, byte_count=excluded.byte_count, task_id=excluded.task_id,
                agent_id=excluded.agent_id, created_at=excluded.created_at, json=excluded.json
            """,
            [.text(stored.id.rawValue), .text(stored.kind), .text(stored.mimeType), .int(stored.byteCount), .optional(stored.taskID?.rawValue),
             .optional(stored.agentID?.rawValue), .date(stored.createdAt), .text(try Self.encode(stored))]
        )
    }

    public func artifact(_ id: ArtifactID) throws -> ArtifactRecord? {
        try db.query("SELECT json FROM artifacts WHERE id = ?", [.text(id.rawValue)]) { Self.decode(ArtifactRecord.self, $0.string(0), context: "artifact \(id)") }.first ?? nil
    }

    public func artifactData(_ id: ArtifactID) throws -> Data? {
        let url = artifactFileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func deleteArtifact(_ id: ArtifactID) throws {
        try db.execute("DELETE FROM artifacts WHERE id = ?", [.text(id.rawValue)])
        let url = artifactFileURL(id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
