import PennantCore
import Foundation

/// Contract for the host's SQLite-backed source of truth. Implemented by `SQLiteStore`.
/// All methods are safe to call concurrently; the implementation serialises access.
public protocol StoreProtocol: Sendable {
    /// Removes messages (a reply the runtime replaced).
    func deleteMessages(_ ids: [MessageID]) async throws
    // MARK: Event log
    /// Persist a durable event, assign the next sequence, and return it. Transient payloads are not stored.
    func appendEvent(_ payload: EventPayload) async throws -> HostEvent
    func events(afterSeq: EventSeq, limit: Int) async throws -> [HostEvent]
    func latestEventSeq() async throws -> EventSeq

    // MARK: Agents
    func upsertAgent(_ agent: AgentProfile) async throws
    func deleteConversations(_ ids: [ConversationID]) async throws
    func agent(_ id: AgentID) async throws -> AgentProfile?
    func listAgents(includeRetired: Bool) async throws -> [AgentProfile]

    // MARK: Conversations and messages
    func upsertConversation(_ conversation: Conversation) async throws
    func conversation(_ id: ConversationID) async throws -> Conversation?
    /// Reads, changes and writes a conversation as one step, so two changes at once (a task finishing, its thread
    /// being closed) can't overwrite each other. Nil when there's no such conversation.
    func mutateConversation(_ id: ConversationID, _ change: @Sendable (inout Conversation) -> Void) async throws -> Conversation?
    func listConversations(agentID: AgentID) async throws -> [Conversation]
    func appendMessage(_ message: Message) async throws
    func updateMessage(_ message: Message) async throws
    func message(_ id: MessageID) async throws -> Message?
    /// Newest-first page of messages. `before` excludes that message and anything newer.
    func listMessages(conversationID: ConversationID, before: MessageID?, limit: Int) async throws -> [Message]
    /// Oldest-first messages after a given message (exclusive). Nil returns from the start.
    func messagesAfter(conversationID: ConversationID, after: MessageID?, limit: Int) async throws -> [Message]
    func searchMessages(text: String, agentID: AgentID?, limit: Int) async throws -> [Message]

    // MARK: Tasks
    func upsertTask(_ task: TaskRecord) async throws
    func task(_ id: TaskID) async throws -> TaskRecord?
    func listTasks(agentID: AgentID?, includeFinished: Bool) async throws -> [TaskRecord]
    func recordTransition(_ transition: TaskTransition) async throws
    func childTasks(parentTaskID: TaskID) async throws -> [TaskRecord]

    // MARK: Tool records
    func upsertToolRecord(_ record: ToolRecord) async throws
    func toolRecords(taskID: TaskID) async throws -> [ToolRecord]

    // MARK: Checkpoints
    func saveCheckpoint(_ checkpoint: Checkpoint) async throws
    func latestCheckpoint(conversationID: ConversationID) async throws -> Checkpoint?

    // MARK: Artifacts
    func putArtifact(_ record: ArtifactRecord, data: Data) async throws
    func artifactData(_ id: ArtifactID) async throws -> Data?

    // MARK: Memory: entities, relations, preferences
    func upsertEntity(_ entity: MemoryEntity) async throws
    func entity(_ id: MemoryEntityID) async throws -> MemoryEntity?
    func findEntities(name: String, kind: MemoryEntityKind?, scopes: [String]) async throws -> [MemoryEntity]
    func listEntities(kind: MemoryEntityKind?, scope: String?, includeInactive: Bool, limit: Int) async throws -> [MemoryEntity]
    func upsertRelation(_ relation: MemoryRelation) async throws
    func relations(entityID: MemoryEntityID, includeInactive: Bool) async throws -> [MemoryRelation]
    func upsertPreference(_ preference: Preference) async throws
    func preference(_ id: PreferenceID) async throws -> Preference?
    func listPreferences(scopes: [String]?, includeInactive: Bool) async throws -> [Preference]
    /// Full-text search over entities (name, summary, attributes). Returns entity and bm25 rank (lower is better).
    func searchEntities(text: String, scopes: [String], includeInactive: Bool, limit: Int) async throws -> [(MemoryEntity, Double)]
    func searchPreferences(text: String, scopes: [String], limit: Int) async throws -> [(Preference, Double)]
    /// Forget: clears content, sets status to forgotten, and removes the item from FTS indexes.
    func forgetEntity(_ id: MemoryEntityID) async throws
    func forgetRelation(_ id: MemoryRelationID) async throws
    func forgetPreference(_ id: PreferenceID) async throws

    // MARK: Embeddings (optional semantic retrieval)
    func putEmbedding(kind: String, itemID: String, vector: [Float]) async throws
    func nearestEmbeddings(kind: String, vector: [Float], limit: Int) async throws -> [(itemID: String, similarity: Double)]
    /// Items of a kind that already have a vector (for backfilling the rest).
    func embeddedItemIDs(kind: String) async throws -> Set<String>
    /// Drops every vector (the embedding model changed, so old vectors don't compare with new ones).
    func clearEmbeddings() async throws

    // MARK: Skills
    func upsertSkill(_ skill: Skill) async throws
    func skill(_ id: SkillID) async throws -> Skill?
    func listSkills(includeDisabled: Bool) async throws -> [Skill]
    func searchSkills(text: String, limit: Int) async throws -> [Skill]

    // MARK: Scheduled jobs
    func upsertSchedule(_ job: ScheduledJob) async throws
    func schedule(_ id: ScheduleID) async throws -> ScheduledJob?
    func listSchedules() async throws -> [ScheduledJob]
    func deleteSchedule(_ id: ScheduleID) async throws
    /// Enabled jobs whose next run is at or before `date`.
    func dueSchedules(before date: Date) async throws -> [ScheduledJob]

    // MARK: MCP
    func upsertMCPServer(_ config: MCPServerConfig) async throws
    func listMCPServers() async throws -> [MCPServerConfig]
    func removeMCPServer(_ id: MCPServerID) async throws

    // MARK: Usage ledger
    func appendUsage(_ record: UsageRecord) async throws

    // MARK: Key-value settings (pairing tokens live in Keychain, not here)
    func setSetting(_ key: String, value: String) async throws
    func setting(_ key: String) async throws -> String?

}

public extension StoreProtocol {
    /// Stores that keep no messages (test doubles) have nothing to remove.
    func deleteMessages(_ ids: [MessageID]) async throws {}
}
