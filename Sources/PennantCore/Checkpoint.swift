import Foundation

/// Durable task state saved before compaction and at meaningful milestones.
/// Summaries reference original events; they never mark unverified actions as done.
public struct Checkpoint: Hashable, Codable, Sendable, Identifiable {
    public var id: CheckpointID
    public var taskID: TaskID
    /// Checkpoints cover a conversation's history, so later tasks in the same conversation inherit them.
    public var conversationID: ConversationID?
    public var agentID: AgentID
    public var objective: String
    public var governingInstructions: [String]
    public var decisions: [String]
    public var completedWork: [String]
    public var pendingActions: [String]
    public var activeDelegations: [TaskID]
    public var artifactIDs: [ArtifactID]
    public var unresolvedQuestions: [String]
    public var nextStep: String
    /// Concise narrative summary of history up to `throughMessageID`.
    public var historySummary: String
    /// Last message included in the summary. Messages after it stay verbatim in context.
    public var throughMessageID: MessageID?
    public var firstEventSeq: EventSeq?
    public var lastEventSeq: EventSeq?
    /// Tool records that were still unresolved at checkpoint time. They must be reconciled, not assumed.
    public var outstandingToolRecordIDs: [ToolRecordID]
    public var createdAt: Date

    public init(id: CheckpointID = CheckpointID(), taskID: TaskID, conversationID: ConversationID? = nil, agentID: AgentID, objective: String, governingInstructions: [String] = [], decisions: [String] = [], completedWork: [String] = [], pendingActions: [String] = [], activeDelegations: [TaskID] = [], artifactIDs: [ArtifactID] = [], unresolvedQuestions: [String] = [], nextStep: String = "", historySummary: String = "", throughMessageID: MessageID? = nil, firstEventSeq: EventSeq? = nil, lastEventSeq: EventSeq? = nil, outstandingToolRecordIDs: [ToolRecordID] = [], createdAt: Date = Date()) {
        self.id = id
        self.taskID = taskID
        self.conversationID = conversationID
        self.agentID = agentID
        self.objective = objective
        self.governingInstructions = governingInstructions
        self.decisions = decisions
        self.completedWork = completedWork
        self.pendingActions = pendingActions
        self.activeDelegations = activeDelegations
        self.artifactIDs = artifactIDs
        self.unresolvedQuestions = unresolvedQuestions
        self.nextStep = nextStep
        self.historySummary = historySummary
        self.throughMessageID = throughMessageID
        self.firstEventSeq = firstEventSeq
        self.lastEventSeq = lastEventSeq
        self.outstandingToolRecordIDs = outstandingToolRecordIDs
        self.createdAt = createdAt
    }
}
