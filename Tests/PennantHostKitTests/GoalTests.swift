import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// Goals: an agent works toward one on its own schedule, keeping its own board, within the freedom the owner gave it.
final class GoalTests: XCTestCase {
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

    private func wait(_ s: HostService, _ id: TaskID, _ state: TaskState) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if try await s.store.task(id)?.state == state { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("task never reached \(state)")
    }

    private func firstGoal(_ s: HostService) async throws -> Goal {
        let goals = try await s.goals.list()
        return try XCTUnwrap(goals.first)
    }

    private func job(_ s: HostService, _ goal: Goal, _ run: String) async throws -> ScheduledJob {
        let jobs = try await s.scheduler.list()
        return try XCTUnwrap(jobs.first { $0.goalID == goal.id && $0.goalRun == run })
    }

    private func pennant(_ s: HostService) async throws -> AgentProfile {
        let agents = try await s.store.listAgents(includeRetired: false)
        return try XCTUnwrap(agents.first { $0.kind == .persistent })
    }

    func testAProposedGoalStartsOnlyWhenApprovedWithItsJobsAndConversation() async throws {
        let propose = ToolCall(id: ToolCallID("g1"), name: "propose_goal", arguments: [
            "title": "Grow the LinkedIn page", "outcome": "5,000 followers by December", "measure": "Follower count on the page",
            "first_steps": .array([.string("Audit the page's About section"), .string("List the ten best posts")]),
        ])
        let provider = ScriptedProvider([.init(toolCalls: [propose]), .init(text: "Proposed.")])
        let s = try await service(provider)
        let agent = try await pennant(s)
        let (_, conversation, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Set up a LinkedIn goal", attachments: [])
        try await wait(s, task, .completed)
        var goal = try await firstGoal(s)
        XCTAssertEqual(goal.status, .proposed)
        let offJobs = try await s.scheduler.list().filter { $0.goalID == goal.id }
        XCTAssertTrue(offJobs.allSatisfy { !$0.enabled }, "nothing runs before approval")

        let messages = try await s.store.messagesAfter(conversationID: conversation, after: nil, limit: 50)
        let card = try XCTUnwrap(messages.flatMap(\.parts).compactMap { if case .approval(let a) = $0 { return a }; return nil }.first)
        XCTAssertEqual(card.title, "Goal: Grow the LinkedIn page")
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .approve, editedText: "6,000 followers by December"), by: MessageAuthor(id: PersonID("owner"), name: "Owner"))
        let deadline = Date().addingTimeInterval(5)
        while goal.status != .active, Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
            goal = try await firstGoal(s)
        }
        XCTAssertEqual(goal.status, .active)
        XCTAssertEqual(goal.outcome, "6,000 followers by December", "the owner's edit is the outcome")
        XCTAssertNotNil(goal.conversationID)
        let jobs = try await s.scheduler.list().filter { $0.goalID == goal.id }
        XCTAssertEqual(Set(jobs.map { $0.goalRun ?? "" }), ["work", "review"])
        XCTAssertTrue(jobs.allSatisfy { $0.enabled && $0.conversationID == goal.conversationID })
        let items = try await s.goals.items(goal.id)
        XCTAssertEqual(items.map(\.title), ["Audit the page's About section", "List the ten best posts"])

        // Pausing turns its jobs off.
        _ = try await s.goals.setStatus(goal.id, .paused)
        let paused = try await s.scheduler.list().filter { $0.goalID == goal.id }
        XCTAssertTrue(paused.allSatisfy { !$0.enabled })
        await s.stop()
    }

    func testAWorkSessionIsWrittenFromTheGoalAndItsBoard() async throws {
        let provider = ScriptedProvider([.init(text: "Worked on the audit.")])
        let s = try await service(provider)
        let agent = try await pennant(s)
        let goal = try await s.goals.save(Goal(title: "Grow the page", outcome: "More followers", measure: "Followers", ownerAgentID: agent.id, status: .active))
        let item = try await s.goals.saveItem(GoalItem(goalID: goal.id, title: "Audit the About section", state: .next))
        _ = try await s.goals.comment(item.id, text: "Lead with the product, not the company", by: "owner")
        let job = try await job(s, goal, "work")
        let ran = try await s.scheduler.runNow(job.id)
        let task = try XCTUnwrap(ran.lastTaskID)
        try await wait(s, task, .completed)
        let goalConversation = try XCTUnwrap(goal.conversationID)
        let prompt = try await s.store.messagesAfter(conversationID: goalConversation, after: nil, limit: 5).first { $0.role == .user }?.text ?? ""
        XCTAssertTrue(prompt.contains("🎯 Work session"), prompt)
        XCTAssertTrue(prompt.contains("Audit the About section"))
        XCTAssertTrue(prompt.contains("Lead with the product, not the company"), "the owner's comments come first")
        XCTAssertTrue(prompt.contains("Work freely: research"))
        await s.stop()
    }

    func testGoalWorkRunsFreelyButStillAsksForTheOwnersSignOffs() async throws {
        struct FakeConnectorTool: Tool {
            var spec: ToolSpec { ToolSpec(name: "mail__mail_send", description: "send", inputSchema: JSONSchema.object([:]), isConsequential: true, source: "mcp:mail") }
            func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult { .text(ToolCallID("x"), name: spec.name, "sent") }
        }
        let send = ToolCall(id: ToolCallID("m1"), name: "mail__mail_send", arguments: [:])
        let shell = ToolCall(id: ToolCallID("s1"), name: "shell", arguments: ["command": "echo drafting"])
        let outside = ToolCall(id: ToolCallID("p1"), name: "shell", arguments: ["command": "echo pushed"])
        let provider = ScriptedProvider([.init(toolCalls: [shell, outside, send]), .init(text: "Done."), .init(toolCalls: [shell]), .init(text: "Done.")])
        let s = try await service(provider)
        await s.broker.register([FakeConnectorTool()])
        let agent = try await pennant(s)
        var goal = try await s.goals.save(Goal(title: "Ideas", outcome: "Ideas", ownerAgentID: agent.id, freedom: .workFreely, status: .active))
        let (_, _, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: goal.conversationID, text: "work", attachments: [])
        // Sending an email waits on the owner: decline it.
        var card: PendingApproval?
        let deadline = Date().addingTimeInterval(10)
        while card == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
            card = try await s.runtime.pendingApprovals().first
        }
        let pending = try XCTUnwrap(card, "an email asks for the owner's sign-off")
        XCTAssertTrue(pending.request.title.hasPrefix("Publish or send"), pending.request.title)
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: pending.id, verdict: .reject), by: nil)
        try await wait(s, task, .completed)
        let records = try await s.store.toolRecords(taskID: task)
        XCTAssertEqual(records.first { $0.call.id == ToolCallID("s1") }?.status, .succeeded)
        XCTAssertEqual(records.first { $0.call.id == ToolCallID("p1") }?.status, .succeeded, "goal work runs by itself")
        XCTAssertEqual(records.first { $0.call.name == "mail__mail_send" }?.status, .denied, "the owner declined the email")

        goal.freedom = .proposeOnly
        goal = try await s.goals.save(goal)
        let (_, _, second) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: goal.conversationID, text: "work", attachments: [])
        try await wait(s, second, .completed)
        let again = try await s.store.toolRecords(taskID: second)
        XCTAssertEqual(again.first?.status, .denied, "propose-only holds back even local changes")
        await s.stop()
    }

    func testAGoalOverItsBudgetSkipsItsSession() async throws {
        let s = try await service(ScriptedProvider([]))
        let agent = try await pennant(s)
        let goal = try await s.goals.save(Goal(title: "Cheap", outcome: "x", ownerAgentID: agent.id, weeklyBudget: 1, status: .active))
        let store = await s.store
        let goalConversation = try XCTUnwrap(goal.conversationID)
        try await store.appendUsage(UsageRecord(agentID: agent.id, taskID: TaskID(), conversationID: goalConversation, profileID: nil, modelLabel: "m", provider: "p", model: "m", inputTokens: 1, cachedInputTokens: 0, outputTokens: 1, cost: 2.5, estimated: false))
        let job = try await job(s, goal, "work")
        let ran = try await s.scheduler.runNow(job.id)
        XCTAssertTrue(ran.lastOutcome?.contains("over its weekly budget") ?? false, ran.lastOutcome ?? "")
        XCTAssertNil(ran.lastTaskID)
        await s.stop()
    }

    /// A helper working for Pennant can't change its boards; only the goal's own agent keeps them.
    func testOnlyTheGoalsAgentKeepsItsBoard() async throws {
        let add = ToolCall(id: ToolCallID("a1"), name: "goal_update", arguments: ["goal": "Ideas", "action": "add", "title": "Interview three customers", "state": "next"])
        let provider = ScriptedProvider([.init(toolCalls: [add]), .init(text: "ok"), .init(toolCalls: [add]), .init(text: "ok")])
        let s = try await service(provider)
        let owner = try await pennant(s)
        let other = AgentProfile(kind: .worker, name: "Pennant's worker", role: "helps", parentAgentID: owner.id)
        try await s.store.upsertAgent(other)
        let goal = try await s.goals.save(Goal(title: "Ideas", outcome: "Ideas", ownerAgentID: owner.id, status: .active))
        let (_, _, mine) = try await s.runtime.submitUserMessage(agentID: owner.id, conversationID: nil, text: "add", attachments: [])
        try await wait(s, mine, .completed)
        let (_, _, theirs) = try await s.runtime.submitUserMessage(agentID: other.id, conversationID: nil, text: "add", attachments: [])
        try await wait(s, theirs, .completed)
        let items = try await s.goals.items(goal.id)
        XCTAssertEqual(items.count, 1, "the helper's add was refused")
        await s.stop()
    }

    /// Found in use: asked to run goals daily, Pennant deleted their jobs and made plain ones. It sees its goals, and
    /// schedules change through update_goal.
    func testAGoalsScheduleChangesWithoutBreakingIt() async throws {
        let list = ToolCall(id: ToolCallID("l1"), name: "goal_board", arguments: [:])
        let daily = ToolCall(id: ToolCallID("u1"), name: "update_goal", arguments: ["goal": "Grow the page", "work_schedule": "daily at 09:00", "freedom": "actWithinLimits", "why": "faster"])
        let provider = ScriptedProvider([.init(toolCalls: [list]), .init(text: "listed"), .init(toolCalls: [daily]), .init(text: "changed")])
        let s = try await service(provider)
        let pennant = try await pennant(s)
        _ = try await s.goals.save(Goal(title: "Grow the page", outcome: "More followers", ownerAgentID: pennant.id, status: .active))
        let (_, conversation, first) = try await s.runtime.submitUserMessage(agentID: pennant.id, conversationID: nil, text: "What goals do we have?", attachments: [])
        try await wait(s, first, .completed)
        let messages = try await s.store.messagesAfter(conversationID: conversation, after: nil, limit: 50)
        let seen = messages.flatMap(\.parts).compactMap { if case .toolResult(let r) = $0 { return r.textContent }; return nil }.joined()
        XCTAssertTrue(seen.contains("Grow the page"), seen)

        let (_, _, second) = try await s.runtime.submitUserMessage(agentID: pennant.id, conversationID: conversation, text: "Make it daily", attachments: [])
        try await wait(s, second, .completed)
        let updated = try await firstGoal(s)
        XCTAssertEqual(updated.workSchedule, "daily at 09:00")
        XCTAssertEqual(updated.freedom, .workFreely, "a change of freedom waits for the owner")
        let work = try await job(s, updated, "work")
        XCTAssertEqual(work.schedule, "daily at 09:00", "the goal's own job follows")
        let jobs = try await s.scheduler.list().filter { $0.name.contains("Grow the page") }
        XCTAssertEqual(jobs.count, 2, "no plain copies")
        let cards = try await s.runtime.pendingApprovals()
        XCTAssertTrue(cards.contains { $0.request.title == "Change the goal: Grow the page" })
        await s.stop()
    }

    func testAnAgentCantDeleteAGoalsJob() async throws {
        let box = Locked<String>("")
        let provider = ScriptedProvider([.init(dynamicToolCalls: { [ToolCall(id: ToolCallID("c1"), name: "cancel_schedule", arguments: ["schedule_id": .string(box.get())])] }), .init(text: "ok")])
        let s = try await service(provider)
        let agent = try await pennant(s)
        let goal = try await s.goals.save(Goal(title: "Ideas", outcome: "x", ownerAgentID: agent.id, status: .active))
        let work = try await job(s, goal, "work")
        box.set(work.id.rawValue)
        let (_, _, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "cancel it", attachments: [])
        try await wait(s, task, .completed)
        let still = try await s.scheduler.list().contains { $0.id == work.id }
        XCTAssertTrue(still, "the goal's job is still there")
        await s.stop()
    }

    func testTheOwnerMovesAGoalToAnyStatusAndDeletesIt() async throws {
        let s = try await service(ScriptedProvider([]))
        let agent = try await pennant(s)
        let goal = try await s.goals.save(Goal(title: "Ideas", outcome: "A steady flow", ownerAgentID: agent.id))
        _ = try await s.goals.saveItem(GoalItem(goalID: goal.id, title: "First idea", state: .next, rank: 0))
        let owner = ConnectedClient(id: ClientID("o"), displayName: "o", platform: "t")

        // Proposed → working → back to proposed: its jobs follow.
        guard case .goal(let started) = await s.handle(.setGoalStatus(goal.id, .active), from: owner) else { return XCTFail("start refused") }
        XCTAssertNotNil(started.conversationID, "started from the Goals page, it gets its conversation")
        var work = try await job(s, started, "work")
        XCTAssertTrue(work.enabled)
        guard case .goal(let proposed) = await s.handle(.setGoalStatus(goal.id, .proposed), from: owner) else { return XCTFail("re-propose refused") }
        XCTAssertEqual(proposed.status, .proposed)
        work = try await job(s, proposed, "work")
        XCTAssertFalse(work.enabled, "a proposed goal doesn't run")

        // Someone who isn't the owner can't delete it.
        let member = ConnectedClient(id: ClientID("m"), displayName: "m", platform: "t", person: Person(name: "Sam", email: "sam@example.com", role: .member))
        guard case .error = await s.handle(.deleteGoal(goal.id), from: member) else { return XCTFail("a member deleted a goal") }

        // The owner can: the goal, its board and its jobs go; its conversation stays.
        guard case .ok = await s.handle(.deleteGoal(goal.id), from: owner) else { return XCTFail("delete refused") }
        let goalsLeft = try await s.goals.list()
        XCTAssertTrue(goalsLeft.isEmpty)
        let itemsLeft = try await s.goals.items(goal.id)
        XCTAssertTrue(itemsLeft.isEmpty)
        let jobsLeft = try await s.scheduler.list().filter { $0.goalID == goal.id }
        XCTAssertTrue(jobsLeft.isEmpty)
        let conversation = try await s.store.conversation(try XCTUnwrap(started.conversationID))
        XCTAssertNotNil(conversation, "its conversation stays")
        let events = try await s.store.events(afterSeq: 0, limit: 500).map(\.payload)
        XCTAssertTrue(events.contains(.goalRemoved(goal.id)))
        await s.stop()
    }

    func testApprovingAGoalsCardAfterTheOwnerStartedItKeepsTheirEdits() async throws {
        let propose = ToolCall(id: ToolCallID("g1"), name: "propose_goal", arguments: ["title": "Grow the page", "outcome": "5,000 followers"])
        let s = try await service(ScriptedProvider([.init(toolCalls: [propose]), .init(text: "Proposed.")]))
        let agent = try await pennant(s)
        let (_, conversation, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Propose a goal", attachments: [])
        try await wait(s, task, .completed)
        var goal = try await firstGoal(s)
        goal.outcome = "6,000 followers"
        goal.status = .active
        _ = try await s.goals.save(goal)

        let messages = try await s.store.messagesAfter(conversationID: conversation, after: nil, limit: 50)
        let card = try XCTUnwrap(messages.flatMap(\.parts).compactMap { if case .approval(let a) = $0 { return a }; return nil }.first)
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: card.id, verdict: .approve), by: MessageAuthor(id: PersonID("owner"), name: "Owner"))
        let decided = try await s.runtime.findApproval(card.id)
        XCTAssertEqual(decided?.request.actionResult?.contains("already under way"), true, "the card's action ran")
        let after = try await firstGoal(s)
        XCTAssertEqual(after.outcome, "6,000 followers", "the stale card doesn't undo the owner's edit")
        XCTAssertEqual(after.status, .active)
        await s.stop()
    }
}
