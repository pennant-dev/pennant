import PennantCore
import Foundation

extension SQLiteStore {
    /// Removes conversations for good, in one transaction: their messages and search index, their tasks with
    /// transitions, tool records, checkpoints and artifacts. Memory keeps what was learned from them; their
    /// passages drop out at the next index pass. Running tasks must be stopped first.
    public func deleteMessages(_ ids: [MessageID]) throws {
        guard !ids.isEmpty else { return }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let params = ids.map { SQLiteValue.text($0.rawValue) }
        try db.transaction {
            try db.execute("DELETE FROM messages_fts WHERE message_id IN (\(marks))", params)
            try db.execute("DELETE FROM messages WHERE id IN (\(marks))", params)
        }
    }

    public func deleteConversations(_ ids: [ConversationID]) throws {
        guard !ids.isEmpty else { return }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let params: [SQLiteValue] = ids.map { .text($0.rawValue) }
        let tasksOf = "SELECT id FROM tasks WHERE conversation_id IN (\(marks))"
        let messagesOf = "SELECT id FROM messages WHERE conversation_id IN (\(marks))"
        let artifactIDs = try db.query("SELECT id FROM artifacts WHERE task_id IN (\(tasksOf))", params) { $0.string(0) }.compactMap { $0 }
        try db.transaction {
            try db.execute("DELETE FROM messages_fts WHERE message_id IN (\(messagesOf))", params)
            try db.execute("DELETE FROM embeddings WHERE kind = 'message' AND item_id IN (\(messagesOf))", params)
            try db.execute("DELETE FROM messages WHERE conversation_id IN (\(marks))", params)
            try db.execute("DELETE FROM artifacts WHERE task_id IN (\(tasksOf))", params)
            try db.execute("DELETE FROM task_transitions WHERE task_id IN (\(tasksOf))", params)
            try db.execute("DELETE FROM tool_records WHERE task_id IN (\(tasksOf))", params)
            try db.execute("DELETE FROM checkpoints WHERE task_id IN (\(tasksOf)) OR conversation_id IN (\(marks))", params + params)
            try db.execute("DELETE FROM tasks WHERE conversation_id IN (\(marks))", params)
            try db.execute("DELETE FROM conversations WHERE id IN (\(marks))", params)
        }
        let fm = FileManager.default
        for raw in artifactIDs {
            let url = paths.artifactsURL.appendingPathComponent(raw)
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        }
        log.info("Deleted \(ids.count) conversation(s) with their messages and tasks", category: "store")
    }
}
