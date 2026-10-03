import PennantCore
import Foundation

/// Cards and questions: posting them, waiting for the owner, and acting on the decision.
extension TaskRuntime {
    // MARK: Approvals

    /// Posts the approval card, waits for the user's decision, and returns the decided request.
    func requestApproval(taskID: TaskID, _ request: ApprovalRequest) async throws -> ApprovalRequest {
        guard let task = try await deps.store.task(taskID) else { throw TaskError.notFound(taskID) }
        let message = Message(conversationID: task.conversationID, agentID: task.agentID, taskID: taskID, role: .assistant, parts: [.approval(request)])
        // From the moment the card is up, a decision on it is this call's result (see `isWaitingOn`).
        awaitingApproval[taskID] = request.id
        defer { awaitingApproval[taskID] = nil }
        try await deps.store.appendMessage(message)
        approvalMessages[request.id] = message.id
        await publish(.messageAppended(message))
        await publishConversation(task.conversationID, after: message)
        try await transition(taskID, to: .waitingForUser, reason: "Waiting for your approval: \(request.title)")
        await reportCard(task, request)
        await setAgentStatus(task.agentID, .waitingForUser, line: "Waiting for your approval")
        await publish(.notice(level: .info, agentID: task.agentID, text: "\(request.title) is ready for your approval."))
        await deps.lease.forget(taskID: taskID)
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                Task { self.registerQuestion(taskID, c) }
            }
        } onCancel: {
            Task { await self.cancelQuestion(taskID) }
        }
        try await transition(taskID, to: .running, reason: "Approval answered")
        await setAgentStatus(task.agentID, .thinking, line: task.title)
        return try await findApproval(request.id)?.request ?? request
    }

    /// Posts a card that carries its own action. The task goes on; the decision is acted on when it comes.
    func postApproval(taskID: TaskID, _ request: ApprovalRequest, proposal: Bool = false) async throws {
        guard let task = try await deps.store.task(taskID) else { throw TaskError.notFound(taskID) }
        guard let action = request.action else { throw ToolError.failed("A card that doesn't wait needs an action to run on approval.") }
        // Changes to agents and skills only come from the proposal tools, which show exactly what changes.
        if !proposal, await deps.broker.tool(named: action.tool)?.spec.access == .approvalOnly {
            throw ToolError.failed("\(action.tool) can't be attached to a card; changes to agents and skills are proposed with the proposal tools.")
        }
        let message = Message(conversationID: task.conversationID, agentID: task.agentID, taskID: taskID, role: .assistant, parts: [.approval(request)])
        try await deps.store.appendMessage(message)
        approvalMessages[request.id] = message.id
        await publish(.messageAppended(message))
        await publishConversation(task.conversationID, after: message)
        await reportCard(task, request)
        await publish(.notice(level: .info, agentID: task.agentID, text: "\(request.title) is ready for your approval."))
    }

    /// Runs an approved card's action with exactly the approved text, and records the outcome on the card.
    private func runApprovedAction(_ approval: ApprovalRequest) async {
        guard let action = approval.action else { return }
        var outcome = ""
        var failed = false
        do {
            guard let tool = await deps.broker.tool(named: action.tool) else { throw ToolError.failed("The tool \(action.tool) isn't available (is its connector signed in?)") }
            guard let task = try await deps.store.task(approval.taskID) else { throw TaskError.notFound(approval.taskID) }
            var args = action.arguments.objectValue ?? [:]
            args[action.textField] = .string(approval.finalText)
            let context = ToolContext(agentID: task.agentID, taskID: task.id, conversationID: task.conversationID, store: deps.store, desktop: deps.desktop, lease: deps.lease, config: deps.config, runtimeHooks: makeHooks(agentID: task.agentID))
            let finalArgs = JSONValue.object(args)
            let result: ToolResult
            // Teams messages go from Pennant's bot, approved cards' included.
            if tool.spec.source.hasPrefix("mcp:"), case .handled(let text, let failed)? = await deps.routeTeamsSend?(tool.spec.name, finalArgs, task.agentID, task.conversationID) {
                result = ToolResult.text(ToolCallID("approved"), name: tool.spec.name, text, isError: failed)
            } else {
                result = try await withTimeout(seconds: 120) { try await tool.invoke(finalArgs, context: context) }
            }
            failed = result.isError
            outcome = String(result.textContent.prefix(300))
        } catch {
            failed = true
            outcome = String(describing: error).prefix(300).description
        }
        log.info("Approved action \(action.tool) for \(approval.id): \(failed ? "failed" : "done") — \(outcome.prefix(120))", category: "runtime")
        _ = try? await updateApproval(approval.id) { a in
            a.actionResult = outcome
            a.actionFailed = failed
        }
    }

    /// Applies the user's decision to the card and resumes the waiting task with it.
    public func decideApproval(_ decision: ApprovalDecision, by author: MessageAuthor? = nil) async throws {
        guard let found = try await findApproval(decision.approvalID) else { throw ToolError.failed("That approval no longer exists.") }
        guard found.request.state == .pending else { throw ToolError.failed("This was already \(found.request.state.rawValue).") }
        let edited = decision.editedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = try await updateApproval(decision.approvalID) { a in
            a.decidedAt = Date()
            a.decidedBy = author
            a.comment = decision.comment?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            switch decision.verdict {
            case .approve, .approveRest:
                a.state = .approved
                if decision.verdict == .approveRest { a.approvedForRest = true }
                if let edited, !edited.isEmpty, edited != a.text { a.approvedText = edited }
            case .requestChanges: a.state = .changesRequested
            case .reject: a.state = .rejected
            }
        }
        // A card with its own action: Pennant acts on the decision itself; nobody is waiting on it.
        if updated.action != nil {
            switch updated.state {
            case .approved:
                await runApprovedAction(updated)
            case .changesRequested:
                // Back to the agent that wrote it, as a new message in the same conversation.
                if let task = try await deps.store.task(updated.taskID) {
                    let text = "Changes requested on \"\(updated.title)\" (approval_id \(updated.id)): \(updated.comment ?? "see the card"). Revise the draft and put it up for approval again with the same action."
                    _ = try? await submitUserMessage(agentID: task.agentID, conversationID: task.conversationID, text: text, attachments: [])
                }
            default:
                break
            }
            return
        }
        // Complete enough to act on even when the host restarted while waiting (then this becomes the tool result).
        let summary: String
        switch updated.state {
        case .approved:
            summary = "APPROVED (approval_id \(updated.id))\(updated.approvedText == nil ? "" : " with the user's edits"). Publish with this approval_id; the publishing tool uses exactly the approved text and images.\(updated.comment.map { " User's note: \($0)" } ?? "")\n\nApproved text:\n\(updated.finalText)"
        case .changesRequested: summary = "CHANGES REQUESTED (approval_id \(updated.id)): \(updated.comment ?? "see the card"). Revise and call request_approval again. Do not publish."
        case .rejected: summary = "REJECTED (approval_id \(updated.id))\(updated.comment.map { ": \($0)" } ?? ""). Do not publish."
        case .pending: summary = "Still pending. Do not publish."
        }
        // The task that asked has already ended (it posted the card and moved on): the decision goes back to the
        // agent as a new message in the same conversation, so it isn't lost.
        if let task = try await deps.store.task(updated.taskID), task.state != .waitingForUser, awaitingApproval[task.id] != updated.id {
            let text = "Decision on \"\(updated.title)\": " + summary
            _ = try await submitUserMessage(agentID: task.agentID, conversationID: task.conversationID, text: text, attachments: [])
            return
        }
        // Waiting, but for something else (a task limit, a question, or the card's call already gave up): the decision
        // is the reply, as a message the agent can read, not a tool result nobody is waiting for.
        if try await !isWaitingOn(approvalID: updated.id, taskID: updated.taskID) {
            try await deliverAnswer(taskID: updated.taskID, text: "Decision on \"\(updated.title)\": " + summary, alreadyAppended: false)
            return
        }
        // The card shows the decision; the tool result carries it to the model. No extra chat message.
        try await deliverAnswer(taskID: updated.taskID, text: summary, alreadyAppended: true)
    }

    /// Whether the task's current wait is this card: live, or (after a restart) its request_approval call still open.
    private func isWaitingOn(approvalID: String, taskID: TaskID) async throws -> Bool {
        if let live = awaitingApproval[taskID] { return live == approvalID }
        if pendingQuestions[taskID] != nil { return false }
        let records = try await deps.store.toolRecords(taskID: taskID)
        guard let last = records.last(where: { ["ask_user", "request_approval"].contains($0.call.name) }) else { return false }
        return last.call.name == "request_approval" && [.intended, .running].contains(last.status)
    }

    /// Report cards in the conversations of tasks from the last 30 days, newest first (at most 200).
    public func reports(now: Date = Date()) async throws -> [PostedReport] {
        let since = now.addingTimeInterval(-30 * 86_400)
        var seen = Set<ConversationID>()
        var out: [PostedReport] = []
        for task in try await deps.store.listTasks(agentID: nil, includeFinished: true) where task.updatedAt >= since {
            guard seen.insert(task.conversationID).inserted else { continue }
            for m in try await deps.store.messagesAfter(conversationID: task.conversationID, after: nil, limit: 4000) {
                for case .report(let r) in m.parts { out.append(PostedReport(report: r, agentID: m.agentID, conversationID: m.conversationID, messageID: m.id)) }
            }
        }
        return Array(out.sorted { $0.report.createdAt > $1.report.createdAt }.prefix(200))
    }

    /// Cards still waiting for the user in the conversations of tasks from the last 30 days, newest first.
    public func pendingApprovals(now: Date = Date()) async throws -> [PendingApproval] {
        let since = now.addingTimeInterval(-30 * 86_400)
        var seen = Set<ConversationID>()
        var out: [PendingApproval] = []
        for task in try await deps.store.listTasks(agentID: nil, includeFinished: true) where task.updatedAt >= since {
            guard seen.insert(task.conversationID).inserted else { continue }
            for m in try await deps.store.messagesAfter(conversationID: task.conversationID, after: nil, limit: 4000) {
                for case .approval(let a) in m.parts where a.state == .pending {
                    approvalMessages[a.id] = m.id
                    out.append(PendingApproval(request: a, agentID: m.agentID, conversationID: m.conversationID, messageID: m.id))
                }
            }
        }
        return out.sorted { $0.request.createdAt > $1.request.createdAt }
    }

    /// The approval and the message that carries it: from the cache, else by scanning the task's conversation.
    func findApproval(_ id: String) async throws -> (request: ApprovalRequest, messageID: MessageID)? {
        if let mid = approvalMessages[id], let m = try await deps.store.message(mid) {
            for case .approval(let a) in m.parts where a.id == id { return (a, mid) }
        }
        for task in try await deps.store.listTasks(agentID: nil, includeFinished: true).sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(50) {
            let messages = try await deps.store.messagesAfter(conversationID: task.conversationID, after: nil, limit: 4000)
            for m in messages.reversed() {
                for case .approval(let a) in m.parts where a.id == id {
                    approvalMessages[id] = m.id
                    return (a, m.id)
                }
            }
        }
        return nil
    }

    @discardableResult
    func updateApproval(_ id: String, _ change: (inout ApprovalRequest) -> Void) async throws -> ApprovalRequest {
        guard let found = try await findApproval(id), var message = try await deps.store.message(found.messageID) else { throw ToolError.failed("That approval no longer exists.") }
        var result = found.request
        message.parts = message.parts.map { part in
            guard case .approval(var a) = part, a.id == id else { return part }
            change(&a)
            result = a
            return .approval(a)
        }
        try await deps.store.updateMessage(message)
        await publish(.messageFinalized(message))
        await noteCardOutcome(result)
        return result
    }

    /// Posts a file card in the task's conversation. The bytes are already in the artifact store; the message
    /// carries only the reference, and the context builder shows it to the model as a text line.
    func shareFile(taskID: TaskID, _ ref: FileRef) async throws { try await postPart(taskID: taskID, .file(ref)) }

    /// A scheduled run of a skill that declares a report, finished with a long text reply and no report card: send it
    /// back once to post the card (short check-ins with nothing to report are left alone). Someone asking in a chat
    /// gets the answer in the chat.
    func reportNudge(task: TaskRecord, reply: String) async -> String? {
        guard Scheduler.isScheduledRun(task.objective), !reportsPosted.contains(task.id), !reportNudged.contains(task.id), reply.count > 600 else { return nil }
        for id in await deps.skillTracker.usedSkills(in: task.id) {
            guard let skill = try? await deps.store.skill(id), let report = skill.outputs?.report else { continue }
            reportNudged.insert(task.id)
            return "The \(skill.name) skill hands its results back as a report card, not a long message. Call post_report now (title \"\(report.title)\"\(report.sections.isEmpty ? "" : "; sections: " + report.sections.joined(separator: "; "))) with what you just wrote, then reply in one line."
        }
        return nil
    }

    /// Posts one card (a file, a report) as an assistant message in the task's conversation.
    func postPart(taskID: TaskID, _ part: ContentPart) async throws {
        if case .report = part { reportsPosted.insert(taskID) }
        guard let task = try await deps.store.task(taskID) else { throw TaskError.notFound(taskID) }
        let message = Message(conversationID: task.conversationID, agentID: task.agentID, taskID: taskID, role: .assistant, parts: [part])
        try await deps.store.appendMessage(message)
        await publish(.messageAppended(message))
        await publishConversation(task.conversationID, after: message)
    }

    func askUser(taskID: TaskID, question: String) async throws -> String {
        guard let task = try await deps.store.task(taskID) else { throw TaskError.notFound(taskID) }
        let message = Message(conversationID: task.conversationID, agentID: task.agentID, taskID: taskID, role: .assistant, parts: [.text(question)])
        try await deps.store.appendMessage(message)
        await publish(.messageAppended(message))
        await publishConversation(task.conversationID, after: message)
        try await transition(taskID, to: .waitingForUser, reason: "Waiting for your answer")
        await reportQuestion(task, question)
        await setAgentStatus(task.agentID, .waitingForUser, line: "Waiting for you")
        await deps.lease.forget(taskID: taskID)
        let answer: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                Task { self.registerQuestion(taskID, c) }
            }
        } onCancel: {
            Task { await self.cancelQuestion(taskID) }
        }
        try await transition(taskID, to: .running, reason: "User answered")
        await setAgentStatus(task.agentID, .thinking, line: task.title)
        return answer
    }

    func registerQuestion(_ id: TaskID, _ c: CheckedContinuation<String, Error>) {
        // Stopping: the cancel that would answer it may already have run.
        if stopping { return c.resume(throwing: CancellationError()) }
        if let old = pendingQuestions.removeValue(forKey: id) { old.resume(throwing: CancellationError()) }
        if let early = earlyAnswers.removeValue(forKey: id) { return c.resume(returning: early) }
        pendingQuestions[id] = c
    }

    func cancelQuestion(_ id: TaskID) {
        if let c = pendingQuestions.removeValue(forKey: id) { c.resume(throwing: CancellationError()) }
    }
}
