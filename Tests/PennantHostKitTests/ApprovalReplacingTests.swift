import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// One card per decision: an agent's new card from the same thread, job or goal says which waiting cards it
/// replaces, or that they're separate; exact repeats replace the old card; replaced cards read "Replaced".
final class ApprovalReplacingTests: XCTestCase {
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

    /// A card that sends a reply when approved: it doesn't hold its task.
    private func reply(_ task: TaskID, _ title: String, to destination: String) -> ApprovalRequest {
        var card = ApprovalRequest(taskID: task, title: title, destination: destination, text: "Draft for \(destination)")
        card.action = ApprovalAction(tool: "mail_reply", arguments: .object([:]), textField: "body", label: "Approve & send")
        return card
    }

    func testANewCardFromTheSameThreadDecidesAboutTheOnesStillWaiting() async throws {
        let s = try await service(ScriptedProvider([.init(text: "Done.")]))
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, _, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Draft the replies", attachments: [])
        try await wait(s, task, .completed)

        let first = reply(task, "Reply to Jonas", to: "Outlook · Jonas")
        _ = try await s.runtime.makeRoom(for: first, taskID: task, replaces: [], alongside: false)
        try await s.runtime.postApproval(taskID: task, first)

        // Another card while the first waits: the agent has to say how they relate. Nothing is posted meanwhile.
        let second = reply(task, "Reply to Priya", to: "Outlook · Priya")
        do {
            _ = try await s.runtime.makeRoom(for: second, taskID: task, replaces: [], alongside: false)
            XCTFail("a second card went up without deciding about the first")
        } catch {
            XCTAssertTrue("\(error)".contains("Reply to Jonas") && "\(error)".contains("alongside"), "\(error)")
        }
        // A different decision: both stay.
        _ = try await s.runtime.makeRoom(for: second, taskID: task, replaces: [], alongside: true)
        try await s.runtime.postApproval(taskID: task, second)
        var pending = try await s.runtime.pendingApprovals().map(\.request.title)
        XCTAssertEqual(Set(pending), ["Reply to Jonas", "Reply to Priya"])

        // The same card again replaces the old one by itself.
        let again = reply(task, "Reply to Jonas", to: "Outlook · Jonas")
        let repeated = try await s.runtime.makeRoom(for: again, taskID: task, replaces: [], alongside: true)
        XCTAssertEqual(repeated, ["Reply to Jonas"])
        try await s.runtime.postApproval(taskID: task, again)

        // A revision names what it replaces, by an id prefix.
        let revised = reply(task, "Reply to Priya, shorter", to: "Outlook · Priya")
        let named = try await s.runtime.makeRoom(for: revised, taskID: task, replaces: [String(second.id.prefix(8))], alongside: true)
        XCTAssertEqual(named, ["Reply to Priya"])
        try await s.runtime.postApproval(taskID: task, revised)

        pending = try await s.runtime.pendingApprovals().map(\.request.title)
        XCTAssertEqual(Set(pending), ["Reply to Jonas", "Reply to Priya, shorter"])
        let found = try await s.runtime.findApproval(second.id)
        let old = try XCTUnwrap(found?.request)
        XCTAssertEqual(old.state, .rejected)
        XCTAssertEqual(old.replacedBy, revised.id)
        XCTAssertEqual(old.comment, "Replaced by a newer card: Reply to Priya, shorter")
        XCTAssertEqual(old.decidedBy?.name, HostService.defaultAgentName)
        await s.stop()
    }

    func testATaskWaitingOnAReplacedCardGoesOnAndIsToldWhy() async throws {
        let ask = ToolCall(id: ToolCallID("a1"), name: "request_approval", arguments: ["title": "LinkedIn post: launch", "destination": "LinkedIn · Harbor", "text": "Harbor 2.0 is live."])
        let s = try await service(ScriptedProvider([.init(toolCalls: [ask]), .init(text: "Stopped.")]))
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, conversation, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Draft the launch post", attachments: [])
        try await wait(s, task, .waitingForUser)
        let cards = try await s.runtime.pendingApprovals()
        let waiting = try XCTUnwrap(cards.first)

        let newer = reply(task, "LinkedIn post: launch, with the numbers", to: "LinkedIn · Harbor")
        _ = try await s.runtime.makeRoom(for: newer, taskID: task, replaces: [waiting.request.id], alongside: false)
        try await s.runtime.postApproval(taskID: task, newer)
        try await wait(s, task, .completed)

        let messages = try await s.store.messagesAfter(conversationID: conversation, after: nil, limit: 100)
        let result = messages.flatMap(\.parts).compactMap { if case .toolResult(let r) = $0 { return r.textContent }; return nil }.joined()
        XCTAssertTrue(result.contains("Replaced by a newer card"), result)
        await s.stop()
    }

    func testTheChatAGoalWasStartedInCountsAsTheGoals() async throws {
        let propose = ToolCall(id: ToolCallID("g1"), name: "propose_goal", arguments: ["title": "Grow the open-source audience", "outcome": "1,000 GitHub stars"])
        let s = try await service(ScriptedProvider([.init(toolCalls: [propose]), .init(text: "Proposed."), .init(text: "Working.")]))
        let agents = try await s.store.listAgents(includeRetired: false)
        let agent = try XCTUnwrap(agents.first { $0.kind == .persistent })
        let (_, _, task) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Start a goal to promote the launch", attachments: [])
        try await wait(s, task, .completed)
        let cards = try await s.runtime.pendingApprovals()
        let proposal = try XCTUnwrap(cards.first)
        try await s.runtime.decideApproval(ApprovalDecision(approvalID: proposal.request.id, verdict: .approve), by: MessageAuthor(id: PersonID("owner"), name: "Owner"))
        let goals = try await s.goals.list()
        let goal = try XCTUnwrap(goals.first)
        let goalThread = try XCTUnwrap(goal.conversationID)
        let (_, _, work) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: goalThread, text: "Work on it", attachments: [])
        try await wait(s, work, .completed)

        let fromGoal = reply(work, "Decision: which launch week", to: "Decision for the owner · launch timing")
        _ = try await s.runtime.makeRoom(for: fromGoal, taskID: work, replaces: [], alongside: false)
        try await s.runtime.postApproval(taskID: work, fromGoal)

        // Drafted in the chat the goal was started in: still the goal's, so the waiting card has to be decided about.
        let fromChat = reply(task, "Decision: launch on Tuesday", to: "Decision for the owner · launch day")
        do {
            _ = try await s.runtime.makeRoom(for: fromChat, taskID: task, replaces: [], alongside: false)
            XCTFail("the goal's card was ignored")
        } catch {
            XCTAssertTrue("\(error)".contains("Grow the open-source audience") && "\(error)".contains("which launch week"), "\(error)")
        }
        await s.stop()
    }

    func testTheGatesCardsBeforeOneCommandAreNeverReplaced() {
        var signOff = ApprovalRequest(taskID: TaskID(), title: "Spend money: Pennant wants to run a command", destination: "shell", text: "stripe charge")
        signOff.approveLabel = ApprovalRequest.signOffLabel
        var command = ApprovalRequest(taskID: TaskID(), title: "Delete: run a command", destination: "Coding", text: "git push --delete")
        command.approveLabel = ApprovalRequest.commandLabel
        XCTAssertFalse(signOff.isAgentProposal)
        XCTAssertFalse(command.isAgentProposal)
        XCTAssertTrue(ApprovalRequest(taskID: TaskID(), title: "Reply", destination: "Outlook", text: "Hi").isAgentProposal)
    }
}
