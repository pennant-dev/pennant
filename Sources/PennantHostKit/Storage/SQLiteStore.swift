import PennantCore
import Foundation

/// SQLite-backed implementation of `StoreProtocol`. One actor owns one connection.
public actor SQLiteStore: StoreProtocol {
    let db: SQLiteDatabase
    public let paths: HostPaths

    public init(paths: HostPaths) throws {
        try paths.ensureDirectories()
        HostPaths.adoptRenamedFiles(in: paths.root)
        self.paths = paths
        self.db = try SQLiteDatabase(path: paths.databaseURL.path)
        try Schema.migrate(db)
        log.info("Opened store at \(paths.databaseURL.path) (SQLite \(SQLiteDatabase.libraryVersion))", category: "store")
    }

    // MARK: - Coding helpers

    nonisolated static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONCodec.encode(value), as: UTF8.self)
    }

    nonisolated static func decode<T: Decodable>(_ type: T.Type, _ json: String?, context: @autoclosure () -> String) -> T? {
        guard let json else { return nil }
        do {
            return try JSONCodec.decode(T.self, from: Data(json.utf8))
        } catch {
            log.warn("Skipping undecodable \(context()): \(error)", category: "store")
            return nil
        }
    }

    /// Turn free text into a safe FTS5 MATCH expression: every token quoted and prefix-matched, AND-ed together.
    /// Returns nil when the text has no searchable tokens.
    public nonisolated static func ftsQuery(from text: String) -> String? {
        var tokens: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        guard !tokens.isEmpty else { return nil }
        return tokens.prefix(32).map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " ")
    }

    /// Recall-oriented variant: OR over significant words (stopwords and one-letter tokens dropped).
    /// Returns nil when the text has no significant words.
    public nonisolated static func ftsAnyQuery(from text: String) -> String? {
        let stop: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "at", "by", "from", "is", "are", "was", "were", "be", "it", "this", "that", "my", "me", "you", "your", "our", "we", "i", "please", "can", "could", "would", "should", "do", "does", "did", "have", "has", "had", "not", "no", "yes", "into", "as", "about", "what", "which", "who", "when", "where", "how", "there", "here", "then", "than", "so", "if", "but", "all", "any", "some", "more", "most", "very", "just", "also", "up", "out", "over", "under", "again", "now", "new", "one", "two", "file", "files", "open", "run", "use", "using", "make", "get", "set", "put", "let", "go", "task", "going", "goes", "tell", "know", "want", "need", "anything", "something", "whats", "s"]
        var words: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) { current.unicodeScalars.append(scalar) }
            else if !current.isEmpty { words.append(current); current = "" }
        }
        if !current.isEmpty { words.append(current) }
        var seen = Set<String>()
        let significant = words.filter { $0.count > 1 && !stop.contains($0) && seen.insert($0).inserted }
        guard !significant.isEmpty else { return nil }
        return significant.prefix(24).map { "\"\($0)\"*" }.joined(separator: " OR ")
    }

    /// The query's words minus those that appear in a large share of what's searched (a fifth or more), when
    /// rarer words remain: in a team's memory the company name is everywhere, and matching it says nothing about
    /// which fact is meant. `table` is an FTS5 table.
    func salientText(_ text: String, table: String) -> String {
        guard let any = Self.ftsAnyQuery(from: text) else { return text }
        let terms = any.components(separatedBy: " OR ")
        guard terms.count > 1, let total = try? db.scalarInt("SELECT COUNT(*) FROM \(table)"), total >= 20 else { return text }
        var kept: [String] = []
        for term in terms {
            let df = (try? db.scalarInt("SELECT COUNT(*) FROM \(table) WHERE \(table) MATCH ?", [.text(term)])) ?? 0
            if Double(df) / Double(total) < 0.2 { kept.append(term) }
        }
        guard !kept.isEmpty else { return text }
        return kept.map { $0.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: "") }.joined(separator: " ")
    }

    /// Runs a precise AND search, then widens to an OR search when it finds little. Precise hits rank first.
    nonisolated static func withRecall<T>(text: String, limit: Int, minimumPrecise: Int = 3, id: (T) -> String, run: (String, Int) throws -> [(T, Double)]) rethrows -> [(T, Double)] {
        var results: [(T, Double)] = []
        if let precise = ftsQuery(from: text) { results = try run(precise, limit) }
        if results.count < minimumPrecise, let wide = ftsAnyQuery(from: text) {
            var seen = Set(results.map { id($0.0) })
            for (item, rank) in try run(wide, limit) where seen.insert(id(item)).inserted {
                results.append((item, rank * 0.5))   // wide matches rank below precise ones
            }
        }
        return Array(results.prefix(limit))
    }

    nonisolated static func eventKind(_ payload: EventPayload) -> String {
        switch payload {
        case .hostStatus: return "hostStatus"
        case .agentUpserted: return "agentUpserted"
        case .agentRemoved: return "agentRemoved"
        case .conversationsRemoved: return "conversationsRemoved"
        case .conversationUpserted: return "conversationUpserted"
        case .messageAppended: return "messageAppended"
        case .messageDelta: return "messageDelta"
        case .messageFinalized: return "messageFinalized"
        case .taskUpserted: return "taskUpserted"
        case .taskTransition: return "taskTransition"
        case .toolRecordUpserted: return "toolRecordUpserted"
        case .checkpointSaved: return "checkpointSaved"
        case .desktopStatus: return "desktopStatus"
        case .memoryEntityUpserted: return "memoryEntityUpserted"
        case .memoryRelationUpserted: return "memoryRelationUpserted"
        case .preferenceUpserted: return "preferenceUpserted"
        case .memoryForgotten: return "memoryForgotten"
        case .skillUpserted: return "skillUpserted"
        case .skillRemoved: return "skillRemoved"
        case .scheduleUpserted: return "scheduleUpserted"
        case .scheduleRemoved: return "scheduleRemoved"
        case .messagesRemoved: return "messagesRemoved"
        case .goalUpserted: return "goalUpserted"
        case .goalItemUpserted: return "goalItemUpserted"
        case .goalRemoved: return "goalRemoved"
        case .mcpServerStatus: return "mcpServerStatus"
        case .notice: return "notice"
        case .teachingUpdated: return "teachingUpdated"
        }
    }

    /// Text that goes into the message FTS index: user/assistant text and tool result text. Reasoning is excluded.
    nonisolated static func searchableText(_ message: Message) -> String {
        var parts: [String] = []
        for part in message.parts {
            switch part {
            case .text(let t): parts.append(t)
            case .toolResult(let r): parts.append(r.textContent)
            case .toolCall(let c): parts.append(c.name)
            case .image(let i): if !i.caption.isEmpty { parts.append(i.caption) }
            case .file(let f): parts.append([f.fileName, f.caption].filter { !$0.isEmpty }.joined(separator: " "))
            case .approval(let a): parts.append([a.title, a.finalText].joined(separator: " "))
            case .report(let r): parts.append(r.markdown)
            case .choices(let q): parts.append(q.summary)
            case .update(let u): parts.append([u.thread, u.text].joined(separator: " "))
            case .reasoning: break
            }
        }
        return parts.joined(separator: "\n")
    }

    static let activeMemoryStatuses = [MemoryStatus.asserted, .inferred, .contradicted].map(\.rawValue)

    // MARK: - Event log

    public func appendEvent(_ payload: EventPayload) throws -> HostEvent {
        let at = Date()
        if payload.isTransient {
            return HostEvent(seq: 0, at: at, payload: payload)
        }
        try db.execute(
            "INSERT INTO events(at, kind, payload) VALUES (?, ?, ?)",
            [.date(at), .text(Self.eventKind(payload)), .text(try Self.encode(payload))]
        )
        return HostEvent(seq: db.lastInsertRowID, at: at, payload: payload)
    }

    public func events(afterSeq: EventSeq, limit: Int) throws -> [HostEvent] {
        try db.query("SELECT seq, at, payload FROM events WHERE seq > ? ORDER BY seq LIMIT ?", [.integer(afterSeq), .int(max(0, limit))]) { row -> HostEvent? in
            guard let payload = Self.decode(EventPayload.self, row.string(2), context: "event \(row.int(0))") else { return nil }
            return HostEvent(seq: row.int(0), at: Date(timeIntervalSince1970: row.double(1)), payload: payload)
        }.compactMap { $0 }
    }

    public func latestEventSeq() throws -> EventSeq {
        try db.scalarInt("SELECT COALESCE(MAX(seq), 0) FROM events")
    }

    public func eventCount() throws -> Int64 {
        try db.scalarInt("SELECT COUNT(*) FROM events")
    }

    // MARK: - Agents

    public func upsertAgent(_ agent: AgentProfile) throws {
        try db.execute(
            """
            INSERT INTO agents(id, kind, status, name, parent_agent_id, created_at, updated_at, json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, status=excluded.status, name=excluded.name,
                parent_agent_id=excluded.parent_agent_id, updated_at=excluded.updated_at, json=excluded.json
            """,
            [.text(agent.id.rawValue), .text(agent.kind.rawValue), .text(agent.status.rawValue), .text(agent.name),
             .optional(agent.parentAgentID?.rawValue), .date(agent.createdAt), .date(agent.updatedAt), .text(try Self.encode(agent))]
        )
    }

    public func agent(_ id: AgentID) throws -> AgentProfile? {
        try db.query("SELECT json FROM agents WHERE id = ?", [.text(id.rawValue)]) { Self.decode(AgentProfile.self, $0.string(0), context: "agent \(id)") }.first ?? nil
    }

    public func listAgents(includeRetired: Bool) throws -> [AgentProfile] {
        let sql = includeRetired
            ? "SELECT json FROM agents ORDER BY created_at"
            : "SELECT json FROM agents WHERE status != 'retired' ORDER BY created_at"
        return try db.query(sql) { Self.decode(AgentProfile.self, $0.string(0), context: "agent") }.compactMap { $0 }
    }

    // MARK: - Conversations

    public func upsertConversation(_ conversation: Conversation) throws {
        try db.execute(
            """
            INSERT INTO conversations(id, agent_id, created_at, updated_at, json) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET agent_id=excluded.agent_id, updated_at=excluded.updated_at, json=excluded.json
            """,
            [.text(conversation.id.rawValue), .text(conversation.agentID.rawValue), .date(conversation.createdAt), .date(conversation.updatedAt), .text(try Self.encode(conversation))]
        )
    }

    /// Atomic on the store's actor: nothing else touches the store between the read and the write.
    public func mutateConversation(_ id: ConversationID, _ change: @Sendable (inout Conversation) -> Void) throws -> Conversation? {
        guard var c = try conversation(id) else { return nil }
        change(&c)
        try upsertConversation(c)
        return c
    }

    public func conversation(_ id: ConversationID) throws -> Conversation? {
        try db.query("SELECT json FROM conversations WHERE id = ?", [.text(id.rawValue)]) { Self.decode(Conversation.self, $0.string(0), context: "conversation \(id)") }.first ?? nil
    }

    public func listConversations(agentID: AgentID) throws -> [Conversation] {
        try db.query("SELECT json FROM conversations WHERE agent_id = ? ORDER BY updated_at DESC", [.text(agentID.rawValue)]) { Self.decode(Conversation.self, $0.string(0), context: "conversation") }.compactMap { $0 }
    }

    // MARK: - Messages

    public func appendMessage(_ message: Message) throws {
        let text = Self.searchableText(message)
        try db.transaction {
            try db.execute(
                """
                INSERT INTO messages(id, conversation_id, agent_id, task_id, role, created_at, text, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET conversation_id=excluded.conversation_id, agent_id=excluded.agent_id, task_id=excluded.task_id,
                    role=excluded.role, created_at=excluded.created_at, text=excluded.text, json=excluded.json
                """,
                [.text(message.id.rawValue), .text(message.conversationID.rawValue), .text(message.agentID.rawValue), .optional(message.taskID?.rawValue),
                 .text(message.role.rawValue), .date(message.createdAt), .text(text), .text(try Self.encode(message))]
            )
            try db.execute("DELETE FROM messages_fts WHERE message_id = ?", [.text(message.id.rawValue)])
            if !text.isEmpty {
                try db.execute("INSERT INTO messages_fts(message_id, text) VALUES (?, ?)", [.text(message.id.rawValue), .text(text)])
            }
            // A user or assistant line is what conversation lists show, and it moves the conversation to the top.
            // Tool and system messages, empty bodies, and streaming placeholders leave the row alone.
            if message.conversationPreview != nil, var conversation = try conversation(message.conversationID) {
                conversation.absorb(message)
                try upsertConversation(conversation)
            }
        }
    }

    public func updateMessage(_ message: Message) throws {
        try appendMessage(message)
    }

    public func message(_ id: MessageID) throws -> Message? {
        try db.query("SELECT json FROM messages WHERE id = ?", [.text(id.rawValue)]) { Self.decode(Message.self, $0.string(0), context: "message \(id)") }.first ?? nil
    }

    private func messageCursor(_ id: MessageID) throws -> (createdAt: Double, rowid: Int64)? {
        try db.query("SELECT created_at, rowid FROM messages WHERE id = ?", [.text(id.rawValue)]) { ($0.double(0), $0.int(1)) }.first
    }

    public func listMessages(conversationID: ConversationID, before: MessageID?, limit: Int) throws -> [Message] {
        let limit = max(0, limit)
        if let before, let cursor = try messageCursor(before) {
            return try db.query(
                """
                SELECT json FROM messages WHERE conversation_id = ? AND (created_at < ? OR (created_at = ? AND rowid < ?))
                ORDER BY created_at DESC, rowid DESC LIMIT ?
                """,
                [.text(conversationID.rawValue), .real(cursor.createdAt), .real(cursor.createdAt), .integer(cursor.rowid), .int(limit)]
            ) { Self.decode(Message.self, $0.string(0), context: "message") }.compactMap { $0 }
        }
        return try db.query(
            "SELECT json FROM messages WHERE conversation_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?",
            [.text(conversationID.rawValue), .int(limit)]
        ) { Self.decode(Message.self, $0.string(0), context: "message") }.compactMap { $0 }
    }

    public func messagesAfter(conversationID: ConversationID, after: MessageID?, limit: Int) throws -> [Message] {
        let limit = max(0, limit)
        if let after, let cursor = try messageCursor(after) {
            return try db.query(
                """
                SELECT json FROM messages WHERE conversation_id = ? AND (created_at > ? OR (created_at = ? AND rowid > ?))
                ORDER BY created_at ASC, rowid ASC LIMIT ?
                """,
                [.text(conversationID.rawValue), .real(cursor.createdAt), .real(cursor.createdAt), .integer(cursor.rowid), .int(limit)]
            ) { Self.decode(Message.self, $0.string(0), context: "message") }.compactMap { $0 }
        }
        return try db.query(
            "SELECT json FROM messages WHERE conversation_id = ? ORDER BY created_at ASC, rowid ASC LIMIT ?",
            [.text(conversationID.rawValue), .int(limit)]
        ) { Self.decode(Message.self, $0.string(0), context: "message") }.compactMap { $0 }
    }

    public func searchMessages(text: String, agentID: AgentID?, limit: Int) throws -> [Message] {
        guard let match = Self.ftsQuery(from: text) else { return [] }
        var sql = """
            SELECT m.json FROM messages_fts f JOIN messages m ON m.id = f.message_id
            WHERE messages_fts MATCH ?
            """
        var params: [SQLiteValue] = [.text(match)]
        if let agentID {
            sql += " AND m.agent_id = ?"
            params.append(.text(agentID.rawValue))
        }
        sql += " ORDER BY bm25(messages_fts) LIMIT ?"
        params.append(.int(max(0, limit)))
        return try db.query(sql, params) { Self.decode(Message.self, $0.string(0), context: "message") }.compactMap { $0 }
    }

    public func messageCount() throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM messages"))
    }

    // MARK: - Usage ledger

    public func appendUsage(_ record: UsageRecord) throws {
        try db.execute("INSERT OR REPLACE INTO usage_events(id, at, agent_id, task_id, model_label, json) VALUES (?, ?, ?, ?, ?, ?)",
                       [.text(record.id), .date(record.at), .text(record.agentID.rawValue), .text(record.taskID.rawValue), .text(record.modelLabel), .text(try Self.encode(record))])
    }

    public func usage(from: Date, to: Date) throws -> [UsageRecord] {
        try db.query("SELECT json FROM usage_events WHERE at >= ? AND at < ? ORDER BY at", [.date(from), .date(to)]) { row in
            Self.decode(UsageRecord.self, row.string(0), context: "usage record")
        }.compactMap { $0 }
    }

    // MARK: - Settings

    public func setSetting(_ key: String, value: String) throws {
        try db.execute("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }

    public func setting(_ key: String) throws -> String? {
        try db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]) { $0.string(0) }.first ?? nil
    }

    // MARK: - Maintenance

    public func databaseSizeBytes() throws -> Int {
        let fm = FileManager.default
        var total = 0
        for suffix in ["", "-wal"] {
            let path = paths.databaseURL.path + suffix
            if let attrs = try? fm.attributesOfItem(atPath: path), let size = attrs[.size] as? Int { total += size }
        }
        return total
    }

    public func backup(to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(HostPaths.databaseName)
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: destination.path + suffix) {
            try fm.removeItem(atPath: destination.path + suffix)
        }
        try db.backup(toPath: destination.path)
        let artifactsDestination = directory.appendingPathComponent("artifacts", isDirectory: true)
        if fm.fileExists(atPath: artifactsDestination.path) { try fm.removeItem(at: artifactsDestination) }
        if fm.fileExists(atPath: paths.artifactsURL.path) {
            try fm.copyItem(at: paths.artifactsURL, to: artifactsDestination)
        } else {
            try fm.createDirectory(at: artifactsDestination, withIntermediateDirectories: true)
        }
        log.info("Backed up store to \(directory.path)", category: "store")
    }

    public func close() {
        db.close()
    }
}
