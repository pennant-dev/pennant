import PennantCore
import Foundation

/// The Pennant chat and its threads. People talk to Pennant in one conversation; Pennant starts a thread for each
/// piece of work and steers it from the chat. What comes of every thread (its result, a failure, a question, a card)
/// is posted back to the chat as an update, so nobody has to go into the threads to keep up.
extension TaskRuntime {
    /// The agent people talk to: Pennant.
    func leadAgent() async -> AgentProfile? {
        let agents = (try? await deps.store.listAgents(includeRetired: false)) ?? []
        return agents.first { $0.name == HostService.defaultAgentName && $0.kind == .persistent } ?? agents.first { $0.kind == .persistent }
    }

    /// The Pennant chat, made the first time it's needed.
    @discardableResult
    public func ensureMainChat() async throws -> Conversation {
        if let id = mainChatID, let c = try await deps.store.conversation(id), c.isMain { return c }
        guard let lead = await leadAgent() else { throw ToolError.failed("Pennant isn't set up yet") }
        if let found = try await deps.store.listConversations(agentID: lead.id).first(where: \.isMain) {
            mainChatID = found.id
            return found
        }
        var chat = Conversation(agentID: lead.id, title: lead.name)
        chat.isMain = true
        try await deps.store.upsertConversation(chat)
        await publish(.conversationUpserted(chat))
        mainChatID = chat.id
        return chat
    }

    /// Whether a task runs in the Pennant chat.
    func inMainChat(_ task: TaskRecord) async -> Bool {
        if mainChatID == nil { _ = try? await ensureMainChat() }
        return task.conversationID == mainChatID
    }

    // MARK: Starting and steering threads

    /// Most threads the chat keeps going at once: more is a loop, not a plan.
    static let maxChatThreads = 8

    /// What a thread the chat starts may use before it stops and reports what it has: the host's limits, but no more
    /// than 50 steps, 2 hours and 2M new tokens. Threads do real work (a sign-up, a booking, a long search), so the cap
    /// leaves room for it, but not for wandering: at 100 steps two threads went far off their ask (one into the
    /// Keychain for tokens, one building by hand what it was asked to make in a service that wasn't connected). A
    /// check-in every 15 steps asks whether it's still on its ask. The owner can always say "keep going".
    static func chatThreadBudget(_ base: TaskBudget) -> TaskBudget {
        func capped(_ value: Int, _ cap: Int) -> Int { value > 0 ? min(value, cap) : cap }
        return TaskBudget(maxSteps: capped(base.maxSteps, 50), maxTokens: capped(base.maxTokens, 2_000_000),
                          maxDuration: base.maxDuration > 0 ? min(base.maxDuration, 2 * 3600) : 2 * 3600, maxDelegations: base.maxDelegations)
    }

    /// For a message the owner said out loud: the reply is read aloud to them.
    static let spokenNote = "They said this out loud, and your reply will be read aloud to them. If you're going to use a tool, first say a few words they'll hear straight away (\"Let me check.\"), in the same reply as the tool call. Answer the way you'd say it: one to three short sentences, no lists, links, headings or code, numbers and times as people say them. If it needs more than a quick answer, say you're on it and start a thread."

    /// Every so many steps, long work is told to take stock.
    static let checkInEvery = 15

    /// A Pennant chat reply still at work after this many steps is told to hand the rest to a thread: the owner is
    /// waiting on the chat.
    static let chatHandOffStep = 3
    /// Past this many steps a chat reply runs only what steers its threads, keeps memory or hands over a file.
    static let chatStepLimit = 5
    static let chatAlwaysAllowed: Set<String> = ThreadTools.names.union(["memory_search", "memory_remember", "remember_instruction", "share_file"])
    static let chatHandOffNote = "This is turning into more than a quick answer, and they're waiting on you. Hand the rest to a thread now: start_thread with what you've found so far and what's left to do, tell them in a line that it's on its way, and end your turn."

    /// A chat reply past its limit that still wants more than the chat does: Pennant starts the thread itself, rather
    /// than refusing the calls and hoping the model hands off (models often don't, and keep trying). The thread gets the
    /// owner's request and what was done so far. Returns the thread's title, or nil when none could start (too many
    /// going): the refusal then explains.
    func handOffChatWork(_ task: TaskRecord) async -> String? {
        let messages = (try? await deps.store.messagesAfter(conversationID: task.conversationID, after: nil, limit: 4000)) ?? []
        let asked = messages.filter { $0.taskID == task.id && $0.role == .user }.map(\.text).joined(separator: "\n\n")
        let request = asked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? task.objective : asked
        let done = ((try? await deps.store.toolRecords(taskID: task.id)) ?? [])
            .filter { $0.status == .succeeded || $0.status == .failed }
            .suffix(12)
            .map { "- \($0.call.name) \(Self.briefArguments($0.call.arguments)) → \($0.resultSummary.prefix(240).replacingOccurrences(of: "\n", with: " "))" }
        var instructions = "The owner asked in the chat:\n\(request)\n\nThe chat started on it and handed it to you because it needs more than a quick answer."
        if !done.isEmpty { instructions += " What it did so far (don't redo what worked):\n" + done.joined(separator: "\n") }
        instructions += "\n\nFinish it, and report back what the owner needs to know."
        let firstLine = request.split(separator: "\n").first.map(String.init) ?? task.title
        let title = String(firstLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        do {
            _ = try await startThread(from: task.id, title: title, instructions: instructions)
            return title
        } catch {
            log.warn("Couldn't hand the chat's work to a thread: \(error)", category: "runtime")
            return nil
        }
    }

    /// What the owner reads when the chat hands its work to a thread.
    static func handedOffLine(_ title: String) -> String {
        "This needs more than a quick answer, so I've started a thread on it: “\(title)”. I'll let you know what it finds."
    }

    /// A tool call's arguments in a few words: its command, query or address when it has one.
    static func briefArguments(_ arguments: JSONValue) -> String {
        for key in ["command", "query", "q", "url", "path", "name"] {
            if let v = arguments[key]?.stringValue { return "`\(v.prefix(120))`" }
        }
        let all = arguments.description
        return all == "{}" ? "" : String(all.prefix(120))
    }

    /// How a call the owner asked to change (on its card) is recorded.
    static let changesRequestedSummary = "Changes requested"

    /// What a check-in at its limit is told.
    static let heartbeatWrapUpNote = "This check-in is at its limit. Stop here and start nothing new: if something needs the owner soon, say it in a line; otherwise reply with only \(nothingToSay)."

    /// This many steps in a row with every call refused end the work.
    static let refusedStepLimit = 3
    /// What the owner sees when that happens.
    static let refusedStopNote = "I stopped: what I kept trying wasn't allowed here. Ask me again, or tell me how you'd like it done."

    /// Whether every one of a step's tool calls was refused. Its records are the task's latest, in the order they ran.
    /// The owner asking for changes on a card isn't a dead end: the work revises and asks again.
    func everyCallRefused(_ taskID: TaskID, calls: [ToolCall]) async -> Bool {
        let records = (try? await deps.store.toolRecords(taskID: taskID)) ?? []
        guard !calls.isEmpty, records.count >= calls.count else { return false }
        let step = records.suffix(calls.count)
        guard step.map(\.call.id.rawValue).sorted() == calls.map(\.id.rawValue).sorted() else { return false }
        return step.allSatisfy { $0.status == .denied && $0.resultSummary != Self.changesRequestedSummary }
    }

    static func checkInNote(steps: Int) -> String {
        "Check-in, \(steps) steps in: take stock before going on. Are you still doing what you were asked, the way you were asked? If something it needs isn't there (a connection, an account, a credential, access you weren't given), don't look for a way around it or build a substitute: stop and say what's missing. If your last few steps were more of the same, another one won't change the answer: finish now with what you have, or say what's blocking you."
    }

    /// Helpers still working when their parent wraps up: collected first, so finishing doesn't stop them mid-change.
    static func collectHelpersNote(_ helpers: [TaskRecord]) -> String {
        let list = helpers.map { "“\($0.title)” (task \($0.id.rawValue))" }.joined(separator: ", ")
        return "Before that, collect your helpers still at work with await_task (and nothing else): \(list). Finishing without them would stop them partway."
    }

    static func helperWrapUpNote(_ why: String) -> String {
        "You've \(why), the limit for this piece of work. Stop here and start nothing new: report what you've found or done so far and what's still open, for the task that asked you."
    }

    static func wrapUpNote(_ why: String) -> String {
        "You've \(why), the limit for this piece of work. Stop here and start nothing new: tell the owner what you've found or done so far, what's still open, and that you can keep going if they want."
    }

    /// Starts a thread for a piece of work: Pennant, in a conversation of its own under the chat, with the instructions
    /// as its first message. Returns at once; the thread's result comes back to the chat as an update.
    func startThread(from taskID: TaskID, title: String, instructions: String) async throws -> (TaskID, ConversationID) {
        guard let asker = try await deps.store.task(taskID), await inMainChat(asker) else {
            throw ToolError.failed("Threads are started from the Pennant chat. Here, do the work yourself, or hand a piece to a helper with delegate_task.")
        }
        // The chat's own threads: a run one of them started inside it is part of that thread's work.
        let chat = try await ensureMainChat().id
        let going = try await chatThreads().filter { t in
            (t.conversation.parentID == nil || t.conversation.parentID == chat) && (t.task.map { !$0.state.isTerminal } ?? false)
        }
        guard going.count < Self.maxChatThreads else {
            throw ToolError.failed("\(going.count) threads are already working. Wait for one to finish, steer one with message_thread, or stop one with stop_thread.")
        }
        let name = (try? await deps.store.agent(asker.agentID))?.name ?? HostService.defaultAgentName
        let (_, threadID, threadTask) = try await submitUserMessage(agentID: asker.agentID, conversationID: nil, text: instructions, attachments: [],
                                                                   author: MessageAuthor(id: PersonID("pennant"), name: name), requestedBy: taskID)
        boardCache = nil
        try await updateTask(threadTask) { $0.budget = Self.chatThreadBudget(deps.config.defaultBudget) }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty, let renamed = try await deps.store.mutateConversation(threadID, { $0.title = String(clean.prefix(80)) }) {
            await publish(.conversationUpserted(renamed))
        }
        return (threadTask, threadID)
    }

    /// Sends a message into a thread from the chat: the answer to its question, a change of plan, or more work for one
    /// that finished. Says what the thread will do with it.
    func messageThread(from taskID: TaskID, thread ref: String, text: String) async throws -> String {
        let thread = try await resolveThread(ref)
        let before = try await deps.store.listTasks(agentID: nil, includeFinished: false).first { $0.conversationID == thread.id && !$0.state.isTerminal }
        let name = (try? await deps.store.agent(thread.agentID))?.name ?? HostService.defaultAgentName
        let (_, _, sent) = try await submitUserMessage(agentID: thread.agentID, conversationID: thread.id, text: text, attachments: [],
                                                      author: MessageAuthor(id: PersonID("pennant"), name: name), requestedBy: before == nil ? taskID : nil)
        // Picked back up: a fresh allowance of the same size.
        if before == nil { try await updateTask(sent) { $0.budget = Self.chatThreadBudget(deps.config.defaultBudget) } }
        let label = "“\(thread.title)” (thread \(thread.id.rawValue.prefix(8)))"
        switch before?.state {
        case .waitingForUser?: return "Sent to \(label). It was waiting for an answer and goes on with this one."
        case .some: return "Sent to \(label). It's working and reads this on its next step."
        case nil: return "Sent to \(label). It had finished, so it picks the work back up; its result comes back here."
        }
    }

    /// Where a thread stands and its latest messages, for answering "how's it going?" without the owner opening it.
    func readThread(_ ref: String, limit: Int) async throws -> String {
        let thread = try await resolveThread(ref)
        let tasks = try await deps.store.listTasks(agentID: nil, includeFinished: true).filter { $0.conversationID == thread.id }
        var out = "Thread “\(thread.title)” (thread \(thread.id.rawValue.prefix(8)))"
        if let latest = tasks.max(by: { $0.createdAt < $1.createdAt }) {
            out += ": \(Self.stateWords(latest))"
        }
        out += "\n"
        let messages = try await deps.store.listMessages(conversationID: thread.id, before: nil, limit: max(4, min(limit, 60))).reversed()
        for m in messages {
            let line: String
            switch m.role {
            case .user: line = "Asked: " + m.text
            case .assistant:
                var bits: [String] = []
                if !m.text.isEmpty { bits.append(m.text) }
                for part in m.parts {
                    switch part {
                    case .toolCall(let c): bits.append("→ \(c.name)")
                    case .approval(let a): bits.append("[card “\(a.title)” — \(a.state.rawValue)]")
                    case .report(let r): bits.append("[report] " + r.markdown)
                    case .file(let f): bits.append("[file \(f.fileName)]")
                    case .choices(let q): bits.append("[questions] " + q.summary)
                    default: break
                    }
                }
                line = bits.joined(separator: " ")
            case .tool:
                let r = m.parts.compactMap { if case .toolResult(let r) = $0 { return r } else { return nil } }.first
                line = "Result (\(r?.name ?? "tool")): " + (r?.textContent ?? "")
            case .system: line = "Note: " + m.text
            }
            let flat = line.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if !flat.isEmpty { out += "- " + (flat.count > 400 ? String(flat.prefix(400)) + "…" : flat) + "\n" }
        }
        return out
    }

    /// Stops the work going on in a thread, and in the threads it started (a skill run in Claude Code, a coding run),
    /// which would otherwise carry on out of sight. What it already did stays done.
    func stopThread(_ ref: String) async throws -> String {
        let thread = try await resolveThread(ref)
        let conversations = try await deps.store.listConversations(agentID: thread.agentID)
        var threads: Set<ConversationID> = [thread.id]
        var frontier: [ConversationID] = [thread.id]
        while let next = frontier.popLast() {
            for c in conversations where c.parentID == next && !threads.contains(c.id) {
                threads.insert(c.id)
                frontier.append(c.id)
            }
        }
        let open = try await deps.store.listTasks(agentID: nil, includeFinished: false).filter { threads.contains($0.conversationID) && !$0.state.isTerminal }
        guard !open.isEmpty else { return "“\(thread.title)” has nothing going; there's nothing to stop." }
        for task in open { try await cancelTask(task.id, reason: "Stopped from the Pennant chat") }
        return "Stopped “\(thread.title)”. What it already did stays done."
    }

    /// A thread by its id (or the first characters of it) or its title.
    func resolveThread(_ ref: String) async throws -> Conversation {
        let key = ref.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "“”\""))
        guard !key.isEmpty else { throw ToolError.invalidArguments("Name the thread: its id from the work board, or its title.") }
        if let exact = try await deps.store.conversation(ConversationID(key)), !exact.isMain { return exact }
        let threads = try await chatThreads(includeClosed: true).map(\.conversation)
        if let byID = threads.first(where: { $0.id.rawValue.lowercased().hasPrefix(key.lowercased()) && key.count >= 6 }) { return byID }
        if let byTitle = threads.first(where: { $0.title.caseInsensitiveCompare(key) == .orderedSame })
            ?? threads.first(where: { $0.title.localizedCaseInsensitiveContains(key) }) { return byTitle }
        // A helper's conversation, by its id: it isn't one of the chat's threads, but work can still be passed to it.
        if key.count >= 6, let open = try? await deps.store.listTasks(agentID: nil, includeFinished: false),
           let task = open.first(where: { $0.conversationID.rawValue.lowercased().hasPrefix(key.lowercased()) }),
           let conversation = try await deps.store.conversation(task.conversationID), !conversation.isMain { return conversation }
        throw ToolError.invalidArguments("No thread \(key). The work board in your context lists them with their ids.")
    }

    // MARK: Heartbeat

    /// How a heartbeat's turn starts its objective (the brief follows).
    static let heartbeatLead = "[Heartbeat] "

    static func isHeartbeat(_ task: TaskRecord) -> Bool { task.objective.hasPrefix(heartbeatLead) }

    /// A heartbeat found something to look at: Pennant takes one turn in its chat, on its own, to deal with it or tell
    /// the owner. Nothing to do or say leaves no trace (see `complete`). Nil when the chat is busy.
    func heartbeatTurn(brief: String) async throws -> TaskID? {
        let chat = try await ensureMainChat()
        let busy = try await deps.store.listTasks(agentID: nil, includeFinished: false).contains { $0.conversationID == chat.id && !$0.state.isTerminal }
        guard !busy else { return nil }
        let objective = Self.heartbeatLead + """
        You're checking in on your own; the owner didn't write. Since your last look:
        \(brief)
        Decide what, if anything, to do about it. Nudge or stop work that's stuck (message_thread, stop_thread), or \
        tell the owner something they'd want to know now, in a line or two, the way you'd mention it in passing. \
        What the owner asked for on each check-in, do with the tools you have, and tell them only what needs them \
        soon, a line each; leave the routine out. \
        Don't remind them of something you already told them today, and keep no notes for yourself in the chat: they \
        read everything there, and the next check-in is told when this one was. If nothing needs doing or saying, \
        reply with only \(Self.nothingToSay), no other words or punctuation. They won't see this check.
        """
        let task = TaskRecord(agentID: chat.agentID, conversationID: chat.id, title: "Checking in", objective: objective, completionCriteria: "",
                              budget: TaskBudget(maxSteps: 8, maxTokens: 200_000, maxDuration: 600, maxDelegations: 0))
        try await deps.store.upsertTask(task)
        await publish(.taskUpserted(task))
        await schedule()
        return task.id
    }

    /// A heartbeat turn that had nothing to say leaves nothing in the chat: not its "(nothing)", and not the look it
    /// took (its thinking, its tool calls and their results; the calls stay in the tool records). Cards, updates and
    /// files it made stay.
    func clearQuietHeartbeat(_ task: TaskRecord, reply: String) async {
        guard Self.isHeartbeat(task), Self.saysNothing(reply) else { return }
        let messages = (try? await deps.store.messages(taskID: task.id)) ?? []
        let trace = messages.filter { m in
            m.parts.allSatisfy { part in
                switch part {
                case .text, .reasoning, .toolCall, .toolResult: return true
                default: return false
                }
            }
        }.map(\.id)
        if !trace.isEmpty { await removeMessages(trace, in: task.conversationID) }
    }

    /// Check-ins of the last week that said nothing but left a trace (finished before the trace was cleared, or under
    /// an older way of saying nothing): cleared when the host starts.
    func clearQuietHeartbeats(since: Date = Date().addingTimeInterval(-7 * 86_400)) async {
        guard let chat = try? await ensureMainChat() else { return }
        let done = ((try? await deps.store.listTasks(agentID: nil, includeFinished: true)) ?? [])
            .filter { $0.conversationID == chat.id && $0.state == .completed && $0.createdAt > since && Self.isHeartbeat($0) }
        for task in done { await clearQuietHeartbeat(task, reply: task.resultSummary ?? "") }
    }

    /// Whether the work a goal job runs is waiting on the owner: a question or a card in the goal's thread, or in its
    /// latest session's.
    func goalWaitsOnOwner(_ job: ScheduledJob) async -> Bool {
        var places = Set<ConversationID>()
        if let c = job.conversationID { places.insert(c) }
        if let goalID = job.goalID, let goal = (await deps.goals?() ?? []).first(where: { $0.id == goalID }), let c = goal.conversationID { places.insert(c) }
        if let last = job.lastTaskID, let task = try? await deps.store.task(last) { places.insert(task.conversationID) }
        guard !places.isEmpty else { return false }
        let open = (try? await deps.store.listTasks(agentID: nil, includeFinished: false)) ?? []
        if open.contains(where: { places.contains($0.conversationID) && $0.state == .waitingForUser }) { return true }
        let cards = (try? await pendingApprovals()) ?? []
        return cards.contains { places.contains($0.conversationID) }
    }

    /// What a heartbeat should look at in Pennant's threads: work that stopped moving, and questions or drafts left
    /// waiting on the owner for hours. Each comes with a key, so the same thing isn't raised on every beat.
    func heartbeatSignals(now: Date = Date()) async -> [(key: String, text: String)] {
        var out: [(key: String, text: String)] = []
        let chat = try? await ensureMainChat()
        let open = (try? await deps.store.listTasks(agentID: nil, includeFinished: false)) ?? []
        let ago = RelativeDateTimeFormatter()
        for task in open where task.parentTaskID == nil && task.conversationID != chat?.id {
            guard let thread = try? await deps.store.conversation(task.conversationID), !thread.isMain else { continue }
            let label = "“\(thread.title)” (thread \(thread.id.rawValue.prefix(8)))"
            switch task.state {
            case .running, .waitingForTool:
                if now.timeIntervalSince(task.updatedAt) > Self.stalledAfter {
                    out.append(("stalled:\(task.id.rawValue)", "\(label) hasn't moved since \(ago.localizedString(for: task.updatedAt, relativeTo: now)) (\(task.usage.steps) steps so far)."))
                }
            case .waitingForUser:
                if now.timeIntervalSince(task.updatedAt) > Self.waitingTooLong {
                    out.append(("waiting:\(task.id.rawValue)", "\(label) has waited on the owner since \(ago.localizedString(for: task.updatedAt, relativeTo: now)): \(Self.stateWords(task))."))
                }
            default:
                break
            }
        }
        return out
    }

    /// Work with no step for this long has stopped moving.
    static let stalledAfter: TimeInterval = 20 * 60
    /// A question or draft left this long is worth a mention.
    static let waitingTooLong: TimeInterval = 6 * 3600

    // MARK: The work board

    /// A thread and its latest task.
    struct ChatThread {
        var conversation: Conversation
        var task: TaskRecord?
        var cards: Int
    }

    /// Pennant's threads: every conversation of the lead agent but the chat, newest activity first. A thread started
    /// inside another (a skill run in Claude Code, a coding run) counts while it has work going, so nothing runs unseen.
    func chatThreads(includeClosed: Bool = false, since: Date? = nil) async throws -> [ChatThread] {
        guard let lead = await leadAgent() else { return [] }
        let chat = try await ensureMainChat().id
        let tasks = try await deps.store.listTasks(agentID: nil, includeFinished: true)
        let busy = Set(tasks.filter { !$0.state.isTerminal }.map(\.conversationID))
        let conversations = try await deps.store.listConversations(agentID: lead.id).filter { c in
            !c.isMain && (c.parentID == nil || c.parentID == chat || busy.contains(c.id)) && (includeClosed || !c.isClosed) && (since.map { c.updatedAt >= $0 } ?? true)
        }
        let ids = Set(conversations.map(\.id))
        var latest: [ConversationID: TaskRecord] = [:]
        for t in tasks where ids.contains(t.conversationID) && t.parentTaskID == nil {
            if let have = latest[t.conversationID], have.createdAt >= t.createdAt { continue }
            latest[t.conversationID] = t
        }
        let pending = (try? await pendingApprovals()) ?? []
        return conversations.map { c in
            ChatThread(conversation: c, task: latest[c.id], cards: pending.filter { $0.conversationID == c.id }.count)
        }
    }

    /// The work board, rebuilt at most once a minute: a turn reads it on every step.
    func currentWorkBoard(now: Date = Date()) async -> String {
        if let cache = boardCache, now.timeIntervalSince(cache.at) < 60 { return cache.text }
        let text = await workBoard(now: now)
        boardCache = (now, text)
        return text
    }

    /// The threads Pennant reads at the top of every turn in the chat: what waits on the owner, what's working,
    /// what finished lately.
    func workBoard(now: Date = Date()) async -> String {
        let threads = (try? await chatThreads(since: now.addingTimeInterval(-3 * 86_400))) ?? []
        func rank(_ t: ChatThread) -> Int {
            if t.cards > 0 || t.task?.state == .waitingForUser { return 0 }
            if let s = t.task?.state, !s.isTerminal { return 1 }
            return 2
        }
        let shown = threads.sorted { (rank($0), $1.conversation.updatedAt) < (rank($1), $0.conversation.updatedAt) }.prefix(15)
        let header = "## What's going on (your notes, for answering in your own words; the ids are for your thread tools)\n"
        guard !shown.isEmpty else { return header + "Nothing is going on in the background right now.\n" }
        let ago = RelativeDateTimeFormatter()
        var s = header
        for t in shown {
            var line = "- “\(t.conversation.title)” (thread \(t.conversation.id.rawValue.prefix(8))): "
            line += t.task.map { Self.stateWords($0) } ?? "nothing started yet"
            if t.cards > 0, t.task?.state != .waitingForUser { line += "; \(t.cards == 1 ? "a draft" : "\(t.cards) drafts") waiting for their OK" }
            if let up = t.conversation.parentID, up != mainChatID, let parent = try? await deps.store.conversation(up) {
                line += "; started by the thread “\(parent.title)” (stopping that one stops this too)"
            }
            line += " (\(ago.localizedString(for: t.conversation.updatedAt, relativeTo: now)))"
            s += line + "\n"
        }
        if threads.count > shown.count { s += "(and \(threads.count - shown.count) more; read_thread finds any by its title)\n" }
        return s
    }

    /// Where a thread's work stands, in words.
    static func stateWords(_ task: TaskRecord) -> String {
        switch task.state {
        case .waitingForUser:
            let reason = task.stateReason
            if reason.hasPrefix(Self.approvalReasonLead) { return "waiting for their OK on “\(reason.dropFirst(Self.approvalReasonLead.count))”" }
            if reason.hasPrefix("Waiting for your answer") { return "waiting for their answer" }
            return "waiting on them: \(reason)"
        case .running, .waitingForTool, .waitingForDesktop: return "working on it"
        case .queued: return "about to start"
        case .paused: return "paused (\(task.stateReason))"
        case .completed: return "done" + (task.resultSummary.map { ": " + Conversation.previewLine($0, limit: 200) } ?? "")
        case .failed: return "didn't finish: \(task.stateReason)"
        case .cancelled: return "stopped"
        }
    }

    static let approvalReasonLead = "Waiting for your approval: "

    /// The task's last message is news for the owner in the Pennant chat: work the chat asked for, a scheduled run, or
    /// a goal's session.
    func reportsToChat(_ task: TaskRecord) async -> Bool {
        guard task.parentTaskID == nil, await threadForUpdates(task) != nil else { return false }
        if await askedByChat(task) || Scheduler.isScheduledRun(task.objective) { return true }
        let goals = await deps.goals?() ?? []
        return goals.contains { $0.conversationID == task.conversationID }
    }

    // MARK: Updates to the chat

    /// The thread a task's news belongs to, when it should reach the chat: any work outside the chat, except the
    /// steps inside a thread another thread started (those report to that thread).
    func threadForUpdates(_ task: TaskRecord) async -> Conversation? {
        // A helper's news (a card it put up) is its parent's thread's.
        var task = task
        for _ in 0 ..< 4 {
            guard let up = task.parentTaskID, let parent = try? await deps.store.task(up) else { break }
            task = parent
        }
        guard let chat = try? await ensureMainChat(), task.conversationID != chat.id,
              let thread = try? await deps.store.conversation(task.conversationID) else { return nil }
        guard thread.parentID == nil || thread.parentID == chat.id else { return nil }
        return thread
    }

    /// Posts an update in the chat, under what Pennant says about it when it says something.
    func postUpdate(_ update: WorkUpdate, saying words: String? = nil) async {
        guard let chat = try? await ensureMainChat() else { return }
        let parts: [ContentPart] = words.map { [.text($0), .update(update)] } ?? [.update(update)]
        let message = Message(conversationID: chat.id, agentID: chat.agentID, role: .assistant, parts: parts)
        do {
            try await deps.store.appendMessage(message)
        } catch {
            log.warn("Couldn't post an update to the Pennant chat: \(error)", category: "runtime")
            return
        }
        if let id = update.approvalID { updateMessages[id] = message.id }
        boardCache = nil
        await publish(.messageAppended(message))
        await publishConversation(chat.id, after: message)
    }

    /// A plugin's note in the Pennant chat, under its name.
    public func postPluginNote(from plugin: String, _ text: String) async {
        guard let chat = try? await ensureMainChat() else { return }
        let message = Message(conversationID: chat.id, agentID: chat.agentID, role: .assistant, parts: [.text("**\(plugin):** \(text)")])
        do {
            try await deps.store.appendMessage(message)
        } catch {
            log.warn("Couldn't post \(plugin)'s note to the Pennant chat: \(error)", category: "plugins")
            return
        }
        await publish(.messageAppended(message))
        await publishConversation(chat.id, after: message)
    }

    /// A thread's task ended: its result (or why it failed) goes to the chat when the chat asked for the work, when it
    /// failed, or when it made something to look at. A quiet scheduled run, a chat with someone that ended in a reply,
    /// and work stopped on purpose stay where they are.
    func reportFinished(_ task: TaskRecord) async {
        guard task.parentTaskID == nil, task.state == .completed || task.state == .failed,
              let thread = await threadForUpdates(task) else { return }
        let askedByChat = await askedByChat(task)
        if task.state == .completed, !askedByChat {
            let messages = (try? await deps.store.messagesAfter(conversationID: task.conversationID, after: nil, limit: 4000)) ?? []
            let made = messages.contains { m in
                m.taskID == task.id && m.parts.contains { if case .report = $0 { return true }; if case .file = $0 { return true }; return false }
            }
            guard made else { return }
        }
        let text: String
        if task.state == .failed {
            text = task.stateReason
        } else {
            let last = (try? await deps.store.listMessages(conversationID: task.conversationID, before: nil, limit: 40))?
                .first { $0.taskID == task.id && $0.role == .assistant && !$0.text.isEmpty }?.text
            text = (task.resultSummary?.nilIfEmpty ?? last ?? "Done.")
        }
        var update = WorkUpdate(kind: task.state == .failed ? .failed : .finished, threadID: thread.id, taskID: task.id, thread: thread.title, text: text)
        // Pennant tells them in its own words, or nothing when they already know.
        Task { [self] in
            switch await self.wordUpdate(update) {
            case .say(let words)?: await self.postUpdate(update, saying: words)
            case .quiet?:
                update.silent = true
                await self.postUpdate(update)
            case nil: await self.postUpdate(update)
            }
        }
    }

    /// The thread was started (or picked back up) by the chat.
    func askedByChat(_ task: TaskRecord) async -> Bool {
        guard let asker = task.requestedByTaskID, let record = try? await deps.store.task(asker) else { return false }
        return await inMainChat(record)
    }

    /// A thread stopped to ask the owner something.
    ///
    /// Pennant asks them in the chat, in its own words, with the thread's question kept under its message as where it
    /// came from. When no model words it in time, the question goes up as the thread put it.
    func reportQuestion(_ task: TaskRecord, _ question: String) async {
        guard let thread = await threadForUpdates(task) else { return }
        let update = WorkUpdate(kind: .question, threadID: thread.id, taskID: task.id, thread: thread.title, text: question)
        // Worded on the side: the thread goes on to wait for the answer meanwhile.
        Task { [self] in
            if case .say(let words)? = await self.wordUpdate(update) { await self.postUpdate(update, saying: words) } else { await self.postUpdate(update) }
        }
    }

    /// What Pennant makes of news from its work: words for the owner, or nothing to tell them.
    enum Wording: Equatable { case say(String), quiet }

    /// News from a thread as Pennant would put it in the chat, from the chat so far and in its voice: a question asked,
    /// a result told (or kept to itself when they already know), a failure explained, a draft introduced. Nil when no
    /// model answers in time.
    func wordUpdate(_ update: WorkUpdate, detail: String = "") async -> Wording? {
        guard let lead = await leadAgent(), let chat = try? await ensureMainChat() else { return nil }
        let recent = ((try? await deps.store.listMessages(conversationID: chat.id, before: nil, limit: 16)) ?? []).reversed()
        var transcript = ""
        for m in recent {
            let words: String
            switch m.role {
            case .user: words = "Owner: " + m.text
            case .assistant:
                words = "You: " + m.parts.compactMap { p -> String? in
                    if case .update(let u) = p { return u.modelLine }
                    return p.plainText
                }.joined(separator: " ")
            default: continue
            }
            let flat = words.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if flat.count > 8 { transcript += String(flat.prefix(500)) + "\n" }
        }
        var system = "You are \(lead.name), the owner's assistant, writing in your chat with them.\n"
        if !lead.style.isEmpty { system += "Voice and manner: \(lead.style)\n" }
        system += "\n" + ContextBuilder.voiceRules + "\n\n" + Self.newsRules(update.kind)
        let work = "“\(update.thread)”"
        let news: String
        switch update.kind {
        case .question: news = "Something you're working on (\(work)) needs their answer. What it asks:\n\(update.text)"
        case .finished: news = "Something you were doing in the background (\(work)) just finished. What it reported:\n\(update.text)"
        case .failed: news = "Something you were doing in the background (\(work)) couldn't finish. Why:\n\(update.text)"
        case .approval: news = "A draft from your work on \(work) is ready for their OK: “\(update.text)”.\n\(detail)"
        }
        let ask = (transcript.isEmpty ? "" : "The chat so far, latest last:\n\(transcript)\n") + news + "\n\nWrite your message to them."
        for choice in await modelChoices(for: lead) {
            let request = InferenceRequest(messages: [.system(system), .user(ask)], maxOutputTokens: 1500, temperature: 0.4, disableTools: true)
            guard let reply = try? await withTimeout(seconds: 45, { try await choice.provider.complete(request).text }) else { continue }
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if Self.saysNothing(text) { return update.kind == .finished ? .quiet : nil }
            return .say(text)
        }
        return nil
    }

    /// The reply for "nothing to tell them".
    static let nothingToSay = "(nothing)"

    /// Whether a reply is the "nothing to say" marker. Models don't always write it exactly ("(noting nothing)",
    /// "(nnothing)", "(none)"), so a short aside about nothing counts too; one with news in it ("(nothing urgent, but
    /// Dana replied)") doesn't. Nor do notes it keeps for itself ("(noting the 14:55 check-in: no new mail)"), alone or
    /// ahead of the marker, or any asides it ends with the marker: they aren't for the owner, and once one stays in the
    /// chat every check-in after it copies it.
    static func saysNothing(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: strayMarks)
        if isNothingMarker(t) { return true }
        let (asides, rest) = bracketedAsides(t)
        let left = rest.trimmingCharacters(in: strayMarks)
        // Everything in brackets and the last word the marker: what came before it was said to itself.
        if left.isEmpty, asides.count > 1, let last = asides.last, isNothingMarker("(\(last))") { return true }
        func isNote(_ aside: String) -> Bool {
            let a = aside.trimmingCharacters(in: .whitespacesAndNewlines)
            return a.hasPrefix("noting ") || a.hasPrefix("note:") || a.hasPrefix("note to self")
        }
        guard asides.contains(where: isNote) else { return false }
        return asides.allSatisfy { isNote($0) || isNothingMarker("(\($0))") } && (left.isEmpty || isNothingMarker(left))
    }

    /// Stray punctuation around the marker ("(nothing):", copied with the colon that followed it) doesn't count.
    private static let strayMarks = CharacterSet(charactersIn: " .,:;!?\n\"'`*_~-—")

    private static func isNothingMarker(_ t: String) -> Bool {
        let inner = t.trimmingCharacters(in: CharacterSet(charactersIn: "()[] .!"))
        if ["nothing", "none", "nothing to say", "nothing to report", "nothing new", "nothing needs you", "all quiet"].contains(inner) { return true }
        let words = inner.split(whereSeparator: \.isWhitespace)
        guard t.hasPrefix("("), t.hasSuffix(")") else { return false }
        return words.count <= 3 && !inner.contains(",") && (inner.contains("noth") || inner == "none")
    }

    /// A reply's asides in round brackets, and what's written outside them.
    private static func bracketedAsides(_ text: String) -> (asides: [String], rest: String) {
        var asides: [String] = [], rest = "", current = "", depth = 0
        for ch in text {
            if ch == "(" {
                if depth > 0 { current.append(ch) }
                depth += 1
            } else if ch == ")", depth > 0 {
                depth -= 1
                if depth == 0 { asides.append(current); current = "" } else { current.append(ch) }
            } else if depth > 0 {
                current.append(ch)
            } else {
                rest.append(ch)
            }
        }
        // An aside left open is written out, not set aside.
        if depth > 0 { rest += "(" + current }
        return (asides, rest)
    }

    /// What Pennant does with each kind of news.
    static func newsRules(_ kind: WorkUpdate.Kind) -> String {
        let task: String
        switch kind {
        case .question:
            task = """
            Something you're working on needs their answer. Ask them yourself, as one short chat message: only what they \
            need to decide, with the one or two facts that matter for it. Several questions: number them, a line each. \
            Don't say you were asked to ask.
            """
        case .finished:
            task = """
            Some work of yours just finished. Decide whether to tell them anything now. If the chat shows they already \
            know (you said you'd do it, and it went as you said) or it's routine, reply with exactly \(nothingToSay). \
            Otherwise tell them in a line or two what came of it, and what's next if anything.
            """
        case .failed:
            task = """
            Some work of yours couldn't finish. Tell them in a sentence or two what didn't work and what you'd suggest. \
            Leave out error codes unless they'd act on one.
            """
        case .approval:
            task = """
            A draft is ready for their OK, and it shows right under your message, so don't repeat it. Introduce it in one \
            short line: what it is, and anything worth checking before they approve.
            """
        }
        return "## Now\n" + task + "\nWrite only the message."
    }

    /// A thread put up a card for the owner: it shows in the chat, where it can be decided.
    func reportCard(_ task: TaskRecord, _ card: ApprovalRequest) async {
        guard let thread = await threadForUpdates(task) else { return }
        var update = WorkUpdate(kind: .approval, threadID: thread.id, taskID: task.id, thread: thread.title, text: card.title, approvalID: card.id)
        let draft = [card.destination, String(card.finalText.prefix(600)), card.notes.isEmpty ? "" : "Note: \(card.notes)"].filter { !$0.isEmpty }.joined(separator: "\n")
        // Pennant introduces it in a line; the card shows under its words.
        Task { [self] in
            let words = await self.wordUpdate(update, detail: draft)
            // Decided while it was being worded: the update says so from the start.
            if let current = try? await self.findApproval(card.id)?.request, current.state != .pending { update.outcome = Self.outcome(of: current) }
            if case .say(let line)? = words { await self.postUpdate(update, saying: line) } else { await self.postUpdate(update) }
        }
    }

    /// A card was decided (or replaced): its update in the chat says so.
    func noteCardOutcome(_ card: ApprovalRequest) async {
        guard card.state != .pending, let chat = mainChatID else { return }
        var messageID = updateMessages[card.id]
        if messageID == nil {
            let recent = (try? await deps.store.listMessages(conversationID: chat, before: nil, limit: 400)) ?? []
            messageID = recent.first { m in m.parts.contains { if case .update(let u) = $0 { return u.approvalID == card.id }; return false } }?.id
        }
        guard let messageID, var message = try? await deps.store.message(messageID) else { return }
        let outcome = Self.outcome(of: card)
        var changed = false
        message.parts = message.parts.map { part in
            guard case .update(var u) = part, u.approvalID == card.id, u.outcome != outcome else { return part }
            u.outcome = outcome
            changed = true
            return .update(u)
        }
        guard changed else { return }
        try? await deps.store.updateMessage(message)
        await publish(.messageFinalized(message))
    }

    static func outcome(of card: ApprovalRequest) -> String {
        switch card.state {
        case .pending: return "Waiting"
        case .approved:
            if card.actionFailed == true { return "Approved, but it failed: \(card.actionResult ?? "see the thread")" }
            return card.publishedURL == nil ? "Approved" : "Approved and published"
        case .changesRequested: return "Changes requested"
        case .rejected: return card.replacedBy == nil ? "Rejected" : "Replaced by a newer card"
        }
    }
}
