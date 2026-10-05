import PennantCore
import Foundation

/// What a turn sends the model: the conversation since its last checkpoint, and folding long conversations into
/// checkpoints.
extension TaskRuntime {
    // MARK: Context and compaction

    func buildContext(task: TaskRecord, agent: AgentProfile, model: ModelChoice) async throws -> (ContextBuilder.Output, [ToolSpec]) {
        let preferences = (try? await deps.memory.governingPreferences(for: agent)) ?? []
        // The whole conversation is the agent's history; earlier tasks' turns stay visible until a
        // checkpoint (automatic or manual) folds them into a summary. Only what came after the checkpoint is read, so a
        // conversation that goes on for months (the Pennant chat) never outgrows the read.
        var checkpoint = try await deps.store.latestCheckpoint(conversationID: task.conversationID)
        let messages = try await deps.store.messagesAfter(conversationID: task.conversationID, after: checkpoint?.throughMessageID, limit: 4000)
        // Recall for what was just asked: the latest message from the person, else the task's objective.
        let latestAsk = messages.last(where: { $0.role == .user && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text ?? task.objective
        let hits = (try? await deps.memory.retrieve(MemoryQuery(text: String(latestAsk.prefix(500)), limit: 10), agent: agent, includeMessages: false,
                                                     forContext: true, excludingConversation: task.conversationID, includeInstructions: false)) ?? []
        let skills = await relevantSkills(for: task, agent: agent)
        let specs = try await turnSpecs(task: task, agent: agent)
        let services = await connectedServices(agent: agent, visible: specs)
        let board = await inMainChat(task) ? await currentWorkBoard() : nil
        let reportsToChat = board == nil ? await reportsToChat(task) : false
        let desktop = await deps.lease.snapshot(permissions: DesktopPermissions(), frontmostApp: await deps.desktop.frontmostApp()?.name, displayWidth: 0, displayHeight: 0, streamingClients: 0)
        let notes = runtimeNotes.removeValue(forKey: task.id) ?? []
        let store = deps.store
        let loader: @Sendable (ArtifactID) async -> Data? = { id in try? await store.artifactData(id) }
        let builder = ContextBuilder()
        let provider = model.provider
        let estimator: @Sendable ([ModelMessage], [ToolSpec]) -> Int = { provider.estimateTokens($0, tools: $1) }

        let config = deps.config
        let coding = await codingBrief(task: task)
        let make: @Sendable (Checkpoint?) async -> ContextBuilder.Output = { cp in
            var input = ContextBuilder.Input(agent: agent, task: task, config: config, preferences: preferences, memoryHits: hits, skills: skills, checkpoint: cp, messages: messages, toolSpecs: specs, desktopStatus: desktop, runtimeNotes: notes, artifactLoader: loader, services: services, coding: coding, workBoard: board)
            input.reportsToChat = reportsToChat
            return await builder.build(input, estimator: estimator)
        }

        var output = await make(checkpoint)
        let window = model.provider.capabilities.contextWindowTokens
        let limit = deps.config.compaction.threshold(window: window) - model.maxOutputTokens
        let keepRecent = max(1, deps.config.compaction.keepRecentMessages)
        // Compact only when there is history beyond the recent window to fold into a checkpoint.
        if output.estimatedTokens > limit, output.includedMessageIDs.count > keepRecent + 1 {
            // Save a checkpoint covering everything but the most recent messages, then rebuild.
            let keep = min(keepRecent, output.includedMessageIDs.count - 1)
            let boundary = output.includedMessageIDs[output.includedMessageIDs.count - 1 - keep]
            let compactor = Compactor(provider: model.provider, store: deps.store)
            let cp = await compactor.makeCheckpoint(task: task, agent: agent, preferences: preferences, previous: checkpoint, messages: messages, throughMessageID: boundary, contextForSummary: output.messages)
            try await deps.store.saveCheckpoint(cp)
            await publish(.checkpointSaved(cp))
            try await updateTask(task.id) { $0.usage.compactions += 1; $0.usage.lastCompactedAt = Date() }
            checkpoint = cp
            output = await make(cp)
            log.info("Compacted task \(task.id) to ~\(output.estimatedTokens) tokens", category: "compaction")
            if output.estimatedTokens > limit, output.includedMessageIDs.count > 3 {
                // Still too large (huge recent results): keep only the last two messages verbatim.
                var cp2 = cp
                cp2.id = CheckpointID()
                cp2.throughMessageID = output.includedMessageIDs[output.includedMessageIDs.count - 3]
                cp2.createdAt = Date()
                try await deps.store.saveCheckpoint(cp2)
                await publish(.checkpointSaved(cp2))
                output = await make(cp2)
            }
        }
        let contextTokens = output.estimatedTokens
        // The inspector shows Pennant's own turns, not a coding run's.
        if coding == nil { lastInspections[agent.id] = inspection(agent: agent, context: output, specs: specs, services: services, model: model, isPreview: false, inChat: board != nil) }
        let updated = try await updateTask(task.id) { $0.usage.lastContextTokens = contextTokens; $0.usage.contextWindowTokens = window }
        await publish(.taskUpserted(updated))
        return (output, specs)
    }

    /// The most the Pennant chat's prompt may take: it goes with every reply, so a long history slows every reply.
    /// Past it, older turns fold into the chat's running summary; the threads keep the details. (Tests shorten both.)
    nonisolated(unsafe) static var chatContextBudget = 20_000
    /// Messages the chat keeps word for word when it folds the rest.
    nonisolated(unsafe) static var chatKeepsRecent = 8

    /// After a chat reply whose prompt took `contextTokens`: past the budget, all but the chat's last few messages
    /// fold into its summary now, so the next reply starts small and nobody waits on the summary.
    func tidyMainChat(contextTokens: Int) async {
        guard let chatID = mainChatID, !tidyingChat, contextTokens > Self.chatContextBudget else { return }
        tidyingChat = true
        defer { tidyingChat = false }
        do {
            _ = try await compactConversation(chatID, keepingRecent: Self.chatKeepsRecent, quietly: true)
        } catch {
            log.warn("Couldn't fold the Pennant chat's history: \(error)", category: "compaction")
        }
    }

    /// Fold a conversation's history into a checkpoint now, all of it or all but its last `keepingRecent` messages.
    /// Works whether or not a task is running: a running loop reads the newest checkpoint on its next step.
    /// Start the conversation over, at the owner's word: a reply in progress stops, and a checkpoint with nothing in it
    /// marks the place, so nothing said before reaches the model again. The messages stay on screen; memory and
    /// threads are untouched.
    public func startOver(_ conversationID: ConversationID) async throws {
        guard let conversation = try await deps.store.conversation(conversationID) else { throw ToolError.failed("Conversation not found") }
        let tasks = try await deps.store.listTasks(agentID: conversation.agentID, includeFinished: true).filter { $0.conversationID == conversationID }
        for task in tasks where !task.state.isTerminal { try? await cancelTask(task.id, reason: "Started over") }
        let messages = try await deps.store.messagesAfter(conversationID: conversationID, after: nil, limit: 100_000)
        guard let last = messages.last, let task = tasks.max(by: { $0.updatedAt < $1.updatedAt }) else { return }
        let checkpoint = Checkpoint(taskID: task.id, conversationID: conversationID, agentID: conversation.agentID, objective: "",
                                    throughMessageID: last.id, startedOver: true)
        try await deps.store.saveCheckpoint(checkpoint)
        await publish(.checkpointSaved(checkpoint))
        log.info("Started conversation \(conversationID) over", category: "compaction")
    }

    public func compactConversation(_ conversationID: ConversationID, keepingRecent: Int = 0, quietly: Bool = false) async throws -> TaskRecord {
        guard let conversation = try await deps.store.conversation(conversationID), let agent = try await deps.store.agent(conversation.agentID) else { throw ToolError.failed("Conversation not found") }
        let tasks = try await deps.store.listTasks(agentID: conversation.agentID, includeFinished: true).filter { $0.conversationID == conversationID }
        guard let task = tasks.first(where: { !$0.state.isTerminal }) ?? tasks.max(by: { $0.updatedAt < $1.updatedAt }) else { throw ToolError.failed("Nothing to compact yet") }
        let previous = try await deps.store.latestCheckpoint(conversationID: conversationID)
        let messages = try await deps.store.messagesAfter(conversationID: conversationID, after: previous?.throughMessageID, limit: 4000)
        guard messages.count > keepingRecent else { return task }
        let last = messages[messages.count - 1 - keepingRecent]
        if previous?.throughMessageID == last.id { return task }
        let preferences = (try? await deps.memory.governingPreferences(for: agent)) ?? []
        let specs = await deps.broker.specs(for: agent)
        let store = deps.store
        let loader: @Sendable (ArtifactID) async -> Data? = { id in try? await store.artifactData(id) }
        let provider = deps.provider
        let estimator: @Sendable ([ModelMessage], [ToolSpec]) -> Int = { provider.estimateTokens($0, tools: $1) }
        let builder = ContextBuilder()
        let config = deps.config
        let make: @Sendable (Checkpoint?) async -> ContextBuilder.Output = { cp in
            await builder.build(ContextBuilder.Input(agent: agent, task: task, config: config, preferences: preferences, memoryHits: [], skills: [], checkpoint: cp, messages: messages, toolSpecs: specs, desktopStatus: DesktopStatus(), runtimeNotes: [], artifactLoader: loader), estimator: estimator)
        }
        let before = await make(previous)
        let compactor = Compactor(provider: deps.provider, store: deps.store)
        let cp = await compactor.makeCheckpoint(task: task, agent: agent, preferences: preferences, previous: previous, messages: messages, throughMessageID: last.id, contextForSummary: before.messages)
        try await deps.store.saveCheckpoint(cp)
        await publish(.checkpointSaved(cp))
        let after = await make(cp)
        let window = deps.provider.capabilities.contextWindowTokens
        let updated = try await updateTask(task.id) {
            $0.usage.compactions += 1
            $0.usage.lastCompactedAt = Date()
            $0.usage.lastContextTokens = after.estimatedTokens
            $0.usage.contextWindowTokens = window
        }
        await publish(.taskUpserted(updated))
        if quietly {
            log.info("Folded the Pennant chat's history: about \(before.estimatedTokens) → \(after.estimatedTokens) tokens", category: "compaction")
        } else {
            await publish(.notice(level: .info, agentID: agent.id, text: "Compacted the conversation: about \(before.estimatedTokens) → \(after.estimatedTokens) tokens."))
        }
        return updated
    }

    private func relevantSkills(for task: TaskRecord, agent: AgentProfile) async -> [Skill] {
        let found = (try? await deps.store.searchSkills(text: String(task.objective.prefix(300)), limit: 8)) ?? []
        var latestByName: [String: Skill] = [:]
        for s in found where s.status != .disabled {
            if agent.skillIDs.isEmpty || agent.skillIDs.contains(s.id) {
                if let cur = latestByName[s.name], cur.version >= s.version { continue }
                latestByName[s.name] = s
            }
        }
        return latestByName.values.sorted { ($0.status == .validated ? 0 : 1, $0.name) < ($1.status == .validated ? 0 : 1, $1.name) }
    }
}
