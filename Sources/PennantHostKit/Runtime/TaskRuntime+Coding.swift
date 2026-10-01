import PennantCore
import Foundation

/// Coding runs: a thread's work handed to a coding engine in a project folder, its permission requests shown as cards,
/// and (for Claude Code) its steps streamed back into the thread. The Pennant engine's side is in `+PennantEngine`.
extension TaskRuntime {
    // MARK: Claude Code runs

    /// Hands the conversation's new messages to Claude Code, streams its turns into the chat, and repeats while you
    /// keep writing during a run. Each conversation keeps one CLI session, resumed every time.
    func runCodingAgent(_ taskID: TaskID, agent: AgentProfile, setup: CodingSetup) async throws {
        guard let exe = ClaudeCodeEngine.locate() else { throw ClaudeCodeEngine.NotInstalled() }
        let engine = ClaudeCodeEngine(executable: exe)
        defer { codingToolNames[taskID] = nil; codingIdentity[taskID] = nil }
        var summary = ""
        var round = 0
        while true {
            try Task.checkCancellation()
            guard let task = try await deps.store.task(taskID), var conversation = try await deps.store.conversation(task.conversationID) else { throw TaskError.notFound(taskID) }
            let fresh = try await deps.store.messagesAfter(conversationID: conversation.id, after: conversation.engineCursor, limit: 500).filter { $0.role == .user }
            var prompt = fresh.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
            if prompt.isEmpty {
                guard round == 0 else { break }
                prompt = task.objective
            }
            if let last = fresh.last { conversation.engineCursor = last.id }
            let folder = conversation.workingDirectory ?? setup.folder ?? NSHomeDirectory()
            conversation.workingDirectory = folder
            try await deps.store.upsertConversation(conversation)
            await setAgentStatus(agent.id, .acting, line: "Coding in \((folder as NSString).lastPathComponent)")

            let conversationID = conversation.id, agentID = agent.id
            let (environment, identityNote) = await mintGitHubIdentity(setup.gitHubApp, taskID: taskID, agentID: agent.id)
            let instructions = [setup.instructions.trimmingCharacters(in: .whitespacesAndNewlines), identityNote].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let finish = try await engine.run(prompt: prompt, in: URL(fileURLWithPath: folder), sessionID: conversation.engineSessionID,
                                              mcpConfig: try permissionBridgeConfig(taskID: taskID),
                                              mode: conversation.engineMode ?? .acceptEdits, model: conversation.engineModel,
                                              instructions: instructions.isEmpty ? nil : instructions, environment: environment) { [weak self] event in
                await self?.applyCodingEvent(event, taskID: taskID, agentID: agentID, conversationID: conversationID)
            }
            try await recordCodingUsage(finish, taskID: taskID, agentID: agentID, conversationID: conversationID)
            if finish.isError { throw ToolError.failed(finish.text.isEmpty ? "Claude Code stopped with an error." : finish.text) }
            summary = finish.text
            round += 1
        }
        // The CLI can finish while one of its cards still waits (its permission request timed out and it moved on):
        // that card is moot, and a waiting task can't be completed ("waitingForUser -> completed").
        if let t = try await deps.store.task(taskID), t.state == .waitingForUser {
            cancelQuestion(taskID)
            try await transition(taskID, to: .running, reason: "The coding run finished without that answer")
        }
        try await complete(task: taskID, summary: summary)
    }

    /// What a coding run works with: the host's Coding settings, for a coding thread. Nil: not a coding run.
    struct CodingSetup: Sendable {
        var engine: CodingEngine
        /// The default project's folder, for a thread that has none of its own.
        var folder: String?
        var instructions: String
        var gitHubApp: GitHubAppIdentity?
    }

    func codingSetup(conversation: Conversation?) -> CodingSetup? {
        guard let engine = conversation?.engine else { return nil }
        let coding = deps.config.coding
        return CodingSetup(engine: engine, folder: coding?.defaultProject?.path, instructions: coding?.instructions ?? "", gitHubApp: coding?.gitHubApp)
    }

    /// The folder a coding request asks for: a project by name, or a folder's full path; nothing asked, the default
    /// project's.
    static func projectFolder(_ asked: String?, in coding: HostConfig.Coding) throws -> String {
        let names = coding.projects.map(\.name).joined(separator: ", ")
        guard let asked = asked?.trimmingCharacters(in: .whitespacesAndNewlines), !asked.isEmpty else {
            guard let project = coding.defaultProject else { throw ToolError.failed("Coding has no project folder yet: the owner adds one in Settings › Pennant › Coding.") }
            return project.path
        }
        if let project = coding.project(named: asked) { return project.path }
        if asked.hasPrefix("/") || asked.hasPrefix("~") { return (asked as NSString).expandingTildeInPath }
        throw ToolError.invalidArguments("There's no coding project called \(asked). Projects: \(names). Or pass a folder's full path.")
    }

    /// The environment a coding session acts on GitHub with, and what to tell it about that: its own App, with a
    /// fresh token (they last an hour); nothing when it has no App or GitHub wouldn't give it a token.
    func mintGitHubIdentity(_ app: GitHubAppIdentity?, taskID: TaskID, agentID: AgentID) async -> (environment: [String: String], note: String) {
        guard let app, let mint = deps.gitHubEnvironment else {
            codingIdentity[taskID] = nil
            return ([:], "")
        }
        do {
            let environment = try await mint(app)
            codingIdentity[taskID] = app.botLogin
            return (environment, "On GitHub you are \(app.botLogin), your own identity: git and gh are already signed in as it and commits are authored by it. Push, open and update pull requests normally; never sign in as anyone else or change the git identity.")
        } catch {
            codingIdentity[taskID] = nil
            await publish(.notice(level: .warning, agentID: agentID, text: "Coding couldn't act as \(app.botLogin): \(error)"))
            return ([:], "Your GitHub identity (\(app.botLogin)) isn't available right now (\(error)). Don't push or open pull requests; leave the work on a local branch and say so.")
        }
    }

    /// A coding CLI's tools that Pennant draws as cards (a choice card, a plan to approve) instead of tool activity.
    static let cardTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    private func applyCodingEvent(_ event: ClaudeCodeEngine.Event, taskID: TaskID, agentID: AgentID, conversationID: ConversationID) async {
        switch event {
        case .started(let sessionID, _):
            guard var c = try? await deps.store.conversation(conversationID), c.engineSessionID != sessionID else { return }
            c.engineSessionID = sessionID
            try? await deps.store.upsertConversation(c)
            await publish(.conversationUpserted(c))
        case .assistant(let pieces):
            var parts: [ContentPart] = []
            for piece in pieces {
                switch piece {
                case .text(let t): parts.append(.text(t))
                case .thinking(let t): parts.append(.reasoning(t))
                case .toolUse(let id, let name, let input):
                    codingToolNames[taskID, default: [:]][id] = name
                    // Questions and plans show as their own cards; the raw call would repeat them as JSON.
                    if Self.cardTools.contains(name) { continue }
                    parts.append(.toolCall(ToolCall(id: ToolCallID(id), name: name, arguments: input)))
                }
            }
            guard !parts.isEmpty else { return }
            let message = Message(conversationID: conversationID, agentID: agentID, taskID: taskID, role: .assistant, parts: parts)
            try? await deps.store.appendMessage(message)
            await publish(.messageAppended(message))
            await publishConversation(conversationID, after: message)
            _ = try? await updateTask(taskID) { $0.usage.steps += 1 }
        case .toolResults(let results):
            let names = codingToolNames[taskID] ?? [:]
            let parts: [ContentPart] = results.filter { !Self.cardTools.contains(names[$0.id] ?? "") }.map { r in
                .toolResult(ToolResult.text(ToolCallID(r.id), name: names[r.id] ?? "tool", String(r.text.prefix(20_000)), isError: r.isError))
            }
            guard !parts.isEmpty else { return }
            let message = Message(conversationID: conversationID, agentID: agentID, taskID: taskID, role: .tool, parts: parts)
            try? await deps.store.appendMessage(message)
            await publish(.messageAppended(message))
        case .finished:
            break
        }
    }

    /// The CLI's cost and tokens, on the task and in the usage ledger.
    private func recordCodingUsage(_ f: ClaudeCodeEngine.Finish, taskID: TaskID, agentID: AgentID, conversationID: ConversationID) async throws {
        let task = try await updateTask(taskID) {
            $0.usage.inputTokens += f.inputTokens
            $0.usage.outputTokens += f.outputTokens
            // A CLI run reports its turns summed; what it hadn't read before is what wasn't served from cache.
            $0.usage.newTokens += max(0, f.inputTokens - f.cachedInputTokens) + f.outputTokens
        }
        await publish(.taskUpserted(task))
        let record = UsageRecord(agentID: agentID, taskID: taskID, conversationID: conversationID, profileID: nil, modelLabel: "Claude Code",
                                 provider: "claude-code", model: "claude-code", inputTokens: f.inputTokens, cachedInputTokens: f.cachedInputTokens,
                                 outputTokens: f.outputTokens, cost: f.costUSD, estimated: false)
        try? await deps.store.appendUsage(record)
    }

    /// The MCP config that makes the CLI ask Pennant (through `pennant-host coder-permission`) before running
    /// anything its allow-list doesn't cover. Nil when this process isn't the host binary (tests).
    private func permissionBridgeConfig(taskID: TaskID) throws -> URL? {
        guard let host = Bundle.main.executablePath, (host as NSString).lastPathComponent == "pennant-host", let root = deps.dataRoot else { return nil }
        let dir = root.appendingPathComponent("coder", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mcp-\(taskID.rawValue).json")
        let config: [String: Any] = ["mcpServers": ["pennant": [
            "command": host,
            "args": ["coder-permission", "--task", taskID.rawValue, "--root", root.path, "--port", String(deps.config.api.port)],
        ]]]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]).write(to: url, options: .atomic)
        return url
    }

    /// Pennant's own tools a coding agent gets through its bridge: messaging people the Pennant way (from Pennant, to
    /// its contacts and group chats, with an approval card for anyone not allowed), not with the CLI's own plugins.
    static let coderPennantTools: Set<String> = ["send_message", "list_contacts"]

    /// Runs one of `coderPennantTools` for a running coding task, through the same checks as any agent's call.
    public func coderTool(taskID: TaskID, name: String, arguments: JSONValue) async throws -> (text: String, isError: Bool) {
        guard Self.coderPennantTools.contains(name) else { return ("\(name) isn't available to coding agents.", true) }
        guard let task = try await deps.store.task(taskID), let agent = try await deps.store.agent(task.agentID) else { throw TaskError.notFound(taskID) }
        let call = ToolCall(id: ToolCallID(UUID().uuidString), name: name, arguments: arguments)
        let (result, _) = try await executeTool(call, task: task, agent: agent)
        return (result.textContent, result.isError)
    }

    /// The CLI asks to use a tool its allow-list doesn't cover: show it as an approval card and answer with the
    /// decision. An edited command (the card's text) is what runs.
    public func coderPermission(taskID: TaskID, tool: String, input: JSONValue) async throws -> (allow: Bool, input: JSONValue?, message: String?, mode: CodingMode?) {
        guard let task = try await deps.store.task(taskID) else { throw TaskError.notFound(taskID) }
        // Questions aren't permissions: they become a card with the options to tap, and the answers go back as input.
        if tool == "AskUserQuestion", let question = ChoiceQuestion(claudeInput: input) {
            let answers = try await askChoices(taskID: taskID, question)
            guard case .object(var fields) = input else { return (true, input, nil, nil) }
            fields["answers"] = .object(answers.mapValues { .string($0) })
            return (true, .object(fields), nil, nil)
        }
        if tool == "ExitPlanMode" { return try await approvePlan(taskID: taskID, conversationID: task.conversationID, input: input) }
        let command = input["command"]?.stringValue
        // On GitHub a coding agent is its own identity or nobody: never the owner.
        let identity = codingIdentity[taskID]
        if tool == "Bash", let command, let refusal = GitHubGuard.refusal(command, identity: identity) {
            return (false, nil, refusal, nil)
        }
        // A person's sign-off (approving a PR, resolving a review thread) is never given with the owner's account.
        // Acting as its own App, an approval is the App's, under its own name.
        if tool == "Bash", identity == nil, let command, GitHubGuard.signsOff(command) {
            return (false, nil, "Refused: approving a pull request or resolving a review thread with the owner's GitHub account is their sign-off, never given as them. Approve as a GitHub App (its ghapp.sh), ask the reviewers through Pennant (send_message), or say who needs to approve.", nil)
        }
        // Only the owner's three sign-offs ask (publishing or email, deleting, spending); everything else runs.
        // "Ask for everything" (manual) means every command.
        let mode = (try? await deps.store.conversation(task.conversationID))?.engineMode
        var signOff: SignOff.Reason?
        if tool == "Bash" { signOff = SignOff.reason(command: command ?? "") }
        else if tool.hasPrefix("mcp__") { signOff = SignOff.reason(tool: String(tool.split(separator: "_", omittingEmptySubsequences: true).dropFirst(2).joined(separator: "_")), arguments: input) }
        if mode != .manual {
            if coderAllowsRest.contains(taskID) { return (true, input, nil, nil) }
            if signOff == nil { return (true, input, nil, nil) }
        }
        let folder = (try? await deps.store.conversation(task.conversationID))?.workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "the project"
        let title: String
        let text: String
        switch tool {
        case "Bash": title = signOff.map { "\($0.title): run a command" } ?? "Run a command"; text = command ?? ""
        case "Write": title = "Write a file"; text = Self.fileChange(input, ["content"])
        case "Edit": title = "Edit a file"; text = Self.fileChange(input, ["old_string", "new_string"])
        case "WebFetch": title = "Read a web page"; text = input["url"]?.stringValue ?? ""
        case "WebSearch": title = "Search the web"; text = input["query"]?.stringValue ?? ""
        default:
            title = "Use \(tool)"
            let data = (try? JSONEncoder().encode(input)) ?? Data()
            text = String(data: data, encoding: .utf8) ?? ""
        }
        var request = ApprovalRequest(taskID: taskID, title: title, destination: "Coding · \(folder)", text: text.isEmpty ? tool : text,
                                      notes: input["description"]?.stringValue ?? "")
        request.details = [ApprovalDetail(label: "Tool", value: tool)]
        request.approveLabel = "Allow"
        if mode != .manual { request.allowRestLabel = "Allow for the rest of this task" }
        let decided = try await requestApproval(taskID: taskID, request)
        switch decided.state {
        case .approved:
            if decided.approvedForRest == true { coderAllowsRest.insert(taskID) }
            // The command as approved (the card lets you edit it before it runs).
            if tool == "Bash", case .object(var fields) = input, let edited = decided.approvedText, edited != command {
                fields["command"] = .string(edited)
                return (true, .object(fields), nil, nil)
            }
            return (true, input, nil, nil)
        case .changesRequested:
            return (false, nil, "The user asked for a change instead: \(decided.comment ?? "no reason given"). Adjust and continue.", nil)
        default:
            return (false, nil, "The user declined\(decided.comment.map { ": \($0)" } ?? "."). Don't retry the same thing; find another way or ask.", nil)
        }
    }

    /// What a file write or edit changes, for its card: the file, then the text it writes or replaces.
    private static func fileChange(_ input: JSONValue, _ fields: [String]) -> String {
        let parts = fields.map { String((input[$0]?.stringValue ?? "").prefix(4000)) }
        return (input["file_path"]?.stringValue ?? "a file") + "\n\n" + parts.joined(separator: "\n\n— becomes —\n\n")
    }

    /// Claude Code's plan from plan mode, put to the owner (see `decidePlan`), answered the way its permission tool
    /// expects.
    private func approvePlan(taskID: TaskID, conversationID: ConversationID, input: JSONValue) async throws -> (allow: Bool, input: JSONValue?, message: String?, mode: CodingMode?) {
        let (decided, usual) = try await decidePlan(taskID: taskID, conversationID: conversationID, plan: input["plan"]?.stringValue ?? "")
        switch decided.state {
        case .approved:
            var approved = input
            if let edited = decided.approvedText, case .object(var fields) = input {
                fields["plan"] = .string(edited)
                approved = .object(fields)
            }
            return (true, approved, nil, usual)
        case .changesRequested:
            return (false, nil, "The user wants changes to the plan: \(decided.comment ?? "no reason given"). Revise the plan and present it again.", nil)
        default:
            return (false, nil, "The user rejected the plan\(decided.comment.map { ": \($0)" } ?? "."). Stop and ask what they want instead.", nil)
        }
    }

    /// The plan a coding run wrote in plan mode, as a card. Approved, the conversation leaves plan mode for the host's
    /// usual mode (returned with the decided card), and the run goes on to make the changes.
    func decidePlan(taskID: TaskID, conversationID: ConversationID, plan: String) async throws -> (decided: ApprovalRequest, usual: CodingMode) {
        let folder = (try? await deps.store.conversation(conversationID))?.workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "the project"
        var request = ApprovalRequest(taskID: taskID, title: "Approve the plan", destination: "Coding · \(folder)", text: plan, notes: "Approve to let it make these changes.")
        request.approveLabel = "Approve plan"
        let decided = try await requestApproval(taskID: taskID, request)
        let usual = deps.config.coding?.mode.flatMap { $0 == .plan ? nil : $0 } ?? .acceptEdits
        if decided.state == .approved, var c = try await deps.store.conversation(conversationID), c.engineMode == .plan {
            c.engineMode = usual
            try await deps.store.upsertConversation(c)
            await publish(.conversationUpserted(c))
        }
        return (decided, usual)
    }

    /// Posts a choice card and waits. The answers come from the card (structured) or as a typed reply, which then
    /// answers every question.
    private func askChoices(taskID: TaskID, _ question: ChoiceQuestion) async throws -> [String: String] {
        guard let task = try await deps.store.task(taskID) else { throw TaskError.notFound(taskID) }
        let message = Message(conversationID: task.conversationID, agentID: task.agentID, taskID: taskID, role: .assistant, parts: [.choices(question)])
        try await deps.store.appendMessage(message)
        await publish(.messageAppended(message))
        await publishConversation(task.conversationID, after: message)
        let first = question.items[0].question
        try await transition(taskID, to: .waitingForUser, reason: question.items.count == 1 ? first : "\(question.items.count) questions: \(first)")
        await setAgentStatus(task.agentID, .waitingForUser, line: "Waiting for your answer")
        await publish(.notice(level: .info, agentID: task.agentID, text: "\(first) is waiting for your answer."))
        openChoices[taskID] = question.id
        defer { openChoices[taskID] = nil }
        let typed = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                Task { self.registerQuestion(taskID, c) }
            }
        } onCancel: {
            Task { await self.cancelQuestion(taskID) }
        }
        let answers = choiceAnswers.removeValue(forKey: taskID) ?? Dictionary(question.items.map { ($0.question, typed) }, uniquingKeysWith: { a, _ in a })
        // The card shows what was chosen; a typed reply is the answer, not a new prompt for the next round.
        if var updated = try await deps.store.message(message.id) {
            updated.parts = updated.parts.map { part in
                guard case .choices(var q) = part, q.id == question.id else { return part }
                q.answers = answers
                return .choices(q)
            }
            try await deps.store.updateMessage(updated)
            await publish(.messageFinalized(updated))
        }
        if var c = try await deps.store.conversation(task.conversationID),
           let reply = try await deps.store.messagesAfter(conversationID: c.id, after: message.id, limit: 50).last(where: { $0.role == .user }) {
            c.engineCursor = reply.id
            try await deps.store.upsertConversation(c)
        }
        try await transition(taskID, to: .running, reason: "Answered")
        await setAgentStatus(task.agentID, .acting, line: task.title)
        return answers
    }

    /// The answers from a choice card.
    public func answerChoices(taskID: TaskID, questionID: String, answers: [String: String], by author: MessageAuthor? = nil) async throws {
        guard openChoices[taskID] == questionID else { throw ToolError.failed("Those questions were already answered or are no longer open.") }
        choiceAnswers[taskID] = answers
        // Record who answered on the card before the run picks the answers up.
        let messages = try await deps.store.listMessages(conversationID: try await deps.store.task(taskID)?.conversationID ?? ConversationID(""), before: nil, limit: 30)
        if var m = messages.first(where: { $0.parts.contains { if case .choices(let q) = $0 { return q.id == questionID }; return false } }) {
            m.parts = m.parts.map { part in
                guard case .choices(var q) = part, q.id == questionID else { return part }
                q.answeredBy = author
                return .choices(q)
            }
            try await deps.store.updateMessage(m)
        }
        try await deliverAnswer(taskID: taskID, text: answers.values.joined(separator: "; "), alreadyAppended: true)
    }

    func publishConversation(_ id: ConversationID, after message: Message) async {
        let created = message.createdAt
        guard let conversation = try? await deps.store.mutateConversation(id, { c in
            if c.updatedAt < created { c.updatedAt = created }
            // Something new in a closed thread brings it back (not a message that was already going when it closed).
            if let closed = c.closedAt, created > closed { c.closedAt = nil }
        }) else { return }
        await publish(.conversationUpserted(conversation))
    }

    static func title(from text: String) -> String {
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "…" : trimmed
    }
}
