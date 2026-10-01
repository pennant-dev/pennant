import Foundation

public enum NoticeLevel: String, Codable, Sendable { case info, warning, error }

public struct HostInfo: Hashable, Codable, Sendable {
    public var hostName: String
    public var version: String
    public var startedAt: Date
    public var mode: DeploymentMode
    public var inferenceEndpoint: String
    public var inferenceModel: String
    public var inferenceReachable: Bool
    public var databasePath: String
    public var activeTaskCount: Int
    public var connectedClients: Int
    /// The configured model's context window, in tokens.
    public var contextWindowTokens: Int
    /// "openai" or "chatgpt" (see `HostConfig.Inference.provider`).
    public var inferenceProvider: String
    /// The encrypted port and the SHA-256 fingerprint of the host's certificate (lowercase hex), when it has one.
    public var tlsPort: Int?
    public var tlsFingerprint: String?
    /// Every address this host answers on, best first: its Tailscale name and addresses, then its local network
    /// address. A phone paired on one keeps working on the others (away from home over Tailscale, say).
    public var addresses: [String]?
    /// The build number of the helper bundle the host runs from (nil for a command-line build). The Mac app restarts a
    /// host whose build is not its own: one left running from before an update.
    public var build: String?

    public init(hostName: String, version: String, startedAt: Date, mode: DeploymentMode, inferenceEndpoint: String, inferenceModel: String, inferenceReachable: Bool, databasePath: String, activeTaskCount: Int, connectedClients: Int, contextWindowTokens: Int = 0, inferenceProvider: String = "openai") {
        self.inferenceProvider = inferenceProvider
        self.hostName = hostName
        self.version = version
        self.startedAt = startedAt
        self.mode = mode
        self.inferenceEndpoint = inferenceEndpoint
        self.inferenceModel = inferenceModel
        self.inferenceReachable = inferenceReachable
        self.databasePath = databasePath
        self.activeTaskCount = activeTaskCount
        self.connectedClients = connectedClients
        self.contextWindowTokens = contextWindowTokens
    }

    private enum CodingKeys: String, CodingKey { case hostName, version, startedAt, mode, inferenceEndpoint, inferenceModel, inferenceReachable, databasePath, activeTaskCount, connectedClients, contextWindowTokens, inferenceProvider, tlsPort, tlsFingerprint, addresses, build }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostName = try c.decode(String.self, forKey: .hostName)
        version = try c.decode(String.self, forKey: .version)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        mode = try c.decode(DeploymentMode.self, forKey: .mode)
        inferenceEndpoint = try c.decode(String.self, forKey: .inferenceEndpoint)
        inferenceModel = try c.decode(String.self, forKey: .inferenceModel)
        inferenceReachable = try c.decode(Bool.self, forKey: .inferenceReachable)
        databasePath = try c.decode(String.self, forKey: .databasePath)
        activeTaskCount = try c.decode(Int.self, forKey: .activeTaskCount)
        connectedClients = try c.decode(Int.self, forKey: .connectedClients)
        contextWindowTokens = try c.decodeIfPresent(Int.self, forKey: .contextWindowTokens) ?? 0
        inferenceProvider = try c.decodeIfPresent(String.self, forKey: .inferenceProvider) ?? "openai"
        tlsPort = try c.decodeIfPresent(Int.self, forKey: .tlsPort)
        tlsFingerprint = try c.decodeIfPresent(String.self, forKey: .tlsFingerprint)
        addresses = try c.decodeIfPresent([String].self, forKey: .addresses)
        build = try c.decodeIfPresent(String.self, forKey: .build)
    }
}

public enum DeploymentMode: String, Codable, Sendable, CaseIterable {
    /// The agent shares the desktop the user works on.
    case everyday
    /// The host runs on a separate Mac operated through clients.
    case dedicated
}

/// Streaming delta for an in-progress assistant message.
public struct MessageDelta: Hashable, Codable, Sendable {
    public var messageID: MessageID
    public var conversationID: ConversationID
    public var agentID: AgentID
    public var textDelta: String?
    public var reasoningDelta: String?
    /// A tool call that just became complete in the streamed message.
    public var toolCall: ToolCall?

    public init(messageID: MessageID, conversationID: ConversationID, agentID: AgentID, textDelta: String? = nil, reasoningDelta: String? = nil, toolCall: ToolCall? = nil) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.agentID = agentID
        self.textDelta = textDelta
        self.reasoningDelta = reasoningDelta
        self.toolCall = toolCall
    }
}

/// Something that happened on the host. Persisted with a monotonic sequence so clients can replay.
public struct HostEvent: Hashable, Codable, Sendable, Identifiable {
    public var seq: EventSeq
    public var at: Date
    public var payload: EventPayload

    public var id: EventSeq { seq }

    public init(seq: EventSeq, at: Date = Date(), payload: EventPayload) {
        self.seq = seq
        self.at = at
        self.payload = payload
    }
}

public enum EventPayload: Hashable, Codable, Sendable {
    case hostStatus(HostInfo)
    case agentUpserted(AgentProfile)
    case agentRemoved(AgentID)
    case conversationUpserted(Conversation)
    /// Conversations deleted for good, with their messages and tasks.
    case conversationsRemoved([ConversationID])
    case messageAppended(Message)
    case messageDelta(MessageDelta)
    case messageFinalized(Message)
    case taskUpserted(TaskRecord)
    case taskTransition(TaskTransition)
    case toolRecordUpserted(ToolRecord)
    case checkpointSaved(Checkpoint)
    case desktopStatus(DesktopStatus)
    case memoryEntityUpserted(MemoryEntity)
    case memoryRelationUpserted(MemoryRelation)
    case preferenceUpserted(Preference)
    case memoryForgotten(kind: String, id: String)
    case skillUpserted(Skill)
    case skillRemoved(SkillID)
    case scheduleUpserted(ScheduledJob)
    case scheduleRemoved(ScheduleID)
    /// Messages taken back (a reply the runtime replaced with a better one).
    case messagesRemoved(conversationID: ConversationID, ids: [MessageID])
    case goalUpserted(Goal)
    case goalItemUpserted(GoalItem)
    /// A goal deleted, with its board and its jobs.
    case goalRemoved(GoalID)
    case mcpServerStatus(MCPServerStatus)
    case notice(level: NoticeLevel, agentID: AgentID?, text: String)
    /// The teach-mode session changed (a step recorded, stopped, drafted), or ended (`nil`).
    case teachingUpdated(TeachingSession?)

    /// Transient payloads are not written to the durable log: streaming deltas and status snapshots
    /// (the welcome snapshot always carries the current values).
    public var isTransient: Bool {
        switch self {
        case .messageDelta, .hostStatus, .desktopStatus, .teachingUpdated: return true
        default: return false
        }
    }
}
