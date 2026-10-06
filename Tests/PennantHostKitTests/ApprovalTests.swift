import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

final class ApprovalTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private func service(_ provider: ScriptedProvider) async throws -> HostService {
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        return s
    }

    private func waitFor(_ s: HostService, _ id: TaskID, _ state: TaskState) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if try await s.store.task(id)?.state == state { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("task never reached \(state)")
    }

    func testApprovalCardWaitsAndReturnsTheEditedText() async throws {
        let image = paths.root.appendingPathComponent("slide-1.png")
        try AttachmentTests.png.write(to: image)
        let ask = ToolCall(id: ToolCallID("a1"), name: "request_approval", arguments: [
            "title": "LinkedIn post: guardrails", "destination": "LinkedIn · Acme company page",
            "text": "Original text.", "images": .array([.string(image.path)]), "notes": "Sources: example.com",
        ])
        let provider = ScriptedProvider([.init(toolCalls: [ask]), .init(text: "Published.")])
        let s = try await service(provider)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Post it", attachments: [])
        try await waitFor(s, taskID, .waitingForUser)

        let messages = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 50)
        let card: ApprovalRequest = try XCTUnwrap(messages.lazy.flatMap(\.parts).compactMap { if case .approval(let a) = $0 { return a }; return nil }.first)
        XCTAssertEqual(card.state, .pending)
        XCTAssertEqual(card.images.count, 1)
        let stored = try await s.store.artifactData(card.images[0].artifactID)
        XCTAssertEqual(stored, AttachmentTests.png)

        let client = ConnectedClient(id: ClientID("t"), displayName: "t", platform: "t")
        guard case .ok = await s.handle(.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .approve, editedText: "Edited text.", comment: "ship it")), from: client) else { return XCTFail("decision refused") }
        try await waitFor(s, taskID, .completed)

        let after = try await s.runtime.findApproval(card.id)?.request
        XCTAssertEqual(after?.state, .approved)
        XCTAssertEqual(after?.finalText, "Edited text.")
        let toolResult = provider.requests.last?.messages.last { $0.role == .tool }?.text ?? ""
        XCTAssertTrue(toolResult.contains("APPROVED"))
        XCTAssertTrue(toolResult.contains("Edited text."))
        guard case .error = await s.handle(.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .reject)), from: client) else { return XCTFail("a decided approval was decided again") }
        await s.stop()
    }

    /// A stand-in "send" tool that records what it was asked to send.
    final class RecordingSendTool: Tool, @unchecked Sendable {
        let lock = NSLock()
        var calls: [JSONValue] = []
        var spec: ToolSpec { ToolSpec(name: "test_send_reply", description: "Sends a reply.", inputSchema: JSONSchema.object(["id": JSONSchema.string("id"), "body": JSONSchema.string("body")], required: ["id", "body"])) }
        func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
            lock.withLock { calls.append(arguments) }
            return .text(ToolCallID("pending"), name: spec.name, "Replied.")
        }
    }

    func testCardsWithAnActionDontWaitAndSendExactlyTheApprovedText() async throws {
        let ask = ToolCall(id: ToolCallID("a1"), name: "request_approval", arguments: [
            "title": "Reply: Q3 pricing", "destination": "Outlook · reply to dana@example.com", "text": "Draft reply.",
            "headline": "Re: Q3 pricing",
            "on_approve": .object(["tool": "test_send_reply", "arguments": .object(["id": "msg-42"]), "text_field": "body", "label": "Approve & send"]),
        ])
        let provider = ScriptedProvider([.init(toolCalls: [ask]), .init(text: "Drafted 1 reply for approval.")])
        let s = try await service(provider)
        let sender = RecordingSendTool()
        await s.broker.register(sender)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Triage my inbox", attachments: [])
        // The task doesn't wait for the decision.
        try await waitFor(s, taskID, .completed)
        let messages = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 50)
        let card: ApprovalRequest = try XCTUnwrap(messages.lazy.flatMap(\.parts).compactMap { if case .approval(let a) = $0 { return a }; return nil }.first)
        XCTAssertEqual(card.action?.tool, "test_send_reply")
        XCTAssertTrue(sender.calls.isEmpty, "nothing is sent before approval")
        let waiting = try await s.runtime.pendingApprovals()
        XCTAssertEqual(waiting.map(\.id), [card.id])
        XCTAssertEqual(waiting.first?.agentID, agent.id)
        XCTAssertEqual(waiting.first?.conversationID, conversationID)

        let client = ConnectedClient(id: ClientID("t"), displayName: "t", platform: "t")
        guard case .ok = await s.handle(.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .approve, editedText: "Edited reply.")), from: client) else { return XCTFail("decision refused") }
        XCTAssertEqual(sender.calls.count, 1)
        XCTAssertEqual(sender.calls.first?["body"]?.stringValue, "Edited reply.", "the approved (edited) text is what gets sent")
        XCTAssertEqual(sender.calls.first?["id"]?.stringValue, "msg-42")
        let after = try await s.runtime.findApproval(card.id)?.request
        XCTAssertEqual(after?.actionFailed, false)
        XCTAssertEqual(after?.actionResult, "Replied.")
        guard case .error = await s.handle(.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .approve)), from: client) else { return XCTFail("approved twice") }
        XCTAssertEqual(sender.calls.count, 1, "never sent twice")
        let afterDecision = try await s.runtime.pendingApprovals()
        XCTAssertTrue(afterDecision.isEmpty, "a decided card leaves the pending list")
        await s.stop()
    }

    final class RecordingConnectionTool: Tool, @unchecked Sendable {
        let lock = NSLock()
        var calls: [JSONValue] = []
        var spec: ToolSpec { ToolSpec(name: "microsoft_365__mail_reply", description: "[Microsoft 365] Replies to a message.", inputSchema: JSONSchema.object([:]), isConsequential: true, needsDesktop: false, source: "mcp:microsoft-365") }
        func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
            lock.withLock { calls.append(arguments) }
            return .text(ToolCallID("pending"), name: spec.name, "Replied.")
        }
    }

    func testTheBrokerFindsAConnectionsToolTheWaysModelsWriteIt() async {
        let broker = ToolBroker()
        await broker.registerMCPTools([FakeServiceTool(server: "microsoft-365", serverName: "Microsoft 365", name: "mail_reply")], server: MCPServerID("microsoft-365"))
        // The forms cards were written with before this was checked, and the real one.
        for name in ["microsoft_365__mail_reply", "mcp:Microsoft 365:mail_reply", "mcp:microsoft-365:mail_reply", "mcp:microsoft_365:mail_reply", "Microsoft 365/mail_reply", " mcp:microsoft_365__mail_reply "] {
            let found = await broker.resolve(name)?.spec.name
            XCTAssertEqual(found, "microsoft_365__mail_reply", name)
        }
        let missing = await broker.resolve("mcp:Microsoft 365:mail_forward")
        XCTAssertNil(missing)
        let close = await broker.whyMissing("mail_reply")
        XCTAssertTrue(close.contains("Did you mean microsoft_365__mail_reply?"), close)
        let offline = await broker.whyMissing("mcp:Nowhere:send")
        XCTAssertTrue(offline.contains("no connection called Nowhere is connected"), offline)
    }

    func testACardNamingAConnectionsToolLooselyRunsTheRealOne() async throws {
        let ask = ToolCall(id: ToolCallID("a1"), name: "request_approval", arguments: [
            "title": "Reply: Q3 pricing", "destination": "Outlook · reply to dana@example.com", "text": "Draft reply.",
            "on_approve": .object(["tool": "mcp:Microsoft 365:mail_reply", "arguments": .object(["id": "msg-7"]), "text_field": "body"]),
        ])
        let provider = ScriptedProvider([.init(toolCalls: [ask]), .init(text: "Drafted.")])
        let s = try await service(provider)
        let reply = RecordingConnectionTool()
        await s.broker.registerMCPTools([reply], server: MCPServerID("microsoft-365"))
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Reply to Dana", attachments: [])
        try await waitFor(s, taskID, .completed)
        let messages = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 50)
        let card: ApprovalRequest = try XCTUnwrap(messages.lazy.flatMap(\.parts).compactMap { if case .approval(let a) = $0 { return a }; return nil }.first)
        XCTAssertEqual(card.action?.tool, "microsoft_365__mail_reply", "the card carries the tool's real name")
        XCTAssertTrue(provider.requests.last?.messages.last { $0.role == .tool }?.text.contains("Pennant runs microsoft_365__mail_reply") == true)

        let client = ConnectedClient(id: ClientID("t"), displayName: "t", platform: "t")
        guard case .ok = await s.handle(.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .approve)), from: client) else { return XCTFail("decision refused") }
        XCTAssertEqual(reply.calls.first?["body"]?.stringValue, "Draft reply.")
        let after = try await s.runtime.findApproval(card.id)?.request
        XCTAssertEqual(after?.actionFailed, false)
        await s.stop()
    }

    func testACardWhoseActionNamesNoToolNeverGoesUp() async throws {
        let ask = ToolCall(id: ToolCallID("a1"), name: "request_approval", arguments: [
            "title": "Reply", "destination": "Mail", "text": "Draft reply.",
            "on_approve": .object(["tool": "mcp:Nowhere:send", "text_field": "body"]),
        ])
        let provider = ScriptedProvider([.init(toolCalls: [ask]), .init(text: "Couldn't put it up.")])
        let s = try await service(provider)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Reply", attachments: [])
        try await waitFor(s, taskID, .completed)
        let messages = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 50)
        XCTAssertFalse(messages.contains { $0.parts.contains { if case .approval = $0 { return true }; return false } }, "no card that would fail once approved")
        let result = provider.requests.last?.messages.last { $0.role == .tool }?.text ?? ""
        XCTAssertTrue(result.contains("no connection called Nowhere is connected"), result)
        await s.stop()
    }

    func testTagsAndSettingsTravelWithTheCardAndOldCardsStillDecode() async throws {
        let ask = ToolCall(id: ToolCallID("a1"), name: "request_approval", arguments: [
            "title": "YouTube demo", "destination": "YouTube", "text": "Description.", "headline": "Title",
            "tags": .array([" platform engineering ", "", "AI agents"]),
            "details": .array([.object(["label": "Altered or synthetic content", "value": "Yes"]), .object(["value": "no label"])]),
        ])
        let provider = ScriptedProvider([.init(toolCalls: [ask]), .init(text: "Uploaded.")])
        let s = try await service(provider)
        let a = try await s.store.listAgents(includeRetired: false).first { $0.kind == .persistent }!
        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: a.id, conversationID: nil, text: "Upload", attachments: [])
        try await waitFor(s, taskID, .waitingForUser)
        let messages = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 50)
        let card: ApprovalRequest = try XCTUnwrap(messages.lazy.flatMap(\.parts).compactMap { if case .approval(let a) = $0 { return a }; return nil }.first)
        XCTAssertEqual(card.tags, ["platform engineering", "AI agents"])
        XCTAssertEqual(card.details, [ApprovalDetail(label: "Altered or synthetic content", value: "Yes")])
        await s.stop()

        let old = #"{"id":"x","taskID":"\#(TaskID().rawValue)","title":"t","destination":"d","text":"x","images":[],"notes":"","state":"pending","createdAt":0}"#
        let decoded = try JSONDecoder().decode(ApprovalRequest.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.tags, [])
        XCTAssertEqual(decoded.details, [])
    }

    func testADecisionAfterTheTaskEndedReachesTheAgentAsANewMessage() async throws {
        let ask = ToolCall(id: ToolCallID("a1"), name: "request_approval", arguments: ["title": "Post", "destination": "LinkedIn", "text": "Draft."])
        let provider = ScriptedProvider([.init(toolCalls: [ask]), .init(text: "Redoing the slides.")])
        let s = try await service(provider)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Post it", attachments: [])
        try await waitFor(s, taskID, .waitingForUser)
        let messages = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 50)
        let card: ApprovalRequest = try XCTUnwrap(messages.lazy.flatMap(\.parts).compactMap { if case .approval(let a) = $0 { return a }; return nil }.first)
        try await s.runtime.cancelTask(taskID, reason: "moved on")
        let client = ConnectedClient(id: ClientID("t"), displayName: "t", platform: "t")
        guard case .ok = await s.handle(.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .requestChanges, comment: "No other companies on the slides")), from: client) else { return XCTFail("decision refused") }
        let deadline = Date().addingTimeInterval(8)
        var delivered = false
        while Date() < deadline, !delivered {
            let after = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 100)
            delivered = after.contains { $0.role == .user && $0.text.contains("CHANGES REQUESTED") && $0.text.contains("No other companies on the slides") }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(delivered, "the change request reached the agent")
        await s.stop()
    }

    func testUseSkillFollowsTheNewestVersionOfTheSkillItWasGiven() async throws {
        let s = try await service(ScriptedProvider([]))
        let v1 = Skill(name: "posting", version: 1, purpose: "old", status: .validated, body: "OLD STEPS")
        var v2 = Skill(name: "posting", version: 2, purpose: "new", status: .validated, body: "NEW STEPS")
        v2.previousVersionID = v1.id
        try await s.store.upsertSkill(v1)
        try await s.store.upsertSkill(v2)
        let store = await s.store
        let context = ToolContext(agentID: AgentID(), taskID: TaskID(), conversationID: ConversationID(), store: store, desktop: FakeDesktop(), lease: DesktopLease(pauseOnHumanInput: false, desktop: FakeDesktop(), onChange: { _ in }), config: HostConfig())
        let result = try await UseSkillTool(tracker: SkillUsageTracker()).invoke(["skill_id": .string(v1.id.rawValue)], context: context)
        XCTAssertTrue(result.textContent.contains("v2"), result.textContent)
        XCTAssertTrue(result.textContent.contains("NEW STEPS"))
        XCTAssertFalse(result.textContent.contains("OLD STEPS"))
        // By name works too (agents often use it).
        let byName = try await UseSkillTool(tracker: SkillUsageTracker()).invoke(["skill_id": "posting"], context: context)
        XCTAssertTrue(byName.textContent.contains("NEW STEPS"))
        await s.stop()
    }

    /// await_task with a 1-second timeout "failed", so the agent asked again, and again. Waits are at least a minute and end with "still running", not an error.
    func testAwaitTaskWaitsAtLeastAMinuteAndSaysStillRunning() async throws {
        let asked = Locked<Double?>(nil)
        let hooks = RuntimeHooks(delegate: { _, _, _, _, _, _, _ in TaskID() }, awaitTask: { _, timeout in asked.set(timeout); throw ToolError.timeout }, askUser: { _, _ in "" }, learnSkill: { _, s in s }, scheduleJob: { _, _, _, _ in throw ToolError.timeout }, deleteSchedule: { _ in }, importSkills: { _ in ([], []) })
        let context = ToolContext(agentID: AgentID(), taskID: TaskID(), conversationID: ConversationID(), store: FakeStore(), desktop: FakeDesktop(), lease: DesktopLease(pauseOnHumanInput: false, desktop: FakeDesktop(), onChange: { _ in }), config: HostConfig(), runtimeHooks: hooks)
        let result = try await AwaitTaskTool().invoke(["task_id": "t-1", "timeout_seconds": 1], context: context)
        XCTAssertEqual(asked.get(), 60)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.textContent.contains("still running") && result.textContent.contains("Don't send the request again"), result.textContent)
    }

    func testAScheduledRunNeverRedirectsABusyConversation() async throws {
        // The conversation's task waits on a card; the job fires into the same conversation.
        let ask = ToolCall(id: ToolCallID("a1"), name: "request_approval", arguments: ["title": "Post", "destination": "LinkedIn", "text": "Draft."])
        let provider = ScriptedProvider([.init(toolCalls: [ask]), .init(text: "Scheduled run done.")])
        let s = try await service(provider)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, busyConversation, busyTask) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Post it", attachments: [])
        try await waitFor(s, busyTask, .waitingForUser)
        let job = try await s.scheduler.upsert(ScheduledJob(name: "Check", agentID: agent.id, prompt: "Hourly check", schedule: "every 1h", conversationID: busyConversation))
        let ran = try await s.scheduler.runNow(job.id)
        XCTAssertNotEqual(ran.conversationID, busyConversation, "the run got a conversation of its own")
        let newTask = try XCTUnwrap(ran.lastTaskID)
        XCTAssertNotEqual(newTask, busyTask)
        let busy = try await s.store.task(busyTask)
        XCTAssertEqual(busy?.state, .waitingForUser, "the busy task was left alone")
        await s.stop()
    }

    func testBrowserScriptRefusesUnapprovedContent() async throws {
        let request = ApprovalRequest(taskID: TaskID(), title: "t", destination: "d", text: "x", state: .pending)
        let hooks = RuntimeHooks(delegate: { _, _, _, _, _, _, _ in TaskID() }, awaitTask: { _, _ in throw ToolError.timeout }, askUser: { _, _ in "" }, learnSkill: { _, s in s }, scheduleJob: { _, _, _, _ in throw ToolError.timeout }, deleteSchedule: { _ in }, importSkills: { _ in ([], []) })
        var withApproval = hooks
        withApproval.approval = { _ in request }
        let tool = BrowserScriptTool(browser: BrowserRunner(root: paths.root.appendingPathComponent("browser")), screenshots: paths.root)
        let context = ToolContext(agentID: AgentID(), taskID: request.taskID, conversationID: ConversationID(), store: FakeStore(), desktop: FakeDesktop(), lease: DesktopLease(pauseOnHumanInput: false, desktop: FakeDesktop(), onChange: { _ in }), config: HostConfig(), runtimeHooks: withApproval)
        do {
            _ = try await tool.invoke(["script": "/tmp/none.mjs", "approval_id": .string(request.id)], context: context)
            XCTFail("ran with a pending approval")
        } catch {
            XCTAssertTrue(String(describing: error).contains("not approved"))
        }
        var published = request
        published.state = .approved
        published.publishedURL = "https://example.com/post"
        let done = published
        withApproval.approval = { _ in done }
        let again = ToolContext(agentID: AgentID(), taskID: request.taskID, conversationID: ConversationID(), store: FakeStore(), desktop: FakeDesktop(), lease: DesktopLease(pauseOnHumanInput: false, desktop: FakeDesktop(), onChange: { _ in }), config: HostConfig(), runtimeHooks: withApproval)
        do {
            _ = try await tool.invoke(["script": "/tmp/none.mjs", "approval_id": .string(request.id)], context: again)
            XCTFail("published twice")
        } catch {
            XCTAssertTrue(String(describing: error).contains("already published"))
        }
    }

    func testShellGetsVaultSecretsAsEnvironmentAndNeverShowsThem() {
        let env = ShellTool.environment(for: ["cloudflare-api": ["secret": "cf-token-1234567890", "username": "ops"]])
        XCTAssertEqual(env["PENNANT_VAULT_CLOUDFLARE_API_SECRET"], "cf-token-1234567890")
        XCTAssertEqual(env["PENNANT_VAULT_CLOUDFLARE_API_USERNAME"], "ops")
        XCTAssertEqual(env.count, 2)
        XCTAssertEqual(ShellTool.redact("token=cf-token-1234567890 ok", ["cf-token-1234567890", "short"]), "token=[redacted] ok")
    }

    func testWritingCheckFindsTellsAndPassesCleanText() {
        let sloppy = """
        Ever wondered why agents fail in production?

        In today's fast-paced world, AI agents unlock huge value — but guardrails matter. It's not a model problem, it's a platform problem.
        Teams need speed, safety, and scale. They want clarity, control, and confidence.
        What do you think?
        """
        let rules = Set(WritingCheckTool.check(sloppy).map(\.rule))
        XCTAssertTrue(rules.isSuperset(of: ["Stock phrase", "Em-dash", "Contrast formula", "Rule of three", "Question hook", "Engagement-bait closer"]))
        XCTAssertEqual(WritingCheckTool.check("Carry `gen_ai.conversation.id` across hops.").map(\.rule), ["Markdown syntax"])
        let clean = """
        Last week a Codex sandbox escape made the rounds. The agent rewrote the policy file that was supposed to stop it, then did what the policy forbade.

        We see the same shape in platform teams. The guardrail lived in a file the agent could edit. Moving it to the deploy pipeline, outside the agent's reach, closed the gap in an afternoon.

        If your agent can change its own limits, you have a suggestion box.
        """
        XCTAssertEqual(WritingCheckTool.check(clean), [])
    }

    func testADecisionWhileTheTaskWaitsOnSomethingElseArrivesAsAMessage() async throws {
        // The card's call gave up (it used to time out after 15 minutes) and the task is now waiting for another reason.
        let question = ToolCall(id: ToolCallID("q1"), name: "ask_user", arguments: ["question": "Keep going?"])
        let provider = ScriptedProvider([.init(toolCalls: [question]), .init(text: "Redoing it as one poster.")])
        let s = try await service(provider)
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, taskID) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Post it", attachments: [])
        try await waitFor(s, taskID, .waitingForUser)
        let card = ApprovalRequest(taskID: taskID, title: "Post", destination: "LinkedIn", text: "Draft.", state: .pending)
        try await s.store.appendMessage(Message(conversationID: conversationID, agentID: agent.id, taskID: taskID, role: .assistant, parts: [.approval(card)]))

        let client = ConnectedClient(id: ClientID("t"), displayName: "t", platform: "t")
        guard case .ok = await s.handle(.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .requestChanges, comment: "One poster, no cross")), from: client) else { return XCTFail("decision refused") }
        try await waitFor(s, taskID, .completed)
        let seen = provider.requests.last?.messages.map(\.text).joined(separator: "\n") ?? ""
        XCTAssertTrue(seen.contains("CHANGES REQUESTED") && seen.contains("One poster, no cross"), "the model read the decision: \(seen)")
        let stored = try await s.store.messagesAfter(conversationID: conversationID, after: nil, limit: 50)
        XCTAssertTrue(stored.contains { $0.role == .user && $0.text.contains("One poster, no cross") }, "the decision is in the conversation")
        await s.stop()
    }

    func testToolsThatWaitForThePersonHaveNoFifteenMinuteLimit() {
        XCTAssertEqual(TaskRuntime.waitsForUser, ["ask_user", "request_approval"])
    }

    func testDecisionAfterAHostRestartReachesTheAgent() async throws {
        let ask = ToolCall(id: ToolCallID("a1"), name: "request_approval", arguments: ["title": "Post", "destination": "LinkedIn", "text": "Final words."])
        let first = ScriptedProvider([.init(toolCalls: [ask])])
        let s1 = try await service(first)
        let agents = try await s1.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversationID, taskID) = try await s1.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Post it", attachments: [])
        try await waitFor(s1, taskID, .waitingForUser)
        let messages = try await s1.store.messagesAfter(conversationID: conversationID, after: nil, limit: 50)
        let card: ApprovalRequest = try XCTUnwrap(messages.lazy.flatMap(\.parts).compactMap { if case .approval(let a) = $0 { return a }; return nil }.first)
        await s1.stop()

        // The host restarts while the card waits.
        let second = ScriptedProvider([.init(text: "Publishing now.")])
        let s2 = try await service(second)
        let client = ConnectedClient(id: ClientID("t"), displayName: "t", platform: "t")
        guard case .ok = await s2.handle(.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .approve)), from: client) else { return XCTFail("decision refused after restart") }
        try await waitFor(s2, taskID, .completed)
        let result = second.requests.last?.messages.last { $0.role == .tool }?.text ?? ""
        XCTAssertTrue(result.contains("APPROVED (approval_id \(card.id))"), result)
        XCTAssertTrue(result.contains("Final words."))
        await s2.stop()
    }

    /// Stopping the host records nothing for the work it interrupts: a task busy at shutdown carries on after the
    /// restart instead of sitting paused.
    func testATaskBusyAtShutdownCarriesOnAfterRestart() async throws {
        let first = ScriptedProvider([.init(blockUntilReleased: true)])
        let s1 = try await service(first)
        let agents = try await s1.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, _, taskID) = try await s1.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Think it over", attachments: [])
        let deadline = Date().addingTimeInterval(8)
        while first.requests.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        await s1.runtime.stop()
        try await Task.sleep(for: .milliseconds(300))
        let left = try await s1.store.task(taskID)
        XCTAssertEqual(left?.state, .running, "shutdown leaves the task as it was")
        await s1.stop()

        let s2 = try await service(ScriptedProvider([.init(text: "Picked up where I left off.")]))
        try await waitFor(s2, taskID, .completed)
        await s2.stop()
    }
}
