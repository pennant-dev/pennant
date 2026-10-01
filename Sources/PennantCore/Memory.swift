import Foundation

/// Where a memory came from. Every fact and relationship keeps this.
public struct Provenance: Hashable, Codable, Sendable {
    public enum SourceType: String, Codable, Sendable {
        case userMessage
        case assistantMessage
        case toolObservation
        case inference
        case userEdit
        case importedData = "import"
        case skillRun
    }
    public var sourceType: SourceType
    /// Message, tool record, or artifact ID the claim came from.
    public var sourceID: String?
    public var eventSeq: EventSeq?
    public var agentID: AgentID?
    public var note: String

    public init(sourceType: SourceType, sourceID: String? = nil, eventSeq: EventSeq? = nil, agentID: AgentID? = nil, note: String = "") {
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.eventSeq = eventSeq
        self.agentID = agentID
        self.note = note
    }
}

public enum MemoryStatus: String, Codable, Sendable, CaseIterable {
    /// Stated by the user or read directly from a source.
    case asserted
    /// Derived by the model. Never silently replaces an asserted claim.
    case inferred
    /// A newer claim conflicts with it; both are kept until resolved.
    case contradicted
    /// Replaced by a newer version (see supersededBy).
    case superseded
    /// Forgotten on request. Content is removed; the tombstone remains for index consistency.
    case forgotten
}

public enum MemoryEntityKind: String, Codable, Sendable, CaseIterable {
    case person, project, document, application, deadline, place, organization, account, device, topic, fact, other
}

/// A node in the memory graph.
public struct MemoryEntity: Hashable, Codable, Sendable, Identifiable {
    public var id: MemoryEntityID
    public var kind: MemoryEntityKind
    public var name: String
    /// Free-form attributes such as email, path, due date, amount.
    public var attributes: JSONValue
    public var summary: String
    public var scope: String
    public var status: MemoryStatus
    public var provenance: Provenance
    public var observedAt: Date
    public var createdAt: Date
    public var updatedAt: Date
    public var supersededBy: MemoryEntityID?
    public var version: Int

    public init(id: MemoryEntityID = MemoryEntityID(), kind: MemoryEntityKind, name: String, attributes: JSONValue = .object([:]), summary: String = "", scope: String = "shared", status: MemoryStatus = .asserted, provenance: Provenance, observedAt: Date = Date(), createdAt: Date = Date(), updatedAt: Date = Date(), supersededBy: MemoryEntityID? = nil, version: Int = 1) {
        self.id = id
        self.kind = kind
        self.name = name
        self.attributes = attributes
        self.summary = summary
        self.scope = scope
        self.status = status
        self.provenance = provenance
        self.observedAt = observedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.supersededBy = supersededBy
        self.version = version
    }
}

/// An edge in the memory graph, e.g. `Invoice 042 -belongs_to-> Project Atlas`.
public struct MemoryRelation: Hashable, Codable, Sendable, Identifiable {
    public var id: MemoryRelationID
    public var fromEntityID: MemoryEntityID
    public var relation: String
    public var toEntityID: MemoryEntityID
    public var scope: String
    public var status: MemoryStatus
    public var provenance: Provenance
    public var observedAt: Date
    public var createdAt: Date
    public var supersededBy: MemoryRelationID?

    public init(id: MemoryRelationID = MemoryRelationID(), fromEntityID: MemoryEntityID, relation: String, toEntityID: MemoryEntityID, scope: String = "shared", status: MemoryStatus = .asserted, provenance: Provenance, observedAt: Date = Date(), createdAt: Date = Date(), supersededBy: MemoryRelationID? = nil) {
        self.id = id
        self.fromEntityID = fromEntityID
        self.relation = relation
        self.toEntityID = toEntityID
        self.scope = scope
        self.status = status
        self.provenance = provenance
        self.observedAt = observedAt
        self.createdAt = createdAt
        self.supersededBy = supersededBy
    }
}

/// An explicit instruction from the user that governs future work.
public struct Preference: Hashable, Codable, Sendable, Identifiable {
    public var id: PreferenceID
    public var text: String
    public var scope: String
    public var status: MemoryStatus
    public var provenance: Provenance
    public var version: Int
    public var previousVersionID: PreferenceID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: PreferenceID = PreferenceID(), text: String, scope: String = "shared", status: MemoryStatus = .asserted, provenance: Provenance, version: Int = 1, previousVersionID: PreferenceID? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.scope = scope
        self.status = status
        self.provenance = provenance
        self.version = version
        self.previousVersionID = previousVersionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A retrieval hit, with the reason it was retrieved so the model and UI can show evidence.
public struct MemoryHit: Hashable, Codable, Sendable {
    public enum Item: Hashable, Codable, Sendable {
        case entity(MemoryEntity)
        case relation(MemoryRelation, from: MemoryEntity, to: MemoryEntity)
        case preference(Preference)
        case message(Message)
        /// What was actually said: a passage from a conversation or a report, as evidence.
        case passage(MemoryPassage)
    }
    public var item: Item
    public var score: Double
    public var reason: String

    public init(item: Item, score: Double, reason: String) {
        self.item = item
        self.score = score
        self.reason = reason
    }
}

/// A passage of what was actually said (a conversation's messages, a report), indexed in ~140-word pieces so
/// memory can cite the words behind a fact instead of only a one-line summary.
public struct MemoryPassage: Hashable, Codable, Sendable, Identifiable {
    /// "<source>#<ordinal>".
    public var id: String
    /// "conversation" or "report".
    public var sourceKind: String
    public var title: String
    public var text: String
    /// Who said it first in the passage.
    public var speaker: String
    public var at: Date
    public var conversationID: ConversationID?
    public var agentID: AgentID?
    /// Where the passage starts, to open it.
    public var messageID: MessageID?

    public init(id: String, sourceKind: String, title: String, text: String, speaker: String, at: Date,
                conversationID: ConversationID? = nil, agentID: AgentID? = nil, messageID: MessageID? = nil) {
        self.id = id; self.sourceKind = sourceKind; self.title = title; self.text = text; self.speaker = speaker; self.at = at
        self.conversationID = conversationID; self.agentID = agentID; self.messageID = messageID
    }
}

/// A claim that conflicts with the current fact of the same name, waiting for someone to pick one.
public struct MemoryConflict: Hashable, Codable, Sendable, Identifiable {
    public var current: MemoryEntity
    public var claim: MemoryEntity
    public var id: String { claim.id.rawValue }
    public init(current: MemoryEntity, claim: MemoryEntity) { self.current = current; self.claim = claim }
}

/// A decision Pennant made to keep memory current (instead of asking the owner to review it), with what to put back
/// if the owner disagrees.
public struct MemoryUpkeepEntry: Hashable, Codable, Sendable, Identifiable {
    public enum Action: String, Codable, Sendable {
        /// The fact on record stood; a newer claim was set aside.
        case kept
        /// A newer claim replaced the fact on record.
        case updated
        /// The record and the claim were combined into one.
        case combined
    }
    public var id: String
    public var at: Date
    public var action: Action
    public var name: String
    /// One sentence, for the owner.
    public var reason: String
    /// What memory holds now.
    public var keptID: MemoryEntityID
    /// What was set aside; undoing brings it back.
    public var droppedID: MemoryEntityID
    public var undone: Bool

    public init(id: String = UUID().uuidString, at: Date = Date(), action: Action, name: String, reason: String, keptID: MemoryEntityID, droppedID: MemoryEntityID, undone: Bool = false) {
        self.id = id; self.at = at; self.action = action; self.name = name; self.reason = reason; self.keptID = keptID; self.droppedID = droppedID; self.undone = undone
    }
}

/// A name the user removed from memory: agents won't remember it again until it is restored.
public struct IgnoredMemoryName: Hashable, Codable, Sendable, Identifiable {
    public var name: String
    public var kind: MemoryEntityKind
    public var ignoredAt: Date
    public var id: String { "\(kind.rawValue):\(name)" }
    public init(name: String, kind: MemoryEntityKind, ignoredAt: Date = Date()) { self.name = name; self.kind = kind; self.ignoredAt = ignoredAt }
}

/// Summary counts for the Memory view.
public struct MemoryOverview: Hashable, Codable, Sendable {
    public var entityCount: Int
    public var relationCount: Int
    public var preferenceCount: Int
    public var messageCount: Int
    public var skillCount: Int
    public var databaseBytes: Int
    /// Passages indexed from conversations and reports.
    public var passageCount: Int
    /// Facts, instructions and passages that have a vector for meaning search.
    public var embeddedCount: Int
    public var embeddableCount: Int
    /// Contradicted facts waiting for someone to settle them.
    public var needsReviewCount: Int

    public init(entityCount: Int = 0, relationCount: Int = 0, preferenceCount: Int = 0, messageCount: Int = 0, skillCount: Int = 0, databaseBytes: Int = 0,
                passageCount: Int = 0, embeddedCount: Int = 0, embeddableCount: Int = 0, needsReviewCount: Int = 0) {
        self.entityCount = entityCount
        self.relationCount = relationCount
        self.preferenceCount = preferenceCount
        self.messageCount = messageCount
        self.skillCount = skillCount
        self.databaseBytes = databaseBytes
        self.passageCount = passageCount
        self.embeddedCount = embeddedCount
        self.embeddableCount = embeddableCount
        self.needsReviewCount = needsReviewCount
    }

    private enum CodingKeys: String, CodingKey { case entityCount, relationCount, preferenceCount, messageCount, skillCount, databaseBytes, passageCount, embeddedCount, embeddableCount, needsReviewCount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ k: CodingKeys) throws -> Int { try c.decodeIfPresent(Int.self, forKey: k) ?? 0 }
        self.init(entityCount: try int(.entityCount), relationCount: try int(.relationCount), preferenceCount: try int(.preferenceCount),
                  messageCount: try int(.messageCount), skillCount: try int(.skillCount), databaseBytes: try int(.databaseBytes),
                  passageCount: try int(.passageCount), embeddedCount: try int(.embeddedCount), embeddableCount: try int(.embeddableCount),
                  needsReviewCount: try int(.needsReviewCount))
    }
}
