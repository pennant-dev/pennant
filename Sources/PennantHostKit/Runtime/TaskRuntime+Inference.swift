import PennantCore
import Foundation

/// Calling the model: streaming a turn, waiting out rate limits and outages, and falling back to another model.
extension TaskRuntime {
    // MARK: Inference

    func runInference(task: TaskRecord, agent: AgentProfile, context: ContextBuilder.Output, specs: [ToolSpec]) async throws -> (Message, InferenceResponse) {
        var message = Message(conversationID: task.conversationID, agentID: agent.id, taskID: task.id, role: .assistant, parts: [], isStreaming: true)
        try await deps.store.appendMessage(message)
        await publish(.messageAppended(message))
        var model = await currentModel(task: task, agent: agent)
        let skillEffort = await skillEffort(task: task)
        let inChat = await inMainChat(task)
        func request(for model: ModelChoice) -> InferenceRequest {
            InferenceRequest(messages: context.messages, tools: specs, maxOutputTokens: model.maxOutputTokens, temperature: deps.config.inference.temperature,
                             reasoningEffort: inChat ? Self.chatEffort(agent: agent, model: model) : Self.raise(agent.reasoningEffort ?? model.reasoningEffort, to: skillEffort))
        }
        var response = InferenceResponse()
        var attempt = 0
        var rateLimited = 0
        var sentAt = Date()
        var firstTokenAt: Date?
        while true {
            do {
                response = InferenceResponse()
                sentAt = Date()
                firstTokenAt = nil
                for try await chunk in model.provider.stream(request(for: model)) {
                    try Task.checkCancellation()
                    switch chunk {
                    case .textDelta, .reasoningDelta, .toolCall: if firstTokenAt == nil { firstTokenAt = Date() }
                    default: break
                    }
                    switch chunk {
                    case .textDelta(let t):
                        response.text += t
                        await bufferDelta(message, text: t, reasoning: nil, task: task)
                    case .reasoningDelta(let r):
                        response.reasoning += r
                        await bufferDelta(message, text: nil, reasoning: r, task: task)
                    case .toolCall(let c):
                        response.toolCalls.append(c)
                        await flushDelta(message.id, task: task, toolCall: c)
                    case .usage(let u): response.usage = u
                    case .finished(let f): response.finishReason = f
                    }
                }
                await flushDelta(message.id, task: task, toolCall: nil)
                try Task.checkCancellation()
                break
            } catch let error as InferenceError {
                attempt += 1
                if case .contextTooLarge = error { throw error }
                if attempt <= Self.serverErrorWaits.count, !Task.isCancelled, Self.isServerError(error) {
                    log.warn("Inference attempt \(attempt) failed: \(error). Retrying.", category: "runtime")
                    try await Task.sleep(for: .seconds(Self.serverErrorWaits[attempt - 1]))
                    continue
                }
                // Still failing on the server side: rest this model for a few minutes and carry on with the next one
                // instead of pausing the task. It comes back first in line once the cooldown ends.
                if Self.isServerError(error), !Task.isCancelled {
                    downUntil[model.label] = Date().addingTimeInterval(Self.outageCooldown)
                    let from = model.label
                    let choices = await modelChoices(for: agent)
                    if let first = choices.first, first.label != from {
                        modelIndex[task.id] = 0
                        model = first
                        attempt = 0
                        rateLimited = 0
                        log.warn("Task \(task.id): \(from) is failing (\(error.description.prefix(160))); switching to \(model.label)", category: "runtime")
                        await publish(.notice(level: .warning, agentID: agent.id, text: "\(from) isn't answering (\(error.description.prefix(80))); \(agent.name) is using \(model.label) for the next few minutes."))
                        continue
                    }
                }
                // A used-up quota won't clear in a minute: skip this model until its reset and move on now.
                if let until = Self.quotaExhausted(error), !Task.isCancelled {
                    exhaustedUntil[model.label] = until
                    let from = model.label
                    let choices = await modelChoices(for: agent)
                    if let first = choices.first, first.label != from {
                        modelIndex[task.id] = 0
                        model = first
                        attempt = 0
                        rateLimited = 0
                        log.warn("Task \(task.id): \(from) is out of quota until \(until); switching to \(model.label)", category: "runtime")
                        await publish(.notice(level: .warning, agentID: agent.id, text: "\(from) is out of quota until \(until.formatted(date: .abbreviated, time: .shortened)); \(agent.name) is using \(model.label) meanwhile."))
                        continue
                    }
                }
                // Rate limits usually clear within a minute: wait and retry the same model a few times first.
                if Self.isRateLimit(error), rateLimited < 3, !Task.isCancelled {
                    rateLimited += 1
                    let wait = Self.rateLimitWaits[min(rateLimited - 1, Self.rateLimitWaits.count - 1)]
                    log.warn("Rate limited by \(model.label); retrying in \(Int(wait))s", category: "runtime")
                    await setAgentStatus(agent.id, .thinking, line: "Rate limited; retrying in \(Int(wait))s")
                    try await Task.sleep(for: .seconds(wait))
                    continue
                }
                // A model that refuses the request (missing deployment, refused key, rejected parameters, rate
                // limits that did not clear): move the task to the next model instead of failing it.
                if Self.shouldFallBack(error), !Task.isCancelled {
                    let choices = await modelChoices(for: agent)
                    let next = (modelIndex[task.id] ?? 0) + 1
                    if next < choices.count {
                        modelIndex[task.id] = next
                        let from = model.label
                        model = choices[next]
                        attempt = 0
                        rateLimited = 0
                        log.warn("Task \(task.id): \(from) refused (\(error.description.prefix(160))); switching to \(model.label)", category: "runtime")
                        await publish(.notice(level: .warning, agentID: agent.id, text: "\(agent.name) switched from \(from) to \(model.label): \(error.description.prefix(160))"))
                        continue
                    }
                }
                message.isStreaming = false
                message.parts = [.text("[inference failed: \(error.description.prefix(200))]")]
                try? await deps.store.updateMessage(message)
                await publish(.messageFinalized(message))
                await publishConversation(task.conversationID, after: message)
                throw error
            }
        }
        if response.finishReason == .cancelled { throw CancellationError() }
        var parts: [ContentPart] = []
        if !response.reasoning.isEmpty { parts.append(.reasoning(response.reasoning)) }
        if !response.text.isEmpty { parts.append(.text(response.text)) }
        parts += response.toolCalls.map { .toolCall($0) }
        message.parts = parts
        message.isStreaming = false
        message.stats = Self.stats(response, sentAt: sentAt, firstTokenAt: firstTokenAt, model: model.label)
        // Every call goes in the usage ledger (who, which run, which model, tokens, cost).
        let sentModel = model
        let record = Self.usageRecord(response, model: sentModel, task: task) { TokenEstimator.tokens(for: request(for: sentModel).messages, tools: request(for: sentModel).tools) }
        do { try await deps.store.appendUsage(record) } catch { log.warn("Could not record usage: \(error)", category: "runtime") }
        try await deps.store.updateMessage(message)
        await publish(.messageFinalized(message))
        await publishConversation(task.conversationID, after: message)
        return (message, response)
    }

    private func bufferDelta(_ message: Message, text: String?, reasoning: String?, task: TaskRecord) async {
        // Thinking and answer go out in separate events, in the order they came: one event carrying the end of the
        // thinking and the first word of the answer would leave that word on a line of its own until the message ends.
        if let pending = deltaBuffers[message.id], text != nil ? !pending.reasoning.isEmpty : !pending.text.isEmpty {
            await flushDelta(message.id, task: task, toolCall: nil)
        }
        var buf = deltaBuffers[message.id] ?? ("", "")
        if let text { buf.text += text }
        if let reasoning { buf.reasoning += reasoning }
        deltaBuffers[message.id] = buf
        if buf.text.count + buf.reasoning.count >= 24 || buf.text.contains("\n") { await flushDelta(message.id, task: task, toolCall: nil) }
    }

    private func flushDelta(_ id: MessageID, task: TaskRecord, toolCall: ToolCall?) async {
        let buf = deltaBuffers.removeValue(forKey: id) ?? ("", "")
        guard !buf.text.isEmpty || !buf.reasoning.isEmpty || toolCall != nil else { return }
        await deps.eventBus.publish(HostEvent(seq: 0, payload: .messageDelta(MessageDelta(messageID: id, conversationID: task.conversationID, agentID: task.agentID, textDelta: buf.text.isEmpty ? nil : buf.text, reasoningDelta: buf.reasoning.isEmpty ? nil : buf.reasoning, toolCall: toolCall))))
    }
}
