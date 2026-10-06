import PennantCore
import Foundation

/// Owns task execution. One loop per running task; explicit persisted state transitions;
/// desktop access through the lease; pause, takeover, resume, ask-user, delegation, and compaction.
public actor TaskRuntime {
    public struct Dependencies: Sendable {
        public var store: any StoreProtocol
        public var eventBus: EventBus
        public var provider: any InferenceProvider
        public var broker: ToolBroker
        public var desktop: any DesktopControlling
        public var lease: DesktopLease
        public var memory: MemoryService
        public var skillTracker: SkillUsageTracker
        public var config: HostConfig
        /// Builds (and caches) a provider for a saved profile's inference settings; nil means agents can only use
        /// the host's default model.
        public var makeProvider: (@Sendable (HostConfig.Inference) async -> any InferenceProvider)?
        /// The host's data folder (logs, the local token): where helper processes like the coding CLI's permission
        /// bridge find the host. Nil in tests.
        public var dataRoot: URL?
        /// Teams sends through a connector go from Pennant's bot (see `ChannelService.routeTeamsSend`); nil when it isn't
        /// one, or there's no bot. Nil in tests.
        public var routeTeamsSend: (@Sendable (_ tool: String, _ arguments: JSONValue, _ agentID: AgentID, _ conversationID: ConversationID) async -> ChannelService.TeamsRoute?)?
        /// Whether Pennant's Chrome extension is connected, so threads work in its tabs instead of driving Chrome with
        /// AppleScript. Nil in tests that don't set it.
        public var chromeConnected: (@Sendable () async -> Bool)?
        /// The freedom of the goal a task works for (nil: not goal work). Nil in tests.
        public var goalFreedom: (@Sendable (TaskID) async -> Goal.Freedom?)?
        /// Every goal, for telling which one a card comes from. Nil in tests that have no goals.
        public var goals: (@Sendable () async -> [Goal])?
        /// The environment a coding session runs with to act as its agent's GitHub App (a fresh token each run).
        public var gitHubEnvironment: (@Sendable (GitHubAppIdentity) async throws -> [String: String])?

        public init(store: any StoreProtocol, eventBus: EventBus, provider: any InferenceProvider, broker: ToolBroker, desktop: any DesktopControlling, lease: DesktopLease, memory: MemoryService, skillTracker: SkillUsageTracker, config: HostConfig) {
            self.store = store
            self.eventBus = eventBus
            self.provider = provider
            self.broker = broker
            self.desktop = desktop
            self.lease = lease
            self.memory = memory
            self.skillTracker = skillTracker
            self.config = config
        }
    }

    enum LoopExit: Error { case paused(String) }

    var deps: Dependencies
    /// Which of `modelChoices` a task is on (it moves on only when a model refuses the request).
    var modelIndex: [TaskID: Int] = [:]
    /// Models whose quota ran out (a subscription's weekly limit, say), by label, until the reset time they reported.
    var exhaustedUntil: [String: Date] = [:]
    /// Tasks that posted a report card, and tasks already sent back once to post one.
    var reportsPosted: Set<TaskID> = []
    var reportNudged: Set<TaskID> = []
    /// Models that kept failing on the server side (503 "no healthy upstream", timeouts), by label, until a short
    /// cooldown ends; tasks use the next model meanwhile and come back when it ends.
    var downUntil: [String: Date] = [:]
    /// MCP servers whose tools a task has loaded with find_tools or by calling one, most recently loaded first.
    var activeServers: [TaskID: [String]] = [:]
    /// How many times a task was sent back for stopping at an offer.
    var offerNudges: [TaskID: Int] = [:]
    /// The answer an offer nudge followed up on: the next reply either stands by it ("(done)") or replaces it, so the
    /// user sees one answer, not two.
    var offerPending: [TaskID: (message: MessageID, text: String)] = [:]
    /// Approval id → the message carrying its card.
    var approvalMessages: [String: MessageID] = [:]
    /// Coding tasks whose person chose "Allow for the rest of this task": their commands no longer ask.
    var coderAllowsRest: Set<TaskID> = []
    /// The card each task is blocked on right now, so a decision is only handed over as that call's result.
    var awaitingApproval: [TaskID: String] = [:]
    /// Each agent's latest turn, for the prompt inspector.
    var lastInspections: [AgentID: PromptInspection] = [:]
    var loops: [TaskID: Task<Void, Never>] = [:]
    /// Set by `stop()`: the host is shutting down, so cancelled work records nothing. Its tasks keep their state and
    /// open tool calls, and the next start picks them up (a card still waiting gets its decision as the call's result).
    var stopping = false
    private var pauseReasons: [TaskID: String] = [:]
    private var cancelReasons: [TaskID: String] = [:]
    var pausedForDesktop: Set<TaskID> = []
    var pausedForInference: Set<TaskID> = []
    /// Deletions the owner allowed for the rest of a thread ("Allow deletes here"): later ones in the same place there
    /// don't ask again.
    var signedOffDeletions: [ConversationID: [SignOff.Deletion]] = [:]
    var pendingQuestions: [TaskID: CheckedContinuation<String, Error>] = [:]
    /// Answers that came while a task's question or card was up but before it started waiting (it was still posting
    /// the update to the Pennant chat, say): handed over the moment it waits.
    var earlyAnswers: [TaskID: String] = [:]
    /// Work told to wrap up at its limit (once; past that, it pauses and asks).
    var wrappedUp: Set<TaskID> = []
    var taskWaiters: [TaskID: [CheckedContinuation<TaskRecord, Error>]] = [:]
    var runtimeNotes: [TaskID: [String]] = [:]
    var freshScreen: Set<TaskID> = []
    var emptyReplies: [TaskID: Int] = [:]
    /// Coding tasks: each tool call's name by id, so results (which carry only the id) can be named.
    var codingToolNames: [TaskID: [String: String]] = [:]
    /// The GitHub bot each running coding session acts as; absent when it has none (or its token couldn't be minted).
    var codingIdentity: [TaskID: String] = [:]
    /// Coding runs on the Pennant engine whose loop is running: their project and GitHub identity.
    var pennantCodingRuns: [TaskID: PennantCodingRun] = [:]
    /// Structured answers from a choice card, picked up by the coding run waiting on it.
    var choiceAnswers: [TaskID: [String: String]] = [:]
    /// The open choice card each coding task is waiting on (task → question id).
    var openChoices: [TaskID: String] = [:]
    var nudged: Set<TaskID> = []
    var deltaBuffers: [MessageID: (text: String, reasoning: String)] = [:]
    public var maxConcurrentTasks = 5
    /// Tasks that are only waiting (on a helper, a coding run, a person): they don't hold one of the slots, or a task
    /// waiting on an answer could keep the one who'd answer it queued behind it.
    var parked: Set<TaskID> = []
    static let waitsOnOthers: Set<String> = ["await_task", "ask_user", "request_approval"]
    /// Tool names that act on the screen and therefore require a fresh screenshot after a resume.
    static let pointerTools: Set<String> = ["click", "double_click", "right_click", "drag", "move_mouse", "scroll", "type_text", "press_key", "ui_action", "ui_set_value"]
    static let observationTools: Set<String> = ["screenshot", "ui_tree"]
    /// Why AppleScript that drives the owner's Chrome was refused, and what to do instead.
    static let chromeFromChat = "Refused: this drives the owner's Chrome (bringing it forward, opening tabs, changing or clicking in pages), which takes over the window they're working in. Use your own tab in their Chrome instead, with the same sign-ins: web_open, web_read, web_click and web_type. Reading which page they have open, or its text, is fine from here."
    static let chromeInThread = "Refused: this drives the owner's Chrome (bringing it forward, opening tabs, changing or clicking in pages), which takes over the window they're working in. Work in your own tabs in their Chrome instead, with the same sign-ins: web_open the page, then web_read, web_click and web_type. Reading which page they have open, or its text, is still fine."
    /// Tools that wait for the person, who may be away for hours. The 15-minute tool limit would end the wait while the
    /// question or card is still up, and the agent would carry on without an answer.
    static let waitsForUser: Set<String> = ["ask_user", "request_approval"]

    var scheduler: Scheduler?
    /// The Pennant chat, once found or made.
    var mainChatID: ConversationID?
    /// The chat's history is being folded into its summary (`tidyMainChat`).
    var tidyingChat = false
    /// Card id → its update in the Pennant chat, so the update can say how it was decided.
    var updateMessages: [String: MessageID] = [:]
    /// The work board as last built, reused for a minute (a turn reads it on every step).
    var boardCache: (at: Date, text: String)?
    /// macOS permissions whose system prompt this process has already shown, by label.
    var promptedPermissions: Set<String> = []

    public init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// Settings saved from Settings or the model pill reach running agents on their next step.
    public func updateConfig(_ config: HostConfig) { deps.config = config }

    /// The scheduler is created after the runtime (it needs it); attach once both exist.
    public func attach(scheduler: Scheduler) { self.scheduler = scheduler }

    // MARK: Startup and recovery

    /// Reconcile state left by a previous process, then resume schedulable work.
    public func start() async {
        do {
            let tasks = try await deps.store.listTasks(agentID: nil, includeFinished: false)
            // Tasks paused for a rate limit or an unreachable model lost their resume timer with the old process:
            // arm it again (a short wait, then carry on).
            for task in tasks where task.state == .paused && (task.stateReason.hasPrefix("Rate limited") || task.stateReason.hasPrefix("Inference endpoint unavailable")) {
                pausedForInference.insert(task.id)
                let id = task.id
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    await self?.resumeAfterRateLimit(id)
                }
            }
            for task in tasks where task.state.isActive {
              do {
                var notes: [String] = ["The host restarted while this task was \(task.state.rawValue) at \(ISO8601.format(task.updatedAt))."]
                for record in try await deps.store.toolRecords(taskID: task.id) where [.intended, .running].contains(record.status) {
                    var r = record
                    if record.status == .running {
                        r.status = .uncertain
                        r.reconciliationNote = "Host restarted during execution"
                        notes.append("The outcome of \(record.call.name) \(record.call.arguments.compactText.prefix(100)) is unknown. Read back the target state before repeating it.")
                    } else {
                        r.status = .cancelled
                        r.reconciliationNote = "Never started; host restarted"
                    }
                    r.finishedAt = Date()
                    try await deps.store.upsertToolRecord(r)
                    await publish(.toolRecordUpserted(r))
                }
                runtimeNotes[task.id, default: []].append(contentsOf: notes)
                try await transition(task.id, to: .queued, reason: "Recovered after host restart")
              } catch {
                log.error("Could not recover task \(task.id): \(error)", category: "runtime")
              }
            }
            // Retire workers whose tasks are finished.
            for agent in try await deps.store.listAgents(includeRetired: false) where agent.kind == .worker {
                let active = try await deps.store.listTasks(agentID: agent.id, includeFinished: false)
                if active.isEmpty { await setAgentStatus(agent.id, .retired, line: "Retired") }
            }
        } catch {
            log.error("Recovery failed: \(error)", category: "runtime")
        }
        await schedule()
    }

    public func stop() async {
        stopping = true
        for (_, t) in loops { t.cancel() }
        loops = [:]
    }

    // MARK: Public commands

    /// A user message: either answers a waiting question or starts a task in the conversation.
    public func submitUserMessage(agentID: AgentID, conversationID: ConversationID?, text: String, attachments: [Attachment], author: MessageAuthor? = nil, folder: String? = nil,
                                  mode: CodingMode? = nil, model: String? = nil, requestedBy: TaskID? = nil, engine: CodingEngine? = nil,
                                  chrome: Bool = false, spoken: Bool = false) async throws -> (MessageID, ConversationID, TaskID) {
        guard let agent = try await deps.store.agent(agentID), agent.status != .retired else { throw ToolError.failed("Agent not found") }
        let conversation: Conversation
        if let conversationID, var existing = try await deps.store.conversation(conversationID) {
            // Writing in a closed conversation picks it back up.
            if existing.closedAt != nil {
                existing.closedAt = nil
                try await deps.store.upsertConversation(existing)
                await publish(.conversationUpserted(existing))
            }
            conversation = existing
        } else {
            let fallbackTitle = attachments.isEmpty ? "New conversation" : "Attachment: \(attachments[0].fileName)"
            var created = Conversation(agentID: agentID, title: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackTitle : Self.title(from: text))
            // A coding run can start in a chosen project instead of the default folder.
            if engine != nil, let folder, !folder.isEmpty {
                let expanded = (folder as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else { throw ToolError.failed("\(folder) isn't a folder on this Mac") }
                created.workingDirectory = expanded
            }
            if engine != nil {
                created.engineMode = mode
                created.engineModel = model?.nilIfEmpty
                created.engineChrome = chrome ? true : nil
                created.engine = engine
            }
            // Asked by another agent's task: it belongs under that task's thread, not in the list of its own.
            if let requestedBy, let asker = try await deps.store.task(requestedBy) { created.parentID = asker.conversationID }
            conversation = created
            try await deps.store.upsertConversation(conversation)
            await publish(.conversationUpserted(conversation))
        }
        var parts: [ContentPart] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !attachments.isEmpty ? [] : [.text(text)]
        for a in attachments where a.mimeType.hasPrefix("image/") {
            parts.append(.image(ImageRef(artifactID: a.artifactID, mimeType: a.mimeType, caption: a.fileName)))
        }
        for a in attachments where !a.mimeType.hasPrefix("image/") {
            let place = a.path.map { " saved at \($0) (read it with read_file or the shell)" } ?? ", artifact \(a.artifactID.rawValue)"
            parts.append(.text("[attached file: \(a.fileName), \(a.byteCount) bytes\(place)]"))
        }

        // Waiting question in this conversation?
        let waiting = try await deps.store.listTasks(agentID: agentID, includeFinished: false).first { $0.conversationID == conversation.id && $0.state == .waitingForUser }
        if let waiting {
            let message = Message(conversationID: conversation.id, agentID: agentID, taskID: waiting.id, role: .user, parts: parts, author: author)
            try await deps.store.appendMessage(message)
            await publish(.messageAppended(message))
            await publishConversation(conversation.id, after: message)
            if spoken { runtimeNotes[waiting.id, default: []].append(Self.spokenNote) }
            try await deliverAnswer(taskID: waiting.id, text: text, alreadyAppended: true)
            return (message.id, conversation.id, waiting.id)
        }

        // A conversation runs one task at a time; a new message while a task is active becomes a follow-up note.
        let active = try await deps.store.listTasks(agentID: agentID, includeFinished: false).first { $0.conversationID == conversation.id && !$0.state.isTerminal }
        if let active {
            let message = Message(conversationID: conversation.id, agentID: agentID, taskID: active.id, role: .user, parts: parts, author: author)
            try await deps.store.appendMessage(message)
            await publish(.messageAppended(message))
            await publishConversation(conversation.id, after: message)
            runtimeNotes[active.id, default: []].append("The user sent a new message while you were working; it is included in the conversation. Take it into account.")
            if spoken { runtimeNotes[active.id, default: []].append(Self.spokenNote) }
            if active.state == .paused { try await resumeTask(active.id) }
            return (message.id, conversation.id, active.id)
        }

        var task = TaskRecord(agentID: agentID, conversationID: conversation.id, title: Self.title(from: text), objective: text, completionCriteria: "", budget: deps.config.defaultBudget)
        task.requestedByTaskID = requestedBy
        let message = Message(conversationID: conversation.id, agentID: agentID, taskID: task.id, role: .user, parts: parts, author: author)
        try await deps.store.appendMessage(message)
        await publish(.messageAppended(message))
        try await deps.store.upsertTask(task)
        await publish(.taskUpserted(task))
        await publishConversation(conversation.id, after: message)
        if spoken { runtimeNotes[task.id, default: []].append(Self.spokenNote) }
        await schedule()
        return (message.id, conversation.id, task.id)
    }

    public func pauseTask(_ id: TaskID, reason: String) async throws {
        guard let task = try await deps.store.task(id) else { throw TaskError.notFound(id) }
        pauseReasons[id] = reason
        if let loop = loops[id] {
            loop.cancel()
        } else if task.state == .queued || task.state == .waitingForUser {
            try await transition(id, to: .paused, reason: reason)
        }
    }

    public func resumeTask(_ id: TaskID) async throws {
        guard let task = try await deps.store.task(id) else { throw TaskError.notFound(id) }
        guard task.state == .paused || task.state == .failed else { return }
        pausedForDesktop.remove(id)
        pausedForInference.remove(id)
        pauseReasons[id] = nil
        freshScreen.remove(id)
        runtimeNotes[id, default: []].append("Task resumed at \(ISO8601.format(Date())) after being \(task.state.rawValue) (\(task.stateReason)). The screen and app state may have changed: take a new screenshot before any click or keystroke.")
        try await transition(id, to: .queued, reason: "Resumed")
        await schedule()
    }

    public func cancelTask(_ id: TaskID, reason: String) async throws {
        guard let task = try await deps.store.task(id) else { throw TaskError.notFound(id) }
        cancelReasons[id] = reason
        if let loop = loops[id] {
            loop.cancel()
        } else if !task.state.isTerminal {
            if let c = pendingQuestions.removeValue(forKey: id) { c.resume(throwing: CancellationError()) }
            try await transition(id, to: .cancelled, reason: reason)
            await finish(task: id)
        }
    }

    /// Closes a conversation: it leaves the list until something happens in it (a message, an answer, a reply) or it's
    /// reopened. Closing stops nothing: work in it carries on, and a question or card in it waits (Stop ends a task).
    public func closeConversation(_ id: ConversationID, closed: Bool) async throws {
        if closed, try await deps.store.conversation(id)?.isMain == true { return }
        let at: Date? = closed ? Date() : nil
        guard let conversation = try await deps.store.mutateConversation(id, { $0.closedAt = at }) else { throw ToolError.failed("No such conversation") }
        await publish(.conversationUpserted(conversation))
    }

    /// Deletes conversations for good: their running work is cancelled (and given a moment to stop), then their
    /// messages and tasks go.
    public func deleteConversations(_ ids: [ConversationID], by who: String) async throws {
        let gone = Set(ids)
        let open = try await deps.store.listTasks(agentID: nil, includeFinished: false).filter { gone.contains($0.conversationID) }
        for task in open { try? await cancelTask(task.id, reason: "Conversation deleted by \(who)") }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(try await deps.store.listTasks(agentID: nil, includeFinished: false).filter { gone.contains($0.conversationID) }.isEmpty) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await deps.store.deleteConversations(ids)
        await publish(.conversationsRemoved(ids))
    }

    /// Closes open conversations with nothing new for `idleDays`: quiet ones only. A thread with work going or a question
    /// or card waiting on someone stays, and so do the ones in `keep` (active goals' threads). Returns how many.
    public func pruneConversations(idleDays: Int, keep: Set<ConversationID> = []) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-Double(max(1, idleDays)) * 86400)
        let busy = Set(try await deps.store.listTasks(agentID: nil, includeFinished: false).map(\.conversationID))
        let goals = keep
        var closed = 0
        for agent in try await deps.store.listAgents(includeRetired: true) {
            for c in try await deps.store.listConversations(agentID: agent.id) where c.closedAt == nil && c.updatedAt < cutoff && !busy.contains(c.id) && !goals.contains(c.id) {
                try await closeConversation(c.id, closed: true)
                closed += 1
            }
        }
        return closed
    }

    public func answerQuestion(taskID: TaskID, text: String) async throws {
        try await deliverAnswer(taskID: taskID, text: text, alreadyAppended: false)
    }

    func deliverAnswer(taskID: TaskID, text: String, alreadyAppended: Bool) async throws {
        guard let task = try await deps.store.task(taskID) else { throw TaskError.notFound(taskID) }
        if !alreadyAppended {
            let message = Message(conversationID: task.conversationID, agentID: task.agentID, taskID: taskID, role: .user, parts: [.text(text)])
            try await deps.store.appendMessage(message)
            await publish(.messageAppended(message))
            await publishConversation(task.conversationID, after: message)
        }
        if let c = pendingQuestions.removeValue(forKey: taskID) {
            c.resume(returning: text)
            return
        }
        // Its loop is live and about to wait (its question or card is up): the answer waits for it.
        if loops[taskID] != nil, task.state == .waitingForUser || awaitingApproval[taskID] != nil {
            earlyAnswers[taskID] = text
            return
        }
        // No live continuation (host restarted while waiting): answer the recorded call and requeue.
        if task.state == .waitingForUser {
            let records = try await deps.store.toolRecords(taskID: taskID)
            if let ask = records.last(where: { ["ask_user", "request_approval"].contains($0.call.name) && [.intended, .running].contains($0.status) }) {
                var r = ask
                r.status = .succeeded
                r.finishedAt = Date()
                r.resultSummary = "User answered"
                try await deps.store.upsertToolRecord(r)
                await publish(.toolRecordUpserted(r))
                let result = ToolResult.text(ask.call.id, name: ask.call.name, ask.call.name == "request_approval" ? text : "User answered: \(text)")
                let toolMessage = Message(conversationID: task.conversationID, agentID: task.agentID, taskID: taskID, role: .tool, parts: [.toolResult(result)])
                try await deps.store.appendMessage(toolMessage)
                await publish(.messageAppended(toolMessage))
            }
            if let why = task.budget.exhaustedReason(usage: task.usage) {
                // Going on gets another allowance of the size the work had: a chat thread's or a helper's, not the
                // host's whole one.
                let fromChat = await askedByChat(task)
                let allowance = task.parentTaskID != nil || fromChat ? Self.chatThreadBudget(deps.config.defaultBudget) : deps.config.defaultBudget
                try await updateTask(taskID) { $0.budget.extend(by: allowance, usage: $0.usage) }
                log.info("Extended budget of task \(taskID) after user reply (\(why))", category: "runtime")
            }
            try await transition(taskID, to: .queued, reason: "User answered")
            await schedule()
        }
    }

    /// Tells the user which limit was hit, waits in `waitingForUser`, and extends the budget when they reply.
    /// Any reply continues the task; the reply itself is already in the conversation as a user message.
    private func pauseForBudget(taskID: TaskID, task: TaskRecord, agent: AgentProfile, reason: String) async throws -> TaskRecord {
        // A thread the chat started stops at a thread's limits (`chatThreadBudget`), not the host's in Settings.
        let limit = await askedByChat(task) ? "the most a thread does before checking with you" : "the limit set in Settings"
        let note = "I've \(reason) on this task, which is \(limit). Reply with anything to keep going (a nudge on what matters most helps), or cancel the task."
        let message = Message(conversationID: task.conversationID, agentID: task.agentID, taskID: taskID, role: .assistant, parts: [.text(note)])
        try await deps.store.appendMessage(message)
        await publish(.messageAppended(message))
        await publishConversation(task.conversationID, after: message)
        try await transition(taskID, to: .waitingForUser, reason: "Task limit: \(reason). Reply to continue.")
        await reportQuestion(task, "It \(reason), \(limit). Should it keep going?")
        await setAgentStatus(agent.id, .waitingForUser, line: "At the task limit, waiting for you")
        await publish(.notice(level: .warning, agentID: agent.id, text: "\(agent.name) \(reason) on \"\(task.title)\" and is waiting for you to say whether to continue."))
        await deps.lease.forget(taskID: taskID)
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                Task { self.registerQuestion(taskID, c) }
            }
        } onCancel: {
            Task { await self.cancelQuestion(taskID) }
        }
        let allowance = deps.config.defaultBudget
        let updated = try await updateTask(taskID) { $0.budget.extend(by: allowance, usage: $0.usage) }
        try await transition(taskID, to: .running, reason: "Continuing after the task limit")
        await setAgentStatus(agent.id, .thinking, line: task.title)
        return updated
    }

    // MARK: Scheduling

    func schedule() async {
        guard !stopping else { return }
        do {
            let tasks = try await deps.store.listTasks(agentID: nil, includeFinished: false)
            let queued = tasks.filter { $0.state == .queued && loops[$0.id] == nil }.sorted { $0.createdAt < $1.createdAt }
            // The Pennant chat answers at once: its turns never wait behind threads for a slot, nor take one.
            let chat = mainChatID
            let inChat = Set(tasks.filter { $0.conversationID == chat }.map(\.id))
            for task in queued {
                let busy = loops.keys.filter { !parked.contains($0) && !inChat.contains($0) }.count
                guard task.conversationID == chat || busy < maxConcurrentTasks else { continue }
                var ready = true
                for dep in task.dependencies {
                    if let d = try await deps.store.task(dep), d.state != .completed { ready = false; break }
                }
                guard ready else { continue }
                let id = task.id
                loops[id] = Task { [weak self] in await self?.runLoop(id) }
            }
        } catch {
            log.error("Scheduling failed: \(error)", category: "runtime")
        }
    }

    // MARK: The loop

    private func runLoop(_ taskID: TaskID) async {
        defer { Task { await self.loopEnded(taskID) } }
        guard var task = try? await deps.store.task(taskID), let agent = try? await deps.store.agent(task.agentID) else { return }
        do {
            try await transition(taskID, to: .running, reason: task.usage.steps == 0 ? "Started" : "Continuing")
            task = try await updateTask(taskID) { if $0.usage.startedAt == nil { $0.usage.startedAt = Date() } }
            await setAgentStatus(agent.id, .thinking, line: task.title)
            // A coding run on Claude Code hands the conversation to the CLI instead of thinking with the model; one on
            // the Pennant engine goes on in this loop, on the run's model and with only the coding tools.
            let conversation = try? await deps.store.conversation(task.conversationID)
            let coding = codingSetup(conversation: conversation ?? nil)
            if let coding {
                switch coding.engine {
                case .claudeCode:
                    try await runCodingAgent(taskID, agent: agent, setup: coding)
                    return
                case .pennant:
                    try await startPennantCoding(taskID, agentID: agent.id, setup: coding)
                }
            }
            defer { if coding != nil { endPennantCoding(taskID) } }
            if coding == nil, try await takePickedSkill(task, agent: agent) { return }
            var usedDesktopThisStep = false

            while true {
                try Task.checkCancellation()
                task = try await deps.store.task(taskID) ?? task
                if let why = task.budget.exhaustedReason(usage: task.usage) {
                    // A helper never stops to ask the owner: it reports what it has to the task that asked for it, and
                    // past that, it finishes with what it has (its parent was waiting on it, and nobody else would answer).
                    let helper = task.parentTaskID != nil
                    // Work that reports to the Pennant chat, and helpers, wrap up once with what they have (a few steps
                    // to write it); the owner (or the parent) says whether to go on.
                    let toChat = helper ? false : await reportsToChat(task)
                    if !wrappedUp.contains(taskID), helper || toChat {
                        wrappedUp.insert(taskID)
                        // Helpers still at work would be stopped when this finishes (mid-change, maybe): it collects
                        // them first, a step each.
                        let working = ((try? await deps.store.childTasks(parentTaskID: taskID)) ?? []).filter { !$0.state.isTerminal }
                        var note = helper ? Self.helperWrapUpNote(why) : Self.wrapUpNote(why)
                        if !working.isEmpty { note += " " + Self.collectHelpersNote(working) }
                        runtimeNotes[taskID, default: []].append(note)
                        task = try await updateTask(taskID) {
                            $0.budget.extend(by: TaskBudget(maxSteps: 3 + working.count, maxTokens: 200_000, maxDuration: 600 + 900 * Double(working.count)), usage: $0.usage)
                        }
                        continue
                    }
                    if helper {
                        let last = (try? await deps.store.listMessages(conversationID: task.conversationID, before: nil, limit: 30))?
                            .first { $0.taskID == taskID && $0.role == .assistant && !$0.text.isEmpty }?.text
                        try await complete(task: taskID, summary: "Stopped at its limit (\(why)) before it finished." + (last.map { " Its last note:\n" + $0 } ?? ""))
                        break
                    }
                    // A limit is a checkpoint, not a verdict: ask the user and carry on if they say so.
                    task = try await pauseForBudget(taskID: taskID, task: task, agent: agent, reason: why)
                    continue
                }

                await setAgentStatus(agent.id, .thinking, line: task.title)
                let profile = coding == nil ? agent : codingProfile(agent, conversation: try await deps.store.conversation(task.conversationID))
                let model = await currentModel(task: task, agent: profile)
                let (context, specs) = try await buildContext(task: task, agent: profile, model: model)
                let (assistant, response) = try await runInference(task: task, agent: profile, context: context, specs: specs)
                task = try await updateTask(taskID) {
                    $0.usage.addTurn(input: response.usage.inputTokens, output: response.usage.outputTokens)
                    $0.usage.steps += 1
                }
                // Long work takes stock now and then, so more of the same doesn't go on unnoticed.
                if !response.toolCalls.isEmpty, task.usage.steps % Self.checkInEvery == 0, !wrappedUp.contains(taskID) {
                    runtimeNotes[taskID, default: []].append(Self.checkInNote(steps: task.usage.steps))
                }
                if !response.toolCalls.isEmpty, task.usage.steps == Self.chatHandOffStep, await inMainChat(task) {
                    runtimeNotes[taskID, default: []].append(Self.chatHandOffNote)
                }

                if response.toolCalls.isEmpty {
                    let empty = response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if empty, emptyReplies[taskID, default: 0] < 2 {
                        emptyReplies[taskID, default: 0] += 1
                        runtimeNotes[taskID, default: []].append(response.finishReason == .length ? "Your previous reply was cut off by the output limit. Continue more concisely." : "Your previous reply was empty. Either call a tool or write the final answer.")
                        continue
                    }
                    if coding != nil {
                        switch try await reviewPlan(task: task, plan: response.text) {
                        case .notPlanning: break
                        case .carryOn(let note):
                            runtimeNotes[taskID, default: []].append(note)
                            continue
                        case .rejected(let summary):
                            try await complete(task: taskID, summary: summary)
                            return
                        }
                    }
                    if let earlier = offerPending.removeValue(forKey: taskID) {
                        if Self.isDoneMarker(response.text) {
                            await removeMessages([assistant.id], in: task.conversationID)
                            try await complete(task: taskID, summary: earlier.text)
                            break
                        }
                        // It wrote the answer again: this one replaces the earlier.
                        await removeMessages([earlier.message], in: task.conversationID)
                    }
                    if let nudge = await completionNudge(task: task, reply: response.text) {
                        runtimeNotes[taskID, default: []].append(nudge)
                        continue
                    }
                    if let nudge = await reportNudge(task: task, reply: response.text) {
                        runtimeNotes[taskID, default: []].append(nudge)
                        continue
                    }
                    // In the Pennant chat, offering a choice is how a person talks: only work elsewhere is sent back
                    // to do what it offered.
                    if await !inMainChat(task), let nudge = offerNudge(task: task, reply: response.text) {
                        runtimeNotes[taskID, default: []].append(nudge)
                        offerPending[taskID] = (assistant.id, response.text)
                        continue
                    }
                    try await complete(task: taskID, summary: response.text)
                    break
                }

                usedDesktopThisStep = false
                for call in response.toolCalls {
                    try Task.checkCancellation()
                    let (result, needsDesktop) = try await executeTool(call, task: task, agent: profile)
                    usedDesktopThisStep = usedDesktopThisStep || needsDesktop
                    let toolMessage = Message(conversationID: task.conversationID, agentID: agent.id, taskID: taskID, role: .tool, parts: [.toolResult(result)])
                    try await deps.store.appendMessage(toolMessage)
                    await publish(.messageAppended(toolMessage))
                    if case .desktopRevoked = result.runtimeSignal {
                        let reason = await deps.lease.humanHasControl ? "The user took control of the computer" : "Computer use paused by the user"
                        pausedForDesktop.insert(taskID)
                        throw LoopExit.paused(reason)
                    }
                }
                if !usedDesktopThisStep { await deps.lease.forget(taskID: taskID) }
                await publish(.taskUpserted(task))
            }
        } catch is CancellationError {
            await handleCancellation(taskID)
        } catch LoopExit.paused(let reason) {
            try? await transition(taskID, to: .paused, reason: reason)
            await setAgentStatus(agent.id, .paused, line: reason)
            await deps.lease.forget(taskID: taskID)
        } catch let error as InferenceError {
            switch error {
            case .httpStatus(429, _):
                // Rate limited everywhere it could go: wait it out instead of failing, then carry on by itself.
                pausedForInference.insert(taskID)
                let wait = Self.rateLimitPause
                try? await transition(taskID, to: .paused, reason: "Rate limited by the model provider. Resuming by itself in \(Int(wait / 60)) min.")
                await setAgentStatus(agent.id, .paused, line: "Rate limited; resuming in \(Int(wait / 60)) min")
                await publish(.notice(level: .warning, agentID: agent.id, text: "\(agent.name) hit the model's rate limit and no other model could take over. It resumes by itself in \(Int(wait / 60)) minutes."))
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    await self?.resumeAfterRateLimit(taskID)
                }
            case .unreachable, .httpStatus(500...599, _):
                pausedForInference.insert(taskID)
                try? await transition(taskID, to: .paused, reason: "Inference endpoint unavailable: \(error.description.prefix(200)). Will resume when it is reachable.")
                await setAgentStatus(agent.id, .paused, line: "Waiting for the model server")
                await publish(.notice(level: .warning, agentID: agent.id, text: "The model server is unreachable. \(agent.name)'s task is paused and will resume automatically."))
            default:
                await fail(task: taskID, reason: error.description)
            }
            await deps.lease.forget(taskID: taskID)
        } catch {
            if Task.isCancelled {
                await handleCancellation(taskID)
            } else if Self.isNetworkBlip(error) {
                // A request to the model timed out or its connection dropped (the network changing under it): wait
                // for the model to be reachable and carry on, as when it's down, instead of losing the task.
                pausedForInference.insert(taskID)
                try? await transition(taskID, to: .paused, reason: "Inference endpoint unavailable: \((error as NSError).localizedDescription). Will resume when it is reachable.")
                await setAgentStatus(agent.id, .paused, line: "Waiting for the model server")
                // A blip may pass before the health check ever sees the model down: try again shortly either way.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    await self?.resumeAfterRateLimit(taskID)
                }
            } else {
                await fail(task: taskID, reason: String(describing: error))
            }
            await deps.lease.forget(taskID: taskID)
        }
    }

    /// A network error that passes: a timeout, a dropped connection, no network or name lookup for a moment.
    static func isNetworkBlip(_ error: Error) -> Bool {
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed].contains(e.code)
    }

    private func handleCancellation(_ taskID: TaskID) async {
        guard !stopping else { return }
        if let reason = cancelReasons.removeValue(forKey: taskID) {
            try? await transition(taskID, to: .cancelled, reason: reason)
            await finish(task: taskID)
        } else {
            let reason = pauseReasons.removeValue(forKey: taskID) ?? "Paused"
            try? await transition(taskID, to: .paused, reason: reason)
            if let t = try? await deps.store.task(taskID) { await setAgentStatus(t.agentID, .paused, line: reason) }
        }
        await deps.lease.forget(taskID: taskID)
    }

    private func loopEnded(_ taskID: TaskID) async {
        loops[taskID] = nil
        await schedule()
    }

}

/// Side channel from a tool result to the loop, never persisted.
public enum RuntimeSignal: Sendable { case desktopRevoked }

private nonisolated(unsafe) var runtimeSignals: [ToolCallID: RuntimeSignal] = [:]
private let runtimeSignalLock = NSLock()

extension ToolResult {
    var runtimeSignal: RuntimeSignal? {
        get { runtimeSignalLock.lock(); defer { runtimeSignalLock.unlock() }; return runtimeSignals[callID] }
        set { runtimeSignalLock.lock(); runtimeSignals[callID] = newValue; runtimeSignalLock.unlock() }
    }
}

func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ToolError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
