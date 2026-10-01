import PennantCore
import Foundation

extension SQLiteStore {
    // MARK: - Entities

    nonisolated private static func attributesText(_ value: JSONValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s): return s
        case .array(let a): return a.map(attributesText).joined(separator: " ")
        case .object(let o): return o.keys.sorted().map { "\($0) \(attributesText(o[$0]!))" }.joined(separator: " ")
        }
    }

    private func indexEntity(_ entity: MemoryEntity) throws {
        try db.execute("DELETE FROM entities_fts WHERE entity_id = ?", [.text(entity.id.rawValue)])
        guard entity.status != .forgotten else { return }
        try db.execute(
            "INSERT INTO entities_fts(entity_id, name, summary, attributes) VALUES (?, ?, ?, ?)",
            [.text(entity.id.rawValue), .text(entity.name), .text(entity.summary), .text(Self.attributesText(entity.attributes))]
        )
    }

    public func upsertEntity(_ entity: MemoryEntity) throws {
        try db.transaction {
            try db.execute(
                """
                INSERT INTO memory_entities(id, kind, name, scope, status, observed_at, updated_at, superseded_by, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, name=excluded.name, scope=excluded.scope, status=excluded.status,
                    observed_at=excluded.observed_at, updated_at=excluded.updated_at, superseded_by=excluded.superseded_by, json=excluded.json
                """,
                [.text(entity.id.rawValue), .text(entity.kind.rawValue), .text(entity.name), .text(entity.scope), .text(entity.status.rawValue),
                 .date(entity.observedAt), .date(entity.updatedAt), .optional(entity.supersededBy?.rawValue), .text(try Self.encode(entity))]
            )
            try indexEntity(entity)
        }
    }

    public func entity(_ id: MemoryEntityID) throws -> MemoryEntity? {
        try db.query("SELECT json FROM memory_entities WHERE id = ?", [.text(id.rawValue)]) { Self.decode(MemoryEntity.self, $0.string(0), context: "entity \(id)") }.first ?? nil
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    public func findEntities(name: String, kind: MemoryEntityKind?, scopes: [String]) throws -> [MemoryEntity] {
        var sql = "SELECT json FROM memory_entities WHERE name = ? COLLATE NOCASE AND status IN (\(Self.placeholders(Self.activeMemoryStatuses.count)))"
        var params: [SQLiteValue] = [.text(name.trimmingCharacters(in: .whitespacesAndNewlines))] + Self.activeMemoryStatuses.map { .text($0) }
        if let kind {
            sql += " AND kind = ?"
            params.append(.text(kind.rawValue))
        }
        if !scopes.isEmpty {
            sql += " AND scope IN (\(Self.placeholders(scopes.count)))"
            params += scopes.map { .text($0) }
        }
        sql += " ORDER BY updated_at DESC"
        return try db.query(sql, params) { Self.decode(MemoryEntity.self, $0.string(0), context: "entity") }.compactMap { $0 }
    }

    public func listEntities(kind: MemoryEntityKind?, scope: String?, includeInactive: Bool, limit: Int) throws -> [MemoryEntity] {
        var clauses: [String] = []
        var params: [SQLiteValue] = []
        if let kind {
            clauses.append("kind = ?")
            params.append(.text(kind.rawValue))
        }
        if let scope {
            clauses.append("scope = ?")
            params.append(.text(scope))
        }
        if !includeInactive {
            clauses.append("status IN (\(Self.placeholders(Self.activeMemoryStatuses.count)))")
            params += Self.activeMemoryStatuses.map { .text($0) }
        }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        params.append(.int(max(0, limit)))
        return try db.query("SELECT json FROM memory_entities" + whereSQL + " ORDER BY updated_at DESC LIMIT ?", params) { Self.decode(MemoryEntity.self, $0.string(0), context: "entity") }.compactMap { $0 }
    }

    public func searchEntities(text: String, scopes: [String], includeInactive: Bool, limit: Int) throws -> [(MemoryEntity, Double)] {
        try Self.withRecall(text: salientText(text, table: "entities_fts"), limit: limit, id: { $0.id.rawValue }) { match, limit in
            try searchEntities(match: match, scopes: scopes, includeInactive: includeInactive, limit: limit)
        }
    }

    private func searchEntities(match: String, scopes: [String], includeInactive: Bool, limit: Int) throws -> [(MemoryEntity, Double)] {
        var sql = """
            SELECT e.json, bm25(entities_fts) AS rank FROM entities_fts f JOIN memory_entities e ON e.id = f.entity_id
            WHERE entities_fts MATCH ?
            """
        var params: [SQLiteValue] = [.text(match)]
        if !scopes.isEmpty {
            sql += " AND e.scope IN (\(Self.placeholders(scopes.count)))"
            params += scopes.map { .text($0) }
        }
        if !includeInactive {
            sql += " AND e.status IN (\(Self.placeholders(Self.activeMemoryStatuses.count)))"
            params += Self.activeMemoryStatuses.map { .text($0) }
        }
        sql += " ORDER BY rank LIMIT ?"
        params.append(.int(max(0, limit)))
        return try db.query(sql, params) { row -> (MemoryEntity, Double)? in
            guard let entity = Self.decode(MemoryEntity.self, row.string(0), context: "entity") else { return nil }
            return (entity, row.double(1))
        }.compactMap { $0 }
    }

    public func forgetEntity(_ id: MemoryEntityID) throws {
        guard var entity = try entity(id) else { return }
        entity.name = ""
        entity.summary = ""
        entity.attributes = .object([:])
        entity.status = .forgotten
        entity.updatedAt = Date()
        try db.transaction {
            try upsertEntity(entity)
            try db.execute("DELETE FROM embeddings WHERE kind = 'entity' AND item_id = ?", [.text(id.rawValue)])
        }
    }

    // MARK: - Relations

    public func upsertRelation(_ relation: MemoryRelation) throws {
        try db.execute(
            """
            INSERT INTO memory_relations(id, from_id, relation, to_id, scope, status, observed_at, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET from_id=excluded.from_id, relation=excluded.relation, to_id=excluded.to_id, scope=excluded.scope,
                status=excluded.status, observed_at=excluded.observed_at, json=excluded.json
            """,
            [.text(relation.id.rawValue), .text(relation.fromEntityID.rawValue), .text(relation.relation), .text(relation.toEntityID.rawValue),
             .text(relation.scope), .text(relation.status.rawValue), .date(relation.observedAt), .text(try Self.encode(relation))]
        )
    }

    public func relation(_ id: MemoryRelationID) throws -> MemoryRelation? {
        try db.query("SELECT json FROM memory_relations WHERE id = ?", [.text(id.rawValue)]) { Self.decode(MemoryRelation.self, $0.string(0), context: "relation \(id)") }.first ?? nil
    }

    public func relations(entityID: MemoryEntityID, includeInactive: Bool) throws -> [MemoryRelation] {
        var sql = "SELECT json FROM memory_relations WHERE (from_id = ? OR to_id = ?)"
        var params: [SQLiteValue] = [.text(entityID.rawValue), .text(entityID.rawValue)]
        if !includeInactive {
            sql += " AND status IN (\(Self.placeholders(Self.activeMemoryStatuses.count)))"
            params += Self.activeMemoryStatuses.map { .text($0) }
        }
        sql += " ORDER BY observed_at DESC"
        return try db.query(sql, params) { Self.decode(MemoryRelation.self, $0.string(0), context: "relation") }.compactMap { $0 }
    }

    public func forgetRelation(_ id: MemoryRelationID) throws {
        guard var relation = try relation(id) else { return }
        relation.relation = ""
        relation.status = .forgotten
        try upsertRelation(relation)
    }

    // MARK: - Preferences

    private func indexPreference(_ preference: Preference) throws {
        try db.execute("DELETE FROM preferences_fts WHERE preference_id = ?", [.text(preference.id.rawValue)])
        guard preference.status != .forgotten, !preference.text.isEmpty else { return }
        try db.execute("INSERT INTO preferences_fts(preference_id, text) VALUES (?, ?)", [.text(preference.id.rawValue), .text(preference.text)])
    }

    public func upsertPreference(_ preference: Preference) throws {
        try db.transaction {
            try db.execute(
                """
                INSERT INTO preferences(id, scope, status, version, updated_at, json) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET scope=excluded.scope, status=excluded.status, version=excluded.version, updated_at=excluded.updated_at, json=excluded.json
                """,
                [.text(preference.id.rawValue), .text(preference.scope), .text(preference.status.rawValue), .int(preference.version), .date(preference.updatedAt), .text(try Self.encode(preference))]
            )
            try indexPreference(preference)
        }
    }

    public func preference(_ id: PreferenceID) throws -> Preference? {
        try db.query("SELECT json FROM preferences WHERE id = ?", [.text(id.rawValue)]) { Self.decode(Preference.self, $0.string(0), context: "preference \(id)") }.first ?? nil
    }

    public func listPreferences(scopes: [String]?, includeInactive: Bool) throws -> [Preference] {
        var clauses: [String] = []
        var params: [SQLiteValue] = []
        if let scopes, !scopes.isEmpty {
            clauses.append("scope IN (\(Self.placeholders(scopes.count)))")
            params += scopes.map { .text($0) }
        }
        if !includeInactive {
            clauses.append("status IN (\(Self.placeholders(Self.activeMemoryStatuses.count)))")
            params += Self.activeMemoryStatuses.map { .text($0) }
        }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        return try db.query("SELECT json FROM preferences" + whereSQL + " ORDER BY updated_at DESC", params) { Self.decode(Preference.self, $0.string(0), context: "preference") }.compactMap { $0 }
    }

    public func searchPreferences(text: String, scopes: [String], limit: Int) throws -> [(Preference, Double)] {
        try Self.withRecall(text: text, limit: limit, id: { $0.id.rawValue }) { match, limit in
            try searchPreferences(match: match, scopes: scopes, limit: limit)
        }
    }

    private func searchPreferences(match: String, scopes: [String], limit: Int) throws -> [(Preference, Double)] {
        var sql = """
            SELECT p.json, bm25(preferences_fts) AS rank FROM preferences_fts f JOIN preferences p ON p.id = f.preference_id
            WHERE preferences_fts MATCH ? AND p.status IN (\(Self.placeholders(Self.activeMemoryStatuses.count)))
            """
        var params: [SQLiteValue] = [.text(match)] + Self.activeMemoryStatuses.map { .text($0) }
        if !scopes.isEmpty {
            sql += " AND p.scope IN (\(Self.placeholders(scopes.count)))"
            params += scopes.map { .text($0) }
        }
        sql += " ORDER BY rank LIMIT ?"
        params.append(.int(max(0, limit)))
        return try db.query(sql, params) { row -> (Preference, Double)? in
            guard let preference = Self.decode(Preference.self, row.string(0), context: "preference") else { return nil }
            return (preference, row.double(1))
        }.compactMap { $0 }
    }

    public func forgetPreference(_ id: PreferenceID) throws {
        guard var preference = try preference(id) else { return }
        preference.text = ""
        preference.status = .forgotten
        preference.updatedAt = Date()
        try db.transaction {
            try upsertPreference(preference)
            try db.execute("DELETE FROM embeddings WHERE kind = 'preference' AND item_id = ?", [.text(id.rawValue)])
        }
    }

    // MARK: - Overview

    public func memoryOverview() throws -> MemoryOverview {
        let active = "(\(Self.activeMemoryStatuses.map { "'\($0)'" }.joined(separator: ", ")))"
        return MemoryOverview(
            entityCount: Int(try db.scalarInt("SELECT COUNT(*) FROM memory_entities WHERE status IN \(active)")),
            relationCount: Int(try db.scalarInt("SELECT COUNT(*) FROM memory_relations WHERE status IN \(active)")),
            preferenceCount: Int(try db.scalarInt("SELECT COUNT(*) FROM preferences WHERE status IN \(active)")),
            messageCount: try messageCount(),
            skillCount: Int(try db.scalarInt("SELECT COUNT(*) FROM skills WHERE status != 'disabled'")),
            databaseBytes: try databaseSizeBytes()
        )
    }

    // MARK: - Embeddings

    nonisolated private static func vectorData(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    nonisolated private static func vector(from data: Data, dims: Int) -> [Float] {
        guard data.count >= dims * MemoryLayout<Float>.size else { return [] }
        return data.withUnsafeBytes { buf in
            Array(buf.bindMemory(to: Float.self).prefix(dims))
        }
    }

    public func putEmbedding(kind: String, itemID: String, vector: [Float]) throws {
        try db.execute(
            "INSERT INTO embeddings(kind, item_id, dims, vector) VALUES (?, ?, ?, ?) ON CONFLICT(kind, item_id) DO UPDATE SET dims=excluded.dims, vector=excluded.vector",
            [.text(kind), .text(itemID), .int(vector.count), .blob(Self.vectorData(vector))]
        )
    }

    public func embeddedItemIDs(kind: String) throws -> Set<String> {
        Set(try db.query("SELECT item_id FROM embeddings WHERE kind = ?", [.text(kind)]) { $0.string(0) }.compactMap { $0 })
    }

    public func clearEmbeddings() throws {
        try db.execute("DELETE FROM embeddings", [])
    }

    public func nearestEmbeddings(kind: String, vector query: [Float], limit: Int) throws -> [(itemID: String, similarity: Double)] {
        guard !query.isEmpty, limit > 0 else { return [] }
        let queryNorm = sqrt(query.reduce(0) { $0 + Double($1) * Double($1) })
        guard queryNorm > 0 else { return [] }
        let scored = try db.query("SELECT item_id, dims, vector FROM embeddings WHERE kind = ? AND dims = ?", [.text(kind), .int(query.count)]) { row -> (String, Double)? in
            guard let id = row.string(0), let data = row.data(2) else { return nil }
            let v = Self.vector(from: data, dims: Int(row.int(1)))
            guard v.count == query.count else { return nil }
            var dot = 0.0
            var norm = 0.0
            for i in 0 ..< v.count {
                dot += Double(v[i]) * Double(query[i])
                norm += Double(v[i]) * Double(v[i])
            }
            guard norm > 0 else { return nil }
            return (id, dot / (sqrt(norm) * queryNorm))
        }.compactMap { $0 }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { (itemID: $0.0, similarity: $0.1) }
    }
}
