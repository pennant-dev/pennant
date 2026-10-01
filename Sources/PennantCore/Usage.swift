import Foundation

/// Prices for a model, in US dollars per million tokens, as the provider bills them. A ChatGPT subscription and
/// local models cost nothing per token; leave prices nil when they are unknown.
public struct ModelPricing: Hashable, Codable, Sendable {
    public var inputPerMillion: Double?
    public var cachedInputPerMillion: Double?
    public var outputPerMillion: Double?
    /// Tokens are included in a subscription (or run locally): cost is zero, tokens are still counted.
    public var included: Bool

    public init(inputPerMillion: Double? = nil, cachedInputPerMillion: Double? = nil, outputPerMillion: Double? = nil, included: Bool = false) {
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.outputPerMillion = outputPerMillion
        self.included = included
    }

    /// Cost in USD, or nil when a needed price is missing.
    public func cost(input: Int, cachedInput: Int, output: Int) -> Double? {
        if included { return 0 }
        guard let i = inputPerMillion, let o = outputPerMillion else { return nil }
        let cachedPrice = cachedInputPerMillion ?? i
        let fresh = max(0, input - cachedInput)
        return (Double(fresh) * i + Double(cachedInput) * cachedPrice + Double(output) * o) / 1_000_000
    }
}

/// One model call, as billed: who made it (agent, task), on which model, how many tokens, what it cost.
public struct UsageRecord: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var at: Date
    public var agentID: AgentID
    public var taskID: TaskID
    public var conversationID: ConversationID?
    public var profileID: String?
    /// The model's name as shown in Pennant (the profile's name, or the model id).
    public var modelLabel: String
    public var provider: String
    public var model: String
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    /// USD at the prices in force when the call was made; nil when the model has no prices set.
    public var cost: Double?
    /// The provider reported no usage, so the counts are Pennant's estimate.
    public var estimated: Bool

    public init(id: String = UUID().uuidString, at: Date = Date(), agentID: AgentID, taskID: TaskID, conversationID: ConversationID?, profileID: String?, modelLabel: String, provider: String, model: String, inputTokens: Int, cachedInputTokens: Int, outputTokens: Int, cost: Double?, estimated: Bool) {
        self.id = id; self.at = at; self.agentID = agentID; self.taskID = taskID; self.conversationID = conversationID
        self.profileID = profileID; self.modelLabel = modelLabel; self.provider = provider; self.model = model
        self.inputTokens = inputTokens; self.cachedInputTokens = cachedInputTokens; self.outputTokens = outputTokens
        self.cost = cost; self.estimated = estimated
    }
}

/// Usage summed per task and model: the rows of the usage dashboard.
public struct UsageRow: Hashable, Codable, Sendable, Identifiable {
    public var id: String { "\(taskID.rawValue)|\(modelLabel)" }
    public var agentID: AgentID
    public var taskID: TaskID
    public var taskTitle: String
    public var modelLabel: String
    public var provider: String
    public var calls: Int
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    /// Sum of the known costs.
    public var cost: Double
    /// Calls whose model had no prices, so `cost` leaves them out.
    public var unpricedCalls: Int
    public var estimatedCalls: Int
    public var first: Date
    public var last: Date
    /// The job the run's spend belongs to: a scheduled job's name, "Coding runs", or the thread's title; a helper's
    /// run counts under the run that started it. Nil from hosts that predate it.
    public var job: String?

    public init(agentID: AgentID, taskID: TaskID, taskTitle: String, modelLabel: String, provider: String, calls: Int, inputTokens: Int, cachedInputTokens: Int, outputTokens: Int, cost: Double, unpricedCalls: Int, estimatedCalls: Int, first: Date, last: Date, job: String? = nil) {
        self.agentID = agentID; self.taskID = taskID; self.taskTitle = taskTitle; self.modelLabel = modelLabel; self.provider = provider
        self.calls = calls; self.inputTokens = inputTokens; self.cachedInputTokens = cachedInputTokens; self.outputTokens = outputTokens
        self.cost = cost; self.unpricedCalls = unpricedCalls; self.estimatedCalls = estimatedCalls; self.first = first; self.last = last
        self.job = job
    }
}

/// Where an export went and what it holds.
public struct PennantExportResult: Hashable, Codable, Sendable {
    public var path: String
    public var bytes: Int
    /// Secrets sealed inside (vault entries and connector sign-ins); 0 without a passphrase.
    public var secrets: Int
    public init(path: String, bytes: Int, secrets: Int) { self.path = path; self.bytes = bytes; self.secrets = secrets }
}
