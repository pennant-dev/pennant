import PennantCore
import Foundation

// The prompt inspector: what an agent's model received on its latest turn, split into the system prompt's sections,
// the history, and the tool definitions, each with an estimated token count.

extension TaskRuntime {
    /// Takes one turn's context apart.
    func inspection(agent: AgentProfile, context: ContextBuilder.Output, specs: [ToolSpec], services: [ContextBuilder.Service], model: ModelChoice, isPreview: Bool) -> PromptInspection {
        let system = context.messages.first { $0.role == .system }?.text ?? ""
        let history = context.messages.filter { $0.role != .system }
        let tools = specs.map { spec in
            PromptInspection.Tool(
                name: spec.name,
                service: spec.source.hasPrefix("mcp:") ? Self.serviceName(of: spec) : "Built in",
                description: spec.description,
                tokens: TokenEstimator.tokens(for: spec)
            )
        }
        return PromptInspection(
            agentID: agent.id,
            agentName: agent.name,
            isPreview: isPreview,
            model: model.label,
            reasoningEffort: agent.reasoningEffort ?? model.reasoningEffort,
            sections: Self.sections(of: system),
            // The per-turn context note goes at the end of every request; it isn't conversation history.
            historyMessages: history.filter { !$0.text.hasPrefix("[Context for this turn]") }.count,
            historyTokens: history.reduce(0) { $0 + TokenEstimator.tokens(for: $1) },
            tools: tools,
            unloadedServices: services.filter { !$0.loaded }.map(\.name)
        )
    }

    /// Splits a system prompt at its "## " headings; the text before the first heading is the agent's identity.
    static func sections(of prompt: String) -> [PromptInspection.Section] {
        var out: [PromptInspection.Section] = []
        var title = "Identity and the agent's own instructions"
        var buffer = ""
        func flush() {
            guard !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { buffer = ""; return }
            out.append(PromptInspection.Section(title: title, text: buffer, tokens: TokenEstimator.tokens(forText: buffer)))
            buffer = ""
        }
        for line in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            buffer += line + "\n"
        }
        flush()
        return out
    }

    /// The agent's latest turn since the host started, or a preview of a new task in its latest conversation.
    public func inspectPrompt(_ agentID: AgentID) async throws -> PromptInspection {
        if let last = lastInspections[agentID] { return last }
        guard let agent = try await deps.store.agent(agentID) else { throw HostCommandError.invalid("No such agent.") }
        let conversation = try await deps.store.listConversations(agentID: agentID).max { $0.updatedAt < $1.updatedAt }
        let task = TaskRecord(agentID: agentID, conversationID: conversation?.id ?? ConversationID(), title: "Preview", objective: "(your next message)")
        let messages = conversation == nil ? [] : try await deps.store.messagesAfter(conversationID: task.conversationID, after: nil, limit: 4000)
        let preferences = (try? await deps.memory.governingPreferences(for: agent)) ?? []
        let checkpoint = conversation == nil ? nil : try await deps.store.latestCheckpoint(conversationID: task.conversationID)
        let model = await currentModel(task: task, agent: agent)
        let specs = try await turnSpecs(task: task, agent: agent)
        let services = await connectedServices(agent: agent, visible: specs)
        let store = deps.store
        let loader: @Sendable (ArtifactID) async -> Data? = { id in try? await store.artifactData(id) }
        let provider = model.provider
        let output = await ContextBuilder().build(
            ContextBuilder.Input(agent: agent, task: task, config: deps.config, preferences: preferences, memoryHits: [], skills: [], checkpoint: checkpoint, messages: messages, toolSpecs: specs, desktopStatus: DesktopStatus(), runtimeNotes: [], artifactLoader: loader, services: services),
            estimator: { provider.estimateTokens($0, tools: $1) }
        )
        return inspection(agent: agent, context: output, specs: specs, services: services, model: model, isPreview: true)
    }
}
