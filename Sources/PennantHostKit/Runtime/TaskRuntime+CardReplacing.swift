import PennantCore
import Foundation

/// One card per decision. An agent that proposes something new about a goal, a job or a thread where its earlier
/// cards still wait says which ones the new card replaces (they're withdrawn, reading "Replaced") or that they're
/// about other things; an exact repeat replaces the old card by itself. The gates' cards before one command are
/// never replaced.
extension TaskRuntime {
    /// Where a card comes from: the goal its task works for, else the scheduled job whose run it is, else its
    /// thread, followed up the chain of tasks that asked for it.
    struct CardSource: Equatable {
        var key: String
        /// "the goal “Grow the page”", for telling the agent.
        var label: String
    }

    func cardSource(_ taskID: TaskID) async -> CardSource? {
        guard var root = try? await deps.store.task(taskID) else { return nil }
        for _ in 0 ..< 6 {
            guard let up = root.requestedByTaskID ?? root.parentTaskID, let parent = try? await deps.store.task(up) else { break }
            // Threads the Pennant chat started are each their own source, not the chat's.
            if await inMainChat(parent) { break }
            root = parent
        }
        let goals = await deps.goals?() ?? []
        if let goal = goals.first(where: { $0.conversationID == root.conversationID }) {
            return CardSource(key: "goal:\(goal.id.rawValue)", label: "the goal “\(goal.title)”")
        }
        // The chat a goal was started in is the goal's too: its proposal card there names it. Not the Pennant chat, where
        // everything is talked about: a goal proposed there doesn't make the chat's other cards the goal's.
        if await !inMainChat(root), let goal = await goalProposed(in: root.conversationID, among: goals) {
            return CardSource(key: "goal:\(goal.id.rawValue)", label: "the goal “\(goal.title)”")
        }
        if let name = UsageJobs.scheduledName(root.objective) {
            let job = (try? await deps.store.listSchedules())?.first { $0.name == name }
            // A goal's own jobs, or a job named after the goal ("🎯 Book the team's place · daily").
            if let goal = goals.first(where: { $0.id == job?.goalID || ($0.title.count >= 8 && name.contains($0.title)) }) {
                return CardSource(key: "goal:\(goal.id.rawValue)", label: "the goal “\(goal.title)”")
            }
            return CardSource(key: "job:\(name)", label: "the job “\(name)”")
        }
        return CardSource(key: "thread:\(root.conversationID.rawValue)", label: "this thread")
    }

    /// The goal last proposed in a thread, from its proposal card's action.
    private func goalProposed(in conversation: ConversationID, among goals: [Goal]) async -> Goal? {
        guard !goals.isEmpty, let messages = try? await deps.store.messagesAfter(conversationID: conversation, after: nil, limit: 4000) else { return nil }
        for message in messages.reversed() {
            for case .approval(let card) in message.parts where card.action?.tool == ActivateGoalTool.name {
                if let id = card.action?.arguments["goal_id"]?.stringValue, let goal = goals.first(where: { $0.id.rawValue == id }) { return goal }
            }
        }
        return nil
    }

    /// Makes room for an agent's card before it goes up: the cards it names in `replaces`, and exact repeats from
    /// the same source, are withdrawn. Other cards of the agent's still waiting from the same source stop it, unless
    /// `alongside` says they're about other things, so it decides instead of stacking. Returns the replaced titles.
    func makeRoom(for card: ApprovalRequest, taskID: TaskID, replaces: [String], alongside: Bool) async throws -> [String] {
        let pending = (try? await pendingApprovals()) ?? []
        var replaced: [ApprovalRequest] = []
        for key in replaces.map({ $0.trimmingCharacters(in: .whitespaces) }) where !key.isEmpty {
            guard let match = pending.first(where: { $0.request.id == key || $0.request.id.hasPrefix(key) }) else {
                throw ToolError.invalidArguments("No card \(key) is waiting to be replaced. Nothing was posted.")
            }
            guard match.request.isAgentProposal else {
                throw ToolError.invalidArguments("Card \(key) is the owner's check before one command; it can't be replaced. Nothing was posted.")
            }
            if !replaced.contains(where: { $0.id == match.request.id }) { replaced.append(match.request) }
        }
        if let source = await cardSource(taskID) {
            var waiting: [PendingApproval] = []
            for p in pending where p.request.isAgentProposal && !replaced.contains(where: { $0.id == p.request.id }) {
                if await cardSource(p.request.taskID) == source { waiting.append(p) }
            }
            let repeats = waiting.filter { Self.isRepeat($0.request, of: card) }
            replaced += repeats.map(\.request)
            let others = waiting.filter { p in !repeats.contains { $0.request.id == p.request.id } }
            if !others.isEmpty, !alongside {
                throw ToolError.failed("""
                These cards from \(source.label) are still waiting on the owner:
                \(Self.describe(others.map(\.request)))
                One card per decision. If this card revises, replaces or adds to any of them, pass their ids in `replaces` \
                and fold what's still needed into this card. If they're about other things, pass `alongside: true`. \
                Nothing was posted.
                """)
            }
        }
        for old in replaced { await replace(old, with: card) }
        return replaced.map(\.title)
    }

    /// Withdraws a card a newer one takes the place of: it reads "Replaced", and a task waiting on it goes on, told
    /// what replaced it.
    private func replace(_ old: ApprovalRequest, with new: ApprovalRequest) async {
        _ = try? await updateApproval(old.id) { $0.replacedBy = new.id }
        try? await decideApproval(ApprovalDecision(approvalID: old.id, verdict: .reject, comment: "Replaced by a newer card: \(new.title)"),
                                  by: MessageAuthor(id: PersonID("pennant"), name: HostService.defaultAgentName))
    }

    /// The same proposal again: the same title, or the same text for the same place.
    static func isRepeat(_ old: ApprovalRequest, of new: ApprovalRequest) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        if norm(old.title) == norm(new.title) { return true }
        return !old.destination.isEmpty && norm(old.destination) == norm(new.destination) && norm(old.text) == norm(new.text)
    }

    static func describe(_ cards: [ApprovalRequest], now: Date = Date()) -> String {
        cards.map { card in
            let age = RelativeDateTimeFormatter().localizedString(for: card.createdAt, relativeTo: now)
            return "- \(card.id.prefix(8)) “\(card.title)”\(card.destination.isEmpty ? "" : " → \(card.destination)"), posted \(age)"
        }.joined(separator: "\n")
    }
}
