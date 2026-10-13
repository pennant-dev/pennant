import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// Pennant's heartbeat: a look over the work without the model, goal sessions started when they're due, and a turn
/// in the chat only when something needs one.
final class HeartbeatTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private func service(_ provider: ScriptedProvider, heartbeat: HostConfig.Heartbeat = HostConfig.Heartbeat()) async throws -> HostService {
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        config.heartbeat = heartbeat
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

    private func pennant(_ s: HostService) async throws -> AgentProfile {
        let agents = try await s.store.listAgents(includeRetired: false)
        return try XCTUnwrap(agents.first { $0.kind == .persistent })
    }

    /// A thread whose work last moved `minutes` ago, as a task left running.
    private func stuckThread(_ s: HostService, _ title: String, minutes: Double) async throws -> TaskRecord {
        let agent = try await pennant(s)
        let thread = Conversation(agentID: agent.id, title: title)
        try await s.store.upsertConversation(thread)
        var task = TaskRecord(agentID: agent.id, conversationID: thread.id, title: title, objective: title, completionCriteria: "", budget: TaskBudget())
        task.state = .running
        task.updatedAt = Date().addingTimeInterval(-minutes * 60)
        try await s.store.upsertTask(task)
        return task
    }

    /// What the owner asked for on each check-in is in their words, so it works with whatever they use (Gmail,
    /// Outlook, a calendar, a dashboard): each beat is a turn to do it, told how often it comes and when it last did.
    func testWhatTheOwnerAskedForIsDoneOnEachCheckIn() async throws {
        var settings = HostConfig.Heartbeat()
        settings.instructions = "Check my email for anything that needs me today."
        settings.maxTurnsPerDay = 2
        let provider = ScriptedProvider([.init(text: "Dana needs the signed contract back today."), .init(text: TaskRuntime.nothingToSay)])
        let s = try await service(provider, heartbeat: settings)

        let first = await s.heartbeat.beat()
        XCTAssertEqual(first.signals.count, 1)
        XCTAssertTrue(first.signals[0].hasPrefix("On each check-in the owner asked you to: Check my email for anything that needs me today. (you check in every 30 minutes; it's now 20"), first.signals[0])
        let turn = try XCTUnwrap(first.turn)
        try await wait(s, turn, .completed)
        let objective = try await s.store.task(turn)?.objective ?? ""
        XCTAssertTrue(objective.contains("Check my email for anything that needs me today."), objective)
        XCTAssertTrue(objective.contains("What the owner asked for on each check-in, do with the tools you have"), objective)
        XCTAssertFalse(objective.contains("inbox runs"), "nothing assumes a setup the owner may not have")

        let second = await s.heartbeat.beat()
        // With its date and zone, so "since then" can't land in the future.
        XCTAssertTrue(second.signals.first?.contains("the last one was at 20") ?? false, "\(second.signals)")
        XCTAssertNotNil(second.signals.first?.range(of: #"at \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})"#, options: .regularExpression), "\(second.signals)")
        try await wait(s, try XCTUnwrap(second.turn, "every check-in, not just when something changed"), .completed)

        let third = await s.heartbeat.beat()
        XCTAssertNil(third.turn)
        XCTAssertEqual(third.skipped, "already took 2 turns today", "the daily cap still holds")
        await s.stop()
    }

    /// A stand-in for a connection's search, counting its calls.
    final class Search: Tool, @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var spec: ToolSpec { ToolSpec(name: "mail__search", description: "[Mail] Search", inputSchema: JSONSchema.object(["q": JSONSchema.string("")]), source: "mcp:mail") }
        func invoke(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
            lock.withLock { calls += 1 }
            return .text(ToolCallID("pending"), name: spec.name, "No messages.")
        }
    }

    static func searches(_ n: Int) -> [ScriptedProvider.Turn] {
        (1 ... n).map { .init(toolCalls: [ToolCall(id: ToolCallID("s\($0)"), name: "mail__search", arguments: ["q": .string("since \($0)")])]) }
    }

    /// What the owner asked for can take more steps than a quick chat answer: a check-in isn't held to the chat's
    /// "hand it to a thread" limit, only to its own budget.
    func testACheckInIsntHeldToTheChatsQuickAnswerLimit() async throws {
        var settings = HostConfig.Heartbeat()
        settings.instructions = "Check my inbox."
        let s = try await service(ScriptedProvider(Self.searches(7) + [.init(text: TaskRuntime.nothingToSay)]), heartbeat: settings)
        let search = Search()
        await s.broker.register(search)
        let beat = await s.heartbeat.beat()
        let turn = try XCTUnwrap(beat.turn)
        try await wait(s, turn, .completed)
        XCTAssertEqual(search.lock.withLock { search.calls }, 7)
        let refused = try await s.store.toolRecords(taskID: turn).filter { $0.status == .denied }
        XCTAssertEqual(refused.count, 0, refused.map { $0.resultSummary ?? "" }.joined(separator: "; "))
        await s.stop()
    }

    /// A check-in at its limit wraps up and ends: it never stops to ask the owner, who didn't ask for it, so the chat
    /// stays free and the next check-in comes.
    func testACheckInAtItsLimitEndsWithoutAskingAndDoesntHoldTheChat() async throws {
        var settings = HostConfig.Heartbeat()
        settings.instructions = "Check my inbox."
        let s = try await service(ScriptedProvider(Self.searches(20) + [.init(text: TaskRuntime.nothingToSay)]), heartbeat: settings)
        await s.broker.register(Search())
        let beat = await s.heartbeat.beat()
        let turn = try XCTUnwrap(beat.turn)
        try await wait(s, turn, .completed)
        let task = try await s.store.task(turn)
        XCTAssertEqual(task?.resultSummary?.hasPrefix("Stopped at the check-in's limit"), true, task?.resultSummary ?? "")
        let transitions = try await s.store.transitions(taskID: turn)
        XCTAssertFalse(transitions.contains { $0.to == .waitingForUser }, "it never waits on the owner")
        let next = await s.heartbeat.beat()
        XCTAssertNotNil(next.turn, next.skipped ?? "")
        await s.stop()
    }

    /// "Nothing to say" as models actually write it, and replies that only look like it.
    func testNothingToSayAsModelsWriteIt() {
        for quiet in ["(nothing)", "(noting nothing)", "(nnothing)", "(none)", "nothing", "Nothing.", "(nothing new)", "**(nothing)**", "(nothing):", "(nothing);", "— (nothing) —"] {
            XCTAssertTrue(TaskRuntime.saysNothing(quiet), quiet)
        }
        for news in ["(nothing urgent, but Dana replied)", "Dana needs the signed contract back today.", "(none of the threads are stuck but the build failed)", "Nothing new on the contract, but the venue called back.",
                     "(noting the 9:00 check-in) Dana needs the signed contract back today.", "Dana replied about the venue.\n\n(nothing)", "(noting the 9:00 check-in: the venue called (twice) and wants an answer"] {
            XCTAssertFalse(TaskRuntime.saysNothing(news), news)
        }
    }

    /// Notes a check-in keeps for itself, alone or ahead of the marker, say nothing to the owner.
    func testNotesToItselfSayNothing() {
        for note in ["(noting the 14:55 check-in: no new mail since the two 13:32 notifications; the test run is still going)\n\n(nothing)",
                     "(noting the 15:55 check-in: no new mail since 15:25; nothing needs you)  (nothing)",
                     "(noting the 15:26 check-in: inbox quiet; nudged the venue search to report back)",
                     "(noting the 16:25 check-in: one new item, a calendar reminder (routine))\n\nNothing new.",
                     "(noting the 16:55 check-in: inbox quiet)\n\nNothing needs you.",
                     "(none needed — the inbox search above found nothing since the 9:25 check)\n\n(none)"] {
            XCTAssertTrue(TaskRuntime.saysNothing(note), note)
        }
    }

    /// A check-in that looked (a search) and found nothing to say leaves nothing in the chat: not its reply, not its
    /// thinking, not its tool calls. They stay in the tool records.
    func testAQuietCheckInLeavesNoTraceInTheChat() async throws {
        var settings = HostConfig.Heartbeat()
        settings.instructions = "Check my inbox."
        let s = try await service(ScriptedProvider(Self.searches(2) + [.init(text: "(noting nothing)", reasoning: "Nothing new since the last look.")]), heartbeat: settings)
        await s.broker.register(Search())
        let beat = await s.heartbeat.beat()
        let turn = try XCTUnwrap(beat.turn)
        try await wait(s, turn, .completed)
        let chat = try await s.runtime.ensureMainChat()
        let left = try await s.store.messagesAfter(conversationID: chat.id, after: nil, limit: 200).filter { $0.taskID == turn }
        XCTAssertEqual(left.count, 0, left.map { "\($0.role): \($0.text)" }.joined(separator: "; "))
        let records = try await s.store.toolRecords(taskID: turn)
        XCTAssertEqual(records.count, 2, "what it did is still on record")
        await s.stop()
    }

    /// Check-ins from before, that said nothing but left their trace, are cleared when the host starts.
    func testOldQuietCheckInsAreClearedAtStart() async throws {
        let s = try await service(ScriptedProvider([]))
        let chat = try await s.runtime.ensureMainChat()
        var old = TaskRecord(agentID: chat.agentID, conversationID: chat.id, title: "Checking in", objective: TaskRuntime.heartbeatLead + "Since your last look: …",
                             completionCriteria: "", budget: TaskBudget())
        old.state = .completed
        old.resultSummary = "(nnothing)"
        try await s.store.upsertTask(old)
        let call = ToolCall(id: ToolCallID("o1"), name: "mail__search", arguments: [:])
        for message in [Message(conversationID: chat.id, agentID: chat.agentID, taskID: old.id, role: .assistant, parts: [.toolCall(call)]),
                        Message(conversationID: chat.id, agentID: chat.agentID, taskID: old.id, role: .tool, parts: [.toolResult(.text(call.id, name: call.name, "No messages."))]),
                        Message(conversationID: chat.id, agentID: chat.agentID, taskID: old.id, role: .assistant, parts: [.text("(nnothing)")])] {
            try await s.store.appendMessage(message)
        }
        // Days of chat since: the old check-in is far back.
        for n in 0 ..< 350 {
            try await s.store.appendMessage(Message(conversationID: chat.id, agentID: chat.agentID, role: n % 2 == 0 ? .user : .assistant, parts: [.text("Message \(n)")]))
        }
        await s.runtime.clearQuietHeartbeats()
        let left = try await s.store.messagesAfter(conversationID: chat.id, after: nil, limit: 200).filter { $0.taskID == old.id }
        XCTAssertEqual(left.count, 0)
        await s.stop()
    }

    /// A config written before the setting (with the old on/off for mail) still loads, with nothing asked.
    func testAnOlderHeartbeatSettingLoadsWithNothingAsked() throws {
        let old = #"{"enabled":true,"intervalMinutes":30,"maxTurnsPerDay":48,"checksMail":true}"#
        let settings = try JSONDecoder().decode(HostConfig.Heartbeat.self, from: Data(old.utf8))
        XCTAssertTrue(settings.enabled)
        XCTAssertNil(settings.instructions)
    }

    func testABeatWithNothingInItCostsNothing() async throws {
        let provider = ScriptedProvider([])
        let s = try await service(provider)
        let beat = await s.heartbeat.beat()
        XCTAssertTrue(beat.goalSessions.isEmpty && beat.signals.isEmpty)
        XCTAssertNil(beat.turn)
        XCTAssertTrue(provider.requests.isEmpty, "no model call")
        await s.stop()
    }

    func testGoalSessionsStartOnTheBeatWhenDueAndWaitWhileTheOwnerIsAsked() async throws {
        let s = try await service(ScriptedProvider([.init(text: "Worked on it.")]))
        let onHeartbeat = await s.scheduler.goalsOnHeartbeat
        XCTAssertTrue(onHeartbeat, "the timer leaves goal jobs to the heartbeat")
        let agent = try await pennant(s)
        let goal = try await s.goals.save(Goal(title: "Grow the page", outcome: "More followers", ownerAgentID: agent.id, workSchedule: "every 2h", status: .active))
        let jobs = try await s.scheduler.list()
        var work = try XCTUnwrap(jobs.first { $0.goalID == goal.id && $0.goalRun == "work" })

        // Worked an hour ago: not due yet.
        work.lastRunAt = Date().addingTimeInterval(-3600)
        try await s.store.upsertSchedule(work)
        var beat = await s.heartbeat.beat()
        XCTAssertTrue(beat.goalSessions.isEmpty)

        // Three hours ago: due, so its session starts.
        work.lastRunAt = Date().addingTimeInterval(-3 * 3600)
        try await s.store.upsertSchedule(work)
        beat = await s.heartbeat.beat()
        XCTAssertEqual(beat.goalSessions, [work.name])
        let ranJob = try await s.store.schedule(work.id)
        let ran = try XCTUnwrap(ranJob)
        try await wait(s, try XCTUnwrap(ran.lastTaskID), .completed)

        // Due again, but the goal is waiting on the owner (a question in its thread): it waits too.
        var asking = TaskRecord(agentID: agent.id, conversationID: try XCTUnwrap(goal.conversationID), title: "Which banner?", objective: "Which banner?", completionCriteria: "", budget: TaskBudget())
        asking.state = .waitingForUser
        try await s.store.upsertTask(asking)
        let stored = try await s.store.schedule(work.id)
        var again = try XCTUnwrap(stored)
        again.lastRunAt = Date().addingTimeInterval(-3 * 3600)
        try await s.store.upsertSchedule(again)
        beat = await s.heartbeat.beat()
        XCTAssertTrue(beat.goalSessions.isEmpty)
        let waited = try await s.store.schedule(work.id)
        XCTAssertEqual(waited?.lastOutcome, "skipped: waiting on you")
        await s.stop()
    }

    func testStuckWorkGetsOneLookAndANothingLeavesNoTrace() async throws {
        let provider = ScriptedProvider([])
        provider.chatTurns = [.init(text: "(nothing)")]
        let s = try await service(provider)
        _ = try await stuckThread(s, "Venue search", minutes: 30)
        let beat = await s.heartbeat.beat()
        XCTAssertEqual(beat.signals.count, 1)
        let turn = try XCTUnwrap(beat.turn)
        try await wait(s, turn, .completed)
        let chat = try await s.runtime.ensureMainChat()
        let said = try await s.store.messagesAfter(conversationID: chat.id, after: nil, limit: 50).filter { $0.role == .assistant && !$0.text.isEmpty }
        XCTAssertTrue(said.isEmpty, "nothing to say leaves nothing: \(said.map(\.text))")
        let brief = try XCTUnwrap(provider.requests.first { $0.messages.first?.text.contains("## The Pennant chat") == true })
        XCTAssertTrue(brief.messages.first?.text.contains("“Venue search”") == true && brief.messages.first?.text.contains("hasn't moved") == true)

        // The same thing isn't raised on the next beat.
        let next = await s.heartbeat.beat()
        XCTAssertTrue(next.signals.isEmpty)
        XCTAssertNil(next.turn)
        await s.stop()
    }

    func testWhatPennantSaysOnABeatStaysInTheChat() async throws {
        let provider = ScriptedProvider([])
        provider.chatTurns = [.init(text: "The venue search had stalled, so I stopped it. Want me to try again with a shorter list?")]
        let s = try await service(provider)
        _ = try await stuckThread(s, "Venue search", minutes: 45)
        let spoke = await s.heartbeat.beat()
        let turn = try XCTUnwrap(spoke.turn)
        try await wait(s, turn, .completed)
        let chat = try await s.runtime.ensureMainChat()
        let said = try await s.store.messagesAfter(conversationID: chat.id, after: nil, limit: 50).filter { $0.role == .assistant && !$0.text.isEmpty }
        XCTAssertEqual(said.map { $0.text.trimmingCharacters(in: .whitespaces) }, ["The venue search had stalled, so I stopped it. Want me to try again with a shorter list?"])
        await s.stop()
    }

    func testTurnsAreCappedPerDayAndAnOffHeartbeatDoesNothing() async throws {
        let provider = ScriptedProvider([])
        provider.chatTurns = [.init(text: "(nothing)"), .init(text: "(nothing)")]
        let s = try await service(provider, heartbeat: HostConfig.Heartbeat(enabled: true, intervalMinutes: 30, maxTurnsPerDay: 1))
        _ = try await stuckThread(s, "First", minutes: 30)
        let firstBeat = await s.heartbeat.beat()
        let first = try XCTUnwrap(firstBeat.turn)
        try await wait(s, first, .completed)
        _ = try await stuckThread(s, "Second", minutes: 30)
        let capped = await s.heartbeat.beat()
        XCTAssertNil(capped.turn)
        XCTAssertEqual(capped.skipped, "already took 1 turns today")

        await s.heartbeat.update(HostConfig.Heartbeat(enabled: false))
        let stillOnHeartbeat = await s.scheduler.goalsOnHeartbeat
        XCTAssertFalse(stillOnHeartbeat, "off: goals go back to their schedules")
        let off = await s.heartbeat.beat()
        XCTAssertEqual(off.skipped, "off")
        await s.stop()
    }
}
