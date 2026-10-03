import PennantCore
import Foundation

/// How tasks end: the checks before one may finish, state transitions, completing or failing, and what a finished
/// task teaches (skills, memory).
extension TaskRuntime {
    // MARK: Skills

    func learnSkill(taskID: TaskID, _ draft: Skill) async throws -> Skill {
        var skill = draft
        let existing = try await deps.store.listSkills(includeDisabled: true).filter { $0.name.caseInsensitiveCompare(draft.name) == .orderedSame }
        if let latest = existing.max(by: { $0.version < $1.version }) {
            skill.version = latest.version + 1
            skill.previousVersionID = latest.id
            skill.evidenceTaskIDs = Array(Set(latest.evidenceTaskIDs + draft.evidenceTaskIDs))
            // Steps that failed in earlier versions stay marked uncertain until they are re-verified.
            for (i, step) in skill.steps.enumerated() {
                if let old = latest.steps.first(where: { $0.instruction == step.instruction }), old.uncertain { skill.steps[i].uncertain = true }
            }
        }
        try await deps.store.upsertSkill(skill)
        await publish(.skillUpserted(skill))
        await deps.skillTracker.markUsed(skill.id, in: taskID)
        return skill
    }

    private func recordSkillOutcomes(task: TaskRecord, succeeded: Bool) async {
        let used = await deps.skillTracker.usedSkills(in: task.id)
        await deps.skillTracker.clear(task.id)
        for id in used {
            guard var skill = try? await deps.store.skill(id) else { continue }
            skill.outcomes.append(SkillOutcome(taskID: task.id, succeeded: succeeded, note: succeeded ? "Task completed" : task.stateReason))
            let successes = skill.outcomes.filter(\.succeeded).count
            if skill.status == .provisional, successes >= 3, let rate = skill.successRate, rate >= 0.75 { skill.status = .validated }
            if !succeeded { for i in skill.steps.indices { skill.steps[i].uncertain = true } }
            skill.updatedAt = Date()
            try? await deps.store.upsertSkill(skill)
            await publish(.skillUpserted(skill))
        }
    }

    // MARK: Completion checks

    /// One-time nudges for claims that the runtime can cheaply check against tool records:
    /// a reply that says something was remembered when no memory tool ran.
    func completionNudge(task: TaskRecord, reply: String) async -> String? {
        guard !nudged.contains(task.id) else { return nil }
        let asked = task.objective.range(of: "\\bremember\\b", options: [.regularExpression, .caseInsensitive]) != nil
        let claims = reply.range(of: "(stored|saved|remembered|recorded).{0,40}(memory|instruction|preference)", options: [.regularExpression, .caseInsensitive]) != nil
        guard asked || claims else { return nil }
        let records = (try? await deps.store.toolRecords(taskID: task.id)) ?? []
        let usedMemory = records.contains { ["memory_remember", "remember_instruction"].contains($0.call.name) && $0.status == .succeeded }
        guard !usedMemory else { return nil }
        nudged.insert(task.id)
        return "Your reply claims something was remembered, but no memory tool ran in this task. Call remember_instruction for standing instructions and memory_remember for facts now, then answer. Never claim an action you did not perform."
    }

    // MARK: Transitions and completion

    /// Read-modify-write so concurrent transitions are never overwritten by a stale copy.
    @discardableResult
    func updateTask(_ id: TaskID, _ mutate: (inout TaskRecord) -> Void) async throws -> TaskRecord {
        guard var task = try await deps.store.task(id) else { throw TaskError.notFound(id) }
        mutate(&task)
        task.updatedAt = Date()
        try await deps.store.upsertTask(task)
        return task
    }

    public func transition(_ id: TaskID, to next: TaskState, reason: String) async throws {
        guard var task = try await deps.store.task(id) else { throw TaskError.notFound(id) }
        guard task.state.canTransition(to: next) else {
            if task.state == next { return }
            throw TaskError.illegalTransition(from: task.state, to: next)
        }
        let transition = TaskTransition(taskID: id, from: task.state, to: next, reason: reason)
        task.usage.track(from: task.state, to: next, at: transition.at)
        task.state = next
        task.stateReason = reason
        task.updatedAt = transition.at
        if next.isTerminal { task.finishedAt = transition.at }
        try await deps.store.upsertTask(task)
        try await deps.store.recordTransition(transition)
        await publish(.taskTransition(transition))
    }

    func complete(task id: TaskID, summary: String) async throws {
        let done = try await updateTask(id) { $0.resultSummary = summary }
        await clearQuietHeartbeat(done, reply: summary)
        try await transition(id, to: .completed, reason: "Completed")
        await finish(task: id)
        // Keep what the exchange established, without holding up the reply.
        Task.detached(priority: .utility) { [weak self] in await self?.learn(from: id, answer: summary) }
    }

    /// Writes the durable facts a finished task established into memory (see `MemoryLearner`), and says so.
    private func learn(from id: TaskID, answer: String) async {
        guard let task = try? await deps.store.task(id), task.parentTaskID == nil, !Self.isHeartbeat(task),
              let agent = try? await deps.store.agent(task.agentID),
              (try? await deps.store.conversation(task.conversationID))??.isCodingRun != true else { return }
        let messages = (try? await deps.store.messagesAfter(conversationID: task.conversationID, after: nil, limit: 400)) ?? []
        let question = messages.filter { $0.taskID == id && $0.role == .user }.map(\.text).joined(separator: "\n\n")
        let final = answer.isEmpty ? (messages.last { $0.taskID == id && $0.role == .assistant && !$0.text.isEmpty }?.text ?? "") : answer
        let tools = ((try? await deps.store.toolRecords(taskID: id)) ?? []).map(\.call.name)
        guard MemoryLearner.worthLearning(question: question.isEmpty ? task.objective : question, answer: final, toolsUsed: tools) else { return }
        let model = await currentModel(task: task, agent: agent)
        let remembered = await deps.memory.learn(question: question.isEmpty ? task.objective : question, answer: final, taskID: id, agentID: agent.id,
                                                 taskTitle: task.title) { messages in
            try await model.provider.complete(InferenceRequest(messages: messages, maxOutputTokens: 1200, temperature: 0, disableTools: true, jsonMode: true)).text
        }
        if !remembered.isEmpty {
            await publish(.notice(level: .info, agentID: agent.id, text: "\(agent.name) remembered \(remembered.joined(separator: ", "))."))
            // Something it learned may disagree with what memory held: settle it now rather than queue it for you.
            await tendMemory()
        }
    }

    /// Settles contradictions in memory with the lead agent's model (see MemoryKeeper), and says what changed.
    @discardableResult
    public func tendMemory() async -> [MemoryUpkeepEntry] {
        let agents = (try? await deps.store.listAgents(includeRetired: false)) ?? []
        guard let lead = agents.first(where: { $0.kind == .persistent }),
              let model = await modelChoices(for: lead).first else { return [] }
        let done = await deps.memory.tend { messages in
            try await model.provider.complete(InferenceRequest(messages: messages, maxOutputTokens: 600, temperature: 0, disableTools: true, jsonMode: true)).text
        }
        if !done.isEmpty {
            let words = done.map { e -> String in
                switch e.action {
                case .kept: return "kept \(e.name) as it was"
                case .updated: return "updated \(e.name)"
                case .combined: return "combined what it knew about \(e.name)"
                }
            }
            await publish(.notice(level: .info, agentID: lead.id, text: "\(lead.name) kept memory current: \(words.joined(separator: "; ")). See Memory to undo."))
        }
        return done
    }

    func fail(task id: TaskID, reason: String) async {
        try? await transition(id, to: .failed, reason: reason)
        if let t = try? await deps.store.task(id) {
            await publish(.notice(level: .error, agentID: t.agentID, text: "\(t.title): \(reason)"))
        }
        await finish(task: id)
    }

    /// Common wrap-up for any terminal state.
    func finish(task id: TaskID) async {
        guard let task = try? await deps.store.task(id) else { return }
        await deps.lease.forget(taskID: id)
        await CaptureGeometryRegistry.shared.forget(taskID: id)
        await AppCaptureRegistry.shared.forget(taskID: id)
        freshScreen.remove(id)
        emptyReplies[id] = nil
        earlyAnswers[id] = nil
        wrappedUp.remove(id)
        nudged.remove(id)
        runtimeNotes[id] = nil
        await recordSkillOutcomes(task: task, succeeded: task.state == .completed)
        await publish(.taskUpserted(task))
        await reportFinished(task)
        for c in taskWaiters.removeValue(forKey: id) ?? [] { c.resume(returning: task) }
        // Helpers it started and never collected have nobody to report to: stop them (and theirs, as each finishes).
        for child in (try? await deps.store.listTasks(agentID: nil, includeFinished: false)) ?? [] where child.parentTaskID == id {
            try? await cancelTask(child.id, reason: "The task that started it has finished")
        }
        if let agent = try? await deps.store.agent(task.agentID) {
            if agent.kind == .worker {
                await setAgentStatus(agent.id, .retired, line: task.state == .completed ? "Done" : task.state.rawValue)
            } else {
                await setAgentStatus(agent.id, task.state == .failed ? .error : .idle, line: task.state == .completed ? "" : task.stateReason)
            }
        }
        let now = Date()
        if let conv = try? await deps.store.mutateConversation(task.conversationID, { $0.updatedAt = now }) {
            await publish(.conversationUpserted(conv))
        }
    }

    func setAgentStatus(_ id: AgentID, _ status: AgentStatus, line: String) async {
        guard var agent = try? await deps.store.agent(id) else { return }
        guard agent.status != status || agent.statusLine != line else { return }
        agent.status = status
        agent.statusLine = line
        agent.updatedAt = Date()
        try? await deps.store.upsertAgent(agent)
        await publish(.agentUpserted(agent))
    }

    // MARK: Helpers

    func publish(_ payload: EventPayload) async {
        do {
            let event = try await deps.store.appendEvent(payload)
            await deps.eventBus.publish(event)
        } catch {
            log.error("Failed to append event: \(error)", category: "runtime")
        }
    }

    /// Tells clients a conversation changed because a message landed in it. The store maintains `preview` and
    /// `updatedAt` for user and assistant text; anything else (an image-only message) still moves the row up.
}
