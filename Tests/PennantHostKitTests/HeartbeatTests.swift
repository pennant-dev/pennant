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
