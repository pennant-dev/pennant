import PennantCore
import Foundation

/// Helpers a task delegates to and waits on, and the desktop lease: who has the Mac's screen and keyboard.
extension TaskRuntime {
    // MARK: Delegation

    public func delegate(parentTaskID: TaskID, title: String, objective: String, completionCriteria: String, context: String, workerName: String?, workerRole: String?, model: String? = nil) async throws -> TaskID {
        guard var parent = try await deps.store.task(parentTaskID), let parentAgent = try await deps.store.agent(parent.agentID) else { throw TaskError.notFound(parentTaskID) }
        guard parent.usage.delegations < parent.budget.maxDelegations else { throw TaskError.budgetExhausted("delegation limit \(parent.budget.maxDelegations) reached; finish the work yourself or ask the user") }
        var worker = AgentProfile(kind: .worker, name: workerName ?? "\(parentAgent.name)'s worker", role: workerRole ?? "worker for \(parentAgent.name)", style: parentAgent.style, memoryScope: MemoryScope(label: parentAgent.memoryScope.label, readableScopes: parentAgent.memoryScope.readableScopes), toolAllowlist: parentAgent.toolAllowlist, parentAgentID: parentAgent.id, statusLine: "Starting", avatar: "shape:hexagon", accentColorHex: parentAgent.accentColorHex)
        // Workers run on the model asked for (a profile's name or id), else the worker model, else the default.
        let config = deps.config
        if let model, let p = config.profile(matching: model) {
            worker.modelProfileID = p.id
        } else if let model {
            throw ToolError.invalidArguments("No model named \(model). Models: \(config.inferenceProfiles.map(\.name).joined(separator: ", "))")
        } else {
            worker.modelProfileID = config.profile(config.workerProfileID)?.id
        }
        try await deps.store.upsertAgent(worker)
        await publish(.agentUpserted(worker))
        let conversation = Conversation(agentID: worker.id, title: title)
        try await deps.store.upsertConversation(conversation)
        await publish(.conversationUpserted(conversation))
        var budget = parent.budget
        budget.maxSteps = parent.budget.maxSteps == 0 ? 0 : max(10, parent.budget.maxSteps / 2)
        budget.maxDelegations = max(0, parent.budget.maxDelegations - 1)
        let task = TaskRecord(agentID: worker.id, conversationID: conversation.id, parentTaskID: parentTaskID, title: title, objective: objective, completionCriteria: completionCriteria, context: context, budget: budget)
        let kickoff = Message(conversationID: conversation.id, agentID: worker.id, taskID: task.id, role: .user, parts: [.text("Delegated by \(parentAgent.name): \(objective)\(completionCriteria.isEmpty ? "" : "\nDone when: \(completionCriteria)")")])
        try await deps.store.appendMessage(kickoff)
        await publish(.messageAppended(kickoff))
        try await deps.store.upsertTask(task)
        await publish(.taskUpserted(task))
        parent = try await updateTask(parentTaskID) { $0.usage.delegations += 1 }
        await publish(.taskUpserted(parent))
        await schedule()
        return task.id
    }

    public func awaitTask(_ id: TaskID, timeout: TimeInterval) async throws -> TaskRecord {
        guard let t = try await deps.store.task(id) else { throw TaskError.notFound(id) }
        if t.state.isTerminal { return t }
        return try await withThrowingTaskGroup(of: TaskRecord.self) { group in
            group.addTask { [self] in
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { c in
                        Task { await self.addWaiter(id, c) }
                    }
                } onCancel: {
                    Task { await self.failWaiters(id, CancellationError()) }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ToolError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func addWaiter(_ id: TaskID, _ c: CheckedContinuation<TaskRecord, Error>) async {
        if let t = try? await deps.store.task(id), t.state.isTerminal { c.resume(returning: t); return }
        taskWaiters[id, default: []].append(c)
    }

    private func failWaiters(_ id: TaskID, _ error: Error) {
        for c in taskWaiters.removeValue(forKey: id) ?? [] { c.resume(throwing: error) }
    }

    // MARK: Desktop events

    /// Called when a human takes over or pauses the desktop. Tasks holding the lease will observe
    /// revocation on their next action; nothing to do here beyond a status line.
    public func desktopPausedByHuman(reason: String) async {
        await publish(.notice(level: .info, agentID: nil, text: reason))
    }

    /// Called when the human releases or resumes the desktop: tasks paused for that reason continue.
    public func desktopResumed() async {
        let ids = pausedForDesktop
        pausedForDesktop = []
        for id in ids { try? await resumeTask(id) }
    }

    /// A task paused for a rate limit continues, unless it was resumed, cancelled or changed meanwhile.
    func resumeAfterRateLimit(_ id: TaskID) async {
        guard pausedForInference.contains(id), (try? await deps.store.task(id))?.state == .paused else { return }
        try? await resumeTask(id)
    }

    /// A command the owner already approved on a card in this task (an agent that asked first): not asked again.
    func alreadySignedOff(task: TaskRecord, call: ToolCall) async -> Bool {
        guard let command = call.arguments["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return false }
        let recent = (try? await deps.store.listMessages(conversationID: task.conversationID, before: nil, limit: 60)) ?? []
        return recent.contains { m in
            m.taskID == task.id && m.parts.contains { part in
                if case .approval(let a) = part, a.state == .approved { return (a.approvedText ?? a.text).contains(command) }
                return false
            }
        }
    }

    /// Called by the health monitor when inference becomes reachable again.
    public func inferenceAvailable() async {
        let ids = pausedForInference
        pausedForInference = []
        for id in ids { try? await resumeTask(id) }
    }

    public var activeTaskCount: Int { loops.count }
    public func setMaxConcurrentTasks(_ n: Int) { maxConcurrentTasks = max(1, n) }
}
