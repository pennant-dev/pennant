import PennantCore
import Foundation

/// Coding runs on the Pennant engine: the task's own loop, on the run's model, with only the coding tools, writing only
/// inside the project folder, and asking first exactly as a Claude Code run does (`coderPermission`).
extension TaskRuntime {
    /// What a Pennant-engine run works with, and what it has while its plan waits for the owner: no file writes.
    static let codingTools = ["read_file", "list_directory", "edit_file", "write_file", "shell"]
    static let planningTools = ["read_file", "list_directory", "shell"]

    /// A Pennant-engine coding run under way: its project folder, and the GitHub identity its commands act as.
    struct PennantCodingRun: Sendable {
        var folder: String
        var gitHubApp: GitHubAppIdentity?
        var environment: [String: String] = [:]
        var identityNote = ""
        var mintedAt = Date.distantPast
    }

    // MARK: Starting and ending

    /// Sets a run up as its loop starts (again, after a pause): the thread's folder, the default project's when it has
    /// none, and a fresh GitHub token.
    func startPennantCoding(_ taskID: TaskID, agentID: AgentID, setup: CodingSetup) async throws {
        guard let task = try await deps.store.task(taskID), var conversation = try await deps.store.conversation(task.conversationID) else { throw TaskError.notFound(taskID) }
        guard let folder = conversation.workingDirectory ?? setup.folder else {
            throw ToolError.failed("Coding has no project folder yet: the owner adds one in Settings › Pennant › Coding.")
        }
        if conversation.workingDirectory == nil {
            conversation.workingDirectory = folder
            try await deps.store.upsertConversation(conversation)
            await publish(.conversationUpserted(conversation))
        }
        pennantCodingRuns[taskID] = PennantCodingRun(folder: folder, gitHubApp: setup.gitHubApp)
        await refreshCodingIdentity(taskID, agentID: agentID)
    }

    func endPennantCoding(_ taskID: TaskID) {
        pennantCodingRuns[taskID] = nil
        codingIdentity[taskID] = nil
    }

    /// Mints the run's GitHub token again once the one it has nears the end of its hour. When GitHub won't renew it,
    /// commands keep the lapsed one: a push then fails instead of going out with the owner's own sign-in.
    func refreshCodingIdentity(_ taskID: TaskID, agentID: AgentID) async {
        guard let run = pennantCodingRuns[taskID], Date().timeIntervalSince(run.mintedAt) > 50 * 60 else { return }
        let (environment, note) = await mintGitHubIdentity(run.gitHubApp, taskID: taskID, agentID: agentID)
        // The run may have ended while the token was minted.
        guard pennantCodingRuns[taskID] != nil else { return }
        if !environment.isEmpty || run.environment.isEmpty { pennantCodingRuns[taskID]?.environment = environment }
        pennantCodingRuns[taskID]?.identityNote = note
        pennantCodingRuns[taskID]?.mintedAt = Date()
    }

    /// The project a run's tool calls work in, with the environment of the identity its commands act as.
    func projectScope(_ taskID: TaskID) -> ProjectScope? {
        pennantCodingRuns[taskID].map { ProjectScope(folder: $0.folder, environment: $0.environment) }
    }

    // MARK: Model and tools

    /// Pennant as a coding run: on the run's model with that model's own reasoning effort, and with only the coding
    /// tools (no file writes while the thread is in plan mode).
    func codingProfile(_ agent: AgentProfile, conversation: Conversation?) -> AgentProfile {
        var profile = agent
        profile.modelProfileID = codingModel(conversation: conversation)?.id
        profile.reasoningEffort = nil
        profile.toolAllowlist = conversation?.engineMode == .plan ? Self.planningTools : Self.codingTools
        return profile
    }

    /// The model a run uses: the thread's own choice, else the one set in Settings › Pennant › Coding; nil: the
    /// host's default.
    func codingModel(conversation: Conversation?) -> InferenceProfile? {
        let config = deps.config
        return config.profile(matching: conversation?.engineModel) ?? config.profile(config.coding?.modelProfileID)
    }

    // MARK: Asking first

    /// Whether a call runs, and with which arguments.
    enum CodingVerdict { case run(JSONValue), refuse(String) }

    /// A run's call, put through the policy Claude Code runs get: its commands as Claude Code's Bash, its file writes
    /// as Write and Edit. Reads never ask. A command the owner edited on its card runs as edited.
    func codingPermission(_ call: ToolCall, task: TaskRecord) async throws -> CodingVerdict {
        let arguments = call.arguments
        let folder = pennantCodingRuns[task.id]?.folder ?? deps.config.workingDirectory
        func file() -> JSONValue { .string(PathResolver.resolve(arguments["path"]?.stringValue ?? "", base: folder)) }
        let tool: String, input: JSONValue
        switch call.name {
        case "shell": (tool, input) = ("Bash", ["command": arguments["command"] ?? ""])
        case "write_file": (tool, input) = ("Write", ["file_path": file(), "content": arguments["content"] ?? ""])
        case "edit_file": (tool, input) = ("Edit", ["file_path": file(), "old_string": arguments["old_text"] ?? "", "new_string": arguments["new_text"] ?? ""])
        default: return .run(arguments)
        }
        let decision = try await coderPermission(taskID: task.id, tool: tool, input: input)
        guard decision.allow else { return .refuse(decision.message ?? "Not allowed.") }
        if tool == "Bash", let edited = decision.input?["command"], case .object(var fields) = arguments {
            fields["command"] = edited
            return .run(.object(fields))
        }
        return .run(arguments)
    }

    // MARK: Plan first

    enum PlanReview { case notPlanning, carryOn(String), rejected(String) }

    /// A run in plan mode ends its turn with the plan, which goes to the owner on the same card Claude Code's plans
    /// do. Approved, the thread leaves plan mode and the run makes the changes; with changes asked for, it plans again;
    /// rejected, it ends having changed nothing.
    func reviewPlan(task: TaskRecord, plan: String) async throws -> PlanReview {
        guard try await deps.store.conversation(task.conversationID)?.engineMode == .plan else { return .notPlanning }
        let (decided, _) = try await decidePlan(taskID: task.id, conversationID: task.conversationID, plan: plan)
        switch decided.state {
        case .approved:
            return .carryOn("The owner approved your plan\(decided.approvedText == nil ? "" : " with their edits"). Make the changes now:\n\(decided.finalText)")
        case .changesRequested:
            return .carryOn("The owner wants changes to the plan: \(decided.comment ?? "no reason given"). Revise it and end your turn with the new plan; still change nothing.")
        default:
            return .rejected("The owner rejected the plan\(decided.comment.map { ": \($0)" } ?? ""). Nothing was changed.")
        }
    }

    // MARK: Instructions

    /// What the run is told about its job: the project, the owner's coding instructions, how it asks, and who it is
    /// on GitHub. Nil: not a Pennant-engine run.
    func codingBrief(task: TaskRecord) async -> ContextBuilder.CodingBrief? {
        guard let run = pennantCodingRuns[task.id] else { return nil }
        let coding = deps.config.coding
        let mode = (try? await deps.store.conversation(task.conversationID))??.engineMode ?? .acceptEdits
        return ContextBuilder.CodingBrief(folder: run.folder, project: coding?.projects.first { $0.path == run.folder }?.name,
                                          instructions: coding?.instructions ?? "", identityNote: run.identityNote, mode: mode)
    }
}
