import PennantCore
import Foundation

/// Runs scheduled jobs: at each due time it starts a task for the job's agent in the job's own
/// conversation, then computes the next run. Outcomes are recorded when the task finishes.
public actor Scheduler {
    private let store: any StoreProtocol
    private let eventBus: EventBus
    private let runtime: TaskRuntime
    private var loop: Task<Void, Never>?
    private var outcomeWatcher: Task<Void, Never>?
    /// Jobs missed by more than this while the host was down are not caught up, only rescheduled.
    public var catchUpWindow: TimeInterval = 6 * 3600
    public var tickInterval: TimeInterval = 30
    /// A goal's job: its instructions, written from the goal and its board at each run, or why it's skipped.
    private var goalPrompt: (@Sendable (GoalID, String) async throws -> (text: String?, skip: String?))?
    public func setGoalPrompt(_ f: @escaping @Sendable (GoalID, String) async throws -> (text: String?, skip: String?)) { goalPrompt = f }

    public init(store: any StoreProtocol, eventBus: EventBus, runtime: TaskRuntime) {
        self.store = store
        self.eventBus = eventBus
        self.runtime = runtime
    }

    public func start() async {
        // Fill in missing next-run times and catch up recent misses.
        for var job in (try? await store.listSchedules()) ?? [] where job.enabled {
            if job.nextRunAt == nil, let next = try? Self.parse(job).next(after: Date()) {
                job.nextRunAt = next
                try? await store.upsertSchedule(job)
                await publish(.scheduleUpserted(job))
            } else if let next = job.nextRunAt, next < Date().addingTimeInterval(-catchUpWindow), let rescheduled = try? Self.parse(job).next(after: Date()) {
                log.info("Schedule \(job.name) missed \(next); rescheduling to \(rescheduled)", category: "scheduler")
                job.nextRunAt = rescheduled
                try? await store.upsertSchedule(job)
                await publish(.scheduleUpserted(job))
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                guard let self else { return }
                try? await Task.sleep(for: .seconds(await self.tickInterval))
            }
        }
        outcomeWatcher = Task { [weak self] in
            guard let self else { return }
            let stream = await self.eventBus.subscribe()
            for await event in stream {
                if case .taskTransition(let t) = event.payload, t.to.isTerminal { await self.recordOutcome(taskID: t.taskID) }
            }
        }
    }

    public func stop() {
        loop?.cancel()
        outcomeWatcher?.cancel()
    }

    // MARK: Editing

    public static func parse(_ job: ScheduledJob) throws -> CronSchedule {
        try CronSchedule.parse(job.schedule, timeZone: TimeZone(identifier: job.timeZone) ?? .current)
    }

    public static func preview(expression: String, timeZone: String, count: Int) -> ([Date], String?) {
        do {
            let schedule = try CronSchedule.parse(expression, timeZone: TimeZone(identifier: timeZone) ?? .current)
            return (schedule.preview(after: Date(), count: count), nil)
        } catch {
            return ([], String(describing: error))
        }
    }

    static let jobLead = "Scheduled job "
    static let pinnedSkillLead = "Follow the skill "

    /// Whether a task was started by a schedule or a goal's session (rather than by someone writing).
    static func isScheduledRun(_ objective: String) -> Bool {
        objective.hasPrefix(jobLead + "\"") || objective.contains("\n\n" + pinnedSkillLead + "\"")
    }

    /// Validate, compute the next run, persist, and announce.
    @discardableResult
    public func upsert(_ input: ScheduledJob) async throws -> ScheduledJob {
        var job = input
        let schedule = try Self.parse(job)
        guard try await store.agent(job.agentID) != nil else { throw ToolError.failed("Agent not found") }
        if let skillID = job.skillID, try await store.skill(skillID) == nil { throw ToolError.failed("Skill not found") }
        let existing = try await store.schedule(job.id)
        let scheduleChanged = existing?.schedule != job.schedule || existing?.timeZone != job.timeZone
        if job.enabled, job.nextRunAt == nil || scheduleChanged || existing?.enabled == false {
            job.nextRunAt = schedule.next(after: Date())
            if job.nextRunAt == nil { job.enabled = false }
        }
        if !job.enabled { job.nextRunAt = nil }
        job.updatedAt = Date()
        if existing == nil { job.createdAt = Date() }
        try await store.upsertSchedule(job)
        await publish(.scheduleUpserted(job))
        return job
    }

    public func delete(_ id: ScheduleID) async throws {
        try await store.deleteSchedule(id)
        await publish(.scheduleRemoved(id))
    }

    public func list() async throws -> [ScheduledJob] { try await store.listSchedules() }

    // MARK: Firing

    private func tick() async {
        guard let due = try? await store.dueSchedules(before: Date()) else { return }
        for job in due { await fire(job, manual: false) }
    }

    @discardableResult
    public func runNow(_ id: ScheduleID) async throws -> ScheduledJob {
        guard let job = try await store.schedule(id) else { throw ToolError.failed("Schedule not found") }
        return await fire(job, manual: true)
    }

    @discardableResult
    private func fire(_ input: ScheduledJob, manual: Bool) async -> ScheduledJob {
        var job = input
        let now = Date()
        do {
            guard let agent = try await store.agent(job.agentID), agent.status != .retired else { throw ToolError.failed("agent missing") }
            // The job's own previous run is still going: skip this turn rather than stack a second run behind it.
            if !manual, let last = job.lastTaskID, let previous = try await store.task(last), !previous.state.isTerminal {
                job.lastOutcome = "skipped: the previous run is still going"
                job.nextRunAt = (try? Self.parse(job))?.next(after: now)
                job.updatedAt = now
                try? await store.upsertSchedule(job)
                log.info("Schedule \(job.name): skipped, previous run \(last) still \(previous.state.rawValue)", category: "scheduler")
                return job
            }
            // Each run of a job gets a thread of its own (it closes itself when nothing in it needs anyone); a goal's
            // sessions all happen in the goal's thread.
            let fresh = job.goalID == nil || job.freshConversation == true
            var hasConversation = false
            if !fresh, let existingID = job.conversationID, try await store.conversation(existingID) != nil { hasConversation = true }
            // Something else is working in the job's conversation (another job, a chat): run separately, in a
            // conversation of its own, instead of redirecting that task.
            if hasConversation, let existingID = job.conversationID,
               try await store.listTasks(agentID: job.agentID, includeFinished: false).contains(where: { $0.conversationID == existingID && !$0.state.isTerminal }) {
                hasConversation = false
            }
            if !hasConversation {
                let conversation = Conversation(agentID: job.agentID, title: fresh ? "⏰ \(job.name) · \(now.formatted(.dateTime.month(.abbreviated).day().hour().minute()))" : "⏰ \(job.name)")
                try await store.upsertConversation(conversation)
                await publish(.conversationUpserted(conversation))
                job.conversationID = conversation.id
            }
            var goalText: String?
            if let goalID = job.goalID, let goalPrompt {
                let (text, skip) = try await goalPrompt(goalID, job.goalRun ?? "work")
                if let skip {
                    job.lastOutcome = "skipped: \(skip)"
                    job.nextRunAt = (try? Self.parse(job))?.next(after: now)
                    job.updatedAt = now
                    try? await store.upsertSchedule(job)
                    await publish(.scheduleUpserted(job))
                    log.info("Schedule \(job.name): skipped, \(skip)", category: "scheduler")
                    return job
                }
                goalText = text
            }
            var text = goalText ?? Self.jobLead + "\"\(job.name)\"" + (manual ? " (run now)" : "") + ":\n\(job.prompt)"
            if let skillID = job.skillID, let pinned = try await store.skill(skillID) {
                // A schedule names a skill, not one version of it: always the newest enabled version.
                let skill = try await store.listSkills(includeDisabled: false).filter { $0.name == pinned.name }.max { $0.version < $1.version } ?? pinned
                text += "\n\n" + Self.pinnedSkillLead + "\"\(skill.name)\" (id \(skill.id.rawValue), v\(skill.version)): call use_skill first, then carry out its steps and verify the result."
            }
            if goalText == nil { text += "\n\nWhen done, end with a short report of what happened. If nothing needed doing, say so." }
            let (_, _, taskID) = try await runtime.submitUserMessage(agentID: job.agentID, conversationID: job.conversationID, text: text, attachments: [])
            job.lastRunAt = now
            job.lastTaskID = taskID
            job.lastOutcome = "running"
            job.runCount += 1
        } catch {
            job.lastRunAt = now
            job.lastOutcome = "failed to start: \(error)"
            log.warn("Schedule \(job.name) failed to start: \(error)", category: "scheduler")
        }
        if !manual || job.nextRunAt.map({ $0 <= now }) ?? true {
            job.nextRunAt = (try? Self.parse(job))?.next(after: now)
            if job.nextRunAt == nil { job.enabled = false }
        }
        job.updatedAt = Date()
        try? await store.upsertSchedule(job)
        await publish(.scheduleUpserted(job))
        return job
    }

    private func recordOutcome(taskID: TaskID) async {
        guard let jobs = try? await store.listSchedules(), var job = jobs.first(where: { $0.lastTaskID == taskID }), let task = try? await store.task(taskID) else { return }
        let summary = task.resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? task.stateReason
        job.lastOutcome = "\(task.state.rawValue): \(summary.prefix(200))"
        job.updatedAt = Date()
        try? await store.upsertSchedule(job)
        await publish(.scheduleUpserted(job))
        // A run that finished with nothing to show closes its thread; a report, a card, a file or a question keeps it
        // in the list (and so does a run that failed).
        if job.goalID == nil, task.state == .completed, (try? await Self.isQuiet(task, store: store)) == true {
            try? await runtime.closeConversation(task.conversationID, closed: true)
        }
    }

    /// The task posted nothing but text, and nothing else is going in its thread.
    static func isQuiet(_ task: TaskRecord, store: any StoreProtocol) async throws -> Bool {
        let messages = try await store.listMessages(conversationID: task.conversationID, before: nil, limit: 200).filter { $0.taskID == task.id }
        let shows = messages.contains { m in
            m.parts.contains { part in
                switch part {
                case .report, .approval, .file, .choices: return true
                default: return false
                }
            }
        }
        let busy = try await store.listTasks(agentID: nil, includeFinished: false).contains { $0.conversationID == task.conversationID }
        return !shows && !busy
    }

    private func publish(_ payload: EventPayload) async {
        if let event = try? await store.appendEvent(payload) { await eventBus.publish(event) }
    }
}
