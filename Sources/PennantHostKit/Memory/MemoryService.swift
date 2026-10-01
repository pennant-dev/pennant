import PennantCore
import Foundation

/// Memory operations with the rules from the spec: provenance on everything, versions kept,
/// inferred claims never silently replace asserted ones, and retrieval that combines
/// full-text search, graph neighbours, and optional embeddings.
public actor MemoryService {
    let store: any StoreProtocol
    private let eventBus: EventBus
    private let embeddings: (any EmbeddingProvider)?

    public init(store: any StoreProtocol, eventBus: EventBus, embeddings: (any EmbeddingProvider)? = nil) {
        self.store = store
        self.eventBus = eventBus
        self.embeddings = embeddings
    }

    /// Passages, aliases and removed names; the SQLite store has them, test doubles may not.
    private var evidence: (any MemoryEvidenceStore)? { store as? any MemoryEvidenceStore }

    /// A name as a lookup key: lowercase, accents and punctuation gone, spaces collapsed, a leading "the" dropped.
    public static func normalize(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        let words = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        var parts = String(words).split(separator: " ").map(String.init)
        if parts.count > 1, parts.first == "the" { parts.removeFirst() }
        return parts.joined(separator: " ")
    }

    // MARK: Scopes

    public func readableScopes(for agent: AgentProfile) -> [String] {
        var scopes = Set(agent.memoryScope.readableScopes)
        scopes.insert(agent.memoryScope.label)
        scopes.insert("shared")
        return Array(scopes)
    }

    // MARK: Governing instructions

    public func governingPreferences(for agent: AgentProfile) async throws -> [Preference] {
        try await store.listPreferences(scopes: readableScopes(for: agent), includeInactive: false)
            .filter { $0.status == .asserted }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Record an explicit instruction. A near-duplicate active preference is superseded by a new version.
    @discardableResult
    public func addPreference(text: String, scope: String, provenance: Provenance) async throws -> Preference {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try await store.searchPreferences(text: trimmed, scopes: [scope], limit: 3)
        var previous: Preference?
        for (candidate, _) in existing where candidate.status == .asserted {
            if Similarity.jaccard(candidate.text, trimmed) > 0.6 { previous = candidate; break }
        }
        var pref = Preference(text: trimmed, scope: scope, status: .asserted, provenance: provenance)
        if let previous {
            pref.version = previous.version + 1
            pref.previousVersionID = previous.id
            var old = previous
            old.status = .superseded
            old.updatedAt = Date()
            try await store.upsertPreference(old)
            _ = try await publish(.preferenceUpserted(old))
        }
        try await store.upsertPreference(pref)
        await indexEmbedding(kind: "preference", id: pref.id.rawValue, title: "instruction", text: pref.text)
        _ = try await publish(.preferenceUpserted(pref))
        return pref
    }

    /// User edits from the Memory view: replaces the text as a new asserted version.
    public func editPreference(_ edited: Preference) async throws -> Preference {
        guard let current = try await store.preference(edited.id) else { throw ToolError.failed("Preference not found") }
        var old = current
        old.status = .superseded
        old.updatedAt = Date()
        try await store.upsertPreference(old)
        var next = edited
        next.id = PreferenceID()
        next.version = current.version + 1
        next.previousVersionID = current.id
        next.status = .asserted
        next.provenance = Provenance(sourceType: .userEdit, sourceID: current.id.rawValue, note: "Edited in Memory view")
        next.createdAt = Date()
        next.updatedAt = Date()
        try await store.upsertPreference(next)
        await indexEmbedding(kind: "preference", id: next.id.rawValue, title: "instruction", text: next.text)
        _ = try await publish(.preferenceUpserted(old))
        _ = try await publish(.preferenceUpserted(next))
        return next
    }

    public func forgetPreference(_ id: PreferenceID) async throws {
        try await store.forgetPreference(id)
        _ = try await publish(.memoryForgotten(kind: "preference", id: id.rawValue))
    }

    // MARK: Entities and relations

    /// Assert or infer an entity. Rules:
    /// - identical content only refreshes `observedAt`;
    /// - an asserted claim supersedes the previous active version;
    /// - an inferred claim that differs from an asserted one is stored as `contradicted` and the asserted one stays current;
    /// - an inferred claim supersedes an older inferred one.
    @discardableResult
    public func assertEntity(kind: MemoryEntityKind, name: String, attributes: JSONValue = .object([:]), summary: String = "", scope: String, status: MemoryStatus, provenance: Provenance) async throws -> MemoryEntity {
        var cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let evidence {
            let key = Self.normalize(cleanName)
            // Removed by the user: not remembered again until they restore it.
            if try await evidence.isIgnored(normalized: key, kind: kind) {
                throw ToolError.failed("The user removed \"\(cleanName)\" from memory; don't remember it again unless they ask.")
            }
            // A renamed or merged fact answers to its old names.
            if let target = try await evidence.aliasTarget(key) { cleanName = target }
        }
        // One copy per fact: an agent's private write updates the shared entity when there is one, rather than
        // starting a second copy only it can see.
        let matches = try await store.findEntities(name: cleanName, kind: kind, scopes: Array(Set([scope, "shared"])))
        let current = matches.first { $0.status == .asserted || $0.status == .inferred }
        var entity = MemoryEntity(kind: kind, name: cleanName, attributes: attributes, summary: summary, scope: current?.scope ?? scope, status: status, provenance: provenance)

        if let current {
            let same = current.attributes == attributes && current.summary == summary
            if same {
                var touched = current
                touched.observedAt = Date()
                touched.updatedAt = Date()
                try await store.upsertEntity(touched)
                return touched
            }
            entity.version = current.version + 1
            // Merge: keep old attributes that the new claim does not mention.
            if case .object(let oldAttrs) = current.attributes, case .object(var newAttrs) = attributes {
                for (k, v) in oldAttrs where newAttrs[k] == nil { newAttrs[k] = v }
                entity.attributes = .object(newAttrs)
            }
            if entity.summary.isEmpty { entity.summary = current.summary }
            switch (current.status, status) {
            case (.asserted, .inferred):
                entity.status = .contradicted
                try await store.upsertEntity(entity)
                _ = try await publish(.memoryEntityUpserted(entity))
                log.info("Inferred claim about \(cleanName) contradicts an asserted fact; kept both", category: "memory")
                return entity
            default:
                var old = current
                old.status = .superseded
                old.supersededBy = entity.id
                old.updatedAt = Date()
                try await store.upsertEntity(old)
                _ = try await publish(.memoryEntityUpserted(old))
            }
        }
        try await store.upsertEntity(entity)
        await indexEmbedding(kind: "entity", id: entity.id.rawValue, title: entity.name, text: Self.entityText(entity))
        _ = try await publish(.memoryEntityUpserted(entity))
        return entity
    }

    /// Link two entities by name, creating missing endpoints as `inferred` placeholders of the given kinds.
    @discardableResult
    public func relate(fromName: String, fromKind: MemoryEntityKind, relation: String, toName: String, toKind: MemoryEntityKind, scope: String, status: MemoryStatus, provenance: Provenance) async throws -> MemoryRelation {
        let from = try await resolveOrCreate(name: fromName, kind: fromKind, scope: scope, provenance: provenance)
        let to = try await resolveOrCreate(name: toName, kind: toKind, scope: scope, provenance: provenance)
        let rel = relation.lowercased().replacingOccurrences(of: " ", with: "_")
        let existing = try await store.relations(entityID: from.id, includeInactive: false)
        if let dup = existing.first(where: { $0.fromEntityID == from.id && $0.toEntityID == to.id && $0.relation == rel }) {
            if dup.status == .inferred, status == .asserted {
                var upgraded = dup
                upgraded.status = .asserted
                upgraded.provenance = provenance
                upgraded.observedAt = Date()
                try await store.upsertRelation(upgraded)
                _ = try await publish(.memoryRelationUpserted(upgraded))
                return upgraded
            }
            return dup
        }
        let relationRecord = MemoryRelation(fromEntityID: from.id, relation: rel, toEntityID: to.id, scope: scope, status: status, provenance: provenance)
        try await store.upsertRelation(relationRecord)
        _ = try await publish(.memoryRelationUpserted(relationRecord))
        return relationRecord
    }

    private func resolveOrCreate(name: String, kind: MemoryEntityKind, scope: String, provenance: Provenance) async throws -> MemoryEntity {
        let matches = try await store.findEntities(name: name, kind: kind, scopes: [scope, "shared"])
        if let e = matches.first(where: { $0.status == .asserted }) ?? matches.first(where: { $0.status == .inferred }) { return e }
        return try await assertEntity(kind: kind, name: name, scope: scope, status: .inferred, provenance: provenance)
    }

    public func editEntity(_ edited: MemoryEntity) async throws -> MemoryEntity {
        guard let current = try await store.entity(edited.id) else { throw ToolError.failed("Entity not found") }
        var old = current
        var next = edited
        next.id = MemoryEntityID()
        next.version = current.version + 1
        next.status = .asserted
        next.provenance = Provenance(sourceType: .userEdit, sourceID: current.id.rawValue, note: "Edited in Memory view")
        next.createdAt = Date()
        next.updatedAt = Date()
        next.observedAt = Date()
        old.status = .superseded
        old.supersededBy = next.id
        old.updatedAt = Date()
        try await store.upsertEntity(old)
        try await store.upsertEntity(next)
        // Re-point active relations to the new version so the graph stays connected.
        for rel in try await store.relations(entityID: current.id, includeInactive: false) {
            var moved = rel
            if moved.fromEntityID == current.id { moved.fromEntityID = next.id }
            if moved.toEntityID == current.id { moved.toEntityID = next.id }
            try await store.upsertRelation(moved)
        }
        await indexEmbedding(kind: "entity", id: next.id.rawValue, title: next.name, text: Self.entityText(next))
        _ = try await publish(.memoryEntityUpserted(old))
        _ = try await publish(.memoryEntityUpserted(next))
        return next
    }

    /// Forgets a fact for good: it's removed, and its name is kept on the removed list so agents don't learn it
    /// again (restore it to allow that).
    public func forgetEntity(_ id: MemoryEntityID) async throws {
        if let evidence, let e = try await store.entity(id) {
            try await evidence.ignore(name: e.name, normalized: Self.normalize(e.name), kind: e.kind)
        }
        for rel in try await store.relations(entityID: id, includeInactive: false) {
            try await store.forgetRelation(rel.id)
            _ = try await publish(.memoryForgotten(kind: "relation", id: rel.id.rawValue))
        }
        try await store.forgetEntity(id)
        _ = try await publish(.memoryForgotten(kind: "entity", id: id.rawValue))
    }


    // MARK: Retrieval

    /// Combined retrieval, as Binders does it: keyword search (BM25) and meaning search (embeddings) each give a
    /// ranked list, and the lists are merged by reciprocal rank (k = 60), so scores from different searches never
    /// have to be compared. Asserted claims rank above inferred and recent observations above old ones; superseded
    /// items are left out unless asked for, and contradicted ones never reach an agent's context on their own
    /// (`forContext`). Graph neighbours of the strongest entities come along below them.
    /// `includeInstructions`: agents already have every standing instruction in their system prompt, so their
    /// lookups leave them out; otherwise instructions (which mention the same few names everywhere) crowd out facts.
    public func retrieve(_ query: MemoryQuery, agent: AgentProfile?, includeMessages: Bool = true, forContext: Bool = false,
                         excludingConversation: ConversationID? = nil, includeInstructions: Bool = true) async throws -> [MemoryHit] {
        let scopes = query.scopes.isEmpty ? (agent.map { readableScopes(for: $0) } ?? []) : query.scopes
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var items: [String: MemoryHit.Item] = [:]
        var reasons: [String: String] = [:]
        var fused: [String: Double] = [:]
        func rank(_ list: [(key: String, item: MemoryHit.Item)], reason: String, weight: Double = 1) {
            for (i, entry) in list.enumerated() {
                fused[entry.key, default: 0] += weight / Double(Self.fusionK + i + 1)
                if items[entry.key] == nil { items[entry.key] = entry.item; reasons[entry.key] = reason }
            }
        }
        func usable(_ status: MemoryStatus) -> Bool {
            switch status {
            case .asserted, .inferred: return true
            case .contradicted: return !forContext
            case .superseded, .forgotten: return query.includeSuperseded
            }
        }
        func inScope(_ scope: String) -> Bool { scopes.isEmpty || scopes.contains(scope) }

        // Keyword.
        let entityHits = try await store.searchEntities(text: text, scopes: scopes, includeInactive: query.includeSuperseded, limit: Self.candidates)
        rank(entityHits.filter { usable($0.0.status) }.map { (key: "e:\($0.0.id)", item: .entity($0.0)) }, reason: "matched text")
        if includeInstructions {
            let preferenceHits = try await store.searchPreferences(text: text, scopes: scopes, limit: 16)
            rank(preferenceHits.filter { $0.0.status == .asserted }.map { (key: "p:\($0.0.id)", item: .preference($0.0)) }, reason: "matched instruction")
        }

        // What was said: passages from conversations and reports (not the conversation being worked on, which the
        // agent already sees).
        let passagesIndexed = ((try? await evidence?.passageCount()) ?? 0) > 0
        if let evidence, passagesIndexed {
            let said = try await evidence.searchPassages(text: text, excludingConversation: excludingConversation, limit: Self.candidates)
            rank(said.map { (key: "c:\($0.0.id)", item: .passage($0.0)) }, reason: "what was said")
        }

        // Meaning.
        let vector = embeddings == nil ? nil : try? await embeddings!.embed([queryPrompt(text)]).first
        if let evidence, passagesIndexed, let vector {
            var said: [(key: String, item: MemoryHit.Item)] = []
            for (itemID, sim) in try await store.nearestEmbeddings(kind: "chunk", vector: vector, limit: Self.candidates) where sim >= Self.minimumSimilarity {
                if let p = try await evidence.passage(itemID), excludingConversation == nil || p.conversationID != excludingConversation {
                    said.append((key: "c:\(p.id)", item: .passage(p)))
                }
            }
            rank(said, reason: "what was said, related in meaning")
        }
        if let vector {
            var related: [(key: String, item: MemoryHit.Item)] = []
            for (itemID, sim) in try await store.nearestEmbeddings(kind: "entity", vector: vector, limit: Self.candidates) where sim >= Self.minimumSimilarity {
                if let e = try await store.entity(MemoryEntityID(itemID)), inScope(e.scope), usable(e.status) { related.append((key: "e:\(e.id)", item: .entity(e))) }
            }
            rank(related, reason: "related in meaning")
            if includeInstructions {
                var instructions: [(key: String, item: MemoryHit.Item)] = []
                for (itemID, sim) in try await store.nearestEmbeddings(kind: "preference", vector: vector, limit: 16) where sim >= Self.minimumSimilarity {
                    if let p = try await store.preference(PreferenceID(itemID)), inScope(p.scope), p.status == .asserted { instructions.append((key: "p:\(p.id)", item: .preference(p))) }
                }
                rank(instructions, reason: "related instruction")
            }
        }

        for (key, item) in items { fused[key, default: 0] *= Self.weight(item) }

        // Graph expansion: one hop from the strongest entity hits.
        let topEntities = items.compactMap { key, item -> (MemoryEntity, Double)? in
            if case .entity(let e) = item { return (e, fused[key] ?? 0) } else { return nil }
        }.sorted { $0.1 > $1.1 }.prefix(5)
        for (entity, score) in topEntities {
            for rel in try await store.relations(entityID: entity.id, includeInactive: false) {
                let otherID = rel.fromEntityID == entity.id ? rel.toEntityID : rel.fromEntityID
                guard let other = try await store.entity(otherID), usable(other.status), other.status != .contradicted, inScope(other.scope) else { continue }
                let from = rel.fromEntityID == entity.id ? entity : other
                let to = rel.fromEntityID == entity.id ? other : entity
                let key = "r:\(rel.id)"
                let value = score * 0.5 * (rel.status == .asserted ? 1 : 0.8)
                if value > (fused[key] ?? 0) {
                    fused[key] = value
                    items[key] = .relation(rel, from: from, to: to)
                    reasons[key] = "related to \(entity.name)"
                }
            }
        }

        // Before the passage index exists, earlier messages stand in for it.
        if includeMessages, !passagesIndexed {
            let messages = try await store.searchMessages(text: text, agentID: nil, limit: 8)
            rank(messages.map { (key: "m:\($0.id)", item: .message($0)) }, reason: "earlier conversation", weight: 0.8)
        }

        // Scores on a readable scale: top of one list is about 0.5, top of both about 1.
        return fused.sorted { $0.value > $1.value }.prefix(query.limit).compactMap { key, value in
            items[key].map { MemoryHit(item: $0, score: value * Double(Self.fusionK) / 2, reason: reasons[key] ?? "") }
        }
    }

    static let fusionK = 60
    static let candidates = 40
    static let minimumSimilarity = 0.35

    /// Asserted over inferred, and a small lift for what was confirmed recently, so newer facts win ties.
    static func weight(_ item: MemoryHit.Item, now: Date = Date()) -> Double {
        func recency(_ d: Date) -> Double { 1 + 0.15 * exp(-now.timeIntervalSince(d) / (60 * 86400)) }
        switch item {
        case .entity(let e):
            let status: Double
            switch e.status {
            case .asserted: status = 1
            case .inferred: status = 0.85
            case .contradicted: status = 0.5
            case .superseded, .forgotten: status = 0.3
            }
            return status * recency(e.observedAt)
        case .preference(let p): return 1.1 * recency(p.updatedAt)
        case .relation: return 1
        case .message(let m): return recency(m.createdAt)
        case .passage(let p): return 0.9 * recency(p.at)
        }
    }

    /// Render hits for the model as numbered sources, so it can tell them apart and let newer win over older.
    public static func render(_ hits: [MemoryHit], maxChars: Int = 6000) -> String {
        var out = ""
        for (i, hit) in hits.enumerated() {
            var line = "[\(i + 1)] "
            switch hit.item {
            case .entity(let e):
                line += "\(e.kind.rawValue) \"\(e.name)\" (\(e.status.rawValue), confirmed \(Self.shortDate(e.observedAt)))"
                if !e.summary.isEmpty { line += ": \(e.summary)" }
                if case .object(let attrs) = e.attributes, !attrs.isEmpty {
                    line += " {" + attrs.sorted { $0.key < $1.key }.prefix(8).map { "\($0.key)=\($0.value.stringValue ?? $0.value.compactText)" }.joined(separator: ", ") + "}"
                }
                line += " id \(e.id.rawValue.prefix(8))"
            case .relation(let r, let from, let to):
                line += "\(from.name) —\(r.relation)→ \(to.name) (\(r.status.rawValue))"
            case .preference(let p):
                line += "instruction (\(Self.shortDate(p.updatedAt))): \"\(p.text)\""
            case .message(let m):
                line += "earlier message (\(Self.shortDate(m.createdAt)), \(m.role.rawValue)): \(m.text.prefix(300).replacingOccurrences(of: "\n", with: " "))"
            case .passage(let p):
                let text = p.text.count > 700 ? String(p.text.prefix(700)) + "…" : p.text
                line += "\(p.sourceKind) \"\(p.title)\" (\(Self.shortDate(p.at))):\n    " + text.replacingOccurrences(of: "\n", with: "\n    ")
            }
            if out.count + line.count > maxChars { break }
            out += line + "\n"
        }
        return out
    }

    static func shortDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    // MARK: Passages (what was said)

    /// Indexes conversations as passages: each changed conversation's messages (people and agents, not tool
    /// output) and report cards are cut into ~140-word pieces, keyword-indexed and embedded; conversations that
    /// are gone are dropped. Unchanged conversations are skipped. Returns how many were (re)indexed.
    @discardableResult
    public func syncPassages() async -> Int {
        guard let evidence else { return 0 }
        do {
            var known = try await evidence.sourceSignatures()
            var indexed = 0
            for agent in try await store.listAgents(includeRetired: true) {
                for conversation in try await store.listConversations(agentID: agent.id) {
                    let id = "conversation:\(conversation.id.rawValue)"
                    let signature = String(format: "%.3f", conversation.updatedAt.timeIntervalSince1970)
                    defer { known[id] = nil }
                    guard known[id] != signature else { continue }
                    let messages = try await store.messagesAfter(conversationID: conversation.id, after: nil, limit: 5000)
                    let passages = Self.passages(conversation: conversation, agent: agent, messages: messages)
                    let title = conversation.title.isEmpty ? (conversation.preview.isEmpty ? "Conversation with \(agent.name)" : conversation.preview) : conversation.title
                    try await evidence.replaceSource(id: id, kind: "conversation", conversationID: conversation.id, agentID: agent.id, title: title,
                                                     updatedAt: conversation.updatedAt, signature: signature, passages: passages)
                    await embedPassages(passages)
                    indexed += 1
                }
            }
            // Whatever is left in `known` no longer exists.
            for gone in known.keys { try await evidence.deleteSource(gone) }
            if indexed > 0 { log.info("Indexed \(indexed) conversation(s) as memory passages", category: "memory") }
            return indexed
        } catch {
            log.warn("Passage indexing stopped: \(error)", category: "memory")
            return 0
        }
    }

    /// A conversation's passages. Short acknowledgements and an agent's running commentary between tool calls
    /// are left out; report cards count, as their own lines.
    static func passages(conversation: Conversation, agent: AgentProfile, messages: [Message]) -> [MemoryPassage] {
        var blocks: [MemoryChunker.Block] = []
        for m in messages where !m.isStreaming && (m.role == .user || m.role == .assistant) {
            let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = MemoryChunker.wordCount(text)
            let speaker = m.role == .user ? (m.author?.name ?? "User") : agent.name
            if m.role == .user ? words >= 2 : words >= 12 {
                blocks.append(.init(speaker: speaker, text: text, at: m.createdAt, messageID: m.id))
            }
            for case .report(let r) in m.parts {
                blocks.append(.init(speaker: "\(agent.name) (report \"\(r.title)\")", text: r.markdown, at: m.createdAt, messageID: m.id))
            }
        }
        let title = conversation.title.isEmpty ? conversation.preview : conversation.title
        return MemoryChunker.chunks(blocks).enumerated().map { i, c in
            MemoryPassage(id: "conversation:\(conversation.id.rawValue)#\(i)", sourceKind: "conversation", title: title, text: c.text,
                          speaker: c.speaker, at: c.at, conversationID: conversation.id, agentID: agent.id, messageID: c.messageID)
        }
    }

    private func embedPassages(_ passages: [MemoryPassage]) async {
        guard let embeddings, !passages.isEmpty else { return }
        do {
            for start in stride(from: 0, to: passages.count, by: 48) {
                let batch = Array(passages[start ..< min(start + 48, passages.count)])
                let vectors = try await embeddings.embed(batch.map { documentPrompt(title: $0.title, text: $0.text) })
                for (p, v) in zip(batch, vectors) { try await store.putEmbedding(kind: "chunk", itemID: p.id, vector: v) }
            }
        } catch {
            log.warn("Passage embedding failed: \(error)", category: "memory")
        }
    }

    /// The passages that mention a fact (by its name or old names), newest first: the evidence behind it.
    public func evidence(for id: MemoryEntityID, limit: Int = 8) async throws -> [MemoryPassage] {
        guard let evidence, let e = try await store.entity(id) else { return [] }
        let aliases = try await evidence.aliases(of: e.name)
        return try await evidence.passagesMentioning([e.name] + aliases, limit: limit)
    }

    // MARK: Corrections

    /// Renames a fact. The old name becomes an alias, so agents writing it later update this fact; renaming onto
    /// the name of another current fact of the same kind merges the two.
    public func rename(_ id: MemoryEntityID, to newName: String) async throws -> MemoryEntity {
        guard let current = try await store.entity(id) else { throw ToolError.failed("Entity not found") }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != current.name else { return current }
        if let other = try await store.findEntities(name: name, kind: current.kind, scopes: []).first(where: { $0.id != id && ($0.status == .asserted || $0.status == .inferred) }) {
            return try await merge(id, into: other.id)
        }
        var renamed = current
        renamed.name = name
        let next = try await editEntity(renamed)
        try await evidence?.setAlias(Self.normalize(current.name), name: name)
        for old in (try await evidence?.aliases(of: current.name)) ?? [] { try await evidence?.setAlias(old, name: name) }
        return next
    }

    /// Folds one fact into another: its relations move over, attributes it had that the other lacks are kept,
    /// and its name (and old names) become aliases of the other.
    public func merge(_ fromID: MemoryEntityID, into intoID: MemoryEntityID) async throws -> MemoryEntity {
        guard fromID != intoID, let from = try await store.entity(fromID), var into = try await store.entity(intoID) else { throw ToolError.failed("Entity not found") }
        let existing = try await store.relations(entityID: into.id, includeInactive: false)
        for rel in try await store.relations(entityID: from.id, includeInactive: false) {
            var moved = rel
            if moved.fromEntityID == from.id { moved.fromEntityID = into.id }
            if moved.toEntityID == from.id { moved.toEntityID = into.id }
            let duplicate = moved.fromEntityID == moved.toEntityID || existing.contains { $0.fromEntityID == moved.fromEntityID && $0.toEntityID == moved.toEntityID && $0.relation == moved.relation }
            if duplicate { try await store.forgetRelation(rel.id) } else { try await store.upsertRelation(moved) }
        }
        if case .object(let fromAttrs) = from.attributes, case .object(var attrs) = into.attributes {
            for (k, v) in fromAttrs where attrs[k] == nil { attrs[k] = v }
            into.attributes = .object(attrs)
        }
        if into.summary.isEmpty { into.summary = from.summary }
        into.observedAt = max(into.observedAt, from.observedAt)
        into.updatedAt = Date()
        try await store.upsertEntity(into)
        var old = from
        old.status = .superseded
        old.supersededBy = into.id
        old.updatedAt = Date()
        try await store.upsertEntity(old)
        try await evidence?.setAlias(Self.normalize(from.name), name: into.name)
        for alias in (try await evidence?.aliases(of: from.name)) ?? [] { try await evidence?.setAlias(alias, name: into.name) }
        await indexEmbedding(kind: "entity", id: into.id.rawValue, title: into.name, text: Self.entityText(into))
        _ = try await publish(.memoryEntityUpserted(old))
        _ = try await publish(.memoryEntityUpserted(into))
        return into
    }

    /// Contradictions waiting to be settled: each claim that conflicts with the current fact of the same name.
    public func conflicts() async throws -> [MemoryConflict] {
        let all = try await store.listEntities(kind: nil, scope: nil, includeInactive: false, limit: 100_000)
        return all.filter { $0.status == .contradicted }.compactMap { claim in
            guard let current = all.first(where: { $0.id != claim.id && $0.kind == claim.kind && $0.name.caseInsensitiveCompare(claim.name) == .orderedSame && $0.status == .asserted }) else { return nil }
            return MemoryConflict(current: current, claim: claim)
        }
    }

    /// Settles a contradiction: the kept version becomes the asserted fact, the other is superseded by it.
    public func resolve(keep keepID: MemoryEntityID, drop dropID: MemoryEntityID) async throws -> MemoryEntity {
        guard var keep = try await store.entity(keepID), var drop = try await store.entity(dropID) else { throw ToolError.failed("Entity not found") }
        keep.status = .asserted
        keep.observedAt = Date()
        keep.updatedAt = Date()
        keep.provenance = Provenance(sourceType: .userEdit, sourceID: keep.id.rawValue, note: "Kept when settling a contradiction")
        drop.status = .superseded
        drop.supersededBy = keep.id
        drop.updatedAt = Date()
        try await store.upsertEntity(keep)
        try await store.upsertEntity(drop)
        _ = try await publish(.memoryEntityUpserted(drop))
        _ = try await publish(.memoryEntityUpserted(keep))
        return keep
    }

    public func ignoredNames() async throws -> [IgnoredMemoryName] { try await evidence?.ignoredNames() ?? [] }

    /// Lets agents remember a removed name again.
    public func restore(_ name: String, kind: MemoryEntityKind) async throws {
        try await evidence?.unignore(normalized: Self.normalize(name), kind: kind)
    }

    /// Counts for the Memory view: passages, and how much of memory meaning search covers.
    public func indexCounts() async -> (passages: Int, embedded: Int, embeddable: Int, needsReview: Int) {
        let passages = (try? await evidence?.passageCount()) ?? 0
        let entities = (try? await store.listEntities(kind: nil, scope: nil, includeInactive: false, limit: 100_000)) ?? []
        let prefs = (try? await store.listPreferences(scopes: nil, includeInactive: false)) ?? []
        var embedded = 0
        if embeddings != nil {
            for kind in ["entity", "preference", "chunk"] { embedded += ((try? await store.embeddedItemIDs(kind: kind)) ?? []).count }
        }
        let review = ((try? await conflicts()) ?? []).count
        return (passages, embedded, embeddings == nil ? 0 : entities.count + prefs.count + passages, review)
    }

    // MARK: Helpers

    private func indexEmbedding(kind: String, id: String, title: String, text: String) async {
        guard let embeddings else { return }
        do {
            if let v = try await embeddings.embed([documentPrompt(title: title, text: text)]).first { try await store.putEmbedding(kind: kind, itemID: id, vector: v) }
        } catch {
            log.warn("Embedding failed: \(error)", category: "memory")
        }
    }

    /// EmbeddingGemma is trained with task prompts: documents as "title: … | text: …", searches as
    /// "task: search result | query: …". Other models get the plain text.
    private var usesTaskPrompts: Bool { embeddings?.modelName.lowercased().contains("gemma") == true }

    func documentPrompt(title: String, text: String) -> String {
        usesTaskPrompts ? "title: \(title.isEmpty ? "none" : title) | text: \(text)" : [title, text].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func queryPrompt(_ query: String) -> String {
        usesTaskPrompts ? "task: search result | query: \(query)" : query
    }

    static func entityText(_ e: MemoryEntity) -> String {
        [e.summary, e.attributes.compactText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Gives every current memory a vector: after meaning search is turned on, for memories saved before, and after
    /// the embedding model changes (vectors from different models don't compare, so the old ones are dropped).
    public func backfillEmbeddings() async {
        guard let embeddings else { return }
        let model = embeddings.modelName
        do {
            if let recorded = try await store.setting("embedding_model"), recorded != model {
                try await store.clearEmbeddings()
                log.info("Embedding model changed from \(recorded) to \(model); re-embedding memory", category: "memory")
            }
            try await store.setSetting("embedding_model", value: model)
            let haveEntities = try await store.embeddedItemIDs(kind: "entity")
            let entities = try await store.listEntities(kind: nil, scope: nil, includeInactive: false, limit: 100_000).filter { !haveEntities.contains($0.id.rawValue) }
            let havePrefs = try await store.embeddedItemIDs(kind: "preference")
            let prefs = try await store.listPreferences(scopes: nil, includeInactive: false).filter { !havePrefs.contains($0.id.rawValue) }
            var done = 0
            for batch in stride(from: 0, to: entities.count, by: 48).map({ Array(entities[$0 ..< min($0 + 48, entities.count)]) }) {
                let vectors = try await embeddings.embed(batch.map { documentPrompt(title: $0.name, text: Self.entityText($0)) })
                for (e, v) in zip(batch, vectors) { try await store.putEmbedding(kind: "entity", itemID: e.id.rawValue, vector: v) }
                done += batch.count
            }
            for batch in stride(from: 0, to: prefs.count, by: 48).map({ Array(prefs[$0 ..< min($0 + 48, prefs.count)]) }) {
                let vectors = try await embeddings.embed(batch.map { documentPrompt(title: "instruction", text: $0.text) })
                for (p, v) in zip(batch, vectors) { try await store.putEmbedding(kind: "preference", itemID: p.id.rawValue, vector: v) }
                done += batch.count
            }
            if let evidence {
                let haveChunks = try await store.embeddedItemIDs(kind: "chunk")
                var missing: [MemoryPassage] = []
                for id in try await evidence.passageIDs() where !haveChunks.contains(id) {
                    if let p = try await evidence.passage(id) { missing.append(p) }
                }
                await embedPassages(missing)
                done += missing.count
            }
            if done > 0 { log.info("Embedded \(done) memories for meaning search (\(model))", category: "memory") }
        } catch {
            log.warn("Embedding backfill stopped: \(error)", category: "memory")
        }
    }

    @discardableResult
    func publish(_ payload: EventPayload) async throws -> HostEvent {
        let event = try await store.appendEvent(payload)
        await eventBus.publish(event)
        return event
    }
}

enum Similarity {
    static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }
    static func jaccard(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
    }
}
