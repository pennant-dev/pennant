import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// A model stand-in that replays scripted turns. Each turn may run a hook before it answers,
/// and a turn can block until released to simulate a slow model for pause tests.
final class ScriptedProvider: InferenceProvider, @unchecked Sendable {
    struct Turn {
        var text: String = ""
        var toolCalls: [ToolCall] = []
        var before: (@Sendable () async -> Void)? = nil
        var blockUntilReleased = false
        /// Computed at request time, e.g. to reference ids created earlier in the run.
        var dynamicToolCalls: (@Sendable () async -> [ToolCall])? = nil
    }
    private let lock = NSLock()
    private var turns: [Turn]
    /// Turns served to task-scoped workers (system prompt says so), so parent and worker scripts never interleave.
    var workerTurns: [Turn] = []
    /// Turns served to coding runs on the Pennant engine (their system prompt has "## How to code"), likewise.
    var codingTurns: [Turn] = []
    private(set) var requests: [InferenceRequest] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var gateOpen = false

    init(_ turns: [Turn]) { self.turns = turns }

    var contextWindowTokens = 32_000
    /// Returned for checkpoint (jsonMode) requests without consuming a scripted turn.
    var checkpointJSON = "{\"decisions\":[\"use echo\"],\"completedWork\":[\"ran echo repeatedly\"],\"pendingActions\":[],\"unresolvedQuestions\":[],\"nextStep\":\"finish\",\"historySummary\":\"Echoed lorem ipsum repeatedly.\"}"
    var capabilities: InferenceCapabilities { InferenceCapabilities(vision: true, tools: true, contextWindowTokens: contextWindowTokens, maxOutputTokens: 2048, model: "scripted", endpoint: "memory") }
    func estimateTokens(_ messages: [ModelMessage], tools: [ToolSpec]) -> Int { TokenEstimator.tokens(for: messages, tools: tools) }
    func healthCheck() async -> Bool { true }

    func release() {
        lock.lock()
        gateOpen = true
        let g = gate
        gate = nil
        lock.unlock()
        g?.resume()
    }

    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceChunk, Error> {
        lock.lock()
        requests.append(request)
        let isWorker = request.messages.first?.text.contains("task-scoped worker") ?? false
        let isCoding = request.messages.first?.text.contains("## How to code") ?? false
        let turn: Turn
        if request.jsonMode { turn = Turn(text: checkpointJSON) }
        else if isWorker { turn = workerTurns.isEmpty ? Turn(text: "(no more worker turns)") : workerTurns.removeFirst() }
        else if isCoding { turn = codingTurns.isEmpty ? Turn(text: "(no more coding turns)") : codingTurns.removeFirst() }
        else { turn = turns.isEmpty ? Turn(text: "(no more scripted turns)") : turns.removeFirst() }
        lock.unlock()
        return AsyncThrowingStream { continuation in
            let task = Task {
                await turn.before?()
                if turn.blockUntilReleased {
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                            self.lock.lock()
                            if self.gateOpen { self.lock.unlock(); c.resume(); return }
                            self.gate = c
                            self.lock.unlock()
                        }
                    } onCancel: { self.release() }
                    if Task.isCancelled { continuation.yield(.finished(.cancelled)); continuation.finish(); return }
                }
                for word in turn.text.split(separator: " ", omittingEmptySubsequences: false) {
                    continuation.yield(.textDelta(String(word) + " "))
                }
                let calls = turn.toolCalls + (await turn.dynamicToolCalls?() ?? [])
                for call in calls { continuation.yield(.toolCall(call)) }
                continuation.yield(.usage(TokenUsage(inputTokens: 100, outputTokens: 20)))
                continuation.yield(.finished(calls.isEmpty ? .stop : .toolCalls))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class NullHumanInput: HumanInputObserving, @unchecked Sendable {
    var last: Date?
    func lastHumanInputAt() async -> Date? { last }
    func start() async {}
    func stop() async {}
}

final class RuntimeTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: paths.root)
    }

    func makeService(_ provider: ScriptedProvider, desktop: FakeDesktop = FakeDesktop(), keepRecentMessages: Int = 8, budget: TaskBudget? = nil) async throws -> HostService {
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        config.compaction.keepRecentMessages = keepRecentMessages
        if let budget { config.defaultBudget = budget }
        let service = try HostService(paths: paths, config: config, desktop: desktop, humanInput: NullHumanInput(), provider: provider)
        try await service.start(startAPI: false)
        return service
    }

    func waitForTask(_ service: HostService, _ id: TaskID, state: TaskState, timeout: TimeInterval = 10) async throws -> TaskRecord {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let t = try await service.store.task(id), t.state == state { return t }
            try await Task.sleep(for: .milliseconds(30))
        }
        let t = try await service.store.task(id)
        XCTFail("Task did not reach \(state); is \(t?.state.rawValue ?? "missing") (\(t?.stateReason ?? ""))")
        throw ToolError.timeout
    }

    func defaultAgent(_ service: HostService) async throws -> AgentProfile {
        let agents = try await service.store.listAgents(includeRetired: false)
        return try XCTUnwrap(agents.first { $0.kind == .persistent })
    }

    // MARK: Tests

    func testChatCompletesTaskAndPersistsEverything() async throws {
        let provider = ScriptedProvider([.init(text: "Hello! I can help with that.")])
        let service = try await makeService(provider)
        let agent = try await defaultAgent(service)
        let (_, conversationID, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Hi there", attachments: [])
        let task = try await waitForTask(service, taskID, state: .completed)
        XCTAssertEqual(task.resultSummary?.trimmingCharacters(in: .whitespaces), "Hello! I can help with that.")
        let messages = try await service.store.messagesAfter(conversationID: conversationID, after: nil, limit: 10)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertFalse(messages[1].isStreaming)
        let transitions = try await service.store.transitions(taskID: taskID)
        XCTAssertEqual(transitions.map(\.to), [.running, .completed])
        let events = try await service.store.events(afterSeq: 0, limit: 1000)
        XCTAssertTrue(events.contains { if case .messageFinalized = $0.payload { return true } else { return false } })
        XCTAssertTrue(events.map(\.seq) == events.map(\.seq).sorted())
        let updated = try await service.store.agent(agent.id)
        XCTAssertEqual(updated?.status, .idle)
        // The model saw the agent's identity and the standing instructions block.
        let system = provider.requests.first?.messages.first?.text ?? ""
        XCTAssertTrue(system.contains("You are Pennant"))
        await service.stop()
    }

    func testToolLoopRecordsIntentAndOutcome() async throws {
        let call = ToolCall(id: ToolCallID("c1"), name: "shell", arguments: ["command": "echo pennant-works"])
        let provider = ScriptedProvider([
            .init(text: "Running a command.", toolCalls: [call]),
            .init(text: "Done: the command printed pennant-works."),
        ])
        let service = try await makeService(provider)
        let agent = try await defaultAgent(service)
        let (_, conversationID, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Run echo", attachments: [])
        _ = try await waitForTask(service, taskID, state: .completed)
        let records = try await service.store.toolRecords(taskID: taskID)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].status, .succeeded)
        XCTAssertTrue(records[0].resultSummary.contains("pennant-works"))
        let messages = try await service.store.messagesAfter(conversationID: conversationID, after: nil, limit: 10)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .tool, .assistant])
        // The second request carried the tool result back to the model.
        let second = provider.requests[1].messages
        XCTAssertTrue(second.contains { $0.role == .tool && $0.toolCallID == ToolCallID("c1") && $0.text.contains("pennant-works") })
        XCTAssertTrue(second.contains { $0.role == .assistant && $0.toolCalls.map(\.id) == [ToolCallID("c1")] })
        await service.stop()
    }

    /// A request from a shared chat acts like any other; only the owner's sign-offs (here: deleting) wait on a card.
    func testRequestsFromASharedChatActAndDeletesWaitForTheOwner() async throws {
        let dir = "${TMPDIR:-/tmp}/pennant-shared-chat-test-\(UUID().uuidString.prefix(6))"
        let make = ToolCall(id: ToolCallID("c1"), name: "shell", arguments: ["command": .string("mkdir -p \"\(dir)\"")])
        let remove = ToolCall(id: ToolCallID("c2"), name: "shell", arguments: ["command": "rm -r ~/pennant-nothing-here"])
        let provider = ScriptedProvider([
            .init(text: "Hi all."),
            .init(toolCalls: [make]),
            .init(text: "Made it."),
            .init(toolCalls: [remove]),
            .init(text: "Not deleted."),
        ])
        let service = try await makeService(provider)
        let agent = try await defaultAgent(service)
        let (_, conversationID, first) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "hello", attachments: [])
        _ = try await waitForTask(service, first, state: .completed)
        var chat = ChannelContact(kind: .teams, address: "19:founders@thread.v2", name: "Founders", allowed: true, conversationID: conversationID)
        chat.details = ["group": "19:founders@thread.v2", "type": "groupChat"]
        try await service.channels.upsert(chat)

        let (_, _, acted) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: conversationID, text: "make the folder", attachments: [],
                                                                        author: MessageAuthor(id: PersonID("teams:jonas"), name: "Jonas"))
        _ = try await waitForTask(service, acted, state: .completed)
        let made = try await service.store.toolRecords(taskID: acted)
        XCTAssertEqual(made.map(\.status), [.succeeded], "someone else in the chat can get things done")

        let (_, _, deleting) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: conversationID, text: "delete it", attachments: [],
                                                                           author: MessageAuthor(id: PersonID("teams:jonas"), name: "Jonas"))
        var card: PendingApproval?
        let deadline = Date().addingTimeInterval(10)
        while card == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
            card = try await service.runtime.pendingApprovals().first
        }
        let pending = try XCTUnwrap(card, "deleting waits on the owner")
        XCTAssertTrue(pending.request.title.hasPrefix("Delete"), pending.request.title)
        XCTAssertEqual(pending.request.text, "rm -r ~/pennant-nothing-here")
        try await service.runtime.decideApproval(ApprovalDecision(approvalID: pending.id, verdict: .reject), by: nil)
        _ = try await waitForTask(service, deleting, state: .completed)
        let refused = try await service.store.toolRecords(taskID: deleting)
        XCTAssertEqual(refused.map(\.status), [.denied])
        await service.stop()
    }

    /// A coding agent messages people through Pennant (its bridge relays `send_message`): to Pennant's contacts, from
    /// Pennant; only Pennant's messaging tools, and an answer from the group comes back to its conversation.
    func testACodingAgentMessagesPeopleThroughPennant() async throws {
        let service = try await makeService(ScriptedProvider([.init(text: "Hi.")]))
        let agent = try await defaultAgent(service)
        let (_, conversationID, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "hello", attachments: [])
        _ = try await waitForTask(service, taskID, state: .completed)
        final class Box: @unchecked Sendable { var sent: [(String, String)] = [] }
        let box = Box()
        await service.channels.useSender { c, text in box.sent.append((c.name, text)) }
        try await service.channels.setEnabled(.imessage, true)
        var group = ChannelContact(kind: .imessage, address: "Harbor", name: "Harbor", allowed: true)
        group.details = ["type": "group", "group": "chat42"]
        try await service.channels.upsert(group)

        let sent = try await service.runtime.coderTool(taskID: taskID, name: "send_message", arguments: ["to": "Harbor", "text": "Can you review backend #65?"])
        XCTAssertFalse(sent.isError, sent.text)
        XCTAssertEqual(box.sent.last?.0, "Harbor")
        XCTAssertEqual(box.sent.last?.1, "[Pennant] Can you review backend #65?")
        let listed = try await service.runtime.coderTool(taskID: taskID, name: "list_contacts", arguments: [:])
        XCTAssertTrue(listed.text.contains("Harbor"), listed.text)
        let other = try await service.runtime.coderTool(taskID: taskID, name: "shell", arguments: ["command": "echo hi"])
        XCTAssertTrue(other.isError, "only Pennant's messaging tools")

        // Jonas answers in the group without saying "Pennant": it's the answer, and it goes to the asking conversation.
        let jonas = IMessageBridge.Incoming(rowID: 9, handle: "jonas@example.com", text: "Yes, on it", group: "chat42")
        let accepted = await service.channels.imessageGroupAccepts(jonas, awaitingReply: true)
        XCTAssertEqual(accepted, "Yes, on it")
        await service.channels.received("Yes, on it", from: group.id, speaker: MessageAuthor(id: PersonID("imessage:jonas"), name: "Jonas"))
        let messages = try await service.store.messagesAfter(conversationID: conversationID, after: nil, limit: 50)
        let reply = messages.last { $0.role == .user }?.text ?? ""
        XCTAssertTrue(reply.hasPrefix("Yes, on it") && reply.contains("use send_message to \"Harbor\""), reply)
        let chatter = await service.channels.imessageGroupAccepts(jonas, awaitingReply: false)
        XCTAssertNil(chatter, "otherwise the group's own conversation stays theirs")
        await service.stop()
    }

    /// A model request that timed out or lost its connection pauses the task to carry on later; other errors fail it.
    func testANetworkBlipPausesInsteadOfFailing() {
        XCTAssertTrue(TaskRuntime.isNetworkBlip(URLError(.timedOut)))
        XCTAssertTrue(TaskRuntime.isNetworkBlip(URLError(.networkConnectionLost)))
        XCTAssertTrue(TaskRuntime.isNetworkBlip(URLError(.cannotFindHost)))
        XCTAssertTrue(TaskRuntime.isNetworkBlip(NSError(domain: NSURLErrorDomain, code: -1005)))
        XCTAssertFalse(TaskRuntime.isNetworkBlip(URLError(.badURL)))
        XCTAssertFalse(TaskRuntime.isNetworkBlip(URLError(.userAuthenticationRequired)))
        XCTAssertFalse(TaskRuntime.isNetworkBlip(ToolError.failed("nope")))
    }

    /// An answer ending in an offer gets a nudge; the next reply stands by it ("(done)") or replaces it. Either way the
    /// user sees one answer, not two.
    func testAnOfferNudgeLeavesOneAnswer() async throws {
        let provider = ScriptedProvider([
            .init(text: "All five goals are active. If you want the reviews moved too, just say."),
            .init(text: "(done)"),
            .init(text: "Here it is. Want me to also check the budgets?"),
            .init(text: "Here it is, and the budgets are fine."),
        ])
        let service = try await makeService(provider)
        let agent = try await defaultAgent(service)
        let (_, conversationID, first) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Status?", attachments: [])
        let done = try await waitForTask(service, first, state: .completed)
        XCTAssertTrue(done.resultSummary?.hasPrefix("All five goals are active") ?? false)
        var replies = try await service.store.messagesAfter(conversationID: conversationID, after: nil, limit: 20).filter { $0.role == .assistant }.map { $0.text.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(replies, ["All five goals are active. If you want the reviews moved too, just say."], "the (done) marker is gone")

        let (_, _, second) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: conversationID, text: "And now?", attachments: [])
        _ = try await waitForTask(service, second, state: .completed)
        replies = try await service.store.messagesAfter(conversationID: conversationID, after: nil, limit: 20).filter { $0.role == .assistant }.map { $0.text.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(replies.last, "Here it is, and the budgets are fine.")
        XCTAssertFalse(replies.contains("Here it is. Want me to also check the budgets?"), "the rewritten answer replaced the first")
        await service.stop()
    }

    func testPauseAndResumePreserveTask() async throws {
        let provider = ScriptedProvider([
            .init(text: "slow answer", blockUntilReleased: true),
            .init(text: "Finished after resume."),
        ])
        let service = try await makeService(provider)
        let agent = try await defaultAgent(service)
        let (_, _, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Take your time", attachments: [])
        _ = try await waitForTask(service, taskID, state: .running)
        try await Task.sleep(for: .milliseconds(100))
        try await service.runtime.pauseTask(taskID, reason: "User pressed pause")
        let paused = try await waitForTask(service, taskID, state: .paused)
        XCTAssertEqual(paused.stateReason, "User pressed pause")
        let pausedAgent = try await service.store.agent(agent.id)
        XCTAssertEqual(pausedAgent?.status, .paused)
        try await service.runtime.resumeTask(taskID)
        let done = try await waitForTask(service, taskID, state: .completed)
        XCTAssertEqual(done.resultSummary?.trimmingCharacters(in: .whitespaces), "Finished after resume.")
        let transitions = try await service.store.transitions(taskID: taskID).map(\.to)
        XCTAssertEqual(transitions, [.running, .paused, .queued, .running, .completed])
        // The resumed context told the model what happened.
        XCTAssertTrue(provider.requests.last!.messages.contains { $0.text.contains("Task resumed") })
        await service.stop()
    }

    func testAskUserWaitsForAnswer() async throws {
        let ask = ToolCall(id: ToolCallID("q1"), name: "ask_user", arguments: ["question": "Which folder?"])
        let provider = ScriptedProvider([
            .init(toolCalls: [ask]),
            .init(text: "Filed under Finance."),
        ])
        let service = try await makeService(provider)
        let agent = try await defaultAgent(service)
        let (_, conversationID, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "File this", attachments: [])
        _ = try await waitForTask(service, taskID, state: .waitingForUser)
        let waitingAgent = try await service.store.agent(agent.id)
        XCTAssertEqual(waitingAgent?.status, .waitingForUser)
        // A new message in the same conversation answers the question.
        _ = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: conversationID, text: "Finance", attachments: [])
        _ = try await waitForTask(service, taskID, state: .completed)
        let toolMessage = try await service.store.messagesAfter(conversationID: conversationID, after: nil, limit: 20).first { $0.role == .tool }
        XCTAssertTrue(toolMessage?.parts.first.map { if case .toolResult(let r) = $0 { return r.textContent.contains("Finance") } else { return false } } ?? false)
        await service.stop()
    }

    func testBudgetLimitPausesForUserAndContinuesAfterReply() async throws {
        let echo = ToolCall(id: ToolCallID("s1"), name: "shell", arguments: ["command": "echo one"])
        let provider = ScriptedProvider([
            .init(toolCalls: [echo]),
            .init(text: "All done."),
        ])
        // One step allowed: the tool call uses it, so the next turn hits the limit.
        let service = try await makeService(provider, budget: TaskBudget(maxSteps: 1, maxTokens: 0, maxDuration: 0, maxDelegations: 0))
        let agent = try await defaultAgent(service)
        let (_, conversationID, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Run echo", attachments: [])
        let waiting = try await waitForTask(service, taskID, state: .waitingForUser)
        XCTAssertTrue(waiting.stateReason.contains("1 steps"), waiting.stateReason)
        let note = try await service.store.messagesAfter(conversationID: conversationID, after: nil, limit: 20).last { $0.role == .assistant }
        XCTAssertTrue(note?.text.contains("reached 1 steps") ?? false, note?.text ?? "no note")
        // Any reply continues the task with a fresh allowance.
        _ = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: conversationID, text: "Keep going", attachments: [])
        let done = try await waitForTask(service, taskID, state: .completed)
        XCTAssertEqual(done.budget.maxSteps, 2)
        XCTAssertEqual(done.usage.steps, 2)
        XCTAssertEqual(done.resultSummary?.trimmingCharacters(in: .whitespaces), "All done.")
        await service.stop()
    }

    func testHumanTakeoverPausesAndResumeRequiresFreshScreenshot() async throws {
        let desktop = FakeDesktop()
        let shot = ToolCall(id: ToolCallID("s1"), name: "screenshot", arguments: [:])
        let click1 = ToolCall(id: ToolCallID("k1"), name: "click", arguments: ["x": 100, "y": 100])
        let click2 = ToolCall(id: ToolCallID("k2"), name: "click", arguments: ["x": 200, "y": 200])
        let shot2 = ToolCall(id: ToolCallID("s2"), name: "screenshot", arguments: [:])
        let click3 = ToolCall(id: ToolCallID("k3"), name: "click", arguments: ["x": 300, "y": 300])
        let leaseBox = Locked<DesktopLease?>(nil)
        let provider = ScriptedProvider([
            .init(toolCalls: [shot, click1]),
            .init(toolCalls: [click2], before: { await leaseBox.get()?.humanTakeover() }),   // waits for the human, then refused: stale screen
            .init(toolCalls: [shot2, click3]),   // fresh screenshot, then allowed
            .init(text: "Clicked after you handed the Mac back."),
        ])
        let service = try await makeService(provider, desktop: desktop)
        leaseBox.set(await service.lease)
        let agent = try await defaultAgent(service)
        let (_, _, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Click the button", attachments: [])
        let waiting = try await waitForTask(service, taskID, state: .waitingForDesktop)
        XCTAssertTrue(waiting.stateReason.contains("user has control"), waiting.stateReason)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(desktop.actions.filter { $0.hasPrefix("click") }.count, 1, "Only the first click ran: \(desktop.actions)")
        let ownerDuringTakeover = await service.lease.owner
        XCTAssertEqual(ownerDuringTakeover, .human)
        let agentWhileWaiting = try await service.store.agent(agent.id)
        XCTAssertEqual(agentWhileWaiting?.status, .waitingForDesktop)
        await service.lease.humanRelease()
        let done = try await waitForTask(service, taskID, state: .completed)
        XCTAssertEqual(done.resultSummary?.contains("handed the Mac back"), true)
        let clicks = desktop.actions.filter { $0.hasPrefix("click") }
        XCTAssertEqual(clicks, ["click(111,111,left,1)", "click(333,333,left,1)"], "\(desktop.actions)")
        let records = try await service.store.toolRecords(taskID: taskID)
        let denied = records.filter { $0.status == .denied }
        XCTAssertEqual(denied.map { $0.call.id }, [ToolCallID("k2")], "the click after takeover is refused until a new screenshot: \(records.map { "\($0.call.name):\($0.status.rawValue)" })")
        XCTAssertTrue(denied.first?.resultSummary.contains("Screen changed") ?? false)
        await service.stop()
    }

    func testRecoveryMarksInterruptedToolsUncertainAndBlocksBlindRetry() async throws {
        // Simulate a crash: write a running consequential tool record and a running task directly.
        let provider = ScriptedProvider([
            .init(toolCalls: [ToolCall(id: ToolCallID("r1"), name: "write_file", arguments: ["path": "out.txt", "content": "x"])]),   // blind retry: refused
            .init(toolCalls: [ToolCall(id: ToolCallID("r2"), name: "read_file", arguments: ["path": "out.txt"])]),                     // read back (fails: file absent) -> still an observation? no: must succeed
            .init(toolCalls: [ToolCall(id: ToolCallID("r3"), name: "list_directory", arguments: [:])]),                                  // observation succeeds
            .init(toolCalls: [ToolCall(id: ToolCallID("r4"), name: "write_file", arguments: ["path": "out.txt", "content": "x"])]),   // now allowed
            .init(text: "Recovered and written."),
        ])
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let store = try SQLiteStore(paths: paths)
        let agent = AgentProfile(name: "Pennant", role: "assistant")
        try await store.upsertAgent(agent)
        let conversation = Conversation(agentID: agent.id, title: "t")
        try await store.upsertConversation(conversation)
        var task = TaskRecord(agentID: agent.id, conversationID: conversation.id, title: "Write a file", objective: "Write out.txt")
        task.state = .waitingForTool
        try await store.upsertTask(task)
        try await store.appendMessage(Message(conversationID: conversation.id, agentID: agent.id, taskID: task.id, role: .user, parts: [.text("Write out.txt")]))
        let interrupted = ToolRecord(taskID: task.id, agentID: agent.id, call: ToolCall(id: ToolCallID("r0"), name: "write_file", arguments: ["path": "out.txt", "content": "x"]), status: .running)
        try await store.upsertToolRecord(interrupted)
        await store.close()

        let service = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await service.start(startAPI: false)
        let done = try await waitForTask(service, task.id, state: .completed)
        XCTAssertEqual(done.resultSummary?.contains("Recovered"), true)
        let records = try await service.store.toolRecords(taskID: task.id)
        XCTAssertEqual(records.first { $0.id == interrupted.id }?.status, .uncertain)
        XCTAssertEqual(records.first { $0.call.id == ToolCallID("r1") }?.status, .denied)
        XCTAssertEqual(records.first { $0.call.id == ToolCallID("r4") }?.status, .succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("out.txt").path))
        // The recovery note reached the model.
        XCTAssertTrue(provider.requests.first!.messages.contains { $0.text.contains("host restarted") })
        await service.stop()
    }

    /// The morning inbox run finished while two of its helpers kept searching for over an hour, reporting to nobody.
    func testAFinishedTaskStopsTheHelpersItNeverCollected() async throws {
        let delegate = ToolCall(id: ToolCallID("d1"), name: "delegate_task", arguments: ["title": "List everything", "objective": "List every message", "completion_criteria": "A list"])
        let provider = ScriptedProvider([.init(toolCalls: [delegate]), .init(text: "Done, without waiting for the helper.")])
        provider.workerTurns = [.init(text: "Still listing…", blockUntilReleased: true)]
        let service = try await makeService(provider)
        let agent = try await defaultAgent(service)
        let (_, _, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Triage the inbox", attachments: [])
        _ = try await waitForTask(service, taskID, state: .completed, timeout: 15)
        var worker: TaskRecord?
        for _ in 0..<200 {
            worker = try await service.store.childTasks(parentTaskID: taskID).first
            if worker?.state.isTerminal == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(worker?.state, .cancelled, "a helper nobody will collect is stopped when its task finishes")
        provider.release()
    }

    /// A task waiting on its helper doesn't hold a slot: with one slot, the helper still gets to run.
    func testWaitingOnAHelperDoesntHoldTheOnlySlot() async throws {
        let delegate = ToolCall(id: ToolCallID("d1"), name: "delegate_task", arguments: ["title": "Count files", "objective": "Count the files", "completion_criteria": "A number"])
        let storeBox = Locked<SQLiteStore?>(nil)
        let parentBox = Locked<TaskID?>(nil)
        let provider = ScriptedProvider([
            .init(toolCalls: [delegate]),
            .init(dynamicToolCalls: {
                var childID = "missing"
                for _ in 0..<100 {
                    if let store = storeBox.get(), let parent = parentBox.get(), let child = try? await store.childTasks(parentTaskID: parent).first { childID = child.id.rawValue; break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return [ToolCall(id: ToolCallID("a1"), name: "await_task", arguments: ["task_id": .string(childID), "timeout_seconds": 20])]
            }),
            .init(text: "3 files."),
        ])
        provider.workerTurns = [.init(text: "There are 3 files.")]
        let service = try await makeService(provider)
        await service.runtime.setMaxConcurrentTasks(1)
        storeBox.set(await service.store)
        let agent = try await defaultAgent(service)
        let (_, _, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "How many files?", attachments: [])
        parentBox.set(taskID)
        _ = try await waitForTask(service, taskID, state: .completed, timeout: 15)
        await service.stop()
    }

    func testDelegationRunsWorkerAndReturnsResult() async throws {
        let delegate = ToolCall(id: ToolCallID("d1"), name: "delegate_task", arguments: ["title": "Count files", "objective": "Count the files", "completion_criteria": "A number"])
        let storeBox = Locked<SQLiteStore?>(nil)
        let parentBox = Locked<TaskID?>(nil)
        let provider = ScriptedProvider([
            .init(toolCalls: [delegate]),
            .init(dynamicToolCalls: {
                // Look up the worker task the runtime created and wait for it.
                var childID = "missing"
                for _ in 0..<100 {
                    if let store = storeBox.get(), let parent = parentBox.get(), let child = try? await store.childTasks(parentTaskID: parent).first { childID = child.id.rawValue; break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return [ToolCall(id: ToolCallID("a1"), name: "await_task", arguments: ["task_id": .string(childID), "timeout_seconds": 20])]
            }),
            .init(text: "The worker counted 3 files."),
        ])
        provider.workerTurns = [.init(text: "There are 3 files.")]
        let service = try await makeService(provider)
        storeBox.set(await service.store)
        let agent = try await defaultAgent(service)
        let (_, _, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "How many files?", attachments: [])
        parentBox.set(taskID)
        let done = try await waitForTask(service, taskID, state: .completed, timeout: 15)
        XCTAssertEqual(done.usage.delegations, 1)
        XCTAssertEqual(done.resultSummary?.contains("counted 3 files"), true)
        let children = try await service.store.childTasks(parentTaskID: taskID)
        let worker = try XCTUnwrap(children.first)
        XCTAssertEqual(worker.state, .completed)
        XCTAssertEqual(worker.resultSummary?.contains("3 files"), true)
        let workerAgent = try await service.store.agent(worker.agentID)
        XCTAssertEqual(workerAgent?.kind, .worker)
        XCTAssertEqual(workerAgent?.status, .retired)
        // The parent received the worker's result through await_task.
        let records = try await service.store.toolRecords(taskID: taskID)
        XCTAssertEqual(records.first { $0.call.name == "await_task" }?.status, .succeeded)
        XCTAssertTrue(records.first { $0.call.name == "await_task" }?.resultSummary.contains("3 files") ?? false)
        await service.stop()
    }

    func testWorkersRunOnTheWorkerModelOrTheOneAskedFor() async throws {
        let service = try await makeService(ScriptedProvider([]))
        var config = await service.config
        let spark = InferenceProfile(name: "Spark", inference: HostConfig.Inference(baseURL: "http://127.0.0.1:9/v1", model: "qwen"))
        let sol = InferenceProfile(name: "Sol · Azure", inference: HostConfig.Inference(baseURL: "http://127.0.0.1:9/v1", model: "gpt"))
        config.inferenceProfiles += [spark, sol]
        config.workerProfileID = spark.id
        await service.runtime.updateConfig(config)
        let agent = try await defaultAgent(service)
        let conversation = Conversation(agentID: agent.id, title: "t")
        try await service.store.upsertConversation(conversation)
        var parent = TaskRecord(agentID: agent.id, conversationID: conversation.id, title: "Lead", objective: "Lead")
        parent.state = .running
        try await service.store.upsertTask(parent)

        let plain = try await service.runtime.delegate(parentTaskID: parent.id, title: "Find selectors", objective: "o", completionCriteria: "", context: "", workerName: nil, workerRole: nil)
        let asked = try await service.runtime.delegate(parentTaskID: parent.id, title: "Hard part", objective: "o", completionCriteria: "", context: "", workerName: nil, workerRole: nil, model: "sol · azure")
        let plainTask = try await service.store.task(plain), askedTask = try await service.store.task(asked)
        let plainAgent = try await service.store.agent(try XCTUnwrap(plainTask).agentID)
        let askedAgent = try await service.store.agent(try XCTUnwrap(askedTask).agentID)
        XCTAssertEqual(plainAgent?.modelProfileID, spark.id, "workers default to the worker model")
        XCTAssertEqual(askedAgent?.modelProfileID, sol.id, "a model asked for by name wins")
        do {
            _ = try await service.runtime.delegate(parentTaskID: parent.id, title: "x", objective: "o", completionCriteria: "", context: "", workerName: nil, workerRole: nil, model: "nope")
            XCTFail("an unknown model must be refused")
        } catch {}
        await service.stop()
    }

    func testCompactionSavesCheckpointWhenContextGrows() async throws {
        let big = String(repeating: "lorem ipsum dolor sit amet ", count: 300) // ~8k chars; the context keeps up to 6k per result
        var turns: [ScriptedProvider.Turn] = []
        for i in 0..<6 {
            turns.append(.init(text: "step \(i)", toolCalls: [ToolCall(id: ToolCallID("t\(i)"), name: "shell", arguments: ["command": .string("echo '\(big)'")])]))
        }
        turns.append(.init(text: "All done."))
        let provider = ScriptedProvider(turns)
        provider.contextWindowTokens = 12_000 // trigger at 9000 - 4096 output reserve ≈ 5k tokens of context
        let service = try await makeService(provider, keepRecentMessages: 2)
        let agent = try await defaultAgent(service)
        let (_, _, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Echo a lot", attachments: [])
        _ = try await waitForTask(service, taskID, state: .completed, timeout: 20)
        let checkpoints = try await service.store.checkpoints(taskID: taskID)
        XCTAssertGreaterThanOrEqual(checkpoints.count, 1)
        let cp = try XCTUnwrap(checkpoints.first)
        XCTAssertTrue(cp.historySummary.contains("evidence: events"))
        XCTAssertNotNil(cp.throughMessageID)
        let compactedTask = try await service.store.task(taskID)
        XCTAssertGreaterThanOrEqual(compactedTask?.usage.compactions ?? 0, 1)
        // After compaction the model saw the checkpoint block instead of the full history.
        let last = provider.requests.last!.messages
        XCTAssertTrue(last.first!.text.contains("## Checkpoint"))
        XCTAssertLessThan(last.count, 12)
        await service.stop()
    }

    /// The screenshot case: the agent finds a fact in email and answers, without calling memory_remember. The
    /// fact is remembered anyway, after the task, as inferred and shared, with its relation.
    func testWhatATaskFindsOutIsRememberedAfterward() async throws {
        let look = ToolCall(id: ToolCallID("l1"), name: "list_directory", arguments: ["path": .string(paths.root.path)])
        let provider = ScriptedProvider([
            .init(toolCalls: [look]),
            .init(text: "Harbor is going to LaunchConf 2026, November 17–20 at the Moscone Center in San Francisco, exhibiting at booth 1748."),
        ])
        provider.checkpointJSON = #"{"facts":[{"kind":"topic","name":"LaunchConf 2026","summary":"Harbor exhibits at LaunchConf 2026 at the Moscone Center, San Francisco.","attributes":{"dates":"2026-11-17 to 2026-11-20","booth":"1748"},"from_user":false},{"kind":"organization","name":"Harbor","summary":"The company","from_user":false}],"relations":[{"from":"Harbor","to":"LaunchConf 2026","label":"exhibits at"}]}"#
        let service = try await makeService(provider)
        let agent = try await defaultAgent(service)
        let (_, _, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "what conference is harbor going to?", attachments: [])
        _ = try await waitForTask(service, taskID, state: .completed)
        var found: MemoryEntity?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, found == nil {
            found = try await service.store.findEntities(name: "LaunchConf 2026", kind: nil, scopes: ["shared"]).first
            if found == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let launchConf = try XCTUnwrap(found, "the fact was remembered")
        XCTAssertEqual(launchConf.status, .inferred, "found out, not told: it can't override what the person asserted")
        XCTAssertEqual(launchConf.attributes["booth"]?.stringValue, "1748")
        XCTAssertEqual(launchConf.provenance.sourceID, taskID.rawValue)
        let rels = try await service.store.relations(entityID: launchConf.id, includeInactive: false)
        XCTAssertEqual(rels.first?.relation, "exhibits_at")
        await service.stop()
    }

    func testOnlyExchangesThatBroughtSomethingNewAreLearnedFrom() {
        XCTAssertTrue(MemoryLearner.worthLearning(question: "what conference is harbor going to?", answer: String(repeating: "LaunchConf 2026 details. ", count: 4), toolsUsed: ["memory_search", "mail_search"]))
        XCTAssertFalse(MemoryLearner.worthLearning(question: "what conference is harbor going to?", answer: String(repeating: "From memory. ", count: 6), toolsUsed: ["memory_search"]), "memory only: nothing new")
        XCTAssertTrue(MemoryLearner.worthLearning(question: "Sam Lee is our new head of design starting Monday", answer: "Got it, I'll keep that in mind for design questions.", toolsUsed: []), "the person told it something")
        XCTAssertFalse(MemoryLearner.worthLearning(question: "Scheduled job \"Support · triage\":\nrun it", answer: String(repeating: "Report. ", count: 10), toolsUsed: ["mail_search"]))
        let fenced = MemoryLearner.parse("```json\n{\"facts\":[{\"kind\":\"person\",\"name\":\"Sam Lee\",\"summary\":\"Head of design\",\"attributes\":{\"start\":20261001},\"from_user\":true},{\"kind\":\"topic\",\"name\":\"meeting\"}],\"relations\":[]}\n```")
        XCTAssertEqual(fenced.facts.map(\.name), ["Sam Lee"], "generic words are dropped")
        XCTAssertEqual(fenced.facts.first?.attributes?["start"], "20261001", "numbers count as values")
    }

    func testMemoryToolsAndAssertedBeatsInferred() async throws {
        let remember = ToolCall(id: ToolCallID("m1"), name: "memory_remember", arguments: ["kind": "document", "name": "Invoice 042", "summary": "Supplier invoice", "status": "asserted", "attributes": ["amount": "1200"], "relations": [["relation": "belongs_to", "target_name": "Project Atlas", "target_kind": "project"]]])
        let infer = ToolCall(id: ToolCallID("m2"), name: "memory_remember", arguments: ["kind": "document", "name": "Invoice 042", "summary": "Supplier invoice", "status": "inferred", "attributes": ["amount": "1500"]])
        let pref = ToolCall(id: ToolCallID("m3"), name: "remember_instruction", arguments: ["instruction": "Always file invoices under Finance/2026."])
        let search = ToolCall(id: ToolCallID("m4"), name: "memory_search", arguments: ["query": "invoice 042"])
        let provider = ScriptedProvider([
            .init(toolCalls: [remember, infer, pref]),
            .init(toolCalls: [search]),
            .init(text: "Stored."),
        ])
        let service = try await makeService(provider)
        let agent = try await defaultAgent(service)
        let (_, _, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Remember invoice 042 belongs to Project Atlas", attachments: [])
        _ = try await waitForTask(service, taskID, state: .completed)
        // Facts are shared by default, so every agent can use them.
        let entities = try await service.store.findEntities(name: "Invoice 042", kind: .document, scopes: ["shared"])
        XCTAssertEqual(entities.first { $0.status == .asserted }?.attributes["amount"]?.stringValue, "1200")
        XCTAssertNotNil(entities.first { $0.status == .contradicted })
        let toolRecords = try await service.store.toolRecords(taskID: taskID)
        let hits = try await service.memory.retrieve(MemoryQuery(text: "invoice 042"), agent: agent)
        let rendered = MemoryService.render(hits)
        XCTAssertTrue(rendered.contains("belongs_to"), rendered + "\n" + toolRecords.map { "\($0.call.name): \($0.status.rawValue) \($0.resultSummary)" }.joined(separator: "\n"))
        XCTAssertTrue(rendered.contains("1200"), rendered)
        let prefs = try await service.memory.governingPreferences(for: agent)
        XCTAssertEqual(prefs.map(\.text), ["Always file invoices under Finance/2026."])
        // Later tasks see the instruction in the system prompt.
        let provider2 = ScriptedProvider([.init(text: "ok")])
        await service.stop()
        let service2 = try HostService(paths: paths, config: HostConfig(desktop: .init(pauseOnHumanInput: false), workingDirectory: paths.root.path), desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider2)
        try await service2.start(startAPI: false)
        let (_, _, t2) = try await service2.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "File the invoice", attachments: [])
        _ = try await waitForTask(service2, t2, state: .completed)
        XCTAssertTrue(provider2.requests.first!.messages.first!.text.contains("Always file invoices under Finance/2026."), "standing preferences stay in the (stable) system prompt")
        XCTAssertTrue(provider2.requests.first!.messages.last!.text.contains("Invoice 042"), "memory looked up for the turn rides in the turn note")
        await service2.stop()
    }

    func testLearnSkillVersionsAndOutcomes() async throws {
        let learn = ToolCall(id: ToolCallID("l1"), name: "learn_skill", arguments: ["name": "Export report", "purpose": "Export the monthly report", "steps": [["instruction": "Open Numbers", "tool": "open_app", "check": "Numbers is frontmost"], ["instruction": "Export as PDF", "check": "PDF exists"]]])
        let provider = ScriptedProvider([.init(toolCalls: [learn]), .init(text: "Learned.")])
        let service = try await makeService(provider)
        let agent = try await defaultAgent(service)
        let (_, _, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Export the report", attachments: [])
        _ = try await waitForTask(service, taskID, state: .completed)
        let learned = try await service.store.listSkills(includeDisabled: true).filter { $0.origin == "learned" }
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned[0].status, .provisional)
        XCTAssertEqual(learned[0].outcomes.count, 1)
        XCTAssertEqual(learned[0].evidenceTaskIDs, [taskID])
        await service.stop()
    }
}

extension RuntimeTests {
    /// A follow-up task in the same conversation sees the earlier turns, and a manual compaction folds
    /// them into a conversation-wide checkpoint that the next task inherits.
    func testConversationHistoryCarriesAcrossTasksAndManualCompaction() async throws {
        let provider = ScriptedProvider([
            .init(text: "The codename is Atlas."),
            .init(text: "You asked about Atlas before; still Atlas."),
            .init(text: "After compaction I only see the summary."),
        ])
        let service = try await makeService(provider)
        let agent = try await defaultAgent(service)
        let (_, conversationID, t1) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "What is the project codename?", attachments: [])
        _ = try await waitForTask(service, t1, state: .completed)
        // Second task in the same conversation: the model must see the first exchange verbatim.
        let (_, _, t2) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: conversationID, text: "Remind me what you said.", attachments: [])
        let second = try await waitForTask(service, t2, state: .completed)
        let secondRequest = provider.requests[1].messages
        XCTAssertTrue(secondRequest.contains { $0.role == .assistant && $0.text.contains("codename is Atlas") }, "earlier assistant turn missing from context")
        XCTAssertGreaterThan(second.usage.lastContextTokens, 0)
        XCTAssertEqual(second.usage.contextWindowTokens, 32_000)

        // Manual compaction with no task running.
        let compacted = try await service.runtime.compactConversation(conversationID)
        XCTAssertEqual(compacted.usage.compactions, 1)
        XCTAssertNotNil(compacted.usage.lastCompactedAt)
        let checkpoints = try await service.store.checkpoints(conversationID: conversationID)
        XCTAssertEqual(checkpoints.count, 1)
        XCTAssertEqual(checkpoints[0].conversationID, conversationID)
        let lastMessage = try await service.store.messagesAfter(conversationID: conversationID, after: nil, limit: 100).last
        XCTAssertEqual(checkpoints[0].throughMessageID, lastMessage?.id)
        // Compacting again with nothing new is a no-op.
        let again = try await service.runtime.compactConversation(conversationID)
        XCTAssertEqual(again.usage.compactions, 1)

        // A third task inherits the checkpoint: history is summarised, not replayed.
        let (_, _, t3) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: conversationID, text: "And now?", attachments: [])
        _ = try await waitForTask(service, t3, state: .completed)
        let third = provider.requests.last!.messages
        XCTAssertTrue(third.first!.text.contains("## Checkpoint"))
        XCTAssertFalse(third.contains { $0.role == .assistant && $0.text.contains("codename is Atlas") }, "summarised turns must not be replayed verbatim")
        await service.stop()
    }

    func testChatUpdatesConversationPreviewAndOrder() async throws {
        let provider = ScriptedProvider([.init(text: "**Sure.** Here is the plan.\nStep one first.")])
        let service = try await makeService(provider)
        let agent = try await defaultAgent(service)
        let (_, conversationID, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Plan my week", attachments: [])
        _ = try await waitForTask(service, taskID, state: .completed)
        let messages = try await service.store.messagesAfter(conversationID: conversationID, after: nil, limit: 10)
        let reply = try XCTUnwrap(messages.last { $0.role == .assistant })
        let stored = try await service.store.conversation(conversationID)
        let conversation = try XCTUnwrap(stored)
        XCTAssertEqual(conversation.preview, Conversation.previewLine(reply.text))
        XCTAssertEqual(conversation.preview, "Sure. Here is the plan.")
        XCTAssertGreaterThanOrEqual(conversation.updatedAt, reply.createdAt)
        // Clients heard about it live: the user's line first, then the reply's.
        let events = try await service.store.events(afterSeq: 0, limit: 1000)
        let previews = events.compactMap { event -> String? in
            if case .conversationUpserted(let c) = event.payload, c.id == conversationID { return c.preview } else { return nil }
        }
        XCTAssertTrue(previews.contains("Plan my week"), "\(previews)")
        XCTAssertEqual(previews.last, "Sure. Here is the plan.")
        await service.stop()
    }

    func testShareFileHandsFileToUserAndRefusesCredentials() async throws {
        let dir = paths.root.appendingPathComponent("share-test", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let report = dir.appendingPathComponent("report.md")
        let body = String(repeating: "# Quarterly report\nline\n", count: 100) // 2400 bytes
        try Data(body.utf8).write(to: report)
        let pem = dir.appendingPathComponent("server.pem")
        // Split so secret scanners don't mistake the fixture for a real key.
        try Data(("-----BEGIN " + "PRIVATE KEY-----\n").utf8).write(to: pem)

        let share = ToolCall(id: ToolCallID("f1"), name: "share_file", arguments: ["path": .string(report.path), "caption": "The quarterly report"])
        let refused = ToolCall(id: ToolCallID("f2"), name: "share_file", arguments: ["path": .string(pem.path)])
        let provider = ScriptedProvider([
            .init(text: "Here is the report.", toolCalls: [share]),
            .init(text: "And the key.", toolCalls: [refused]),
            .init(text: "Shared the report; the key stays where it is."),
        ])
        let service = try await makeService(provider)
        let agent = try await defaultAgent(service)
        let (_, conversationID, taskID) = try await service.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Send me the report", attachments: [])
        _ = try await waitForTask(service, taskID, state: .completed)

        // Tool records: the share succeeded and named the size; the credential file was refused with the reason.
        let records = try await service.store.toolRecords(taskID: taskID)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].status, .succeeded)
        XCTAssertEqual(records[0].resultSummary, "Shared report.md (2 KB) with the user.")
        XCTAssertEqual(records[1].status, .failed)
        XCTAssertTrue(records[1].resultSummary.contains("Refused: server.pem looks like a credential file"), records[1].resultSummary)

        // The conversation carries an assistant message whose only part is the file, posted where the tool ran.
        let messages = try await service.store.messagesAfter(conversationID: conversationID, after: nil, limit: 20)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .assistant, .tool, .assistant, .tool, .assistant])
        guard case .file(let ref)? = messages[2].parts.first, messages[2].parts.count == 1 else { return XCTFail("expected a file-only assistant message, got \(messages[2].parts)") }
        XCTAssertEqual(ref.fileName, "report.md")
        XCTAssertEqual(ref.byteCount, body.utf8.count)
        XCTAssertEqual(ref.mimeType, "text/markdown")
        XCTAssertEqual(ref.caption, "The quarterly report")

        // The bytes round-trip through the artifact store under kind "file".
        let artifact = try await service.store.artifact(ref.artifactID)
        XCTAssertEqual(artifact?.kind, "file")
        XCTAssertEqual(artifact?.fileName, "report.md")
        XCTAssertEqual(artifact?.taskID, taskID)
        let data = try await service.store.artifactData(ref.artifactID)
        XCTAssertEqual(data, Data(body.utf8))
        // Only one artifact was written: the refused file never reached the store.
        let pemArtifacts = messages.flatMap(\.parts).filter { if case .file(let f) = $0 { return f.fileName == "server.pem" } else { return false } }
        XCTAssertTrue(pemArtifacts.isEmpty)

        // The model sees the file as a text line placed after the tool result, so the call/result pair stays intact
        // and no "unknown outcome" is invented for share_file.
        let third = provider.requests[2].messages
        let fileLineIndex = try XCTUnwrap(third.firstIndex { $0.role == .assistant && $0.text == "[shared file: report.md, 2 KB]" })
        XCTAssertEqual(third[fileLineIndex - 1].role, .tool)
        XCTAssertEqual(third[fileLineIndex - 1].toolCallID, ToolCallID("f1"))
        XCTAssertEqual(third[fileLineIndex - 2].role, .assistant)
        XCTAssertEqual(third[fileLineIndex - 2].toolCalls.map(\.id), [ToolCallID("f1")])
        XCTAssertFalse(third.contains { $0.text.contains("no result recorded") })
        XCTAssertFalse(third.contains { $0.text.contains("Quarterly report\nline") }, "file bytes must never be inlined")
        await service.stop()
    }
}
