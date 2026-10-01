import PennantCore
@testable import PennantHostKit
import Foundation

/// Minimal in-memory store for tests. Search is substring-based; embeddings use cosine similarity.
public actor FakeStore: StoreProtocol {
    public var events: [HostEvent] = []
    public var agents: [AgentID: AgentProfile] = [:]
    public var conversations: [ConversationID: Conversation] = [:]
    public var messages: [MessageID: Message] = [:]
    public var tasks: [TaskID: TaskRecord] = [:]
    public var transitionsByTask: [TaskID: [TaskTransition]] = [:]
    public var toolRecords: [ToolRecordID: ToolRecord] = [:]
    public var checkpointsByTask: [TaskID: [Checkpoint]] = [:]
    public var artifacts: [ArtifactID: ArtifactRecord] = [:]
    public var artifactBytes: [ArtifactID: Data] = [:]
    public var entities: [MemoryEntityID: MemoryEntity] = [:]
    public var relationsByID: [MemoryRelationID: MemoryRelation] = [:]
    public var preferences: [PreferenceID: Preference] = [:]
    public var embeddings: [String: [String: [Float]]] = [:]
    public var skills: [SkillID: Skill] = [:]
    public var mcpServers: [MCPServerID: MCPServerConfig] = [:]
    public var settings: [String: String] = [:]

    public init() {}

    // MARK: Events

    public func appendEvent(_ payload: EventPayload) async throws -> HostEvent {
        if payload.isTransient { return HostEvent(seq: 0, payload: payload) }
        let event = HostEvent(seq: EventSeq(events.count + 1), payload: payload)
        events.append(event)
        return event
    }
    public func events(afterSeq: EventSeq, limit: Int) async throws -> [HostEvent] { Array(events.filter { $0.seq > afterSeq }.prefix(limit)) }
    public func latestEventSeq() async throws -> EventSeq { events.last?.seq ?? 0 }

    // MARK: Agents

    public func upsertAgent(_ agent: AgentProfile) async throws { agents[agent.id] = agent }
    public func agent(_ id: AgentID) async throws -> AgentProfile? { agents[id] }
    public func listAgents(includeRetired: Bool) async throws -> [AgentProfile] {
        agents.values.filter { includeRetired || $0.status != .retired }.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Conversations and messages

    public func upsertConversation(_ conversation: Conversation) async throws { conversations[conversation.id] = conversation }
    public func conversation(_ id: ConversationID) async throws -> Conversation? { conversations[id] }
    public func mutateConversation(_ id: ConversationID, _ change: @Sendable (inout Conversation) -> Void) async throws -> Conversation? {
        guard var c = conversations[id] else { return nil }
        change(&c)
        conversations[id] = c
        return c
    }
    public func listConversations(agentID: AgentID) async throws -> [Conversation] {
        conversations.values.filter { $0.agentID == agentID }.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func appendMessage(_ message: Message) async throws {
        messages[message.id] = message
        if var conversation = conversations[message.conversationID], conversation.absorb(message) { conversations[message.conversationID] = conversation }
    }
    public func updateMessage(_ message: Message) async throws { try await appendMessage(message) }
    public func message(_ id: MessageID) async throws -> Message? { messages[id] }
    private func ordered(_ conversationID: ConversationID) -> [Message] {
        messages.values.filter { $0.conversationID == conversationID }.sorted { $0.createdAt < $1.createdAt }
    }
    public func listMessages(conversationID: ConversationID, before: MessageID?, limit: Int) async throws -> [Message] {
        var list = ordered(conversationID)
        if let before, let i = list.firstIndex(where: { $0.id == before }) { list = Array(list[..<i]) }
        return Array(list.suffix(limit).reversed())
    }
    public func messagesAfter(conversationID: ConversationID, after: MessageID?, limit: Int) async throws -> [Message] {
        var list = ordered(conversationID)
        if let after, let i = list.firstIndex(where: { $0.id == after }) { list = Array(list[(i + 1)...]) }
        return Array(list.prefix(limit))
    }
    public func searchMessages(text: String, agentID: AgentID?, limit: Int) async throws -> [Message] {
        let needle = text.lowercased()
        return Array(messages.values.filter { (agentID == nil || $0.agentID == agentID) && $0.text.lowercased().contains(needle) }.prefix(limit))
    }

    // MARK: Tasks

    public func upsertTask(_ task: TaskRecord) async throws { tasks[task.id] = task }
    public func task(_ id: TaskID) async throws -> TaskRecord? { tasks[id] }
    public func listTasks(agentID: AgentID?, includeFinished: Bool) async throws -> [TaskRecord] {
        tasks.values.filter { (agentID == nil || $0.agentID == agentID) && (includeFinished || !$0.state.isTerminal) }.sorted { $0.createdAt < $1.createdAt }
    }
    public func recordTransition(_ transition: TaskTransition) async throws { transitionsByTask[transition.taskID, default: []].append(transition) }
    public func childTasks(parentTaskID: TaskID) async throws -> [TaskRecord] { tasks.values.filter { $0.parentTaskID == parentTaskID } }

    // MARK: Tool records

    public func upsertToolRecord(_ record: ToolRecord) async throws { toolRecords[record.id] = record }
    public func toolRecords(taskID: TaskID) async throws -> [ToolRecord] { toolRecords.values.filter { $0.taskID == taskID }.sorted { $0.startedAt < $1.startedAt } }

    // MARK: Checkpoints

    public func saveCheckpoint(_ checkpoint: Checkpoint) async throws { checkpointsByTask[checkpoint.taskID, default: []].append(checkpoint) }
    public var schedules: [ScheduleID: ScheduledJob] = [:]
    public func upsertSchedule(_ job: ScheduledJob) async throws { schedules[job.id] = job }
    public func schedule(_ id: ScheduleID) async throws -> ScheduledJob? { schedules[id] }
    public func listSchedules() async throws -> [ScheduledJob] { Array(schedules.values) }
    public func deleteSchedule(_ id: ScheduleID) async throws { schedules[id] = nil }
    public func dueSchedules(before date: Date) async throws -> [ScheduledJob] { schedules.values.filter { $0.enabled && ($0.nextRunAt ?? .distantFuture) <= date } }
    public func latestCheckpoint(conversationID: ConversationID) async throws -> Checkpoint? { checkpointsByTask.values.flatMap { $0 }.filter { $0.conversationID == conversationID }.max { $0.createdAt < $1.createdAt } }

    // MARK: Artifacts

    public func putArtifact(_ record: ArtifactRecord, data: Data) async throws { artifacts[record.id] = record; artifactBytes[record.id] = data }
    public func artifact(_ id: ArtifactID) async throws -> ArtifactRecord? { artifacts[id] }
    public func artifactData(_ id: ArtifactID) async throws -> Data? { artifactBytes[id] }

    // MARK: Memory

    public func upsertEntity(_ entity: MemoryEntity) async throws { entities[entity.id] = entity }
    public func entity(_ id: MemoryEntityID) async throws -> MemoryEntity? { entities[id] }
    public func findEntities(name: String, kind: MemoryEntityKind?, scopes: [String]) async throws -> [MemoryEntity] {
        entities.values.filter { $0.name.lowercased() == name.lowercased() && (kind == nil || $0.kind == kind) && (scopes.isEmpty || scopes.contains($0.scope)) && $0.status != .forgotten }
    }
    public func listEntities(kind: MemoryEntityKind?, scope: String?, includeInactive: Bool, limit: Int) async throws -> [MemoryEntity] {
        Array(entities.values.filter { (kind == nil || $0.kind == kind) && (scope == nil || $0.scope == scope) && (includeInactive || [.asserted, .inferred, .contradicted].contains($0.status)) }.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }
    public func upsertRelation(_ relation: MemoryRelation) async throws { relationsByID[relation.id] = relation }
    public func relations(entityID: MemoryEntityID, includeInactive: Bool) async throws -> [MemoryRelation] {
        relationsByID.values.filter { ($0.fromEntityID == entityID || $0.toEntityID == entityID) && (includeInactive || [.asserted, .inferred, .contradicted].contains($0.status)) }
    }
    public func upsertPreference(_ preference: Preference) async throws { preferences[preference.id] = preference }
    public func preference(_ id: PreferenceID) async throws -> Preference? { preferences[id] }
    public func listPreferences(scopes: [String]?, includeInactive: Bool) async throws -> [Preference] {
        preferences.values.filter { (scopes == nil || scopes!.contains($0.scope)) && (includeInactive || [.asserted, .inferred, .contradicted].contains($0.status)) }.sorted { $0.createdAt < $1.createdAt }
    }
    public func searchEntities(text: String, scopes: [String], includeInactive: Bool, limit: Int) async throws -> [(MemoryEntity, Double)] {
        let needle = text.lowercased()
        return Array(entities.values.filter { ($0.name.lowercased().contains(needle) || $0.summary.lowercased().contains(needle)) && (scopes.isEmpty || scopes.contains($0.scope)) && (includeInactive || $0.status != .forgotten) }.prefix(limit).map { ($0, -1.0) })
    }
    public func searchPreferences(text: String, scopes: [String], limit: Int) async throws -> [(Preference, Double)] {
        let needle = text.lowercased()
        return Array(preferences.values.filter { $0.text.lowercased().contains(needle) && (scopes.isEmpty || scopes.contains($0.scope)) && $0.status != .forgotten }.prefix(limit).map { ($0, -1.0) })
    }
    public func forgetEntity(_ id: MemoryEntityID) async throws {
        guard var e = entities[id] else { return }
        e.name = ""; e.summary = ""; e.attributes = .object([:]); e.status = .forgotten; entities[id] = e
    }
    public func forgetRelation(_ id: MemoryRelationID) async throws {
        guard var r = relationsByID[id] else { return }
        r.status = .forgotten; relationsByID[id] = r
    }
    public func forgetPreference(_ id: PreferenceID) async throws {
        guard var p = preferences[id] else { return }
        p.text = ""; p.status = .forgotten; preferences[id] = p
    }

    // MARK: Embeddings

    public func putEmbedding(kind: String, itemID: String, vector: [Float]) async throws { embeddings[kind, default: [:]][itemID] = vector }
    public func embeddedItemIDs(kind: String) async throws -> Set<String> { Set(embeddings[kind].map { Array($0.keys) } ?? []) }
    public func clearEmbeddings() async throws { embeddings = [:] }
    public func nearestEmbeddings(kind: String, vector: [Float], limit: Int) async throws -> [(itemID: String, similarity: Double)] {
        func cosine(_ a: [Float], _ b: [Float]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return 0 }
            var dot = 0.0, na = 0.0, nb = 0.0
            for i in a.indices { dot += Double(a[i] * b[i]); na += Double(a[i] * a[i]); nb += Double(b[i] * b[i]) }
            return na == 0 || nb == 0 ? 0 : dot / (na.squareRoot() * nb.squareRoot())
        }
        return Array((embeddings[kind] ?? [:]).map { (itemID: $0.key, similarity: cosine($0.value, vector)) }.sorted { $0.similarity > $1.similarity }.prefix(limit))
    }

    // MARK: Skills

    public func upsertSkill(_ skill: Skill) async throws { skills[skill.id] = skill }
    public func skill(_ id: SkillID) async throws -> Skill? { skills[id] }
    public func listSkills(includeDisabled: Bool) async throws -> [Skill] { skills.values.filter { includeDisabled || $0.status != .disabled }.sorted { $0.name < $1.name } }
    public func searchSkills(text: String, limit: Int) async throws -> [Skill] {
        let needle = text.lowercased()
        return Array(skills.values.filter { $0.name.lowercased().contains(needle) || $0.purpose.lowercased().contains(needle) }.prefix(limit))
    }

    public func deleteConversations(_ ids: [ConversationID]) async throws {
        let gone = Set(ids)
        conversations = conversations.filter { !gone.contains($0.key) }
    }


    // MARK: MCP

    public func upsertMCPServer(_ config: MCPServerConfig) async throws { mcpServers[config.id] = config }
    public func listMCPServers() async throws -> [MCPServerConfig] { mcpServers.values.sorted { $0.createdAt < $1.createdAt } }
    public func removeMCPServer(_ id: MCPServerID) async throws { mcpServers[id] = nil }

    // MARK: Settings and maintenance

    var usageRecords: [UsageRecord] = []
    public func appendUsage(_ record: UsageRecord) async throws { usageRecords.append(record) }
    public func setSetting(_ key: String, value: String) async throws { settings[key] = value }
    public func setting(_ key: String) async throws -> String? { settings[key] }
}
