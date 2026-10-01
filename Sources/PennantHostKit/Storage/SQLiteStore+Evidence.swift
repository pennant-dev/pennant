import PennantCore
import Foundation

/// Memory's evidence and corrections: passages of what was said (conversations, reports) with their own keyword
/// index, the names people removed from memory, and the old names of renamed or merged facts. Only the SQLite
/// store has these; memory works without them (no passages, no aliases) on stores that don't.
public protocol MemoryEvidenceStore: Sendable {
    func sourceSignatures() async throws -> [String: String]
    func replaceSource(id: String, kind: String, conversationID: ConversationID?, agentID: AgentID?, title: String, updatedAt: Date, signature: String, passages: [MemoryPassage]) async throws
    func deleteSource(_ id: String) async throws
    func searchPassages(text: String, excludingConversation: ConversationID?, limit: Int) async throws -> [(MemoryPassage, Double)]
    /// Passages that mention any of these names as a phrase, newest first.
    func passagesMentioning(_ names: [String], limit: Int) async throws -> [MemoryPassage]
    func passage(_ id: String) async throws -> MemoryPassage?
    func passageCount() async throws -> Int
    func passageIDs() async throws -> [String]

    func setAlias(_ normalized: String, name: String) async throws
    func aliasTarget(_ normalized: String) async throws -> String?
    func aliases(of name: String) async throws -> [String]

    func ignore(name: String, normalized: String, kind: MemoryEntityKind) async throws
    func unignore(normalized: String, kind: MemoryEntityKind) async throws
    func isIgnored(normalized: String, kind: MemoryEntityKind) async throws -> Bool
    func ignoredNames() async throws -> [IgnoredMemoryName]
}

extension SQLiteStore: MemoryEvidenceStore {
    public func sourceSignatures() throws -> [String: String] {
        var out: [String: String] = [:]
        let rows = try db.query("SELECT id, signature FROM memory_sources", []) { row -> (String, String)? in
            guard let id = row.string(0), let sig = row.string(1) else { return nil }
            return (id, sig)
        }
        for case let (id, sig)? in rows { out[id] = sig }
        return out
    }

    public func replaceSource(id: String, kind: String, conversationID: ConversationID?, agentID: AgentID?, title: String, updatedAt: Date, signature: String, passages: [MemoryPassage]) throws {
        try db.transaction {
            try removeChunks(sourceID: id)
            let conversation: SQLiteValue = conversationID.map { .text($0.rawValue) } ?? .null
            let agent: SQLiteValue = agentID.map { .text($0.rawValue) } ?? .null
            let params: [SQLiteValue] = [.text(id), .text(kind), conversation, agent, .text(title), .real(updatedAt.timeIntervalSince1970), .text(signature)]
            try db.execute(
                "INSERT INTO memory_sources(id, kind, conversation_id, agent_id, title, updated_at, signature) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, conversation_id=excluded.conversation_id, agent_id=excluded.agent_id, title=excluded.title, updated_at=excluded.updated_at, signature=excluded.signature",
                params
            )
            for (ordinal, p) in passages.enumerated() {
                let json = String(decoding: try JSONCodec.encode(p), as: UTF8.self)
                try db.execute("INSERT INTO memory_chunks(id, source_id, ordinal, json) VALUES (?, ?, ?, ?)", [.text(p.id), .text(id), .int(ordinal), .text(json)])
                try db.execute("INSERT INTO chunks_fts(chunk_id, title, text) VALUES (?, ?, ?)", [.text(p.id), .text(p.title), .text(p.text)])
            }
        }
    }

    public func deleteSource(_ id: String) throws {
        try db.transaction {
            try removeChunks(sourceID: id)
            try db.execute("DELETE FROM memory_sources WHERE id = ?", [.text(id)])
        }
    }

    private func removeChunks(sourceID: String) throws {
        let ids = try db.query("SELECT id FROM memory_chunks WHERE source_id = ?", [.text(sourceID)]) { $0.string(0) }.compactMap { $0 }
        for chunk in ids {
            try db.execute("DELETE FROM chunks_fts WHERE chunk_id = ?", [.text(chunk)])
            try db.execute("DELETE FROM embeddings WHERE kind = 'chunk' AND item_id = ?", [.text(chunk)])
        }
        try db.execute("DELETE FROM memory_chunks WHERE source_id = ?", [.text(sourceID)])
    }

    /// BM25 over an OR of the significant words (Binders weights the text 1.0 and the title 0.4).
    public func searchPassages(text: String, excludingConversation: ConversationID?, limit: Int) throws -> [(MemoryPassage, Double)] {
        guard let match = Self.ftsAnyQuery(from: salientText(text, table: "chunks_fts")) else { return [] }
        let rows = try db.query(
            "SELECT c.json, bm25(chunks_fts, 0, 0.4, 1.0) AS rank FROM chunks_fts f JOIN memory_chunks c ON c.id = f.chunk_id WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?",
            [.text(match), .int(max(0, limit + 20))]
        ) { row -> (MemoryPassage, Double)? in
            guard let p = Self.decode(MemoryPassage.self, row.string(0), context: "passage") else { return nil }
            return (p, row.double(1))
        }.compactMap { $0 }
        return Array(rows.filter { excludingConversation == nil || $0.0.conversationID != excludingConversation }.prefix(limit))
    }

    public func passagesMentioning(_ names: [String], limit: Int) throws -> [MemoryPassage] {
        let phrases = names.map { $0.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces) }.filter { $0.count > 1 }
        guard !phrases.isEmpty else { return [] }
        let match = phrases.map { "\"\($0)\"" }.joined(separator: " OR ")
        let found = try db.query(
            "SELECT c.json FROM chunks_fts f JOIN memory_chunks c ON c.id = f.chunk_id WHERE chunks_fts MATCH ? LIMIT ?",
            [.text(match), .int(max(0, limit * 3))]
        ) { Self.decode(MemoryPassage.self, $0.string(0), context: "passage") }.compactMap { $0 }
        return Array(found.sorted { $0.at > $1.at }.prefix(limit))
    }

    public func passage(_ id: String) throws -> MemoryPassage? {
        try db.query("SELECT json FROM memory_chunks WHERE id = ?", [.text(id)]) { Self.decode(MemoryPassage.self, $0.string(0), context: "passage") }.first ?? nil
    }

    public func passageCount() throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM memory_chunks"))
    }

    public func passageIDs() throws -> [String] {
        try db.query("SELECT id FROM memory_chunks", []) { $0.string(0) }.compactMap { $0 }
    }

    public func setAlias(_ normalized: String, name: String) throws {
        try db.execute("INSERT INTO memory_aliases(normalized, name) VALUES (?, ?) ON CONFLICT(normalized) DO UPDATE SET name=excluded.name", [.text(normalized), .text(name)])
    }

    public func aliasTarget(_ normalized: String) throws -> String? {
        try db.query("SELECT name FROM memory_aliases WHERE normalized = ?", [.text(normalized)]) { $0.string(0) }.first ?? nil
    }

    public func aliases(of name: String) throws -> [String] {
        try db.query("SELECT normalized FROM memory_aliases WHERE name = ? COLLATE NOCASE", [.text(name)]) { $0.string(0) }.compactMap { $0 }
    }

    public func ignore(name: String, normalized: String, kind: MemoryEntityKind) throws {
        try db.execute(
            "INSERT INTO memory_ignored(normalized, kind, name, ignored_at) VALUES (?, ?, ?, ?) ON CONFLICT(normalized, kind) DO UPDATE SET name=excluded.name, ignored_at=excluded.ignored_at",
            [.text(normalized), .text(kind.rawValue), .text(name), .real(Date().timeIntervalSince1970)]
        )
    }

    public func unignore(normalized: String, kind: MemoryEntityKind) throws {
        try db.execute("DELETE FROM memory_ignored WHERE normalized = ? AND kind = ?", [.text(normalized), .text(kind.rawValue)])
    }

    public func isIgnored(normalized: String, kind: MemoryEntityKind) throws -> Bool {
        try db.scalarInt("SELECT COUNT(*) FROM memory_ignored WHERE normalized = ? AND kind = ?", [.text(normalized), .text(kind.rawValue)]) > 0
    }

    public func ignoredNames() throws -> [IgnoredMemoryName] {
        try db.query("SELECT name, kind, ignored_at FROM memory_ignored ORDER BY ignored_at DESC", []) { row -> IgnoredMemoryName? in
            guard let name = row.string(0), let kind = row.string(1).flatMap(MemoryEntityKind.init(rawValue:)) else { return nil }
            return IgnoredMemoryName(name: name, kind: kind, ignoredAt: Date(timeIntervalSince1970: row.double(2)))
        }.compactMap { $0 }
    }
}
