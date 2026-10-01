import PennantCore
import Foundation

/// Running a tool call: the owner's sign-offs, read-back after an uncertain outcome, the desktop lease, recording
/// intent and outcome, and the hooks tools use to reach the runtime.
extension TaskRuntime {
    // MARK: Tools

    func executeTool(_ requested: ToolCall, task: TaskRecord, agent: AgentProfile) async throws -> (ToolResult, needsDesktop: Bool) {
        var call = requested
        var record = ToolRecord(taskID: task.id, agentID: agent.id, call: call)
        if call.name == Self.findToolsSpec.name {
            let query: String = { if case .object(let o) = call.arguments, case .string(let q)? = o["query"] { return q }; return "" }()
            let text = await findTools(query: query, task: task, agent: agent)
            record.status = .succeeded; record.resultSummary = String(text.prefix(200)); record.finishedAt = Date()
            try? await deps.store.upsertToolRecord(record)
            await publish(.toolRecordUpserted(record))
            return (ToolResult.text(call.id, name: call.name, text), false)
        }
        guard let tool = await deps.broker.tool(named: call.name) else {
            record.status = .failed; record.isError = true; record.resultSummary = "Unknown tool"; record.finishedAt = Date()
            try? await deps.store.upsertToolRecord(record)
            await publish(.toolRecordUpserted(record))
            return (ToolResult.text(call.id, name: call.name, "Unknown tool '\(call.name)'. Available tools are listed in your instructions.", isError: true), false)
        }
        let spec = tool.spec
        noteToolUse(spec, task: task.id)
        if !ToolBroker.mayUse(spec, agent) {
            record.status = .denied; record.isError = true; record.resultSummary = spec.access == .approvalOnly ? "Only from an approved card" : "Not granted to this agent"; record.finishedAt = Date()
            try? await deps.store.upsertToolRecord(record)
            await publish(.toolRecordUpserted(record))
            return (ToolResult.text(call.id, name: call.name, spec.access == .approvalOnly ? "Tool '\(call.name)' only runs when the user approves a proposal." : "Tool '\(call.name)' hasn't been granted to this agent.", isError: true), false)
        }
        if !agent.toolAllowlist.isEmpty, !agent.toolAllowlist.contains(spec.name), !agent.toolAllowlist.contains(spec.source) {
            record.status = .denied; record.isError = true; record.resultSummary = "Not in this agent's allowlist"; record.finishedAt = Date()
            try? await deps.store.upsertToolRecord(record)
            await publish(.toolRecordUpserted(record))
            return (ToolResult.text(call.id, name: call.name, "Tool '\(call.name)' is not allowed for this agent.", isError: true), false)
        }
        // A coding run on the Pennant engine goes through the rules Claude Code runs follow instead (below), which know
        // who it is on GitHub.
        let codingRun = pennantCodingRuns[task.id] != nil
        // Approving a pull request (or resolving a review thread, or passing a deployment review) is a person's
        // sign-off: an agent never gives it with the owner's account, whoever asked.
        if !codingRun, spec.name == "shell", GitHubGuard.signsOff(call.arguments["command"]?.stringValue ?? "") {
            record.status = .denied; record.isError = true; record.resultSummary = "Approvals are for people"; record.finishedAt = Date()
            try? await deps.store.upsertToolRecord(record)
            await publish(.toolRecordUpserted(record))
            return (ToolResult.text(call.id, name: call.name, "Refused: approving a pull request, resolving a review thread or passing a deployment review with the owner's GitHub account is their sign-off, and agents never give it as them. Approve as your GitHub App instead (through its ghapp.sh), or ask the people with request_reviews. If an approval doesn't count (GitHub still says review required), say why: code-owner rules usually need a person other than the author or the last pusher.", isError: true), false)
        }
        // A goal set to "only propose" changes nothing by itself.
        if spec.isConsequential, let freedom = await deps.goalFreedom?(task.id), freedom == .proposeOnly {
            record.status = .denied; record.isError = true; record.resultSummary = "Held back in goal work"; record.finishedAt = Date()
            try? await deps.store.upsertToolRecord(record)
            await publish(.toolRecordUpserted(record))
            return (ToolResult.text(call.id, name: call.name, "Held back: this goal only proposes. Put it to the owner as a card with request_approval (on_approve runs it once they approve), move the item to \"waiting\", and carry on with something else.", isError: true), spec.needsDesktop)
        }
        // The owner signs off on three things only: publishing to a public page or sending email, deleting, and
        // spending money. Pennant asks on the agent's behalf and runs exactly what's approved; the rest just runs.
        // A coding run asks the same way a Claude Code run does (and for everything in "Ask for everything").
        if codingRun {
            let verdict: CodingVerdict
            do { verdict = try await codingPermission(call, task: task) } catch {
                if stopping { throw error }
                record.status = .cancelled; record.finishedAt = Date()
                try? await deps.store.upsertToolRecord(record)
                await publish(.toolRecordUpserted(record))
                return (ToolResult.text(call.id, name: call.name, "Cancelled while waiting for the owner.", isError: true), false)
            }
            switch verdict {
            case .refuse(let why):
                record.status = .denied; record.isError = true; record.resultSummary = String(why.prefix(300)); record.finishedAt = Date()
                try? await deps.store.upsertToolRecord(record)
                await publish(.toolRecordUpserted(record))
                return (ToolResult.text(call.id, name: call.name, why, isError: true), false)
            case .run(let arguments):
                call.arguments = arguments
                record.call = call
            }
        } else if let reason = SignOff.reason(tool: spec.name, arguments: call.arguments), !(await alreadySignedOff(task: task, call: call)) {
            let command = call.arguments["command"]?.stringValue
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let shown = command ?? (String(data: (try? encoder.encode(call.arguments)) ?? Data(), encoding: .utf8) ?? spec.name)
            var request = ApprovalRequest(taskID: task.id, title: "\(reason.title): \(agent.name) wants to \(spec.name == "shell" ? "run a command" : "use \(spec.name)")",
                                          destination: spec.source.hasPrefix("mcp:") ? String(spec.source.dropFirst(4)) : spec.name, text: shown,
                                          notes: "Pennant asks before anything \(reason.why). Approving runs exactly this.")
            request.details = [ApprovalDetail(label: "Tool", value: spec.name)]
            request.approveLabel = "Approve & run"
            let decided: ApprovalRequest
            do { decided = try await requestApproval(taskID: task.id, request) } catch {
                if stopping { throw error }
                record.status = .cancelled; record.finishedAt = Date()
                try? await deps.store.upsertToolRecord(record)
                await publish(.toolRecordUpserted(record))
                return (ToolResult.text(call.id, name: call.name, "Cancelled while waiting for the owner's sign-off.", isError: true), spec.needsDesktop)
            }
            guard decided.state == .approved else {
                record.status = .denied; record.isError = true; record.resultSummary = decided.state == .changesRequested ? "Changes requested" : "Declined"; record.finishedAt = Date()
                try? await deps.store.upsertToolRecord(record)
                await publish(.toolRecordUpserted(record))
                let why = decided.comment.map { ": \($0)" } ?? "."
                return (ToolResult.text(call.id, name: call.name, decided.state == .changesRequested ? "The owner asked for a change instead\(why) Adjust and try again." : "The owner declined this\(why) Don't retry it; find another way or ask.", isError: true), spec.needsDesktop)
            }
            // The command as approved (the card lets the owner edit it).
            if let command, let edited = decided.approvedText, edited != command, case .object(var fields) = call.arguments {
                fields["command"] = .string(edited)
                call.arguments = .object(fields)
                record.call = call
            }
        }
        try? await deps.store.upsertToolRecord(record)
        await publish(.toolRecordUpserted(record))

        // Read-back rule: an identical consequential call after an uncertain outcome is refused until
        // some observation happened in between.
        if spec.isConsequential, let blocked = await needsReadback(task: task, call: call) {
            record.status = .denied; record.isError = true; record.resultSummary = "Blocked pending read-back"; record.finishedAt = Date()
            try? await deps.store.upsertToolRecord(record)
            await publish(.toolRecordUpserted(record))
            return (ToolResult.text(call.id, name: call.name, "Refused: an identical call (\(blocked.call.name)) earlier had an unknown outcome. First read back the target state with an observation tool (screenshot, read_file, shell, browser_read_page, ui_tree, memory_search), then retry only if the effect is missing.", isError: true), spec.needsDesktop)
        }
        if Self.pointerTools.contains(spec.name), !freshScreen.contains(task.id) {
            record.status = .denied; record.isError = true; record.resultSummary = "Needs a fresh screenshot"; record.finishedAt = Date()
            try? await deps.store.upsertToolRecord(record)
            await publish(.toolRecordUpserted(record))
            return (ToolResult.text(call.id, name: call.name, "Refused: take a screenshot (or read ui_tree) first so you act on the current screen.", isError: true), spec.needsDesktop)
        }

        // Desktop lease.
        if spec.needsDesktop {
            let holder = await deps.lease.currentHolder
            if holder?.taskID != task.id {
                let ownerNow = await deps.lease.owner
                let pausedNow = await deps.lease.pausedByHuman
                let mustWait = ownerNow != .nobody || pausedNow
                let waitReason: String
                switch (ownerNow, pausedNow) {
                case (.human, _): waitReason = "The user has control of the computer"
                case (_, true): waitReason = "Computer use is paused"
                case (.agent, _): waitReason = "Waiting for another agent to finish with the computer"
                default: waitReason = "Waiting for the computer"
                }
                try? await transition(task.id, to: .waitingForDesktop, reason: waitReason)
                await setAgentStatus(agent.id, .waitingForDesktop, line: waitReason)
                let waitStart = Date()
                do {
                    _ = try await deps.lease.acquire(agentID: agent.id, taskID: task.id)
                } catch {
                    if stopping { throw error }
                    record.status = .cancelled; record.finishedAt = Date()
                    try? await deps.store.upsertToolRecord(record)
                    await publish(.toolRecordUpserted(record))
                    return (ToolResult.text(call.id, name: call.name, "Cancelled while waiting for the desktop.", isError: true), true)
                }
                try? await transition(task.id, to: .running, reason: "Desktop acquired")
                // Someone else used the screen meanwhile: the last screenshot is stale.
                if mustWait || Date().timeIntervalSince(waitStart) > 2 {
                    freshScreen.remove(task.id)
                    if Self.pointerTools.contains(spec.name) {
                        record.status = .denied; record.isError = true; record.resultSummary = "Screen changed while waiting"; record.finishedAt = Date()
                        try? await deps.store.upsertToolRecord(record)
                        await publish(.toolRecordUpserted(record))
                        return (ToolResult.text(call.id, name: call.name, "The computer was in use by someone else while you waited. Take a new screenshot before this action.", isError: true), true)
                    }
                }
            }
        }

        try? await transition(task.id, to: .waitingForTool, reason: "Running \(spec.name)")
        await setAgentStatus(agent.id, spec.needsDesktop ? .acting : .thinking, line: "Using \(spec.name)")
        record.status = .running
        try? await deps.store.upsertToolRecord(record)
        await publish(.toolRecordUpserted(record))

        let hooks = makeHooks(agentID: agent.id, taskID: task.id)
        // A coding run's token may have run out while a card waited.
        if codingRun { await refreshCodingIdentity(task.id, agentID: agent.id) }
        let context = ToolContext(agentID: agent.id, taskID: task.id, conversationID: task.conversationID, store: deps.store, desktop: deps.desktop, lease: deps.lease, config: deps.config,
                                  runtimeHooks: hooks, project: projectScope(task.id))

        var result: ToolResult
        do {
            if spec.source.hasPrefix("mcp:"), case .handled(let text, let failed)? = await deps.routeTeamsSend?(spec.name, call.arguments, agent.id, task.conversationID) {
                result = ToolResult.text(call.id, name: call.name, text, isError: failed)
            } else {
                let parks = Self.waitsOnOthers.contains(spec.name)
                if parks { parked.insert(task.id); await schedule() }
                defer { if parks { parked.remove(task.id) } }
                let arguments = call.arguments
                result = try await withTimeout(seconds: Self.waitsForUser.contains(spec.name) ? 30 * 86_400 : 900) { try await tool.invoke(arguments, context: context) }
            }
            result.callID = call.id
            result.name = call.name
            record.status = .succeeded
            record.isError = result.isError
            if result.isError { record.status = .failed }
            record.resultSummary = String(result.textContent.prefix(300))
            if Self.observationTools.contains(spec.name) { freshScreen.insert(task.id) }
        } catch is CancellationError {
            if stopping { throw CancellationError() }
            record.status = spec.isConsequential ? .uncertain : .cancelled
            record.reconciliationNote = spec.isConsequential ? "Cancelled while running; effect unknown" : nil
            record.finishedAt = Date()
            try? await deps.store.upsertToolRecord(record)
            await publish(.toolRecordUpserted(record))
            try? await transition(task.id, to: .running, reason: "Tool cancelled")
            return (ToolResult.text(call.id, name: call.name, "Cancelled.", isError: true), spec.needsDesktop)
        } catch let error as DesktopError {
            if case .permissionMissing(let label) = error {
                await promptForPermission(label, agent: agent)
            }
            result = ToolResult.text(call.id, name: call.name, error.description, isError: true)
            record.status = .failed; record.isError = true; record.resultSummary = String(error.description.prefix(300))
        } catch let error as ToolError {
            if case .desktopRevoked = error {
                record.status = .denied
                record.resultSummary = "Desktop control revoked"
                record.finishedAt = Date()
                try? await deps.store.upsertToolRecord(record)
                await publish(.toolRecordUpserted(record))
                freshScreen.remove(task.id)
                var r = ToolResult.text(call.id, name: call.name, error.description, isError: true)
                r.runtimeSignal = .desktopRevoked
                return (r, true)
            }
            result = ToolResult.text(call.id, name: call.name, error.description, isError: true)
            record.status = .failed; record.isError = true; record.resultSummary = String(error.description.prefix(300))
        } catch {
            if stopping { throw CancellationError() }
            result = ToolResult.text(call.id, name: call.name, "Tool failed: \(error)", isError: true)
            record.status = .failed; record.isError = true; record.resultSummary = String("\(error)".prefix(300))
        }
        record.finishedAt = Date()
        try? await deps.store.upsertToolRecord(record)
        await publish(.toolRecordUpserted(record))
        try? await transition(task.id, to: .running, reason: "Tool finished")
        return (result, spec.needsDesktop)
    }

    /// A tool hit a missing macOS grant: show the system prompt now (once per label per process) and tell the user.
    private func promptForPermission(_ label: String, agent: AgentProfile) async {
        let targets = PermissionCheck.targets(forMissing: label)
        let grantee = PermissionCheck.grantee()
        await publish(.notice(level: .warning, agentID: agent.id, text: "\(agent.name) needs the macOS permission \"\(label)\" for \(grantee). Grant it in System Settings › Privacy & Security, then resume."))
        guard !targets.isEmpty, !promptedPermissions.contains(label) else { return }
        promptedPermissions.insert(label)
        let desktop = deps.desktop
        Task { _ = await desktop.requestPermissions(targets: targets) }
    }

    func removeMessages(_ ids: [MessageID], in conversation: ConversationID) async {
        try? await deps.store.deleteMessages(ids)
        await publish(.messagesRemoved(conversationID: conversation, ids: ids))
    }

    private func needsReadback(task: TaskRecord, call: ToolCall) async -> ToolRecord? {
        guard let records = try? await deps.store.toolRecords(taskID: task.id) else { return nil }
        guard let uncertain = records.last(where: { $0.status == .uncertain && $0.call.name == call.name && $0.call.arguments == call.arguments }) else { return nil }
        let observedSince = records.contains { r in
            r.startedAt > uncertain.startedAt && r.status == .succeeded && (Self.observationTools.contains(r.call.name) || ["read_file", "shell", "list_directory", "browser_read_page", "memory_search"].contains(r.call.name))
        }
        return observedSince ? nil : uncertain
    }

    func makeHooks(agentID caller: AgentID, taskID callerTask: TaskID? = nil) -> RuntimeHooks {
        var hooks = RuntimeHooks(
            delegate: { [self] parent, title, objective, criteria, context, name, role in
                try await self.delegate(parentTaskID: parent, title: title, objective: objective, completionCriteria: criteria, context: context, workerName: name, workerRole: role)
            },
            awaitTask: { [self] id, timeout in try await self.awaitTask(id, timeout: timeout) },
            askUser: { [self] taskID, question in try await self.askUser(taskID: taskID, question: question) },
            learnSkill: { [self] taskID, skill in try await self.learnSkill(taskID: taskID, skill) },
            scheduleJob: { [self] name, schedule, prompt, skillID in
                guard let scheduler = await self.scheduler else { throw ToolError.failed("Scheduler unavailable") }
                return try await scheduler.upsert(ScheduledJob(name: name, agentID: caller, skillID: skillID, prompt: prompt, schedule: schedule, createdByAgentID: caller))
            },
            deleteSchedule: { [self] id in
                guard let scheduler = await self.scheduler else { throw ToolError.failed("Scheduler unavailable") }
                // A goal's own jobs follow the goal; replacing them with plain jobs cuts them off from its board.
                if let job = try await self.deps.store.schedule(id), job.goalID != nil {
                    throw ToolError.failed("That's a goal's own job (\(job.name)). Change when it runs with update_goal (work_schedule / review_schedule), or pause the goal; don't delete or recreate it.")
                }
                try await scheduler.delete(id)
            },
            importSkills: { [self] path in
                let result = await SkillImporter.importAll(path: path, store: self.deps.store, eventBus: self.deps.eventBus, workingDirectory: self.deps.config.workingDirectory)
                return (result.skills, result.warnings)
            },
            shareFile: { [self] taskID, ref in try await self.shareFile(taskID: taskID, ref) }
        )
        hooks.requestApproval = { [self] taskID, request in try await self.requestApproval(taskID: taskID, request) }
        hooks.startCoding = { [self] request, folder, mode, thread in
            guard let coding = await self.deps.config.coding, !coding.projects.isEmpty else {
                throw ToolError.failed("Coding isn't set up on this host: the owner adds a project folder in Settings › Pennant › Coding.")
            }
            if let callerTask {
                // One run at a time per task, and a few at most: asking again while one works is a loop, not a plan.
                let earlier = ((try? await self.deps.store.listTasks(agentID: caller, includeFinished: true)) ?? []).filter { $0.requestedByTaskID == callerTask }
                if thread == nil, let running = earlier.first(where: { !$0.state.isTerminal }) {
                    throw ToolError.failed("A coding run from this task is still going (task \(running.id.rawValue)). Call await_task with that id, or pass its thread to follow up.")
                }
                if earlier.count >= 4 { throw ToolError.failed("This task has already started \(earlier.count) coding runs. Answer with what you have.") }
            }
            var conversationID: ConversationID?
            if let thread {
                guard let c = try await self.deps.store.conversation(thread), c.agentID == caller, c.isCodingRun else {
                    throw ToolError.failed("\(thread.rawValue) isn't one of your coding threads.")
                }
                conversationID = c.id
            }
            // A follow-up stays in its thread's folder; a new run goes to the project asked for.
            let path = conversationID == nil ? try Self.projectFolder(folder, in: coding) : nil
            let (_, cid, taskID) = try await self.submitUserMessage(agentID: caller, conversationID: conversationID, text: request, attachments: [],
                                                                    folder: path, mode: coding.mode(asked: mode), requestedBy: callerTask, engine: coding.engine)
            return (taskID, cid)
        }
        hooks.delegateOnModel = { [self] parent, title, objective, criteria, context, name, role, model in
            try await self.delegate(parentTaskID: parent, title: title, objective: objective, completionCriteria: criteria, context: context, workerName: name, workerRole: role, model: model)
        }
        hooks.approval = { [self] id in try await self.findApproval(id)?.request }
        hooks.markPublished = { [self] id, url in try await self.updateApproval(id) { $0.publishedURL = url } }
        hooks.postApproval = { [self] taskID, request in try await self.postApproval(taskID: taskID, request) }
        hooks.postProposal = { [self] taskID, request in try await self.postApproval(taskID: taskID, request, proposal: true) }
        hooks.postPart = { [self] taskID, part in try await self.postPart(taskID: taskID, part) }
        return hooks
    }
}
