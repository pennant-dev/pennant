import Foundation

/// Explicit task states. Every transition is persisted by the host.
public enum TaskState: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case waitingForTool
    case waitingForDesktop
    case waitingForUser
    case paused
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    public var isActive: Bool {
        switch self {
        case .running, .waitingForTool, .waitingForDesktop: return true
        default: return false
        }
    }

    /// Legal transitions of the task state machine.
    public func canTransition(to next: TaskState) -> Bool {
        if self == next { return false }
        switch self {
        case .queued:
            return [.running, .cancelled, .failed, .paused].contains(next)
        case .running:
            return [.waitingForTool, .waitingForDesktop, .waitingForUser, .paused, .queued, .completed, .failed, .cancelled].contains(next)
        case .waitingForTool, .waitingForDesktop:
            return [.running, .paused, .queued, .failed, .cancelled, .waitingForUser].contains(next)
        case .waitingForUser:
            return [.running, .queued, .paused, .cancelled, .failed].contains(next)
        case .paused:
            return [.running, .queued, .cancelled, .failed].contains(next)
        case .completed, .failed, .cancelled:
            return false
        }
    }
}

/// Per-task allowance. Reaching a limit pauses the task and asks the user whether to keep going; it never fails it.
/// Zero means no limit for steps, tokens, and duration.
public struct TaskBudget: Hashable, Codable, Sendable {
    public var maxSteps: Int
    public var maxTokens: Int
    public var maxDuration: TimeInterval
    public var maxDelegations: Int

    public init(maxSteps: Int = 200, maxTokens: Int = 5_000_000, maxDuration: TimeInterval = 4 * 3600, maxDelegations: Int = 3) {
        self.maxSteps = maxSteps
        self.maxTokens = maxTokens
        self.maxDuration = maxDuration
        self.maxDelegations = maxDelegations
    }

    /// The allowance shipped before limits paused instead of failed. Configs still carrying it are upgraded on load.
    public static let legacy = TaskBudget(maxSteps: 60, maxTokens: 400_000, maxDuration: 3600, maxDelegations: 3)

    /// The first limit the usage has reached, phrased for the user, or nil while within budget.
    public func exhaustedReason(usage: TaskUsage, now: Date = Date()) -> String? {
        if maxSteps > 0, usage.steps >= maxSteps { return "reached \(maxSteps) steps" }
        if maxDuration > 0, let worked = usage.activeSeconds(now: now), worked > maxDuration { return "worked for \(TaskBudget.duration(maxDuration))" }
        if maxTokens > 0, usage.newTokens > maxTokens { return "added \(TaskBudget.tokens(maxTokens)) new tokens" }
        return nil
    }

    /// Grants another allowance on top of what was used, so a continued task gets a full budget again.
    public mutating func extend(by allowance: TaskBudget, usage: TaskUsage, now: Date = Date()) {
        if maxSteps > 0 { maxSteps = usage.steps + max(allowance.maxSteps, 1) }
        if maxTokens > 0 { maxTokens = usage.newTokens + max(allowance.maxTokens, 1) }
        if maxDuration > 0, let worked = usage.activeSeconds(now: now) { maxDuration = worked + max(allowance.maxDuration, 60) }
    }

    public static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return n % 1_000_000 == 0 ? "\(n / 1_000_000)M" : String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return "\(n / 1000)k" }
        return "\(n)"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s % 3600 == 0 { return s == 3600 ? "1 hour" : "\(s / 3600) hours" }
        if s % 60 == 0 { return "\(s / 60) minutes" }
        return "\(s) seconds"
    }
}

public struct TaskUsage: Hashable, Codable, Sendable {
    public var steps: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var delegations: Int
    public var compactions: Int
    public var startedAt: Date?
    /// Estimated size of the context sent on the most recent model turn (or after the latest compaction).
    public var lastContextTokens: Int
    /// The model's context window at that time, so clients can show a fraction.
    public var contextWindowTokens: Int
    public var lastCompactedAt: Date?
    /// What the task added to the model's work: each turn's growth in input over the turn before (new messages,
    /// tool results, screenshots) plus its output. Re-reading the same conversation every turn doesn't count, so
    /// this is what the per-task token limit measures; `inputTokens` keeps the full total for cost.
    public var newTokens: Int
    /// The input size of the latest model turn, to measure the next turn's growth against.
    public var lastTurnInputTokens: Int
    /// Time spent waiting on a person (an approval, a question) or paused: not the task's own working time.
    public var waitedSeconds: Double = 0
    /// When the current wait began, while the task is waiting on a person or paused.
    public var waitingSince: Date?

    /// How long the task has actually worked: since it started, less the time it waited on a person. This is what
    /// the time limit measures, so an approval that sits for an afternoon doesn't use it up.
    public func activeSeconds(now: Date = Date()) -> TimeInterval? {
        guard let startedAt else { return nil }
        let waitingNow = waitingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return max(0, now.timeIntervalSince(startedAt) - waitedSeconds - waitingNow)
    }

    /// Keeps the waiting clock as the task moves between states.
    public mutating func track(from old: TaskState, to new: TaskState, at: Date) {
        let waiting: Set<TaskState> = [.waitingForUser, .paused]
        if !waiting.contains(old), waiting.contains(new) { waitingSince = at }
        if waiting.contains(old), !waiting.contains(new), let since = waitingSince {
            waitedSeconds += max(0, at.timeIntervalSince(since))
            waitingSince = nil
        }
    }

    /// Counts one model turn.
    public mutating func addTurn(input: Int, output: Int) {
        inputTokens += input
        outputTokens += output
        newTokens += max(0, input - lastTurnInputTokens) + output
        lastTurnInputTokens = input
    }

    public init(steps: Int = 0, inputTokens: Int = 0, outputTokens: Int = 0, delegations: Int = 0, compactions: Int = 0, startedAt: Date? = nil, lastContextTokens: Int = 0, contextWindowTokens: Int = 0, lastCompactedAt: Date? = nil) {
        self.steps = steps
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.delegations = delegations
        self.compactions = compactions
        self.startedAt = startedAt
        self.lastContextTokens = lastContextTokens
        self.contextWindowTokens = contextWindowTokens
        self.lastCompactedAt = lastCompactedAt
        self.newTokens = 0
        self.lastTurnInputTokens = 0
    }

    /// 0...1 fraction of the window in use, when known.
    public var contextFraction: Double? {
        guard contextWindowTokens > 0 else { return nil }
        return min(1, Double(lastContextTokens) / Double(contextWindowTokens))
    }

    private enum CodingKeys: String, CodingKey { case steps, inputTokens, outputTokens, delegations, compactions, startedAt, lastContextTokens, contextWindowTokens, lastCompactedAt, newTokens, lastTurnInputTokens, waitedSeconds, waitingSince }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        delegations = try c.decodeIfPresent(Int.self, forKey: .delegations) ?? 0
        compactions = try c.decodeIfPresent(Int.self, forKey: .compactions) ?? 0
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        lastContextTokens = try c.decodeIfPresent(Int.self, forKey: .lastContextTokens) ?? 0
        contextWindowTokens = try c.decodeIfPresent(Int.self, forKey: .contextWindowTokens) ?? 0
        lastCompactedAt = try c.decodeIfPresent(Date.self, forKey: .lastCompactedAt)
        newTokens = try c.decodeIfPresent(Int.self, forKey: .newTokens) ?? 0
        lastTurnInputTokens = try c.decodeIfPresent(Int.self, forKey: .lastTurnInputTokens) ?? 0
        waitedSeconds = try c.decodeIfPresent(Double.self, forKey: .waitedSeconds) ?? 0
        waitingSince = try c.decodeIfPresent(Date.self, forKey: .waitingSince)
    }
}

/// A unit of delegated or user-requested work owned by one agent.
public struct TaskRecord: Hashable, Codable, Sendable, Identifiable {
    public var id: TaskID
    public var agentID: AgentID
    public var conversationID: ConversationID
    public var parentTaskID: TaskID?
    /// Another agent's task that asked for this one (ask_agent, send_to_agent): who is waiting on it, and whose
    /// person should see its approvals and questions.
    public var requestedByTaskID: TaskID?
    public var title: String
    public var objective: String
    public var completionCriteria: String
    public var dependencies: [TaskID]
    /// Context supplied by the delegating agent, kept separate from the objective.
    public var context: String
    public var budget: TaskBudget
    public var usage: TaskUsage
    public var state: TaskState
    /// Human-readable reason for the current state (why paused, why waiting, what failed).
    public var stateReason: String
    public var resultSummary: String?
    public var artifactIDs: [ArtifactID]
    public var createdAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?

    public init(
        id: TaskID = TaskID(),
        agentID: AgentID,
        conversationID: ConversationID,
        parentTaskID: TaskID? = nil,
        title: String,
        objective: String,
        completionCriteria: String = "",
        dependencies: [TaskID] = [],
        context: String = "",
        budget: TaskBudget = TaskBudget(),
        usage: TaskUsage = TaskUsage(),
        state: TaskState = .queued,
        stateReason: String = "",
        resultSummary: String? = nil,
        artifactIDs: [ArtifactID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.conversationID = conversationID
        self.parentTaskID = parentTaskID
        self.title = title
        self.objective = objective
        self.completionCriteria = completionCriteria
        self.dependencies = dependencies
        self.context = context
        self.budget = budget
        self.usage = usage
        self.state = state
        self.stateReason = stateReason
        self.resultSummary = resultSummary
        self.artifactIDs = artifactIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
    }
}

/// A persisted state change.
public struct TaskTransition: Hashable, Codable, Sendable {
    public var taskID: TaskID
    public var from: TaskState
    public var to: TaskState
    public var reason: String
    public var at: Date

    public init(taskID: TaskID, from: TaskState, to: TaskState, reason: String = "", at: Date = Date()) {
        self.taskID = taskID
        self.from = from
        self.to = to
        self.reason = reason
        self.at = at
    }
}

public enum TaskError: Error, Sendable, Equatable, CustomStringConvertible {
    case illegalTransition(from: TaskState, to: TaskState)
    case notFound(TaskID)
    case budgetExhausted(String)

    public var description: String {
        switch self {
        case .illegalTransition(let f, let t): return "Illegal task transition \(f.rawValue) -> \(t.rawValue)"
        case .notFound(let id): return "Task \(id) not found"
        case .budgetExhausted(let why): return "Task budget exhausted: \(why)"
        }
    }
}
