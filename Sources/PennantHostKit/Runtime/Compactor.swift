import PennantCore
import Foundation

/// Produces checkpoints. The model writes the narrative; the runtime supplies the facts it must not invent:
/// outstanding tool outcomes, active delegations, artifacts, and the event range covered.
public struct Compactor: Sendable {
    let provider: any InferenceProvider
    let store: any StoreProtocol

    public init(provider: any InferenceProvider, store: any StoreProtocol) {
        self.provider = provider
        self.store = store
    }

    public func makeCheckpoint(task: TaskRecord, agent: AgentProfile, preferences: [Preference], previous: Checkpoint?, messages: [Message], throughMessageID: MessageID?, contextForSummary: [ModelMessage]) async -> Checkpoint {
        let outstanding = (try? await store.toolRecords(taskID: task.id))?.filter { [.intended, .running, .uncertain].contains($0.status) } ?? []
        let children = (try? await store.childTasks(parentTaskID: task.id))?.filter { !$0.state.isTerminal } ?? []
        let artifacts = task.artifactIDs
        let firstSeq = previous?.lastEventSeq
        let lastSeq = try? await store.latestEventSeq()

        var checkpoint = Checkpoint(taskID: task.id, conversationID: task.conversationID, agentID: agent.id, objective: task.objective, governingInstructions: preferences.map(\.text), activeDelegations: children.map(\.id), artifactIDs: artifacts, throughMessageID: throughMessageID, firstEventSeq: firstSeq, lastEventSeq: lastSeq, outstandingToolRecordIDs: outstanding.map(\.id))

        if let generated = await generate(task: task, previous: previous, context: contextForSummary) {
            checkpoint.decisions = generated.decisions
            checkpoint.completedWork = generated.completedWork
            checkpoint.pendingActions = generated.pendingActions
            checkpoint.unresolvedQuestions = generated.unresolvedQuestions
            checkpoint.nextStep = generated.nextStep
            checkpoint.historySummary = generated.historySummary
        } else {
            checkpoint.historySummary = mechanicalSummary(messages: messages, previous: previous)
            checkpoint.nextStep = previous?.nextStep ?? "Continue the objective from the latest messages."
            checkpoint.pendingActions = previous?.pendingActions ?? []
            checkpoint.completedWork = previous?.completedWork ?? []
            checkpoint.decisions = previous?.decisions ?? []
        }

        // Runtime facts override narrative: unknown outcomes stay pending and are never listed as done.
        for record in outstanding {
            let line = "Outcome unknown for \(record.call.name) \(record.call.arguments.compactText.prefix(120)) (record \(record.id.rawValue.prefix(8))); read back the target state before retrying."
            checkpoint.pendingActions.append(line)
            checkpoint.completedWork.removeAll { $0.localizedCaseInsensitiveContains(record.call.name) && $0.localizedCaseInsensitiveContains("done") }
        }
        // Summaries only reference evidence; add the event range so originals can be fetched.
        if let f = firstSeq, let l = lastSeq { checkpoint.historySummary += "\n(evidence: events \(f)…\(l))" } else if let l = lastSeq { checkpoint.historySummary += "\n(evidence: events …\(l))" }
        return checkpoint
    }

    struct Generated: Decodable {
        var decisions: [String]
        var completedWork: [String]
        var pendingActions: [String]
        var unresolvedQuestions: [String]
        var nextStep: String
        var historySummary: String
    }

    private func generate(task: TaskRecord, previous: Checkpoint?, context: [ModelMessage]) async -> Generated? {
        var prompt = "You are compacting the working context of an agent so it can continue with less history. Write a JSON object with keys: decisions (array of strings), completedWork (array of strings; only work that was actually verified in the history), pendingActions (array), unresolvedQuestions (array), nextStep (string), historySummary (string, at most 400 words, concrete: names, paths, values, what was tried and what happened). Never claim an action succeeded unless a tool result confirmed it. Objective: \(task.objective)"
        if let previous, !previous.historySummary.isEmpty { prompt += "\nPrevious summary to extend (do not repeat verbatim): \(previous.historySummary.prefix(2500))" }
        var messages: [ModelMessage] = [.system(prompt)]
        // Strip images from the context used for summarisation.
        for m in context.dropFirst() {
            var mm = m
            mm.parts = m.parts.map { if case .image = $0 { return .text("[screenshot]") } else { return $0 } }
            messages.append(mm)
        }
        messages.append(.user("Write the JSON object now."))
        do {
            let response = try await provider.complete(InferenceRequest(messages: messages, maxOutputTokens: 1500, temperature: 0.1, disableTools: true, jsonMode: true))
            let text = Self.extractJSON(response.text)
            return try JSONCodec.decode(Generated.self, from: Data(text.utf8))
        } catch {
            log.warn("Checkpoint generation failed, using mechanical summary: \(error)", category: "compaction")
            return nil
        }
    }

    static func extractJSON(_ text: String) -> String {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end { return String(text[start...end]) }
        return text
    }

    func mechanicalSummary(messages: [Message], previous: Checkpoint?) -> String {
        var s = previous?.historySummary.components(separatedBy: "\n(evidence").first ?? ""
        for m in messages.suffix(30) {
            let line: String
            // Shared files appear by name and size, never by content.
            let files = m.parts.compactMap { if case .file(let ref) = $0 { return FileShareTool.modelLine(ref) } else { return nil } }
            let body = ([m.text] + files).filter { !$0.isEmpty }.joined(separator: " ")
            switch m.role {
            case .user: line = "User: \(body.prefix(240))"
            case .assistant:
                let calls = m.toolCalls.map { "\($0.name)(\($0.arguments.compactText.prefix(80)))" }.joined(separator: ", ")
                line = "Agent: \(body.prefix(200))\(calls.isEmpty ? "" : " → \(calls)")"
            case .tool:
                let r = m.parts.compactMap { if case .toolResult(let r) = $0 { return r } else { return nil } }.first
                line = "Result(\(r?.name ?? "?")): \(r?.textContent.prefix(160) ?? "")\(r?.isError == true ? " [error]" : "")"
            case .system: line = "Note: \(m.text.prefix(160))"
            }
            s += "\n" + line.replacingOccurrences(of: "\n", with: " ")
        }
        return String(s.suffix(6000))
    }
}
